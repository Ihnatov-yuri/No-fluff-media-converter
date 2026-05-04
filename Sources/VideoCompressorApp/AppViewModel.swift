import AppKit
import Foundation
import VideoCompressorCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var jobs: [CompressionJob] = []
    @Published var settings = CompressionSettings.defaults {
        didSet {
            refreshPendingOutputURLs()
            invalidatePendingPreviews()
        }
    }
    @Published var selectedJobID: UUID?
    @Published var isDropTargeted = false
    @Published var isRunning = false
    @Published var appError: String?
    @Published var comparisonRequest: ComparisonRequest?

    private let ffmpegURL: URL?
    private let ffprobeURL: URL?
    private var activeRunner: CompressionRunner?
    private var activePreviewRunner: CompressionRunner?
    private var outputFrameGenerationJobIDs = Set<UUID>()

    init() {
        self.ffmpegURL = BinaryLocator.resolve(
            preferredPath: "/opt/homebrew/bin/ffmpeg",
            executableName: "ffmpeg"
        )
        self.ffprobeURL = BinaryLocator.resolve(
            preferredPath: "/opt/homebrew/bin/ffprobe",
            executableName: "ffprobe"
        )

        if ffmpegURL == nil {
            appError = CompressionError.missingBinary("ffmpeg").localizedDescription
        } else if ffprobeURL == nil {
            appError = CompressionError.missingBinary("ffprobe").localizedDescription
        }
    }

    var selectedJob: CompressionJob? {
        guard let selectedJobID else { return nil }
        return jobs.first(where: { $0.id == selectedJobID })
    }

    var canStart: Bool {
        !isRunning && jobs.contains(where: { $0.status.canRun })
    }

    var canCancel: Bool {
        isRunning
    }

    var canRevealSelectedOutput: Bool {
        guard let selectedJob else { return false }
        return selectedJob.status == .completed && FileManager.default.fileExists(atPath: selectedJob.outputURL.path)
    }

    var canCompareSelectedOutput: Bool {
        selectedJob?.status == .completed
    }

    var completedCount: Int {
        jobs.filter { $0.status == .completed }.count
    }

    var summaryText: String {
        if jobs.isEmpty {
            return "Drop media to begin"
        }
        let total = jobs.count
        let completed = completedCount
        if isRunning {
            return "Compressing \(completed) of \(total) completed"
        }
        return "\(total) file\(total == 1 ? "" : "s"), \(completed) completed"
    }

    func addFiles(_ urls: [URL]) {
        let fileURLs = urls
            .filter { !$0.hasDirectoryPath }
            .map { $0.standardizedFileURL }

        for url in fileURLs {
            if jobs.contains(where: { $0.inputURL == url }) {
                continue
            }

            let outputURL = OutputURLBuilder.compressedOutputURL(for: url, settings: settings)
            let size = fileSize(at: url)
            let job = CompressionJob(inputURL: url, outputURL: outputURL, originalSizeBytes: size)
            jobs.append(job)
            selectedJobID = job.id
            probeJob(id: job.id)
        }
    }

    func startCompression() {
        guard !isRunning else { return }
        guard jobs.contains(where: { $0.status.canRun }) else { return }
        let reviewJobID = selectedJob?.status.canRun == true
            ? selectedJob?.id
            : jobs.first(where: { $0.status.canRun })?.id
        if let reviewJobID {
            comparisonRequest = ComparisonRequest(jobID: reviewJobID, stage: .before)
        }
    }

    func startCompressionAfterReview() {
        comparisonRequest = nil
        beginCompression()
    }

    func beginCompression() {
        guard !isRunning else { return }
        guard let ffmpegURL else {
            appError = CompressionError.missingBinary("ffmpeg").localizedDescription
            return
        }

        let settingsSnapshot = settings
        Task {
            await runQueue(ffmpegURL: ffmpegURL, settings: settingsSnapshot)
        }
    }

    func cancelCompression() {
        activeRunner?.cancel()
    }

    func revealSelectedOutput() {
        guard canRevealSelectedOutput, let selectedJob else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedJob.outputURL])
    }

    func revealURL(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func showSelectedOutputComparison() {
        guard let selectedJob, selectedJob.status == .completed else { return }
        ensureOutputFrames(for: selectedJob.id)
        comparisonRequest = ComparisonRequest(jobID: selectedJob.id, stage: .after)
    }

    func closeComparison() {
        activePreviewRunner?.cancel()
        comparisonRequest = nil
    }

    func renderPreviewSample(for jobID: UUID) {
        guard let ffmpegURL else {
            appError = CompressionError.missingBinary("ffmpeg").localizedDescription
            return
        }

        Task {
            await renderPreviewSample(jobID: jobID, ffmpegURL: ffmpegURL)
        }
    }

    func clearCompleted() {
        for job in jobs where job.status == .completed {
            if let previewURL = job.previewURL {
                try? FileManager.default.removeItem(at: previewURL)
            }
            removeFrameFiles(job.previewFrames)
            removeFrameFiles(job.outputFrames)
        }
        jobs.removeAll { $0.status == .completed }
        if let selectedJobID, !jobs.contains(where: { $0.id == selectedJobID }) {
            self.selectedJobID = jobs.first?.id
        }
    }

    func clearError() {
        appError = nil
    }

    private func runQueue(ffmpegURL: URL, settings: CompressionSettings) async {
        isRunning = true
        var lastCompletedJobID: UUID?
        defer {
            isRunning = false
            activeRunner = nil
            if let lastCompletedJobID {
                ensureOutputFrames(for: lastCompletedJobID)
                comparisonRequest = ComparisonRequest(jobID: lastCompletedJobID, stage: .after)
            }
        }

        let ids = jobs.filter { $0.status.canRun }.map(\.id)
        for id in ids {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
            selectedJobID = id

            do {
                let metadata = try await metadataForRun(jobID: id)
                let resolvedSettings = settings.resolved(for: metadata)
                let outputURL = OutputURLBuilder.compressedOutputURL(for: jobs[index].inputURL, settings: resolvedSettings)
                updateJob(id) {
                    removeFrameFiles($0.outputFrames)
                    $0.metadata = metadata
                    $0.outputURL = outputURL
                    $0.outputMetadata = nil
                    $0.outputSizeBytes = nil
                    $0.appliedSettings = resolvedSettings
                    $0.outputFrames = []
                    $0.status = .running
                    $0.progress = 0
                    $0.errorMessage = nil
                }

                let plan = try FFmpegCommandBuilder(
                    settings: resolvedSettings,
                    inputURL: jobs[index].inputURL,
                    outputURL: outputURL,
                    metadata: metadata
                ).build()

                let runner = CompressionRunner(executableURL: ffmpegURL)
                activeRunner = runner
                try await runner.run(plan: plan) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateJob(id) { job in
                            job.progress = progress
                        }
                    }
                }

                let outputSize = fileSize(at: outputURL)
                let outputMetadata = try? await probeMetadata(outputURL)
                updateJob(id) {
                    $0.status = .completed
                    $0.progress = 1
                    $0.outputSizeBytes = outputSize
                    $0.outputMetadata = outputMetadata
                    $0.errorMessage = nil
                }
                lastCompletedJobID = id
            } catch CompressionError.cancelled {
                updateJob(id) {
                    $0.status = .cancelled
                    $0.errorMessage = CompressionError.cancelled.localizedDescription
                }
                break
            } catch {
                updateJob(id) {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func metadataForRun(jobID: UUID) async throws -> MediaMetadata {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            throw CompressionError.invalidProbeOutput
        }

        if let metadata = jobs[index].metadata {
            return metadata
        }

        guard let ffprobeURL else {
            throw CompressionError.missingBinary("ffprobe")
        }

        let inputURL = jobs[index].inputURL
        return try await Task.detached(priority: .userInitiated) {
            try MediaProbeService(ffprobeURL: ffprobeURL).probe(inputURL)
        }.value
    }

    private func probeMetadata(_ url: URL) async throws -> MediaMetadata {
        guard let ffprobeURL else {
            throw CompressionError.missingBinary("ffprobe")
        }

        return try await Task.detached(priority: .userInitiated) {
            try MediaProbeService(ffprobeURL: ffprobeURL).probe(url)
        }.value
    }

    private func renderPreviewSample(jobID: UUID, ffmpegURL: URL) async {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        guard job.previewStatus != .rendering else { return }

        let inputURL = job.inputURL
        let settingsSnapshot = settings
        let previousPreviewURL = job.previewURL
        let previousPreviewFrames = job.previewFrames

        updateJob(jobID) {
            $0.previewStatus = .rendering
            $0.previewProgress = 0
            $0.previewErrorMessage = nil
            $0.previewURL = nil
            $0.previewMetadata = nil
            $0.previewSizeBytes = nil
            $0.previewSettings = settingsSnapshot
            $0.previewFrames = []
        }
        if let previousPreviewURL {
            try? FileManager.default.removeItem(at: previousPreviewURL)
        }
        removeFrameFiles(previousPreviewFrames)

        do {
            let metadata = try await metadataForRun(jobID: jobID)
            let resolvedSettings = settingsSnapshot.resolved(for: metadata)
            let previewURL = OutputURLBuilder.previewOutputURL(for: inputURL, settings: resolvedSettings)
            updateJob(jobID) {
                $0.previewSettings = resolvedSettings
            }
            let plan = try FFmpegCommandBuilder(
                settings: resolvedSettings,
                inputURL: inputURL,
                outputURL: previewURL,
                metadata: metadata
            ).buildSample(outputURL: previewURL)

            let runner = CompressionRunner(executableURL: ffmpegURL)
            activePreviewRunner = runner
            try await runner.run(plan: plan) { [weak self] progress in
                Task { @MainActor in
                    self?.updateJob(jobID) { job in
                        job.previewProgress = progress
                    }
                }
            }

            let previewMetadata = try? await probeMetadata(previewURL)
            let previewSize = fileSize(at: previewURL)
            updateJob(jobID) {
                $0.previewURL = previewURL
                $0.previewMetadata = previewMetadata
                $0.previewSizeBytes = previewSize
                $0.previewStatus = .ready
                $0.previewProgress = 1
                $0.previewErrorMessage = nil
            }
            generatePreviewFrames(
                jobID: jobID,
                ffmpegURL: ffmpegURL,
                originalURL: inputURL,
                previewURL: previewURL,
                duration: min(6, metadata.duration)
            )
        } catch CompressionError.cancelled {
            updateJob(jobID) {
                $0.previewStatus = .notRendered
                $0.previewErrorMessage = nil
                $0.previewProgress = 0
            }
        } catch {
            updateJob(jobID) {
                $0.previewStatus = .failed
                $0.previewErrorMessage = error.localizedDescription
                $0.previewProgress = 0
            }
        }

        activePreviewRunner = nil
    }

    private func probeJob(id: UUID) {
        guard let ffprobeURL else {
            updateJob(id) {
                $0.status = .failed
                $0.errorMessage = CompressionError.missingBinary("ffprobe").localizedDescription
            }
            return
        }

        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let inputURL = job.inputURL

        Task.detached(priority: .userInitiated) {
            let result = Result {
                try MediaProbeService(ffprobeURL: ffprobeURL).probe(inputURL)
            }
            await MainActor.run {
                switch result {
                case .success(let metadata):
                    self.updateJob(id) {
                        $0.metadata = metadata
                        $0.status = .ready
                        $0.errorMessage = nil
                        let resolved = self.settings.resolved(for: metadata)
                        $0.outputURL = OutputURLBuilder.compressedOutputURL(for: $0.inputURL, settings: resolved)
                    }
                case .failure(let error):
                    self.updateJob(id) {
                        $0.status = .failed
                        $0.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func updateJob(_ id: UUID, mutate: (inout CompressionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    private func refreshPendingOutputURLs() {
        guard !isRunning else { return }
        for index in jobs.indices where jobs[index].status != .completed && jobs[index].status != .running {
            let resolved = settings.resolved(for: jobs[index].metadata)
            jobs[index].outputURL = OutputURLBuilder.compressedOutputURL(for: jobs[index].inputURL, settings: resolved)
        }
    }

    private func invalidatePendingPreviews() {
        guard !isRunning else { return }
        for index in jobs.indices where jobs[index].status != .completed && jobs[index].previewStatus != .rendering {
            if let previewURL = jobs[index].previewURL {
                try? FileManager.default.removeItem(at: previewURL)
            }
            removeFrameFiles(jobs[index].previewFrames)
            jobs[index].previewURL = nil
            jobs[index].previewMetadata = nil
            jobs[index].previewSizeBytes = nil
            jobs[index].previewStatus = .notRendered
            jobs[index].previewProgress = 0
            jobs[index].previewErrorMessage = nil
            jobs[index].previewFrames = []
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }

    private func generatePreviewFrames(
        jobID: UUID,
        ffmpegURL: URL,
        originalURL: URL,
        previewURL: URL,
        duration: Double
    ) {
        Task {
            let frames = (try? await extractComparisonFrames(
                ffmpegURL: ffmpegURL,
                originalURL: originalURL,
                compressedURL: previewURL,
                duration: duration
            )) ?? []

            guard let index = jobs.firstIndex(where: { $0.id == jobID }),
                  jobs[index].previewURL == previewURL else {
                removeFrameFiles(frames)
                return
            }

            removeFrameFiles(jobs[index].previewFrames)
            jobs[index].previewFrames = frames
        }
    }

    private func generateOutputFrames(
        jobID: UUID,
        ffmpegURL: URL,
        originalURL: URL,
        outputURL: URL,
        duration: Double
    ) {
        guard !outputFrameGenerationJobIDs.contains(jobID) else { return }
        outputFrameGenerationJobIDs.insert(jobID)

        Task {
            defer {
                outputFrameGenerationJobIDs.remove(jobID)
            }

            let frames = (try? await extractComparisonFrames(
                ffmpegURL: ffmpegURL,
                originalURL: originalURL,
                compressedURL: outputURL,
                duration: duration
            )) ?? []

            guard let index = jobs.firstIndex(where: { $0.id == jobID }),
                  jobs[index].outputURL == outputURL else {
                removeFrameFiles(frames)
                return
            }

            removeFrameFiles(jobs[index].outputFrames)
            jobs[index].outputFrames = frames
        }
    }

    private func ensureOutputFrames(for jobID: UUID) {
        guard let ffmpegURL,
              let job = jobs.first(where: { $0.id == jobID }),
              job.status == .completed,
              job.outputFrames.isEmpty else {
            return
        }

        let duration = job.metadata?.duration ?? job.outputMetadata?.duration ?? 0
        guard duration > 0 else { return }

        generateOutputFrames(
            jobID: jobID,
            ffmpegURL: ffmpegURL,
            originalURL: job.inputURL,
            outputURL: job.outputURL,
            duration: duration
        )
    }

    private func extractComparisonFrames(
        ffmpegURL: URL,
        originalURL: URL,
        compressedURL: URL,
        duration: Double
    ) async throws -> [ComparisonFrame] {
        try await Task.detached(priority: .userInitiated) {
            let timestamps = Self.frameTimestamps(duration: duration)
            return try timestamps.enumerated().map { index, timestamp in
                let frameID = UUID().uuidString
                let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                let originalFrame = directory.appendingPathComponent("video-compressor-\(frameID)-original-\(index).png")
                let compressedFrame = directory.appendingPathComponent("video-compressor-\(frameID)-compressed-\(index).png")

                try Self.extractFrame(
                    ffmpegURL: ffmpegURL,
                    inputURL: originalURL,
                    timestamp: timestamp,
                    outputURL: originalFrame
                )
                try Self.extractFrame(
                    ffmpegURL: ffmpegURL,
                    inputURL: compressedURL,
                    timestamp: timestamp,
                    outputURL: compressedFrame
                )

                return ComparisonFrame(
                    originalURL: originalFrame,
                    compressedURL: compressedFrame,
                    timestamp: timestamp
                )
            }
        }.value
    }

    nonisolated private static func frameTimestamps(duration: Double) -> [Double] {
        let safeDuration = max(duration, 0.2)
        let candidates = [
            safeDuration * 0.2,
            safeDuration * 0.5,
            safeDuration * 0.8
        ]
        return candidates.map { min(max($0, 0.1), safeDuration - 0.05) }
    }

    nonisolated private static func extractFrame(
        ffmpegURL: URL,
        inputURL: URL,
        timestamp: Double,
        outputURL: URL
    ) throws {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-ss", String(format: "%.3f", timestamp),
            "-i", inputURL.path,
            "-frames:v", "1",
            "-vf", "format=rgb24",
            outputURL.path
        ]

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CompressionError.processFailed(status: process.terminationStatus, stderr: message)
        }
    }

    private func removeFrameFiles(_ frames: [ComparisonFrame]) {
        for frame in frames {
            try? FileManager.default.removeItem(at: frame.originalURL)
            try? FileManager.default.removeItem(at: frame.compressedURL)
        }
    }
}
