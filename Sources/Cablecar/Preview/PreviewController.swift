import AVFoundation
import Foundation
import Observation

/// Quick Look-style preview state. PTP can't stream, so previewing means
/// downloading the original into a session cache first (read-only toward the
/// phone, like every download). Files are cached per item so re-opening a
/// preview is instant; the cache is wiped on launch. While the preview is
/// idle-and-ready, the neighbouring items are prefetched so arrow-key
/// navigation is instant too.
///
/// Video playback lives here (not in the view) so the app-wide Space shortcut
/// can toggle it and the scrub controls stay outside the zoomable surface.
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
        clearPlayer()
        isPresented = false
        state = .idle
    }

    /// Cancels the in-flight preview or prefetch download. Safe to call
    /// anytime: the source's active download can only be ours while we are
    /// loading or prefetching (imports never run concurrently with either).
    func abortLoading(source: any MediaSource) {
        loadGeneration += 1
        prefetchTask?.cancel()
        prefetchTask = nil
        if prefetchDownloadActive {
            source.cancelActiveDownload()
            prefetchDownloadActive = false
        }
        if case .loading = state {
            source.cancelActiveDownload()
            state = .idle
        }
    }

    /// Shows `item` in the open preview, downloading it if not cached yet.
    func load(_ item: MediaItem, source: any MediaSource, importRunning: Bool) {
        guard isPresented else { return }
        currentFilename = item.displayName
        clearPlayer()
        abortLoading(source: source)
        let generation = loadGeneration
        let isVideo = item.kind.isVideo

        guard item.isOnDevice else {
            state = .failed(itemID: item.id, message: "This item is not on the device — the original is in iCloud.")
            return
        }

        if let cachedURL = cachedURL(for: item) {
            enterReady(item: item, url: cachedURL, isVideo: isVideo, source: source, importRunning: importRunning)
            return
        }

        guard !importRunning else {
            state = .failed(itemID: item.id, message: "Preview is unavailable while an import is running.")
            return
        }

        state = .loading(itemID: item.id, progress: 0)
        Task {
            do {
                let finalURL = try await download(item, from: source) { progress in
                    guard self.loadGeneration == generation else { return }
                    self.state = .loading(itemID: item.id, progress: progress)
                }
                guard loadGeneration == generation else {
                    try? FileManager.default.removeItem(at: finalURL)
                    return
                }
                enterReady(item: item, url: finalURL, isVideo: isVideo, source: source, importRunning: importRunning)
            } catch is CancellationError {
                // Superseded by another item or dismissed — nothing to do.
            } catch {
                guard loadGeneration == generation else { return }
                state = .failed(itemID: item.id, message: error.localizedDescription)
            }
        }
    }

    private func enterReady(item: MediaItem, url: URL, isVideo: Bool, source: any MediaSource, importRunning: Bool) {
        state = .ready(itemID: item.id, url: url, isVideo: isVideo)
        if isVideo {
            setUpPlayer(url: url)
        }
        startPrefetch(source: source, importRunning: importRunning)
    }

    // MARK: - Video playback

    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    private var timeObserver: Any?
    private var playStateObservation: NSKeyValueObservation?
    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false

    var hasVideoPlayer: Bool { player != nil }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            // Replay from the start when the clip has finished.
            if duration > 0, currentTime >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    /// J/L-style relative seek, clamped to the clip's bounds.
    func skip(by seconds: Double) {
        guard let player else { return }
        let upperBound = duration > 0 ? duration : Double.greatestFiniteMagnitude
        let target = max(0, min(currentTime + seconds, upperBound))
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    func beginScrubbing() {
        guard player != nil else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
    }

    func scrub(to seconds: Double) {
        currentTime = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    func endScrubbing() {
        isScrubbing = false
        if wasPlayingBeforeScrub { player?.play() }
    }

    private func setUpPlayer(url: URL) {
        let player = AVPlayer(url: url)
        self.player = player
        currentTime = 0
        duration = 0
        playStateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in self?.isPlaying = playing }
        }
        // [weak self] on the outer closure: the player retains it, and self
        // retains the player — a strong capture would be a cycle.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds
                if let itemDuration = self.player?.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }
        player.play()
    }

    private func clearPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        playStateObservation = nil
        player?.pause()
        player = nil
        isPlaying = false
        isScrubbing = false
        currentTime = 0
        duration = 0
    }

    // MARK: - Neighbour prefetch

    private var prefetchCandidates: [MediaItem] = []
    private var prefetchTask: Task<Void, Never>?
    private var prefetchDownloadActive = false

    /// Items to warm the cache with once the current preview is ready —
    /// typically the arrow-key neighbours of the shown item.
    func setPrefetchCandidates(_ items: [MediaItem]) {
        prefetchCandidates = items
    }

    private func startPrefetch(source: any MediaSource, importRunning: Bool) {
        guard !importRunning else { return }
        prefetchTask?.cancel()
        let candidates = prefetchCandidates.filter { $0.isOnDevice && cachedURL(for: $0) == nil }
        guard !candidates.isEmpty else { return }
        prefetchTask = Task {
            for item in candidates {
                guard !Task.isCancelled, isPresented else { return }
                guard case .ready = state else { return }
                prefetchDownloadActive = true
                defer { prefetchDownloadActive = false }
                do {
                    _ = try await download(item, from: source) { _ in }
                } catch {
                    return  // cancelled or source busy — stop quietly
                }
            }
        }
    }

    // MARK: - Cache

    /// Downloads into the cache under a `.part` name, then moves into place.
    /// Returns the final cached URL.
    private func download(
        _ item: MediaItem,
        from source: any MediaSource,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let partialURL = try await source.downloadFile(
            item.id, to: cacheDirectory, saveAs: cacheFilename(for: item) + ".part"
        ) { downloaded, total in
            let expected = total > 0 ? total : item.sizeBytes
            progress(expected > 0 ? Double(downloaded) / Double(expected) : 0)
        }
        let finalURL = cacheDirectory.appendingPathComponent(cacheFilename(for: item))
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        return finalURL
    }

    private func cachedURL(for item: MediaItem) -> URL? {
        let url = cacheDirectory.appendingPathComponent(cacheFilename(for: item))
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64,
              size == item.sizeBytes else { return nil }
        return url
    }

    /// Keeps the display name (and thus the extension, which image decoding
    /// and AVPlayer rely on for type detection) while making the id
    /// filesystem-safe.
    private func cacheFilename(for item: MediaItem) -> String {
        let safeID = String(item.id.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return "\(safeID)-\(item.displayName)"
    }
}
