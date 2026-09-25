import SwiftUI

/// Trailing inspector showing details for the last-clicked item: catalog
/// facts immediately, full device metadata (EXIF/TIFF/GPS) once fetched.
struct MetadataSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isMultipleSelection {
                selectionSummary
            } else if let item = model.inspectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        preview(item)
                        Text(item.displayName)
                            .font(.headline)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        section(MetadataSection(title: "General", fields: generalFields(item)))
                        deviceMetadata(item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Click an item to see its details")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    /// With more than one item selected, per-item metadata makes no sense —
    /// show what the selection amounts to instead.
    private var selectionSummary: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
            Text("\(model.selection.count) items selected")
                .font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: model.selectedTotalBytes, countStyle: .file))
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Click a single item to see its metadata.\nEscape deselects all.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Deselect All") { model.deselectAll() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func preview(_ item: MediaItem) -> some View {
        if let thumbnail = model.thumbnails[item.id] {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 180)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(height: 120)
                .overlay {
                    Image(systemName: item.kind.isVideo ? "video" : "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder
    private func deviceMetadata(_ item: MediaItem) -> some View {
        if let sections = model.metadata[item.id] {
            if sections.isEmpty {
                Text("No additional metadata reported by the device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sections, id: \.title) { section(  $0) }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading metadata…").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private func section(_ section: MetadataSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(section.fields, id: \.self) { field in
                LabeledContent(field.label) {
                    Text(field.value)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .font(.callout)
            }
            Divider()
        }
    }

    private func generalFields(_ item: MediaItem) -> [MetadataField] {
        var fields = [MetadataField(label: "Kind", value: item.kind.displayLabel)]
        if item.orientation != .unknown {
            fields.append(.init(label: "Dimensions", value: "\(item.pixelWidth) × \(item.pixelHeight)"))
        }
        fields.append(.init(
            label: "Size",
            value: ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
        ))
        if let date = item.creationDate {
            fields.append(.init(label: "Created", value: date.formatted(date: .abbreviated, time: .shortened)))
        }
        if let duration = item.duration {
            let total = Int(duration.rounded())
            fields.append(.init(label: "Duration", value: String(format: "%d:%02d", total / 60, total % 60)))
        }
        for sidecar in item.sidecars {
            fields.append(.init(
                label: "Sidecar",
                value: "\(sidecar.filename) (\(ByteCountFormatter.string(fromByteCount: sidecar.sizeBytes, countStyle: .file)))"
            ))
        }
        if !item.isOnDevice {
            fields.append(.init(label: "Availability", value: "Not on device (original in iCloud)"))
        }
        return fields
    }
}

extension MediaKind {
    var displayLabel: String {
        switch self {
        case .photo: return "Photo"
        case .livePhoto: return "Live Photo"
        case .video: return "Video"
        case .slowMoVideo: return "Slow-mo Video"
        case .timeLapseVideo: return "Time-lapse Video"
        }
    }
}
