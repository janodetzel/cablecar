import AppKit
import AVKit
import ImageIO
import SwiftUI

/// Quick Look-style lightbox over the grid. Space toggles it (and toggles
/// play/pause for videos), Escape closes, arrows navigate (handled by the
/// app-wide key monitor), pinch zooms, double-click resets.
struct PreviewOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.preview.dismiss(source: model.source)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Close preview (Esc)")

            Text(model.preview.currentFilename)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("Esc to close · Space plays/pauses video · ⬅︎➡︎⬆︎⬇︎ to navigate · Pinch to zoom")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.preview.state {
        case .idle:
            Color.clear
        case .loading(let itemID, let progress):
            ZStack {
                thumbnailStandIn(for: itemID)
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 260)
                    Text("Loading original from the phone…")
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(20)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
        case .failed(_, let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 380)
        case .ready(let itemID, let url, let isVideo):
            if isVideo {
                videoContent
                    .id(url)
            } else {
                ZoomableView {
                    ImagePreview(url: url, standIn: model.thumbnails[itemID])
                }
                .id(url)  // fresh zoom state per item
            }
        }
    }

    /// Zoomable video surface with the controls kept outside the zoomed area,
    /// so scrubbing and play/pause stay usable at any zoom level.
    private var videoContent: some View {
        VStack(spacing: 10) {
            ZoomableView {
                ZStack {
                    VideoSurface(player: model.preview.player)
                    // AVPlayerView would swallow mouse events — this layer
                    // keeps pinch/pan/double-click working over the video.
                    Color.clear.contentShape(Rectangle())
                }
            }
            VideoControls()
        }
    }

    /// The (small) grid thumbnail, blown up as a stand-in while the original
    /// downloads — the blur hides the upscaling.
    @ViewBuilder
    private func thumbnailStandIn(for itemID: MediaItem.ID) -> some View {
        if let thumbnail = model.thumbnails[itemID] {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .blur(radius: 3)
        }
    }
}

// MARK: - Images

/// Full-resolution image, decoded off the main thread (a lazy NSImage decode
/// at draw time blocks the UI for seconds on large HEICs) and cached so
/// re-opening or arrowing back is instant. Shows the thumbnail while decoding.
private struct ImagePreview: View {
    let url: URL
    let standIn: CGImage?

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                Text("Couldn’t decode \(url.lastPathComponent)")
                    .foregroundStyle(.white.opacity(0.8))
            } else if let standIn {
                Image(decorative: standIn, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .blur(radius: 3)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            if let cached = PreviewImageCache.image(for: url) {
                image = cached
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                PreviewImageCache.decode(url)
            }.value
            if let decoded {
                PreviewImageCache.store(decoded, for: url)
                image = decoded
            } else {
                failed = true
            }
        }
    }
}

enum PreviewImageCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    static func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    static func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    /// Fully decodes the image at native size with the EXIF rotation applied,
    /// so drawing it later is cheap.
    static func decode(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var maxDimension = 16_384
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if max(width, height) > 0 { maxDimension = max(width, height) }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

// MARK: - Video

/// Bare video surface (no AVKit controls — ours live in `VideoControls`).
/// AppKit AVPlayerView instead of SwiftUI's VideoPlayer: the _AVKit_SwiftUI
/// overlay crashes at runtime instantiating its generic metadata (SIGABRT in
/// getSuperclassMetadata) in this SwiftPM-built app.
private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct VideoControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preview = model.preview
        HStack(spacing: 12) {
            Button {
                preview.togglePlayback()
            } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .help(preview.isPlaying ? "Pause (Space)" : "Play (Space)")

            Text(Self.timestamp(preview.currentTime))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

            Slider(
                value: Binding(
                    get: { min(preview.currentTime, preview.duration) },
                    set: { preview.scrub(to: $0) }
                ),
                in: 0...max(preview.duration, 0.01),
                onEditingChanged: { editing in
                    editing ? preview.beginScrubbing() : preview.endScrubbing()
                }
            )

            Text(Self.timestamp(preview.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Zoom & pan

/// Pinch-to-zoom (1×–8×) with drag-to-pan while zoomed; double-click resets.
private struct ZoomableView<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var committedZoom: CGFloat = 1
    @State private var activeZoom: CGFloat = 1
    @State private var committedOffset: CGSize = .zero
    @State private var activeOffset: CGSize = .zero

    private var zoom: CGFloat { committedZoom * activeZoom }

    var body: some View {
        content
            .scaleEffect(zoom)
            .offset(
                x: committedOffset.width + activeOffset.width,
                y: committedOffset.height + activeOffset.height
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnification)
            .simultaneousGesture(pan)
            .onTapGesture(count: 2) { reset() }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                activeZoom = value.magnification
            }
            .onEnded { value in
                committedZoom = min(max(committedZoom * value.magnification, 1), 8)
                activeZoom = 1
                if committedZoom == 1 { reset() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                activeOffset = value.translation
            }
            .onEnded { value in
                guard zoom > 1 else { return }
                committedOffset.width += value.translation.width
                committedOffset.height += value.translation.height
                activeOffset = .zero
            }
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.15)) {
            committedZoom = 1
            activeZoom = 1
            committedOffset = .zero
            activeOffset = .zero
        }
    }
}
