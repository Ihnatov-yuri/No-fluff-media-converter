import AppKit
import AVKit
import SwiftUI
import VideoCompressorCore

struct ComparisonView: View {
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
                VStack(alignment: .leading, spacing: AppMetric.l) {
                    header(for: job)

                    Group {
                        if !comparisonFrames(for: job).isEmpty {
                            FrameComparisonView(
                                frames: comparisonFrames(for: job),
                                selectedIndex: $selectedFrameIndex,
                                zoom: $frameZoom,
                                compressedTitle: compressedTitle
                            )
                        } else {
                            HStack(spacing: AppMetric.gutter) {
                                VideoPane(
                                    title: "Original",
                                    url: job.inputURL,
                                    placeholder: "Original unavailable"
                                )

                                VideoPane(
                                    title: compressedTitle,
                                    url: comparisonVideoURL(for: job),
                                    placeholder: comparisonPlaceholder(for: job)
                                )
                            }
                        }
                    }
                    .frame(height: 330)

                    HStack(alignment: .top, spacing: AppMetric.gutter) {
                        MetricsPanel(title: "Original", rows: originalRows(for: job))
                        MetricsPanel(title: request.stage == .before ? "Planned output" : "Actual output", rows: outputRows(for: job))
                    }

                    if request.stage == .before, job.previewStatus == .rendering {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Rendering a 6-second sample").uiLabel(12.5, color: AppColor.ink2)
                                Spacer()
                                Text("\(Int((job.previewProgress * 100).rounded()))%")
                                    .uiLabel(12.5, color: AppColor.ink3)
                                    .monospacedDigit()
                            }
                            LitProgressBar(value: job.previewProgress)
                        }
                    }

                    if request.stage == .before, let errorMessage = job.previewErrorMessage, job.previewStatus == .failed {
                        // Alerts: the one place a coloured left rule is allowed — it is state.
                        HStack(spacing: 0) {
                            Rectangle().fill(AppColor.statusError).frame(width: 3)
                            Text("The sample could not be rendered. \(errorMessage)")
                                .font(AppFont.text(13))
                                .foregroundStyle(AppColor.statusError)
                                .lineLimit(2)
                                .padding(.horizontal, AppMetric.m)
                                .padding(.vertical, AppMetric.s)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .background(AppColor.veil)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetric.radiusControl, style: .continuous))
                    }

                    HStack(spacing: AppMetric.s) {
                        if request.stage == .before {
                            Button(job.previewStatus == .ready ? "Refresh Sample" : "Render Sample") {
                                viewModel.renderPreviewSample(for: job.id)
                            }
                            .buttonStyle(.lit(.secondary))
                            .disabled(job.previewStatus == .rendering || viewModel.isRunning)
                            .help("Encodes the first six seconds with these settings so you can judge quality before committing.")

                            Spacer()

                            Button("Cancel") {
                                viewModel.closeComparison()
                            }
                            .buttonStyle(.lit(.ghost))
                            .keyboardShortcut(.cancelAction)

                            Button(startTitle) {
                                viewModel.startCompressionAfterReview()
                            }
                            .buttonStyle(.lit(.primary))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(job.previewStatus == .rendering || viewModel.isRunning)
                        } else {
                            Spacer()

                            Button("Reveal Output") {
                                viewModel.revealURL(job.outputURL)
                            }
                            .buttonStyle(.lit(.secondary))

                            Button("Done") {
                                viewModel.closeComparison()
                            }
                            .buttonStyle(.lit(.primary))
                            .keyboardShortcut(.cancelAction)
                        }
                    }
                }
                .padding(AppMetric.xl)
                .frame(width: 980)
                .frame(minHeight: 680)
            } else {
                VStack(spacing: AppMetric.m) {
                    Text("This file is no longer in the queue.")
                        .font(AppFont.text(14.5))
                        .foregroundStyle(AppColor.ink2)
                    Button("Close") {
                        viewModel.closeComparison()
                    }
                    .buttonStyle(.lit(.primary))
                }
                .padding(AppMetric.xl)
            }
        }
        .background(LitField())
    }

    private var compressedTitle: String {
        request.stage == .before ? "Compressed sample" : "Compressed output"
    }

    private var startTitle: String {
        let count = viewModel.jobs.filter { $0.status.canRun }.count
        return count > 1 ? "Start \(count) Files" : "Start Compression"
    }

    @ViewBuilder
    private func header(for job: CompressionJob) -> some View {
        HStack(alignment: .bottom, spacing: AppMetric.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.stage == .before ? "Review before compressing" : "Compression result")
                    .font(AppFont.display(24, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(AppColor.ink)
                Text("\(job.inputURL.lastPathComponent) · \(comparisonSettings(for: job).outputPreset.shortName)")
                    .font(AppFont.text(14))
                    .foregroundStyle(AppColor.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppMetric.l)

            if request.stage == .after, let output = job.outputSizeBytes, job.originalSizeBytes > 0 {
                let change = Double(output - job.originalSizeBytes) / Double(job.originalSizeBytes)
                VStack(alignment: .trailing, spacing: 0) {
                    BigNumber(value: "\(Int((abs(change) * 100).rounded()))", unit: "%", size: 40)
                    Text(output <= job.originalSizeBytes ? "smaller than the original" : "larger than the original")
                        .uiLabel(12.5, color: AppColor.ink3)
                }
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
        ].filter { job.metadata?.videoCodec != nil || !["Video", "Resolution"].contains($0.label) }
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
        if settings.outputPreset.isAudioOnly {
            rows.removeAll { ["Video", "Resolution"].contains($0.label) }
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
            return "\(width)×\(height)"
        }

        let scaledWidth = max(2, Int((Double(width) * Double(maxHeight) / Double(height)) / 2) * 2)
        return "\(scaledWidth)×\(maxHeight)"
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
        VStack(alignment: .leading, spacing: AppMetric.s) {
            HStack(spacing: AppMetric.m) {
                PillTabs(
                    options: frames.indices.map { ($0, "Frame \($0 + 1) · \(durationText(frames[$0].timestamp))") },
                    selection: $selectedIndex
                )
                .fixedSize()

                Spacer()

                Text("Zoom").uiLabel(12.5, color: AppColor.ink2)
                Slider(value: $zoom, in: 1...4)
                    .controlSize(.small)
                    .frame(width: 140)
                    .accessibilityLabel("Zoom frames")
                Text("\(zoom, specifier: "%.1f")×")
                    .uiLabel(12.5, color: AppColor.ink3)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            let frame = frames[boundedIndex]
            HStack(spacing: AppMetric.gutter) {
                FrameImagePane(title: "Original", url: frame.originalURL, zoom: zoom)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title).uiLabel(12.5, color: AppColor.ink2)

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
                            .font(AppFont.text(13))
                            .foregroundStyle(AppColor.ink4)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            .litPanel(strong: true)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title).uiLabel(12.5, color: AppColor.ink2)

            ZStack {
                if let url = playableURL {
                    AppKitVideoPlayer(url: url)
                } else {
                    Text(placeholder)
                        .font(AppFont.text(13))
                        .foregroundStyle(AppColor.ink4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .litPanel(strong: true)
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
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AppFont.display(15, weight: .bold))
                .foregroundStyle(AppColor.ink)
                .padding(.bottom, AppMetric.s)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Hairline()
                }
                HStack(alignment: .firstTextBaseline, spacing: AppMetric.m) {
                    Text(row.label)
                        .uiLabel(12.5, color: AppColor.ink3)
                        .frame(width: 92, alignment: .leading)

                    Text(row.value)
                        .font(AppFont.text(13))
                        .foregroundStyle(AppColor.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.value)
                }
                .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, AppMetric.l)
        .padding(.vertical, AppMetric.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .litPanel()
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

private func codecText(_ codec: String?) -> String {
    codec?.uppercased() ?? "Unknown"
}

private func resolutionText(_ metadata: MediaMetadata?) -> String {
    guard let width = metadata?.width, let height = metadata?.height else {
        return "Unknown"
    }
    return "\(width)×\(height)"
}

private func audioText(_ metadata: MediaMetadata?) -> String {
    guard let metadata else { return "Unknown" }
    return metadata.hasAudio ? codecText(metadata.audioCodec) : "No audio"
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
