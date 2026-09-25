import AppKit
import CoreGraphics
import Foundation
import Observation

/// Observable state for the whole app: mirrors the media source, and owns
/// selection, filtering, sorting, thumbnails, destination, and imports.
@MainActor
@Observable
final class AppModel {
    private static let destinationDefaultsKey = "destinationPath"

    let source: any MediaSource
    let importEngine = ImportEngine()
    let preview = PreviewController()

    /// Column count of the media grid, reported by the view; drives up/down
    /// arrow navigation.
    var gridColumns = 1

    private(set) var sourceState: SourceState = .waitingForDevice
    private(set) var items: [MediaItem] = []
    private(set) var thumbnails: [MediaItem.ID: CGImage] = [:]

    var selection: Set<MediaItem.ID> = []
    var filter: MediaFilter = .all {
        didSet { rebuildVisibleItems() }
    }
    var orientationFilter: OrientationFilter = .any {
        didSet { rebuildVisibleItems() }
    }
    var sortKey: SortKey = .date {
        didSet { rebuildVisibleItems() }
    }
    var sortAscending = false {
        didSet { rebuildVisibleItems() }
    }

    /// Photos-app-style thumbnail rendering: square-cropped or the item's full
    /// aspect ratio letterboxed in the tile. Remembered between launches.
    var squareThumbnails: Bool {
        didSet { UserDefaults.standard.set(squareThumbnails, forKey: Self.squareThumbnailsDefaultsKey) }
    }
    private static let squareThumbnailsDefaultsKey = "squareThumbnails"

    var showInspector: Bool {
        didSet { UserDefaults.standard.set(showInspector, forKey: Self.showInspectorDefaultsKey) }
    }
    private static let showInspectorDefaultsKey = "showInspector"

    /// The item whose details the inspector shows: the last one clicked.
    var inspectedItemID: MediaItem.ID?
    /// Device metadata per item, filled lazily on inspection. `nil` = not
    /// loaded yet; `[]` = the device reported none.
    private(set) var metadata: [MediaItem.ID: [MetadataSection]] = [:]

    var inspectedItem: MediaItem? {
        inspectedItemID.flatMap { id in items.first { $0.id == id } }
    }

    private(set) var visibleItems: [MediaItem] = []

    var destination: URL? {
        didSet {
            UserDefaults.standard.set(destination?.path, forKey: Self.destinationDefaultsKey)
        }
    }

    var showImportSheet = false
    private(set) var importSummary: ImportSummary?

    init(source: any MediaSource) {
        self.source = source
        squareThumbnails = UserDefaults.standard.object(forKey: Self.squareThumbnailsDefaultsKey) as? Bool ?? true
        showInspector = UserDefaults.standard.object(forKey: Self.showInspectorDefaultsKey) as? Bool ?? false
        if let path = UserDefaults.standard.string(forKey: Self.destinationDefaultsKey) {
            destination = URL(fileURLWithPath: path, isDirectory: true)
        }
        source.delegate = self
    }

    func start() {
        source.start()
        installKeyboardShortcuts()
    }

    // MARK: - Keyboard shortcuts

    private var keyMonitor: Any?

    /// ⌘A = select all visible, Escape = deselect all. A local NSEvent monitor
    /// is used instead of SwiftUI key handling so the shortcuts work without
    /// fighting the default Edit menu or view focus.
    private func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            // Only real modifier keys: arrow keys always carry .function and
            // .numericPad, which must not disqualify the plain-key checks.
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            let characters = event.charactersIgnoringModifiers
            let isRepeat = event.isARepeat
            let handled = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self, NSApp.keyWindow?.attachedSheet == nil else { return false }
                // Leave text editing (e.g. a future search field) alone.
                if NSApp.keyWindow?.firstResponder is NSTextView { return false }

                if keyCode == 53, modifiers.isEmpty {  // Escape
                    if preview.isPresented {
                        preview.dismiss(source: source)
                        return true
                    }
                    if !selection.isEmpty {
                        deselectAll()
                        return true
                    }
                    return false
                }
                if keyCode == 49, modifiers.isEmpty, !isRepeat {  // Space
                    if preview.isPresented {
                        // Space controls video playback; Esc closes. For
                        // images, space still closes, Finder-style.
                        if preview.hasVideoPlayer {
                            preview.togglePlayback()
                        } else {
                            preview.dismiss(source: source)
                        }
                        return true
                    }
                    guard inspectedItem != nil else { return false }
                    togglePreview()
                    return true
                }
                if modifiers.isEmpty {
                    let direction: NavigationDirection?
                    switch keyCode {
                    case 123: direction = .left
                    case 124: direction = .right
                    case 125: direction = .down
                    case 126: direction = .up
                    default: direction = nil
                    }
                    if let direction, !visibleItems.isEmpty {
                        navigateSelection(direction)
                        return true
                    }
                }
                if modifiers == .command, characters == "a" {
                    selectAllVisible()
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }

    // MARK: - Selection
    //
    // Finder-style model. Plain click selects just that item (and inspects
    // it), cmd-click toggles items in and out, shift-click selects a live
    // range from the anchor, ⌘A selects everything visible, Escape deselects.
    // The inspector shows metadata for single items and a summary once more
    // than one is selected.

    var isMultipleSelection: Bool { selection.count > 1 }

    /// Range anchor for shift-clicks: the last tile whose selection state was
    /// changed by a direct click.
    private var selectionAnchorID: MediaItem.ID?
    /// What the last shift-click selected. The range is "live" (Finder-style):
    /// the next shift-click from the same anchor replaces it, so clicking
    /// inside the range shrinks it.
    private var shiftRangeIDs: Set<MediaItem.ID> = []

    var selectedItems: [MediaItem] {
        items.filter { selection.contains($0.id) }
    }

    var selectedTotalBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.totalSizeBytes }
    }

    /// A click on a tile, dispatched by modifier keys.
    func handleClick(_ item: MediaItem, shiftPressed: Bool, commandPressed: Bool = false) {
        if shiftPressed {
            extendSelection(to: item)
        } else if commandPressed {
            inspect(item)
            toggleSelection(of: item)
        } else {
            inspect(item)
            replaceSelection(with: item)
        }
    }

    /// Plain click: this item becomes the whole selection (or none, for a
    /// not-on-device item — it still gets inspected).
    private func replaceSelection(with item: MediaItem) {
        selection = item.isOnDevice ? [item.id] : []
        selectionAnchorID = item.isOnDevice ? item.id : nil
        shiftRangeIDs = []
    }

    /// Cmd-click: toggles the item, keeping the rest of the selection.
    func toggleSelection(of item: MediaItem) {
        guard item.isOnDevice else { return }
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        selectionAnchorID = selection.isEmpty ? nil : item.id
        shiftRangeIDs = []
    }

    /// Shift-click: selects every on-device item between the anchor and
    /// `item` in the current visible order, replacing whatever the previous
    /// shift-click from that anchor selected (so a shift-click inside the
    /// current range shrinks it, like Finder). Without an anchor it just
    /// starts the selection at `item`.
    private func extendSelection(to item: MediaItem) {
        guard item.isOnDevice else { return }
        guard
            let anchorID = selectionAnchorID,
            let anchorIndex = visibleItems.firstIndex(where: { $0.id == anchorID }),
            let itemIndex = visibleItems.firstIndex(where: { $0.id == item.id })
        else {
            selection.insert(item.id)
            selectionAnchorID = item.id
            shiftRangeIDs = []
            return
        }
        let range = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
        let newRange = Set(visibleItems[range].filter(\.isOnDevice).map(\.id))
        selection.subtract(shiftRangeIDs)
        selection.formUnion(newRange)
        shiftRangeIDs = newRange
    }

    /// Selects everything currently visible — skipping not-on-device items,
    /// per design.
    func selectAllVisible() {
        selection = Set(visibleItems.filter(\.isOnDevice).map(\.id))
        shiftRangeIDs = []
    }

    func deselectAll() {
        selection = []
        selectionAnchorID = nil
        shiftRangeIDs = []
    }

    // MARK: - Thumbnails

    func requestThumbnail(for itemID: MediaItem.ID) {
        guard thumbnails[itemID] == nil else { return }
        source.requestThumbnail(for: itemID)
    }

    // MARK: - Inspection

    /// Marks an item as inspected (works for not-on-device items too) and
    /// lazily fetches its device metadata. An open preview follows along.
    func inspect(_ item: MediaItem) {
        inspectedItemID = item.id
        requestThumbnail(for: item.id)
        if metadata[item.id] == nil {
            source.requestMetadata(for: item.id)
        }
        if preview.isPresented {
            preview.setPrefetchCandidates(previewNeighbors(of: item))
            preview.load(item, source: source, importRunning: importEngine.isRunning)
        }
    }

    // MARK: - Preview & arrow-key navigation

    func togglePreview() {
        if let item = inspectedItem, !preview.isPresented {
            preview.setPrefetchCandidates(previewNeighbors(of: item))
        }
        preview.toggle(inspectedItem, source: source, importRunning: importEngine.isRunning)
    }

    /// The items arrow keys reach next — warmed in the preview cache so
    /// navigation feels instant. Horizontal neighbours first, then vertical.
    private func previewNeighbors(of item: MediaItem) -> [MediaItem] {
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return [] }
        let columns = max(gridColumns, 1)
        return [1, -1, columns, -columns].compactMap { offset in
            let target = index + offset
            return visibleItems.indices.contains(target) ? visibleItems[target] : nil
        }
    }

    enum NavigationDirection {
        case left, right, up, down
    }

    /// Arrow keys move the selection through the grid (Finder-style), also
    /// while the preview is open. Left/right step one item, up/down one row.
    func navigateSelection(_ direction: NavigationDirection) {
        guard !visibleItems.isEmpty else { return }
        guard
            let currentID = inspectedItemID,
            let currentIndex = visibleItems.firstIndex(where: { $0.id == currentID })
        else {
            selectNavigating(to: visibleItems[0])
            return
        }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -max(gridColumns, 1)
        case .down: step = max(gridColumns, 1)
        }
        let target = currentIndex + step
        guard visibleItems.indices.contains(target) else { return }
        selectNavigating(to: visibleItems[target])
    }

    private func selectNavigating(to item: MediaItem) {
        inspect(item)
        replaceSelection(with: item)
    }

    // MARK: - Import

    var canImport: Bool {
        if case .ready = sourceState {
            return !selection.isEmpty && !importEngine.isRunning
        }
        return false
    }

    func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder to import into"
        if let destination { panel.directoryURL = destination }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        destination = url
        return url
    }

    func startImport() {
        guard canImport else { return }
        guard let destination = destination ?? chooseDestination() else { return }
        let items = selectedItems
        // The source handles one download at a time — never race a preview
        // fetch against the import.
        preview.dismiss(source: source)
        importSummary = nil
        showImportSheet = true
        Task {
            importSummary = await importEngine.run(items: items, from: source, into: destination)
        }
    }

    func cancelImport() { importEngine.cancel() }

    func dismissImportSheet() {
        guard !importEngine.isRunning else { return }
        showImportSheet = false
        importSummary = nil
    }

    // MARK: - Derived counts for the footer

    var photoCount: Int { items.filter { !$0.kind.isVideo }.count }
    var videoCount: Int { items.filter { $0.kind.isVideo }.count }
    var notOnDeviceCount: Int { items.filter { !$0.isOnDevice }.count }

    private func rebuildVisibleItems() {
        let filtered = items.filter { filter.matches($0) && orientationFilter.matches($0) }
        visibleItems = MediaSorter.sort(filtered, by: sortKey, ascending: sortAscending)
    }
}

extension AppModel: MediaSourceDelegate {
    func mediaSourceDidChangeState(_ source: any MediaSource) {
        sourceState = source.state
    }

    func mediaSourceDidUpdateItems(_ source: any MediaSource) {
        items = source.items
        let ids = Set(items.map(\.id))
        selection.formIntersection(ids)
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        metadata = metadata.filter { ids.contains($0.key) }
        if let inspectedItemID, !ids.contains(inspectedItemID) {
            self.inspectedItemID = nil
            if preview.isPresented {
                preview.dismiss(source: source)
            }
        }
        if let selectionAnchorID, !ids.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        shiftRangeIDs.formIntersection(ids)
        rebuildVisibleItems()
    }

    func mediaSource(_ source: any MediaSource, didLoadThumbnail thumbnail: CGImage?, for itemID: MediaItem.ID) {
        if let thumbnail { thumbnails[itemID] = thumbnail }
    }

    func mediaSource(_ source: any MediaSource, didLoadMetadata sections: [MetadataSection]?, for itemID: MediaItem.ID) {
        metadata[itemID] = sections ?? []
    }
}
