import AppKit
import SwiftUI

struct MediaGridView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]

    var body: some View {
        ScrollView {
            if model.visibleItems.isEmpty {
                emptyFilterState
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.visibleItems) { item in
                        MediaCell(
                            item: item,
                            thumbnail: model.thumbnails[item.id],
                            isSelected: model.selection.contains(item.id),
                            isInspected: model.inspectedItemID == item.id,
                            squareThumbnails: model.squareThumbnails
                        )
                        .onTapGesture {
                            let modifiers = NSEvent.modifierFlags
                            model.handleClick(
                                item,
                                shiftPressed: modifiers.contains(.shift),
                                commandPressed: modifiers.contains(.command)
                            )
                        }
                        .onAppear { model.requestThumbnail(for: item.id) }
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyFilterState: some View {
        VStack(spacing: 8) {
            Text(emptyFilterText)
                .font(.title3)
                .foregroundStyle(.secondary)
            if model.filter == .slowMo || model.filter == .timeLapse {
                // Spike caveat: these flags may not survive PTP on all rolls.
                Text("Note: some iPhones don’t report slow-mo/time-lapse flags over USB.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var emptyFilterText: String {
        var parts: [String] = []
        if model.orientationFilter != .any {
            parts.append(model.orientationFilter.rawValue.lowercased())
        }
        if model.filter != .all {
            parts.append(model.filter.rawValue.lowercased())
        }
        let what = parts.isEmpty ? "items" : parts.joined(separator: " ") + " items"
        return "No \(what)"
    }
}

struct MediaCell: View {
    let item: MediaItem
    let thumbnail: CGImage?
    let isSelected: Bool
    let isInspected: Bool
    let squareThumbnails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The tile itself is always square so rows stay aligned no matter
            // the media orientation; the toggle only changes crop vs letterbox.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { thumbnailView }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { selectionBadge }
                .overlay(alignment: .bottomLeading) { kindBadge }
                .overlay(alignment: .center) { notOnDeviceBadge }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(borderColor, lineWidth: 3)
                }

            Text(item.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detailLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .opacity(item.isOnDevice ? 1 : 0.4)
        .help(item.isOnDevice ? item.displayName : "\(item.displayName) — original is in iCloud, not on the phone")
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            if squareThumbnails {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: item.kind.isVideo ? "video" : "photo")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .shadow(radius: 1)
                .padding(6)
        }
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isInspected { return .secondary.opacity(0.5) }
        return .clear
    }

    @ViewBuilder
    private var kindBadge: some View {
        Group {
            switch item.kind {
            case .video:
                if let duration = item.duration { badgeLabel(formatDuration(duration)) }
            case .slowMoVideo:
                badgeLabel("SLO-MO")
            case .timeLapseVideo:
                badgeLabel("TIMELAPSE")
            case .livePhoto:
                badgeLabel("LIVE")
            case .photo:
                EmptyView()
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private var notOnDeviceBadge: some View {
        if !item.isOnDevice {
            VStack(spacing: 4) {
                Image(systemName: "icloud.slash")
                Text("Not on device").font(.caption2.bold())
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold().monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }

    private var detailLine: String {
        var parts = [ByteCountFormatter.string(fromByteCount: item.totalSizeBytes, countStyle: .file)]
        if let date = item.creationDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
