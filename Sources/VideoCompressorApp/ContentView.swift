import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import VideoCompressorCore

struct ContentView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(settings: $viewModel.settings)

            InfoStrip()

            Divider()

            ZStack {
                JobTable()

                if viewModel.jobs.isEmpty {
                    EmptyDropView(isTargeted: viewModel.isDropTargeted)
                        .padding(28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ActionBar(openPanel: openPanel)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

private struct SettingsBar: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var settings: CompressionSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Picker("Mode", selection: $settings.mode) {
                    ForEach(CompressionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)

                if settings.mode == .quality {
                    HStack(spacing: 8) {
                        Picker("Quality", selection: $settings.qualityPreset) {
                            ForEach(QualityPreset.allCases) { quality in
                                Text(quality.displayName).tag(quality)
                            }
                        }
                        .frame(width: 190)

                        Text(settings.outputPreset.isAudioOnly
                             ? settings.qualityPreset.detailText
                             : "\(settings.qualityPreset.detailText), CRF \(settings.crf)")
                            .font(.mono(.caption))
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("Target")
                        TextField("MB", value: $settings.targetSizeMB, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 82)
                        Text("MB")
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                Picker("Format", selection: $settings.outputPreset) {
                    ForEach(OutputPreset.allCases) { preset in
                        Text(preset.shortName).tag(preset)
                    }
                }
                .frame(width: 150)
            }

            HStack(alignment: .center, spacing: 14) {
                Picker("Resolution", selection: $settings.resolutionCap) {
                    ForEach(ResolutionCap.allCases) { cap in
                        Text(cap.displayName).tag(cap)
                    }
                }
                .frame(width: 180)

                Picker("Audio", selection: $settings.audioBitrate) {
                    ForEach(AudioBitrate.allCases) { bitrate in
                        Text(bitrate.displayName).tag(bitrate)
                    }
                }
                .frame(width: 150)
                .help("Audio bitrate. Used as AAC for MP4/MOV outputs and as MP3 for MP3 outputs.")

                Toggle("Speed up silence", isOn: $settings.speedUpSilence)
                    .toggleStyle(.checkbox)
                    .help("Plays quiet stretches longer than a second at higher speed while keeping speech at normal pace. Great for lectures, meetings, and screen recordings.")

                if settings.speedUpSilence {
                    Picker("Silence speed", selection: $settings.silenceSpeed) {
                        ForEach(SilenceSpeed.allCases) { speed in
                            Text(speed.displayName).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 66)
                    .help("How fast the quiet parts play back.")
                }

                Text(settings.outputPreset.compatibilitySummary)
                    .font(.mono(.caption))
                    .foregroundStyle(settings.outputPreset.isBestWindowsChoice ? Color.green : Color.secondary)

                Spacer()
            }
        }
        .disabled(viewModel.isRunning)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct InfoStrip: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Created by")
                .foregroundStyle(.secondary)
            Link("Yuri Ihnatov", destination: URL(string: "https://ihnatov.nl")!)
            Text("as a quick, reliable media converter. Open source and free.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.mono(.caption))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

private struct JobTable: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        Table(viewModel.jobs, selection: $viewModel.selectedJobID) {
            TableColumn("File") { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.inputURL.lastPathComponent)
                        .lineLimit(1)
                    Text(job.inputURL.deletingLastPathComponent().path)
                        .font(.mono(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TableColumn("Original") { job in
                Text(ByteCountFormatter.string(fromByteCount: job.originalSizeBytes, countStyle: .file))
                    .monospacedDigit()
            }
            .width(90)

            TableColumn("Media") { job in
                Text(mediaSummary(job.metadata))
                    .font(.mono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(130)

            TableColumn("Format") { job in
                Text(formatLabel(for: job))
                    .font(.mono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(110)

            TableColumn("Status") { job in
                StatusLabel(job: job)
            }
            .width(130)

            TableColumn("Progress") { job in
                ProgressView(value: job.progress)
                    .frame(width: 110)
            }
            .width(130)

            TableColumn("Output") { job in
                Text(job.outputURL.lastPathComponent)
                    .font(.mono(.body))
                    .lineLimit(1)
                    .foregroundStyle(job.status == .completed ? .primary : .secondary)
            }
        }
    }

    private func formatLabel(for job: CompressionJob) -> String {
        let resolved = job.appliedSettings ?? viewModel.settings.resolved(for: job.metadata)
        let preset = resolved.outputPreset
        var label = preset.isAudioOnly
            ? "\(preset.shortName) (\(resolved.audioBitrate.displayName))"
            : preset.shortName
        if resolved.speedUpSilence {
            label += " · silence \(resolved.silenceSpeed.displayName)"
        }
        return label
    }

    private func mediaSummary(_ metadata: MediaMetadata?) -> String {
        guard let metadata else { return "Reading..." }
        if metadata.videoCodec == nil {
            let codec = metadata.audioCodec?.uppercased() ?? "Audio"
            return "\(codec) audio"
        }
        let size: String
        if let width = metadata.width, let height = metadata.height {
            size = "\(width)x\(height)"
        } else {
            size = "Unknown size"
        }
        let codec = metadata.videoCodec?.uppercased() ?? "Video"
        return "\(codec), \(size)"
    }
}

private struct StatusLabel: View {
    var job: CompressionJob

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.status.displayName)
                if let errorMessage = job.errorMessage, job.status == .failed || job.status == .cancelled {
                    Text(errorMessage)
                        .font(.mono(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .probing:
            return .blue
        case .ready:
            return .secondary
        case .running:
            return .brandOrange
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }
}

private struct EmptyDropView: View {
    var isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(isTargeted ? Color.brandOrange : Color.secondary)
            Text("Drop media here")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Video files compress to MP4 (or your chosen format). Audio files convert to MP3.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.brandOrange : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
    }
}

private struct ActionBar: View {
    @EnvironmentObject private var viewModel: AppViewModel
    var openPanel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(viewModel.summaryText)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: openPanel) {
                Label("Add Media", systemImage: "plus")
            }

            Button {
                viewModel.startCompression()
            } label: {
                Label("Review & Start", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.canStart)

            Button {
                viewModel.cancelCompression()
            } label: {
                Label("Cancel", systemImage: "stop.fill")
            }
            .disabled(!viewModel.canCancel)

            Button {
                viewModel.revealSelectedOutput()
            } label: {
                Label("Reveal Output", systemImage: "folder")
            }
            .disabled(!viewModel.canRevealSelectedOutput)

            Button {
                viewModel.showSelectedOutputComparison()
            } label: {
                Label("Compare", systemImage: "rectangle.split.2x1")
            }
            .disabled(!viewModel.canCompareSelectedOutput)

            Button {
                viewModel.clearCompleted()
            } label: {
                Label("Clear Completed", systemImage: "trash")
            }
            .disabled(viewModel.completedCount == 0 || viewModel.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct ComparisonView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    var request: ComparisonRequest
    @State private var selectedFrameIndex = 0
    @State private var frameZoom = 2.0

    private var job: CompressionJob? {
        viewModel.jobs.first(where: { $0.id == request.jobID })
    }

    var body: some View {
        Group {
            if let job {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(request.stage == .before ? "Review Compression" : "Compression Result")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text(job.inputURL.lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if !comparisonFrames(for: job).isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.magnifyingglass")
                                    .foregroundStyle(.secondary)
                                    .help("Zoom frames")
                                Slider(value: $frameZoom, in: 1...4)
                                    .frame(width: 140)
                                Text("\(frameZoom, specifier: "%.1f")x")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }

                        Text(comparisonSettings(for: job).outputPreset.shortName)
                            .font(.headline)
                    }

                    Group {
                        if !comparisonFrames(for: job).isEmpty {
                            FrameComparisonView(
                                frames: comparisonFrames(for: job),
                                selectedIndex: $selectedFrameIndex,
                                zoom: $frameZoom,
                                compressedTitle: request.stage == .before ? "Compressed Sample" : "Compressed Output"
                            )
                        } else {
                            HStack(spacing: 14) {
                                VideoPane(
                                    title: "Original",
                                    url: job.inputURL,
                                    placeholder: "Original unavailable"
                                )

                                VideoPane(
                                    title: request.stage == .before ? "Compressed Sample" : "Compressed Output",
                                    url: comparisonVideoURL(for: job),
                                    placeholder: comparisonPlaceholder(for: job)
                                )
                            }
                        }
                    }
                    .frame(height: 330)

                    HStack(alignment: .top, spacing: 14) {
                        MetricsPanel(title: "Original", rows: originalRows(for: job))
                        MetricsPanel(title: request.stage == .before ? "Planned Output" : "Actual Output", rows: outputRows(for: job))
                    }

                    if request.stage == .before, job.previewStatus == .rendering {
                        ProgressView(value: job.previewProgress) {
                            Text("Rendering sample")
                        }
                    }

                    if request.stage == .before, let errorMessage = job.previewErrorMessage, job.previewStatus == .failed {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }

                    HStack {
                        if request.stage == .before {
                            Button {
                                viewModel.renderPreviewSample(for: job.id)
                            } label: {
                                Label(job.previewStatus == .ready ? "Refresh Sample" : "Render Sample", systemImage: "play.rectangle")
                            }
                            .disabled(job.previewStatus == .rendering || viewModel.isRunning)

                            Spacer()

                            Button("Cancel") {
                                viewModel.closeComparison()
                            }

                            Button {
                                viewModel.startCompressionAfterReview()
                            } label: {
                                Label("Start Compression", systemImage: "play.fill")
                            }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(job.previewStatus == .rendering || viewModel.isRunning)
                        } else {
                            Spacer()

                            Button {
                                viewModel.revealURL(job.outputURL)
                            } label: {
                                Label("Reveal Output", systemImage: "folder")
                            }

                            Button("Close") {
                                viewModel.closeComparison()
                            }
                            .keyboardShortcut(.cancelAction)
                        }
                    }
                }
                .padding(18)
                .frame(minWidth: 920, minHeight: 660)
            } else {
                VStack(spacing: 12) {
                    Text("The selected job is no longer available.")
                    Button("Close") {
                        viewModel.closeComparison()
                    }
                }
                .padding(24)
            }
        }
    }

    private func comparisonVideoURL(for job: CompressionJob) -> URL? {
        switch request.stage {
        case .before:
            guard let previewURL = job.previewURL,
                  FileManager.default.fileExists(atPath: previewURL.path) else {
                return nil
            }
            return previewURL
        case .after:
            return FileManager.default.fileExists(atPath: job.outputURL.path) ? job.outputURL : nil
        }
    }

    private func comparisonFrames(for job: CompressionJob) -> [ComparisonFrame] {
        switch request.stage {
        case .before:
            return job.previewFrames
        case .after:
            return job.outputFrames
        }
    }

    private func comparisonPlaceholder(for job: CompressionJob) -> String {
        switch request.stage {
        case .before:
            switch job.previewStatus {
            case .notRendered:
                return "Sample not rendered"
            case .rendering:
                return "Rendering sample"
            case .ready:
                return "Sample unavailable"
            case .failed:
                return "Sample failed"
            }
        case .after:
            return "Output unavailable"
        }
    }

    private func originalRows(for job: CompressionJob) -> [MetricRow] {
        [
            MetricRow("Size", byteString(job.originalSizeBytes)),
            MetricRow("Video", codecText(job.metadata?.videoCodec)),
            MetricRow("Resolution", resolutionText(job.metadata)),
            MetricRow("Audio", audioText(job.metadata)),
            MetricRow("Duration", durationText(job.metadata?.duration)),
            MetricRow("Path", job.inputURL.path)
        ]
    }

    private func outputRows(for job: CompressionJob) -> [MetricRow] {
        switch request.stage {
        case .before:
            return beforeOutputRows(for: job)
        case .after:
            return afterOutputRows(for: job)
        }
    }

    private func beforeOutputRows(for job: CompressionJob) -> [MetricRow] {
        let settings = comparisonSettings(for: job)
        var rows = [
            MetricRow("Format", settings.outputPreset.displayName),
            MetricRow("Video", settings.outputPreset.videoCodecDisplayName),
            MetricRow("Quality", qualityText(for: job)),
            MetricRow("Resolution", plannedResolutionText(job.metadata, job: job)),
            MetricRow("Audio", audioMetricText(for: settings)),
            MetricRow("Full Output", job.outputURL.path)
        ]

        if settings.speedUpSilence {
            rows.insert(MetricRow("Silence", "Quiet parts at \(settings.silenceSpeed.displayName)"), at: rows.count - 1)
        }

        if job.previewStatus == .ready {
            rows.insert(MetricRow("Sample Size", byteString(job.previewSizeBytes)), at: 0)
            rows.insert(MetricRow("Sample Video", codecText(job.previewMetadata?.videoCodec)), at: 2)
        } else if settings.mode == .targetSize {
            rows.insert(MetricRow("Target Size", byteString(Int64(settings.targetSizeMB * 1024 * 1024))), at: 0)
        } else {
            rows.insert(MetricRow("Estimate", "Render sample"), at: 0)
        }

        return rows
    }

    private func afterOutputRows(for job: CompressionJob) -> [MetricRow] {
        let settings = comparisonSettings(for: job)
        var rows = [
            MetricRow("Size", byteString(job.outputSizeBytes)),
            MetricRow("Video", codecText(job.outputMetadata?.videoCodec)),
            MetricRow("Resolution", resolutionText(job.outputMetadata)),
            MetricRow("Audio", audioText(job.outputMetadata)),
            MetricRow("Duration", durationText(job.outputMetadata?.duration)),
            MetricRow("Container", containerText(job.outputMetadata)),
            MetricRow("Preset", settings.outputPreset.displayName),
            MetricRow("Saved", job.outputURL.path)
        ]
        if settings.speedUpSilence {
            rows.insert(MetricRow("Silence", "Quiet parts at \(settings.silenceSpeed.displayName)"), at: 5)
        }
        return rows
    }

    private func qualityText(for job: CompressionJob) -> String {
        let settings = comparisonSettings(for: job)
        if settings.outputPreset.isAudioOnly {
            return "MP3 \(settings.audioBitrate.displayName)"
        }
        switch settings.mode {
        case .quality:
            return "\(settings.qualityPreset.displayName), CRF \(settings.crf)"
        case .targetSize:
            return "Target \(settings.targetSizeMB.formatted(.number.precision(.fractionLength(0...1)))) MB"
        }
    }

    private func plannedResolutionText(_ metadata: MediaMetadata?, job: CompressionJob) -> String {
        let settings = comparisonSettings(for: job)
        guard let metadata,
              let width = metadata.width,
              let height = metadata.height else {
            return settings.resolutionCap.displayName
        }

        guard let maxHeight = settings.resolutionCap.maxHeight, height > maxHeight else {
            return "\(width)x\(height)"
        }

        let scaledWidth = max(2, Int((Double(width) * Double(maxHeight) / Double(height)) / 2) * 2)
        return "\(scaledWidth)x\(maxHeight)"
    }

    private func comparisonSettings(for job: CompressionJob?) -> CompressionSettings {
        switch request.stage {
        case .before:
            if let previewSettings = job?.previewSettings {
                return previewSettings
            }
            return viewModel.settings.resolved(for: job?.metadata)
        case .after:
            return job?.appliedSettings ?? viewModel.settings.resolved(for: job?.metadata)
        }
    }
}

private struct FrameComparisonView: View {
    var frames: [ComparisonFrame]
    @Binding var selectedIndex: Int
    @Binding var zoom: Double
    var compressedTitle: String

    private var boundedIndex: Int {
        guard !frames.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), frames.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Frame", selection: $selectedIndex) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                        Text("Frame \(index + 1) - \(durationText(frame.timestamp))").tag(index)
                    }
                }
                .frame(width: 230)

                Spacer()
            }

            let frame = frames[boundedIndex]
            HStack(spacing: 14) {
                FrameImagePane(title: "Original Frame", url: frame.originalURL, zoom: zoom)
                FrameImagePane(title: compressedTitle, url: frame.compressedURL, zoom: zoom)
            }
        }
        .onAppear(perform: normalizeSelection)
        .onChange(of: frames) { _ in
            normalizeSelection()
        }
    }

    private func normalizeSelection() {
        guard !frames.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(selectedIndex, 0), frames.count - 1)
    }
}

private struct FrameImagePane: View {
    var title: String
    var url: URL
    var zoom: Double
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: max(geometry.size.width, 1) * zoom)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    } else {
                        Text("Frame unavailable")
                            .foregroundStyle(.secondary)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear(perform: loadImage)
        .onChange(of: url) { _ in
            loadImage()
        }
    }

    private func loadImage() {
        image = NSImage(contentsOf: url)
    }
}

private struct VideoPane: View {
    var title: String
    var url: URL?
    var placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            ZStack {
                Rectangle()
                    .fill(Color(nsColor: .textBackgroundColor))

                if let url = playableURL {
                    AppKitVideoPlayer(url: url)
                } else {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var playableURL: URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}

private struct AppKitVideoPlayer: NSViewRepresentable {
    var url: URL

    final class Coordinator {
        var url: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        configure(view, context: context)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        configure(nsView, context: context)
    }

    private func configure(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
        context.coordinator.url = url
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

private struct MetricsPanel: View {
    var title: String
    var rows: [MetricRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.label)
                            .font(.mono(.caption))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .frame(width: 86, alignment: .leading)

                        Text(row.value)
                            .font(.mono(.caption))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct MetricRow: Identifiable {
    let id = UUID()
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

private func byteString(_ bytes: Int64?) -> String {
    guard let bytes else { return "Unknown" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func codecText(_ codec: String?) -> String {
    codec?.uppercased() ?? "Unknown"
}

private func resolutionText(_ metadata: MediaMetadata?) -> String {
    guard let width = metadata?.width, let height = metadata?.height else {
        return "Unknown"
    }
    return "\(width)x\(height)"
}

private func audioText(_ metadata: MediaMetadata?) -> String {
    guard let metadata else { return "Unknown" }
    return metadata.hasAudio ? codecText(metadata.audioCodec) : "No audio"
}

private func durationText(_ duration: Double?) -> String {
    guard let duration else { return "Unknown" }
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return "\(minutes):\(String(format: "%02d", seconds))"
}

private func audioMetricText(for settings: CompressionSettings) -> String {
    let codec = settings.outputPreset.isAudioOnly ? "MP3" : "AAC"
    return "\(codec) \(settings.audioBitrate.displayName)"
}

private func containerText(_ metadata: MediaMetadata?) -> String {
    guard let formatName = metadata?.formatName else { return "Unknown" }
    if formatName.contains("mp4") {
        return "MP4-compatible"
    }
    if formatName.contains("mov") {
        return "MOV"
    }
    return formatName
}
