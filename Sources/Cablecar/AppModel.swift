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
        if let path = UserDefaults.standard.string(forKey: Self.destinationDefaultsKey) {
            destination = URL(fileURLWithPath: path, isDirectory: true)
        }
        source.delegate = self
    }

    func start() { source.start() }

    // MARK: - Selection

    var selectedItems: [MediaItem] {
        items.filter { selection.contains($0.id) }
    }

    var selectedTotalBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.totalSizeBytes }
    }

    func toggleSelection(of item: MediaItem) {
        guard item.isOnDevice else { return }
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    /// Selects everything currently visible — skipping not-on-device items,
    /// per design.
    func selectAllVisible() {
        selection = Set(visibleItems.filter(\.isOnDevice).map(\.id))
    }

    func deselectAll() { selection = [] }

    // MARK: - Thumbnails

    func requestThumbnail(for itemID: MediaItem.ID) {
        guard thumbnails[itemID] == nil else { return }
        source.requestThumbnail(for: itemID)
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
        rebuildVisibleItems()
    }

    func mediaSource(_ source: any MediaSource, didLoadThumbnail thumbnail: CGImage?, for itemID: MediaItem.ID) {
        if let thumbnail { thumbnails[itemID] = thumbnail }
    }
}
