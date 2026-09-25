import Foundation
import Observation

/// Quick Look-style preview state. PTP can't stream, so previewing means
/// downloading the original into a session cache first (read-only toward the
/// phone, like every download). Files are cached per item so re-opening a
/// preview is instant; the cache is wiped on launch.
@MainActor
@Observable
final class PreviewController {
    enum State {
        case idle
        case loading(itemID: MediaItem.ID, progress: Double)
        case ready(itemID: MediaItem.ID, url: URL, isVideo: Bool)
        case failed(itemID: MediaItem.ID, message: String)
    }

    private(set) var isPresented = false
    private(set) var state: State = .idle
    private(set) var currentFilename = ""

    private let cacheDirectory: URL
    /// Bumped whenever the current load is superseded (item switch, dismiss),
    /// so stale download completions are ignored.
    private var loadGeneration = 0

    init() {
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CablecarPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func toggle(_ item: MediaItem?, source: any MediaSource, importRunning: Bool) {
        if isPresented {
            dismiss(source: source)
        } else if let item {
            isPresented = true
            load(item, source: source, importRunning: importRunning)
        }
    }

    func dismiss(source: any MediaSource) {
        abortLoading(source: source)
        isPresented = false
        state = .idle
    }

    /// Cancels an in-flight preview download. Safe to call anytime: the
    /// source's active download can only be ours while we are in `.loading`
    /// (imports never run concurrently with a preview load).
    func abortLoading(source: any MediaSource) {
        loadGeneration += 1
        if case .loading = state {
            source.cancelActiveDownload()
            state = .idle
        }
    }

    /// Shows `item` in the open preview, downloading it if not cached yet.
    func load(_ item: MediaItem, source: any MediaSource, importRunning: Bool) {
        guard isPresented else { return }
        currentFilename = item.displayName
        abortLoading(source: source)
        let generation = loadGeneration
        let isVideo = item.kind.isVideo

        guard item.isOnDevice else {
            state = .failed(itemID: item.id, message: "This item is not on the device — the original is in iCloud.")
            return
        }

        let finalURL = cacheDirectory.appendingPathComponent(cacheFilename(for: item))
        if let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size]) as? Int64,
           size == item.sizeBytes {
            state = .ready(itemID: item.id, url: finalURL, isVideo: isVideo)
            return
        }

        guard !importRunning else {
            state = .failed(itemID: item.id, message: "Preview is unavailable while an import is running.")
            return
        }

        state = .loading(itemID: item.id, progress: 0)
        Task {
            do {
                let partialURL = try await source.downloadFile(
                    item.id, to: cacheDirectory, saveAs: cacheFilename(for: item) + ".part"
                ) { downloaded, total in
                    guard self.loadGeneration == generation else { return }
                    let expected = total > 0 ? total : item.sizeBytes
                    self.state = .loading(
                        itemID: item.id,
                        progress: expected > 0 ? Double(downloaded) / Double(expected) : 0
                    )
                }
                guard loadGeneration == generation else {
                    try? FileManager.default.removeItem(at: partialURL)
                    return
                }
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
                state = .ready(itemID: item.id, url: finalURL, isVideo: isVideo)
            } catch is CancellationError {
                // Superseded by another item or dismissed — nothing to do.
            } catch {
                guard loadGeneration == generation else { return }
                state = .failed(itemID: item.id, message: error.localizedDescription)
            }
        }
    }

    /// Keeps the display name (and thus the extension, which NSImage/AVPlayer
    /// rely on for type detection) while making the id filesystem-safe.
    private func cacheFilename(for item: MediaItem) -> String {
        let safeID = String(item.id.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return "\(safeID)-\(item.displayName)"
    }
}
