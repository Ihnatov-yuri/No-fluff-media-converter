import AppKit
import Foundation
import UniformTypeIdentifiers
import VideoCompressorCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var jobs: [CompressionJob] = []
    @Published var settings = AppViewModel.loadSettings() {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
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
    private var activeDetector: SilenceDetector?
    private var activePreviewRunner: CompressionRunner?
    private var activeOutputURL: URL?
    private var isCancelRequested = false
    private var terminationCompletion: (() -> Void)?
    private var outputFrameGenerationJobIDs = Set<UUID>()

    init() {
        self.ffmpegURL = BinaryLocator.resolve(executableName: "ffmpeg")
        self.ffprobeURL = BinaryLocator.resolve(executableName: "ffprobe")

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

    /// True while a compression or a preview sample is still encoding.
    var hasActiveWork: Bool {
        isRunning || activePreviewRunner != nil
    }

    private var isTerminating: Bool {
        terminationCompletion != nil
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

    var canRemoveSelected: Bool {
        guard let selectedJob else { return false }
        return selectedJob.status != .running
    }

    var summaryText: String {
        if jobs.isEmpty {
            return "No files yet"
        }
        let total = jobs.count
        let completed = completedCount
        if isRunning {
            return "Compressing file \(min(completed + 1, total)) of \(total)"
        }
        return "\(total) file\(total == 1 ? "" : "s") · \(completed) completed"
    }

    /// Bytes saved across every completed job, or nil when nothing has finished.
    var totalSavings: (original: Int64, output: Int64)? {
        let finished = jobs.filter { $0.status == .completed && $0.outputSizeBytes != nil }
        guard !finished.isEmpty else { return nil }
        return (
            finished.reduce(0) { $0 + $1.originalSizeBytes },
            finished.reduce(0) { $0 + ($1.outputSizeBytes ?? 0) }
        )
    }

    func addFiles(_ urls: [URL]) {
        var emptyFolders: [String] = []
        var fileURLs: [URL] = []
        for url in urls {
            if Self.isDirectory(url) {
                let found = Self.mediaFiles(inFolder: url)
                if found.isEmpty {
                    emptyFolders.append(url.lastPathComponent)
                }
                fileURLs += found
            } else {
                fileURLs.append(url)
            }
        }
        fileURLs = fileURLs.map { $0.standardizedFileURL }

        if !emptyFolders.isEmpty {
            appError = "No video or audio files found in \(emptyFolders.joined(separator: ", "))."
        }

        for url in fileURLs {
            if jobs.contains(where: { $0.inputURL == url }) {
                continue
            }

            let outputURL = OutputURLBuilder.compressedOutputURL(
                for: url,
                settings: settings,
                reserved: reservedOutputPaths(excluding: nil)
            )
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
        guard !isRunning, !isTerminating else { return }
        guard let ffmpegURL else {
            appError = CompressionError.missingBinary("ffmpeg").localizedDescription
            return
        }

        // Set synchronously so Stop works even before the queue task starts.
        isRunning = true
        isCancelRequested = false
        let settingsSnapshot = settings
        Task {
            await runQueue(ffmpegURL: ffmpegURL, settings: settingsSnapshot)
        }
    }

    /// Stops the queue at whatever step it is in: probing, silence detection or encoding.
    func cancelCompression() {
        guard isRunning else { return }
        isCancelRequested = true
        activeDetector?.cancel()
        activeRunner?.cancel()
    }

    /// Called when the app is about to quit. Stops every ffmpeg process, lets the
    /// queue delete its partial output, then calls `completion`. Falls back to
    /// deleting the partial output itself if ffmpeg does not stop within 5 seconds.
    func stopAllWork(completion: @escaping () -> Void) {
        terminationCompletion = completion
        cancelCompression()
        activePreviewRunner?.cancel()

        // Asynchronous on purpose: the caller must return .terminateLater
        // before the reply is sent.
        Task { @MainActor [weak self] in
            self?.finishTerminationIfIdle()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.forceFinishTermination()
        }
    }

    private func finishTerminationIfIdle() {
        guard let completion = terminationCompletion, !hasActiveWork else { return }
        terminationCompletion = nil
        completion()
    }

    private func forceFinishTermination() {
        guard let completion = terminationCompletion else { return }
        terminationCompletion = nil
        removePartialOutput(activeOutputURL)
        completion()
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
        guard !isTerminating else { return }
        guard let ffmpegURL else {
            appError = CompressionError.missingBinary("ffmpeg").localizedDescription
            return
        }

        Task {
            await renderPreviewSample(jobID: jobID, ffmpegURL: ffmpegURL)
        }
    }

    func removeSelectedJob() {
        guard canRemoveSelected, let selectedJob else { return }
        removeJob(selectedJob.id)
    }

    /// Removes a job from the queue. Never touches the source or a finished output.
    func removeJob(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status != .running else { return }
        if jobs[index].previewStatus == .rendering {
            activePreviewRunner?.cancel()
        }
        removeTemporaryFiles(for: jobs[index])
        jobs.remove(at: index)
        if selectedJobID == id {
            selectedJobID = jobs.indices.contains(index) ? jobs[index].id : jobs.last?.id
        }
    }

    /// Deletes every sample and comparison frame this session wrote to the temp directory.
    func removeAllTemporaryFiles() {
        for job in jobs {
            removeTemporaryFiles(for: job)
        }
    }

    private func removeTemporaryFiles(for job: CompressionJob) {
        if let previewURL = job.previewURL {
            try? FileManager.default.removeItem(at: previewURL)
        }
        removeFrameFiles(job.previewFrames)
        removeFrameFiles(job.outputFrames)
    }

    func clearCompleted() {
        for job in jobs where job.status == .completed {
            removeTemporaryFiles(for: job)
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
            activeDetector = nil
            activeOutputURL = nil
            if isTerminating {
                finishTerminationIfIdle()
            } else if let lastCompletedJobID {
                ensureOutputFrames(for: lastCompletedJobID)
                comparisonRequest = ComparisonRequest(jobID: lastCompletedJobID, stage: .after)
            }
        }

        let toneMapHDR = await Self.supportsToneMapping(ffmpegURL: ffmpegURL)

        let ids = jobs.filter { $0.status.canRun }.map(\.id)
        for id in ids {
            if isCancelRequested { break }
            guard let inputURL = jobs.first(where: { $0.id == id })?.inputURL else { continue }
            selectedJobID = id
            var startedOutputURL: URL?

            do {
                let metadata = try await metadataForRun(jobID: id)
                try throwIfCancelRequested()
                let resolvedSettings = settings.resolved(for: metadata)
                let outputURL = OutputURLBuilder.compressedOutputURL(
                    for: inputURL,
                    settings: resolvedSettings,
                    reserved: reservedOutputPaths(excluding: id)
                )
                // The builder never reuses an existing name, so anything at this
                // path after a failure is our own partial file and safe to delete.
                startedOutputURL = outputURL
                activeOutputURL = outputURL
                updateJob(id) {
                    removeFrameFiles($0.outputFrames)
                    $0.metadata = metadata
                    $0.outputURL = outputURL
                    $0.outputMetadata = nil
                    $0.outputSizeBytes = nil
                    $0.appliedSettings = resolvedSettings
                    $0.outputFrames = []
                    $0.speedSegments = []
                    $0.status = .running
                    $0.progress = 0
                    $0.errorMessage = nil
                }

                let detector = SilenceDetector(ffmpegURL: ffmpegURL)
                activeDetector = detector
                let speedSegments = try await detectSpeedSegments(
                    inputURL: inputURL,
                    metadata: metadata,
                    settings: resolvedSettings,
                    detector: detector
                )
                activeDetector = nil
                try throwIfCancelRequested()
                updateJob(id) { $0.speedSegments = speedSegments }

                let plan = try FFmpegCommandBuilder(
                    settings: resolvedSettings,
                    inputURL: inputURL,
                    outputURL: outputURL,
                    metadata: metadata,
                    speedSegments: speedSegments,
                    toneMapHDR: toneMapHDR
                ).build()

                let runner = CompressionRunner(executableURL: ffmpegURL)
                activeRunner = runner
                try await runner.run(plan: plan) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateJob(id) { job in
                            // Late updates must not pull a finished job back below 100%.
                            guard job.status == .running else { return }
                            job.progress = progress
                        }
                    }
                }
                activeRunner = nil

                let outputSize = fileSize(at: outputURL)
                let outputMetadata = try? await probeMetadata(outputURL)
                updateJob(id) {
                    $0.status = .completed
                    $0.progress = 1
                    $0.outputSizeBytes = outputSize
                    $0.outputMetadata = outputMetadata
                    $0.errorMessage = nil
                }
                activeOutputURL = nil
                lastCompletedJobID = id
            } catch {
                activeRunner = nil
                activeDetector = nil
                activeOutputURL = nil
                removePartialOutput(startedOutputURL)
                // A stopped ffmpeg can also surface as a non-zero exit, so the
                // request flag decides, not only the error type.
                if isCancelRequested || (error as? CompressionError) == .cancelled {
                    updateJob(id) {
                        $0.status = .cancelled
                        $0.progress = 0
                        $0.errorMessage = CompressionError.cancelled.localizedDescription
                    }
                    break
                }
                updateJob(id) {
                    $0.status = .failed
                    $0.progress = 0
                    $0.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func throwIfCancelRequested() throws {
        if isCancelRequested {
            throw CompressionError.cancelled
        }
    }

    nonisolated private static func supportsToneMapping(ffmpegURL: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            FFmpegCapabilities.supportsHDRToneMapping(ffmpegURL: ffmpegURL)
        }.value
    }

    /// Output paths promised to queued jobs, so two inputs that share a base
    /// name (clip.mov, clip.mp4) never show or claim the same output file.
    private func reservedOutputPaths(excluding id: UUID?) -> Set<String> {
        Set(jobs.filter { $0.id != id && $0.status != .completed }.map(\.outputURL.path))
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Video and audio files inside a dropped folder, including subfolders, in name order.
    nonisolated private static func mediaFiles(inFolder folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .audiovisualContent) else { continue }
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func removePartialOutput(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Settings persistence

    private static let settingsDefaultsKey = "compressionSettings"

    private static func loadSettings() -> CompressionSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsDefaultsKey),
              let stored = try? JSONDecoder().decode(CompressionSettings.self, from: data) else {
            return .defaults
        }
        return stored
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsDefaultsKey)
    }

    /// Runs the silence-detection pass when the setting is enabled. Returns [] when
    /// disabled, when the file has no audio, or when nothing worth speeding up was
    /// found — the job then compresses normally.
    private func detectSpeedSegments(
        inputURL: URL,
        metadata: MediaMetadata,
        settings: CompressionSettings,
        detector: SilenceDetector
    ) async throws -> [SpeedSegment] {
        guard settings.speedUpSilence, metadata.hasAudio else { return [] }

        let duration = metadata.duration
        let silences = try await Task.detached(priority: .userInitiated) {
            try detector.detectSilences(in: inputURL, mediaDuration: duration)
        }.value

        return SilenceSpeedupPlanner.segments(
            silences: silences,
            duration: duration,
            silentSpeed: settings.silenceSpeed.multiplier
        )
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
        var startedPreviewURL: URL?

        do {
            let metadata = try await metadataForRun(jobID: jobID)
            let resolvedSettings = settingsSnapshot.resolved(for: metadata)
            let previewURL = OutputURLBuilder.previewOutputURL(for: inputURL, settings: resolvedSettings)
            startedPreviewURL = previewURL
            let toneMapHDR = await Self.supportsToneMapping(ffmpegURL: ffmpegURL)
            updateJob(jobID) {
                $0.previewSettings = resolvedSettings
            }
            let plan = try FFmpegCommandBuilder(
                settings: resolvedSettings,
                inputURL: inputURL,
                outputURL: previewURL,
                metadata: metadata,
                toneMapHDR: toneMapHDR
            ).buildSample(outputURL: previewURL)

            let runner = CompressionRunner(executableURL: ffmpegURL)
            activePreviewRunner = runner
            if isTerminating {
                runner.cancel()
            }
            try await runner.run(plan: plan) { [weak self] progress in
                Task { @MainActor in
                    self?.updateJob(jobID) { job in
                        guard job.previewStatus == .rendering else { return }
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
            removePartialOutput(startedPreviewURL)
            updateJob(jobID) {
                $0.previewStatus = .notRendered
                $0.previewErrorMessage = nil
                $0.previewProgress = 0
            }
        } catch {
            removePartialOutput(startedPreviewURL)
            updateJob(jobID) {
                $0.previewStatus = .failed
                $0.previewErrorMessage = error.localizedDescription
                $0.previewProgress = 0
            }
        }

        activePreviewRunner = nil
        finishTerminationIfIdle()
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
                    let reserved = self.reservedOutputPaths(excluding: id)
                    self.updateJob(id) {
                        $0.metadata = metadata
                        $0.status = .ready
                        $0.errorMessage = nil
                        let resolved = self.settings.resolved(for: metadata)
                        $0.outputURL = OutputURLBuilder.compressedOutputURL(
                            for: $0.inputURL,
                            settings: resolved,
                            reserved: reserved
                        )
                    }
                case .failure(let error):
                    self.updateJob(id) {
                        $0.status = .failed
                        if case CompressionError.processFailed = error {
                            $0.errorMessage = "Not a media file FFmpeg can read."
                        } else {
                            $0.errorMessage = error.localizedDescription
                        }
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
        var reserved = Set<String>()
        for index in jobs.indices where jobs[index].status != .completed && jobs[index].status != .running {
            let resolved = settings.resolved(for: jobs[index].metadata)
            let url = OutputURLBuilder.compressedOutputURL(
                for: jobs[index].inputURL,
                settings: resolved,
                reserved: reserved
            )
            jobs[index].outputURL = url
            reserved.insert(url.path)
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
            let frames = await extractComparisonFrames(
                ffmpegURL: ffmpegURL,
                originalURL: originalURL,
                compressedURL: previewURL,
                duration: duration,
                speedSegments: [],
                compressedDuration: nil
            )

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
        duration: Double,
        speedSegments: [SpeedSegment],
        outputDuration: Double?
    ) {
        guard !outputFrameGenerationJobIDs.contains(jobID) else { return }
        outputFrameGenerationJobIDs.insert(jobID)

        Task {
            defer {
                outputFrameGenerationJobIDs.remove(jobID)
            }

            let frames = await extractComparisonFrames(
                ffmpegURL: ffmpegURL,
                originalURL: originalURL,
                compressedURL: outputURL,
                duration: duration,
                speedSegments: speedSegments,
                compressedDuration: outputDuration
            )

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
            duration: duration,
            speedSegments: job.speedSegments,
            outputDuration: job.outputMetadata?.duration
        )
    }

    /// Extracts matching frame pairs. With silence speed-up the output timeline
    /// is shorter, so each source time is mapped to its output time. A pair that
    /// fails is skipped; the others are still returned.
    private func extractComparisonFrames(
        ffmpegURL: URL,
        originalURL: URL,
        compressedURL: URL,
        duration: Double,
        speedSegments: [SpeedSegment],
        compressedDuration: Double?
    ) async -> [ComparisonFrame] {
        await Task.detached(priority: .userInitiated) {
            let timestamps = Self.frameTimestamps(duration: duration)
            return timestamps.enumerated().compactMap { index, timestamp -> ComparisonFrame? in
                var compressedTimestamp = SilenceSpeedupPlanner.outputTime(
                    forSourceTime: timestamp,
                    segments: speedSegments
                )
                if let compressedDuration, compressedDuration > 0.1 {
                    compressedTimestamp = min(compressedTimestamp, compressedDuration - 0.05)
                }
                compressedTimestamp = max(0, compressedTimestamp)

                let frameID = UUID().uuidString
                let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                let originalFrame = directory.appendingPathComponent("video-compressor-\(frameID)-original-\(index).png")
                let compressedFrame = directory.appendingPathComponent("video-compressor-\(frameID)-compressed-\(index).png")

                do {
                    try Self.extractFrame(
                        ffmpegURL: ffmpegURL,
                        inputURL: originalURL,
                        timestamp: timestamp,
                        outputURL: originalFrame
                    )
                    try Self.extractFrame(
                        ffmpegURL: ffmpegURL,
                        inputURL: compressedURL,
                        timestamp: compressedTimestamp,
                        outputURL: compressedFrame
                    )
                } catch {
                    try? FileManager.default.removeItem(at: originalFrame)
                    try? FileManager.default.removeItem(at: compressedFrame)
                    return nil
                }

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
