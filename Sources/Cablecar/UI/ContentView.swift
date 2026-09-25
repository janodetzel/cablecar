import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if case .ready = model.sourceState {
                MediaGridView()
            } else {
                SourceStatusView(state: model.sourceState)
            }
        }
        .safeAreaInset(edge: .bottom) { FooterBar() }
        // Overlay after the footer inset so an open preview covers it too;
        // the inspector stays visible beside the preview.
        .overlay {
            if model.preview.isPresented {
                PreviewOverlay()
            }
        }
        .inspector(isPresented: $model.showInspector) {
            MetadataSidebar()
                .inspectorColumnWidth(min: 220, ideal: 280, max: 400)
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showImportSheet) { ImportSheet() }
        .navigationTitle("Cablecar")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        switch model.sourceState {
        case .ready(let name): return name
        default: return ""
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model

        ToolbarItemGroup {
            Picker("Filter", selection: $model.filter) {
                ForEach(MediaFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            // A Menu instead of a bare toolbar Picker: the latter renders an
            // empty label until first clicked.
            Menu {
                Picker("Orientation", selection: $model.orientationFilter) {
                    ForEach(OrientationFilter.allCases) { orientation in
                        Text(orientation.rawValue).tag(orientation)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.orientationFilter.rawValue)
            }
            .help("Filter by media orientation")

            Menu {
                Picker("Sort by", selection: $model.sortKey) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.rawValue).tag(key)
                    }
                }
                Divider()
                Picker("Order", selection: $model.sortAscending) {
                    Text("Newest first").tag(false)
                    Text("Oldest first").tag(true)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }

            Button {
                model.squareThumbnails.toggle()
            } label: {
                Label(
                    model.squareThumbnails ? "Full Aspect Ratio" : "Square Thumbnails",
                    systemImage: model.squareThumbnails ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward"
                )
            }
            .help(model.squareThumbnails
                ? "Show thumbnails in their full aspect ratio"
                : "Show thumbnails as squares")
        }

        ToolbarItemGroup {
            Button("Select All") { model.selectAllVisible() }
                .disabled(model.visibleItems.isEmpty)
            Button("Deselect") { model.deselectAll() }
                .disabled(model.selection.isEmpty)
        }

        ToolbarItemGroup {
            Button {
                _ = model.chooseDestination()
            } label: {
                Label(
                    model.destination?.lastPathComponent ?? "Choose Folder…",
                    systemImage: "folder"
                )
            }
            .help(model.destination?.path ?? "Choose the destination folder")

            Button {
                model.startImport()
            } label: {
                Label(importButtonTitle, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canImport)
        }

        ToolbarItem {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .help(model.showInspector ? "Hide item info" : "Show item info")
        }
    }

    private var importButtonTitle: String {
        let count = model.selection.count
        guard count > 0 else { return "Import" }
        let size = ByteCountFormatter.string(fromByteCount: model.selectedTotalBytes, countStyle: .file)
        return "Import \(count) (\(size))"
    }
}

/// Full-window status while no device catalog is available.
struct SourceStatusView: View {
    let state: SourceState

    var body: some View {
        VStack(spacing: 12) {
            switch state {
            case .waitingForDevice:
                Image(systemName: "cable.connector")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Connect your iPhone").font(.title2.bold())
                Text("Plug the phone in via USB. Unlock it and tap Trust if asked.")
                    .foregroundStyle(.secondary)
            case .connecting(let name):
                ProgressView()
                Text("Connecting to \(name)…").font(.title3)
            case .locked(let name):
                Image(systemName: "lock.iphone")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("\(name) is locked").font(.title2.bold())
                Text("Unlock the phone with the cable connected — the camera roll loads automatically.\nIf no Trust prompt appears, unplug and replug the cable.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .loadingCatalog(let name):
                ProgressView()
                Text("Loading camera roll from \(name)…").font(.title3)
            case .ready:
                EmptyView()
            case .failed(let name, let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Couldn’t connect to \(name)").font(.title2.bold())
                Text("\(message)\nRetrying automatically — or unplug and replug the cable.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom bar: catalog counts plus the source's plainly-stated limitations.
struct FooterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            if !model.items.isEmpty {
                Text(counts).monospacedDigit()
            }
            Spacer()
            Text(model.source.limitationsNote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var counts: String {
        var parts = ["\(model.items.count) items", "\(model.photoCount) photos", "\(model.videoCount) videos"]
        if model.notOnDeviceCount > 0 {
            parts.append("\(model.notOnDeviceCount) not on device")
        }
        if !model.selection.isEmpty {
            parts.append("\(model.selection.count) selected")
        }
        return parts.joined(separator: " · ")
    }
}
