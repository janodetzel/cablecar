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

    func start() { source.start() }

    // MARK: - Selection
    //
    // Photos-style two-mode model. Browse mode (nothing selected): clicking a
    // tile only inspects it; selection starts via the hover checkbox or a
    // shift-click. Selection mode (anything selected): plain clicks toggle,
    // shift-clicks extend a range from the last-clicked anchor, and the
    // inspector shows a selection summary instead of metadata.

    var isSelectionMode: Bool { !selection.isEmpty }

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

    /// A plain click on the tile body.
    func handleClick(_ item: MediaItem, shiftPressed: Bool) {
        if shiftPressed {
            extendSelection(to: item)
        } else if isSelectionMode {
            toggleSelection(of: item)
        } else {
            inspect(item)
        }
    }

    /// The hover checkbox: always toggles selection, entering selection mode
    /// from browse mode.
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
    /// lazily fetches its device metadata.
    func inspect(_ item: MediaItem) {
        inspectedItemID = item.id
        requestThumbnail(for: item.id)
        if metadata[item.id] == nil {
            source.requestMetadata(for: item.id)
        }
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
