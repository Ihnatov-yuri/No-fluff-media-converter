import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VideoCompressorCore

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: AppMetric.gutter) {
            TopBar()

            SettingsPanel(settings: $viewModel.settings)

            QueuePanel(openPanel: openPanel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ActionBar(openPanel: openPanel)
        }
        .padding([.horizontal, .bottom], AppMetric.gutter)
        .ignoresSafeArea(.container, edges: .top)
        .background(LitField())
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $viewModel.isDropTargeted,
            perform: handleDrop(providers:)
        )
        .alert(
            "Media Compressor",
            isPresented: Binding(
                get: { viewModel.appError != nil },
                set: { if !$0 { viewModel.clearError() } }
            )
        ) {
            Button("OK") {
                viewModel.clearError()
            }
        } message: {
            Text(viewModel.appError ?? "")
        }
        .sheet(item: $viewModel.comparisonRequest) { request in
            ComparisonView(request: request)
                .environmentObject(viewModel)
                .tint(AppColor.accent)
                .preferredColorScheme(.light)
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .audiovisualContent,
            .movie,
            .mpeg4Movie,
            .quickTimeMovie,
            .audio,
            .wav,
            .mp3
        ]
        panel.prompt = "Add Files"

        if panel.runModal() == .OK {
            viewModel.addFiles(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }

                guard let url else { return }
                Task { @MainActor in
                    viewModel.addFiles([url])
                }
            }
        }
        return true
    }
}

// MARK: - Top bar

/// Sits in the hidden title bar, to the right of the traffic lights.
private struct TopBar: View {
    var body: some View {
        HStack(alignment: .center, spacing: AppMetric.m) {
            Wordmark(size: 15)
            Spacer()
            Link(destination: URL(string: "https://ihnatov.nl")!) {
                Text("by Yuri Ihnatov")
                    .uiLabel(12.5, color: AppColor.ink3)
            }
            .help("Open source and free. ihnatov.nl")
        }
        .padding(.leading, 68)
        .padding(.trailing, 6)
        .frame(height: 38)
    }
}

// MARK: - Settings

private struct SettingsPanel: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var settings: CompressionSettings

    var body: some View {
        VStack(alignment: .leading, spacing: AppMetric.m) {
            HStack(alignment: .bottom, spacing: AppMetric.gutter) {
                LabeledField("Mode") {
                    PillTabs(
                        options: CompressionMode.allCases.map { ($0, $0.displayName) },
                        selection: $settings.mode
                    )
                    .fixedSize()
                }

                if settings.mode == .quality {
                    LabeledField("Quality") {
                        LitMenuPicker(
                            options: QualityPreset.allCases.map { ($0, $0.displayName) },
                            selection: $settings.qualityPreset
                        )
                    }
                } else {
                    LabeledField("Target size") {
                        TargetSizeField(value: $settings.targetSizeMB)
                    }
                }

                LabeledField("Format") {
                    LitMenuPicker(
                        options: OutputPreset.allCases.map { ($0, $0.shortName) },
                        selection: $settings.outputPreset
                    )
                }

                LabeledField("Resolution") {
                    LitMenuPicker(
                        options: ResolutionCap.allCases.map { ($0, $0.displayName) },
                        selection: $settings.resolutionCap
                    )
                }
                .disabled(settings.outputPreset.isAudioOnly)

                LabeledField("Audio") {
                    LitMenuPicker(
                        options: AudioBitrate.allCases.map { ($0, $0.displayName) },
                        selection: $settings.audioBitrate
                    )
                }
                .help("Audio bitrate. AAC for MP4 and MOV, MP3 for MP3.")
            }

            Hairline()

            HStack(alignment: .center, spacing: AppMetric.m) {
                Toggle(isOn: $settings.speedUpSilence) {
                    Text("Speed up silence")
                        .font(AppFont.display(13.5, weight: .semibold))
                        .foregroundStyle(AppColor.ink)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(AppColor.accent)
                .help("Plays quiet stretches longer than a second faster while speech stays at normal pace. Good for lectures, meetings, and screen recordings.")

                if settings.speedUpSilence {
                    PillTabs(
                        options: SilenceSpeed.allCases.map { ($0, $0.displayName) },
                        selection: $settings.silenceSpeed
                    )
                    .fixedSize()
                    .help("How fast the quiet parts play back.")
                }

                Spacer(minLength: AppMetric.m)

                Text(summary)
                    .font(AppFont.text(13))
                    .foregroundStyle(AppColor.ink3)
                    .lineLimit(1)
            }
            .frame(minHeight: AppMetric.controlHeight)
        }
        .disabled(viewModel.isRunning)
        .padding(.horizontal, AppMetric.l)
        .padding(.top, AppMetric.m)
        .padding(.bottom, AppMetric.s)
        .litGlass()
    }

    /// One plain sentence stating what the current settings will produce.
    private var summary: String {
        var parts = [settings.outputPreset.compatibilitySummary]
        if settings.outputPreset.isAudioOnly {
            parts.append(settings.audioBitrate.displayName)
        } else {
            switch settings.mode {
            case .quality:
                parts.append("\(settings.qualityPreset.detailText), CRF \(settings.crf)")
            case .targetSize:
                parts.append("Two-pass to fit the target")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// A typed number, not a slider: people want an exact size.
private struct TargetSizeField: View {
    @Binding var value: Double
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            TextField(
                "",
                value: Binding(
                    get: { value },
                    set: { value = min(max($0, 1), 100_000) }
                ),
                format: .number.precision(.fractionLength(0...1))
            )
            .textFieldStyle(.plain)
            .font(AppFont.display(13.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(AppColor.ink)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("Target size in megabytes")

            Text("MB")
                .uiLabel(12.5, color: AppColor.ink4)
        }
        .padding(.horizontal, 12)
        .frame(height: AppMetric.controlHeight)
        .frame(minWidth: 110)
        .litControlSurface(hovering: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Queue

private enum QueueColumn {
    static let media: CGFloat = 150
    static let output: CGFloat = 130
    static let original: CGFloat = 78
    static let compressed: CGFloat = 104
    static let status: CGFloat = 176
}

private struct QueuePanel: View {
    @EnvironmentObject private var viewModel: AppViewModel
    var openPanel: () -> Void

    var body: some View {
        Group {
            if viewModel.jobs.isEmpty {
                EmptyQueue(openPanel: openPanel)
            } else {
                VStack(spacing: 0) {
                    QueueHeader()
                    Hairline(strong: true)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.jobs) { job in
                                QueueRow(job: job, isSelected: job.id == viewModel.selectedJobID)
                                Hairline()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litPanel()
        .overlay {
            // Drop feedback reuses the focus ring: state, not decoration.
            if viewModel.isDropTargeted {
                RoundedRectangle(cornerRadius: AppMetric.radiusPanel, style: .continuous)
                    .strokeBorder(AppColor.accentOnLight, lineWidth: 2)
            }
        }
    }
}

private struct QueueHeader: View {
    var body: some View {
        HStack(spacing: AppMetric.m) {
            Text("File").uiLabel().frame(maxWidth: .infinity, alignment: .leading)
            Text("Source").uiLabel().frame(width: QueueColumn.media, alignment: .leading)
            Text("Output").uiLabel().frame(width: QueueColumn.output, alignment: .leading)
            Text("Original").uiLabel().frame(width: QueueColumn.original, alignment: .trailing)
            Text("Compressed").uiLabel().frame(width: QueueColumn.compressed, alignment: .trailing)
            Text("Status").uiLabel().frame(width: QueueColumn.status, alignment: .leading)
        }
        .padding(.horizontal, AppMetric.l)
        .frame(height: 34)
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var viewModel: AppViewModel
    var job: CompressionJob
    var isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: AppMetric.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.inputURL.lastPathComponent)
                    .font(AppFont.display(13.5, weight: .semibold))
                    .foregroundStyle(AppColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.inputURL.deletingLastPathComponent().path)
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink4)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(mediaSummary)
                    .font(AppFont.text(13))
                    .foregroundStyle(AppColor.ink2)
                Text(job.metadata.map { durationText($0.duration) } ?? " ")
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink4)
            }
            .lineLimit(1)
            .frame(width: QueueColumn.media, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.metadata == nil ? " " : resolvedSettings.outputPreset.shortName)
                    .font(AppFont.text(13))
                    .foregroundStyle(AppColor.ink2)
                Text(job.metadata == nil ? " " : outputDetail)
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink4)
            }
            .lineLimit(1)
            .frame(width: QueueColumn.output, alignment: .leading)

            Text(byteString(job.originalSizeBytes))
                .font(AppFont.text(13))
                .foregroundStyle(AppColor.ink2)
                .lineLimit(1)
                .frame(width: QueueColumn.original, alignment: .trailing)

            CompressedSizeCell(job: job, settings: resolvedSettings)
                .frame(width: QueueColumn.compressed, alignment: .trailing)

            StatusCell(job: job)
                .frame(width: QueueColumn.status, alignment: .leading)
        }
        .padding(.horizontal, AppMetric.l)
        .frame(height: 52)
        .background(Color.white.opacity(isSelected ? 0.62 : (hovering ? 0.4 : 0)))
        .overlay(alignment: .leading) {
            // The active row is marked by an accent rule, not a filled block.
            if isSelected {
                Rectangle().fill(AppColor.accent).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            viewModel.selectedJobID = job.id
            if job.status == .completed {
                viewModel.showSelectedOutputComparison()
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.selectedJobID = job.id
        })
        .contextMenu {
            Button("Reveal Output in Finder") {
                viewModel.revealURL(job.outputURL)
            }
            .disabled(job.status != .completed)
            Button("Reveal Source in Finder") {
                viewModel.revealURL(job.inputURL)
            }
            Button("Compare with Original") {
                viewModel.selectedJobID = job.id
                viewModel.showSelectedOutputComparison()
            }
            .disabled(job.status != .completed)
            Divider()
            Button("Remove from Queue") {
                viewModel.removeJob(job.id)
            }
            .disabled(job.status == .running)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var resolvedSettings: CompressionSettings {
        job.appliedSettings ?? viewModel.settings.resolved(for: job.metadata)
    }

    private var outputDetail: String {
        let settings = resolvedSettings
        var parts: [String] = []
        if settings.outputPreset.isAudioOnly {
            parts.append(settings.audioBitrate.displayName)
        } else if settings.mode == .targetSize {
            parts.append("fit \(settings.targetSizeMB.formatted(.number.precision(.fractionLength(0...1)))) MB")
        } else {
            parts.append(settings.qualityPreset.displayName)
        }
        if settings.speedUpSilence {
            parts.append("silence \(settings.silenceSpeed.displayName)")
        }
        return parts.joined(separator: " · ")
    }

    private var mediaSummary: String {
        guard let metadata = job.metadata else {
            return job.status == .failed ? "Unreadable" : "Reading"
        }
        if metadata.videoCodec == nil {
            return "\(metadata.audioCodec?.uppercased() ?? "Audio") audio"
        }
        let codec = metadata.videoCodec?.uppercased() ?? "Video"
        if let width = metadata.width, let height = metadata.height {
            return "\(codec) · \(width)×\(height)"
        }
        return codec
    }
}

/// The result column: the compressed size once it exists, an honest estimate
/// before that (the target, or the rendered sample scaled to full length).
private struct CompressedSizeCell: View {
    var job: CompressionJob
    var settings: CompressionSettings

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if job.status == .completed, let output = job.outputSizeBytes {
                Text(byteString(output))
                    .font(AppFont.display(13.5, weight: .bold))
                    .foregroundStyle(AppColor.ink)
                Text(savingText(original: job.originalSizeBytes, output: output))
                    .font(AppFont.text(12))
                    .foregroundStyle(output <= job.originalSizeBytes ? AppColor.ink3 : AppColor.statusWarning)
            } else if let estimate {
                Text("≈ \(byteString(estimate))")
                    .font(AppFont.text(13))
                    .foregroundStyle(AppColor.ink3)
                Text(settings.mode == .targetSize && !settings.outputPreset.isAudioOnly ? "target" : "estimate")
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink4)
            } else {
                Text("–")
                    .font(AppFont.text(13))
                    .foregroundStyle(AppColor.ink4)
                    .help("Render a sample in Review to get an estimate.")
            }
        }
        .lineLimit(1)
    }

    private var estimate: Int64? {
        guard let metadata = job.metadata else { return nil }
        if settings.outputPreset.isAudioOnly {
            // Constant bitrate: size is simply bitrate × duration.
            return Int64(Double(settings.audioBitrate.rawValue) * 1000 / 8 * metadata.duration)
        }
        if settings.mode == .targetSize {
            return Int64(settings.targetSizeMB * 1024 * 1024)
        }
        if job.previewStatus == .ready, let sample = job.previewSizeBytes, sample > 0 {
            let sampleDuration = min(6, metadata.duration)
            guard sampleDuration > 0 else { return nil }
            return Int64(Double(sample) / sampleDuration * metadata.duration)
        }
        return nil
    }
}

private struct StatusCell: View {
    var job: CompressionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(job.status.displayName)
                    .font(AppFont.display(13, weight: .semibold))
                    .foregroundStyle(job.status == .failed ? AppColor.statusError : AppColor.ink)
                if job.status == .running {
                    Spacer(minLength: 4)
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(AppFont.display(12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppColor.ink3)
                }
            }

            if job.status == .running {
                LitProgressBar(value: job.progress)
            } else if let message = job.errorMessage, job.status == .failed || job.status == .cancelled {
                Text(message)
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink4)
                    .lineLimit(1)
                    .help(message)
            }
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .probing, .ready:
            return AppColor.ink4.opacity(0.55)
        case .running:
            return AppColor.accent
        case .completed:
            return AppColor.statusSuccess
        case .failed:
            return AppColor.statusError
        case .cancelled:
            return AppColor.statusWarning
        }
    }
}

/// A real sentence and one action. No illustration.
private struct EmptyQueue: View {
    var openPanel: () -> Void

    var body: some View {
        VStack(spacing: AppMetric.m) {
            Text("Drop video or audio here")
                .font(AppFont.display(24, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(AppColor.ink)
            Text("Files queue up in this list. Video compresses to the format above, audio converts to MP3, and every result is saved next to its original.")
                .font(AppFont.text(14.5))
                .foregroundStyle(AppColor.ink3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 440)
            Button("Add Media", action: openPanel)
                .buttonStyle(.lit(.secondary))
                .padding(.top, 4)
        }
        .padding(AppMetric.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @EnvironmentObject private var viewModel: AppViewModel
    var openPanel: () -> Void

    var body: some View {
        HStack(spacing: AppMetric.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.summaryText)
                    .font(AppFont.display(13, weight: .semibold))
                    .foregroundStyle(AppColor.ink2)
                if let savings = viewModel.totalSavings {
                    Text("\(byteString(savings.original)) → \(byteString(savings.output)) · \(savingText(original: savings.original, output: savings.output))")
                        .font(AppFont.text(12))
                        .foregroundStyle(AppColor.ink4)
                }
            }
            .lineLimit(1)

            Spacer(minLength: AppMetric.m)

            Button("Remove") {
                viewModel.removeSelectedJob()
            }
            .buttonStyle(.lit(.ghost))
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!viewModel.canRemoveSelected)
            .help("Remove the selected file from the queue. Nothing on disk is deleted.")

            Button("Clear Completed") {
                viewModel.clearCompleted()
            }
            .buttonStyle(.lit(.ghost))
            .disabled(viewModel.completedCount == 0 || viewModel.isRunning)

            Button("Reveal Output") {
                viewModel.revealSelectedOutput()
            }
            .buttonStyle(.lit(.ghost))
            .disabled(!viewModel.canRevealSelectedOutput)

            Button("Compare") {
                viewModel.showSelectedOutputComparison()
            }
            .buttonStyle(.lit(.ghost))
            .disabled(!viewModel.canCompareSelectedOutput)

            Button("Add Media", action: openPanel)
                .buttonStyle(.lit(.secondary))
                .keyboardShortcut("o", modifiers: .command)

            if viewModel.isRunning {
                Button("Stop") {
                    viewModel.cancelCompression()
                }
                .buttonStyle(.lit(.destructive))
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Review & Start") {
                    viewModel.startCompression()
                }
                .buttonStyle(.lit(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.canStart)
            }
        }
        .padding(.leading, AppMetric.l)
        .padding(.trailing, AppMetric.s)
        .frame(height: 52)
        .litGlass()
    }
}

// MARK: - Shared formatting

func byteString(_ bytes: Int64?) -> String {
    guard let bytes else { return "Unknown" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// "68% smaller" / "12% larger" — a measurement, not an adjective.
func savingText(original: Int64, output: Int64) -> String {
    guard original > 0 else { return "" }
    let change = Double(output - original) / Double(original)
    let percent = Int((abs(change) * 100).rounded())
    return output <= original ? "\(percent)% smaller" : "\(percent)% larger"
}

func durationText(_ duration: Double?) -> String {
    guard let duration else { return "Unknown" }
    let total = Int(duration.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
    }
    return "\(minutes):\(String(format: "%02d", seconds))"
}
