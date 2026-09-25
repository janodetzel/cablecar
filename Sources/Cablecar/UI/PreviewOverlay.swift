import AppKit
import AVKit
import SwiftUI

/// Quick Look-style lightbox over the grid. Space toggles it, arrows navigate
/// (handled by the app-wide key monitor), pinch zooms, double-click resets.
struct PreviewOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.82))
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
            .help("Close preview (Space)")

            Text(model.preview.currentFilename)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("Space to close · ⬅︎➡︎⬆︎⬇︎ to navigate · Pinch to zoom")
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
                thumbnailBackdrop(for: itemID)
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
        case .ready(_, let url, let isVideo):
            ZoomableView {
                if isVideo {
                    VideoPreview(url: url)
                } else {
                    ImagePreview(url: url)
                }
            }
            .id(url)  // fresh zoom state and player per item
        }
    }

    /// The (small) grid thumbnail, blown up as a stand-in while the original
    /// downloads — same trick Photos uses, blur hides the upscaling.
    @ViewBuilder
    private func thumbnailBackdrop(for itemID: MediaItem.ID) -> some View {
        if let thumbnail = model.thumbnails[itemID] {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .blur(radius: 3)
                .opacity(0.7)
        }
    }
}

private struct ImagePreview: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text("Couldn’t decode \(url.lastPathComponent)")
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// AppKit AVPlayerView instead of SwiftUI's VideoPlayer: the _AVKit_SwiftUI
/// overlay crashes at runtime instantiating its generic metadata (SIGABRT in
/// getSuperclassMetadata) in this SwiftPM-built app. AVPlayerView provides the
/// same inline controls (scrubber, play/pause) natively.
private struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

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
