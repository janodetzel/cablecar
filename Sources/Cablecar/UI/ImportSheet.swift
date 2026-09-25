import SwiftUI

/// Progress while an import runs, then the end-of-import summary.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.importEngine.isRunning {
                progressBody
            } else if let summary = model.importSummary {
                SummaryView(summary: summary)
                HStack {
                    Spacer()
                    Button("Done") { model.dismissImportSheet() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                ProgressView("Preparing import…")
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(model.importEngine.isRunning)
    }

    private var progressBody: some View {
        let engine = model.importEngine
        return VStack(alignment: .leading, spacing: 12) {
            Text("Importing…").font(.headline)

            ProgressView(value: engine.overallProgress) {
                HStack {
                    Text("\(engine.completedFiles) of \(engine.totalFiles) files")
                    Spacer()
                    Text(bytesLine(engine)).monospacedDigit()
                }
                .font(.callout)
            }

            if let name = engine.currentFilename {
                Text(name)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.cancelImport() }
            }
        }
    }

    private func bytesLine(_ engine: ImportEngine) -> String {
        let done = ByteCountFormatter.string(
            fromByteCount: engine.completedBytes + engine.currentFileBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: engine.totalBytes, countStyle: .file)
        return "\(done) / \(total)"
    }
}

struct SummaryView: View {
    let summary: ImportSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                summary.cancelled ? "Import cancelled" : "Import finished",
                systemImage: summary.cancelled ? "xmark.circle" : "checkmark.circle"
            )
            .font(.headline)
            .foregroundStyle(summary.cancelled ? .orange : .green)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                countRow("Imported", summary.imported)
                countRow("Skipped (already in folder)", summary.skippedExisting)
                countRow("Skipped (not on device)", summary.skippedNotOnDevice)
                countRow("Failed", summary.failures.count)
            }
            .font(.callout)

            if !summary.failures.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.failures, id: \.filename) { failure in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(failure.filename).font(.callout.monospaced())
                                Text(failure.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private func countRow(_ label: String, _ count: Int) -> some View {
        GridRow {
            Text(label)
            Text("\(count)").monospacedDigit().gridColumnAlignment(.trailing)
        }
        .foregroundStyle(count == 0 ? .secondary : .primary)
    }
}
