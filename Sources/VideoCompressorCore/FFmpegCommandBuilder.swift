import Foundation

public struct FFmpegCommand: Equatable, Sendable {
    public var arguments: [String]
    public var duration: Double

    public init(arguments: [String], duration: Double) {
        self.arguments = arguments
        self.duration = duration
    }
}

public struct CompressionPlan: Equatable, Sendable {
    public var commands: [FFmpegCommand]
    public var cleanupURLs: [URL]
    public var videoBitrateKbps: Int?

    public init(commands: [FFmpegCommand], cleanupURLs: [URL] = [], videoBitrateKbps: Int? = nil) {
        self.commands = commands
        self.cleanupURLs = cleanupURLs
        self.videoBitrateKbps = videoBitrateKbps
    }
}

public struct FFmpegCommandBuilder: Sendable {
    public var settings: CompressionSettings
    public var inputURL: URL
    public var outputURL: URL
    public var metadata: MediaMetadata
    public var passLogBaseURL: URL?
    public var speedSegments: [SpeedSegment]
    public var scratchDirectoryURL: URL?
    /// Converts HDR (PQ/HLG) sources to SDR BT.709. Only set it when the ffmpeg
    /// build has the `zscale` and `tonemap` filters (see `FFmpegCapabilities`).
    public var toneMapHDR: Bool

    public init(
        settings: CompressionSettings,
        inputURL: URL,
        outputURL: URL,
        metadata: MediaMetadata,
        passLogBaseURL: URL? = nil,
        speedSegments: [SpeedSegment] = [],
        scratchDirectoryURL: URL? = nil,
        toneMapHDR: Bool = false
    ) {
        self.settings = settings
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.metadata = metadata
        self.passLogBaseURL = passLogBaseURL
        self.speedSegments = speedSegments
        self.scratchDirectoryURL = scratchDirectoryURL
        self.toneMapHDR = toneMapHDR
    }

    public func build() throws -> CompressionPlan {
        if settings.outputPreset.isAudioOnly {
            guard metadata.hasAudio else { throw CompressionError.noAudioStream }
            if !speedSegments.isEmpty {
                return try audioOnlySpeedupPlan()
            }
            return CompressionPlan(commands: [audioOnlyCommand(outputURL: outputURL, durationLimit: nil)])
        }
        if !speedSegments.isEmpty {
            return try silenceSpeedupPlan()
        }
        switch settings.mode {
        case .quality:
            return CompressionPlan(commands: [qualityCommand()])
        case .targetSize:
            return try targetSizePlan()
        }
    }

    public func buildSample(outputURL sampleOutputURL: URL, duration sampleDuration: Double = 6) throws -> CompressionPlan {
        let effectiveDuration = max(0.1, min(sampleDuration, metadata.duration))

        if settings.outputPreset.isAudioOnly {
            guard metadata.hasAudio else { throw CompressionError.noAudioStream }
            let command = audioOnlyCommand(outputURL: sampleOutputURL, durationLimit: effectiveDuration)
            return CompressionPlan(commands: [command])
        }

        var arguments = baseArguments(durationLimit: effectiveDuration)
        arguments += videoMap()
        arguments += optionalAudioMap()

        var sampleBitrate: Int?
        switch settings.mode {
        case .quality:
            arguments += qualityVideoArguments()
        case .targetSize:
            let bitrate = try calculatedVideoBitrateKbps()
            sampleBitrate = bitrate
            arguments += bitrateVideoArguments(videoBitrateKbps: bitrate)
        }

        appendVideoFilters(to: &arguments)
        arguments += audioArguments()
        arguments += fastStartArguments()
        arguments += [sampleOutputURL.path]

        return CompressionPlan(
            commands: [FFmpegCommand(arguments: arguments, duration: effectiveDuration)],
            videoBitrateKbps: sampleBitrate
        )
    }

    private func audioOnlyCommand(outputURL audioOutputURL: URL, durationLimit: Double?) -> FFmpegCommand {
        var arguments = baseArguments(durationLimit: durationLimit)
        arguments += [
            "-map", "0:a:0",
            "-vn",
            "-c:a", "libmp3lame",
            "-b:a", settings.audioBitrate.ffmpegValue,
            audioOutputURL.path
        ]
        let duration = durationLimit ?? metadata.duration
        return FFmpegCommand(arguments: arguments, duration: duration)
    }

    private func qualityCommand() -> FFmpegCommand {
        var arguments = baseArguments()
        arguments += videoMap()
        arguments += optionalAudioMap()
        arguments += qualityVideoArguments()
        appendVideoFilters(to: &arguments)
        arguments += audioArguments()
        arguments += fastStartArguments()
        arguments += [outputURL.path]

        return FFmpegCommand(arguments: arguments, duration: metadata.duration)
    }

    private func targetSizePlan() throws -> CompressionPlan {
        let videoBitrate = try calculatedVideoBitrateKbps()
        let passLog = passLogBaseURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("video-compressor-\(UUID().uuidString)")

        var firstPass = baseArguments()
        firstPass += videoMap()
        firstPass += bitrateVideoArguments(videoBitrateKbps: videoBitrate)
        appendVideoFilters(to: &firstPass)
        firstPass += firstPassArguments(passLog: passLog)

        var secondPass = baseArguments()
        secondPass += videoMap()
        secondPass += optionalAudioMap()
        secondPass += bitrateVideoArguments(videoBitrateKbps: videoBitrate)
        appendVideoFilters(to: &secondPass)
        secondPass += secondPassArguments(passLog: passLog)
        secondPass += audioArguments()
        secondPass += fastStartArguments()
        secondPass += [outputURL.path]

        return CompressionPlan(
            commands: [
                FFmpegCommand(arguments: firstPass, duration: metadata.duration),
                FFmpegCommand(arguments: secondPass, duration: metadata.duration)
            ],
            cleanupURLs: passLogCleanupURLs(for: passLog),
            videoBitrateKbps: videoBitrate
        )
    }

    // MARK: - Silence speedup

    /// Speeding up quiet stretches requires trim/concat on exact timestamps, which
    /// desyncs A/V on variable-frame-rate sources (screen recordings, phone video).
    /// So the plan mirrors the proven two-step approach: first normalize to constant
    /// frame rate into a near-lossless temp file, then apply the speed filtergraph
    /// as part of the regular compression encode.
    private func silenceSpeedupPlan() throws -> CompressionPlan {
        let token = UUID().uuidString
        let scratch = scratchDirectory()
        let cfrURL = scratch.appendingPathComponent("video-compressor-cfr-\(token).mov")
        let estimatedDuration = SilenceSpeedupPlanner.estimatedDuration(of: speedSegments)

        let fullGraphURL = scratch.appendingPathComponent("video-compressor-graph-\(token).txt")
        try writeFiltergraph(includeVideo: true, includeAudio: metadata.hasAudio, to: fullGraphURL)

        var cleanupURLs = [cfrURL, fullGraphURL]
        var commands = [cfrNormalizeCommand(outputURL: cfrURL)]
        var videoBitrate: Int?

        switch settings.mode {
        case .quality:
            var arguments = baseArguments(inputPath: cfrURL.path)
            arguments += filtergraphMapArguments(graphURL: fullGraphURL, includeAudio: metadata.hasAudio)
            arguments += qualityVideoArguments()
            if metadata.hasAudio {
                arguments += audioArguments()
            }
            arguments += fastStartArguments()
            arguments += [outputURL.path]
            commands.append(FFmpegCommand(arguments: arguments, duration: estimatedDuration))
        case .targetSize:
            let bitrate = try calculatedVideoBitrateKbps(duration: estimatedDuration)
            videoBitrate = bitrate
            let passLog = passLogBaseURL ?? scratch.appendingPathComponent("video-compressor-\(token)")

            let videoGraphURL = scratch.appendingPathComponent("video-compressor-graph-v-\(token).txt")
            try writeFiltergraph(includeVideo: true, includeAudio: false, to: videoGraphURL)
            cleanupURLs.append(videoGraphURL)
            cleanupURLs += passLogCleanupURLs(for: passLog)

            var firstPass = baseArguments(inputPath: cfrURL.path)
            firstPass += ["-filter_complex_script", videoGraphURL.path, "-map", "[outv]"]
            firstPass += bitrateVideoArguments(videoBitrateKbps: bitrate)
            firstPass += firstPassArguments(passLog: passLog)

            var secondPass = baseArguments(inputPath: cfrURL.path)
            secondPass += filtergraphMapArguments(graphURL: fullGraphURL, includeAudio: metadata.hasAudio)
            secondPass += bitrateVideoArguments(videoBitrateKbps: bitrate)
            secondPass += secondPassArguments(passLog: passLog)
            if metadata.hasAudio {
                secondPass += audioArguments()
            }
            secondPass += fastStartArguments()
            secondPass += [outputURL.path]

            commands.append(FFmpegCommand(arguments: firstPass, duration: estimatedDuration))
            commands.append(FFmpegCommand(arguments: secondPass, duration: estimatedDuration))
        }

        return CompressionPlan(commands: commands, cleanupURLs: cleanupURLs, videoBitrateKbps: videoBitrate)
    }

    private func audioOnlySpeedupPlan() throws -> CompressionPlan {
        let scratch = scratchDirectory()
        let graphURL = scratch.appendingPathComponent("video-compressor-graph-\(UUID().uuidString).txt")
        try writeFiltergraph(includeVideo: false, includeAudio: true, to: graphURL)

        var arguments = baseArguments()
        arguments += [
            "-filter_complex_script", graphURL.path,
            "-map", "[outa]",
            "-c:a", "libmp3lame",
            "-b:a", settings.audioBitrate.ffmpegValue,
            outputURL.path
        ]

        let estimatedDuration = SilenceSpeedupPlanner.estimatedDuration(of: speedSegments)
        return CompressionPlan(
            commands: [FFmpegCommand(arguments: arguments, duration: estimatedDuration)],
            cleanupURLs: [graphURL]
        )
    }

    /// Frame rates outside this range are almost always a bogus timebase
    /// reported for variable-frame-rate files, so the CFR pass falls back to 30.
    static let plausibleFrameRates: ClosedRange<Double> = 1...240

    private func cfrNormalizeCommand(outputURL cfrURL: URL) -> FFmpegCommand {
        let fps = metadata.frameRate.flatMap { Self.plausibleFrameRates.contains($0) ? $0 : nil } ?? 30
        var filter = String(format: "fps=%.6f", fps)
        if !metadata.hasEvenDimensions {
            filter += "," + Self.evenDimensionsExpression
        }

        var arguments = baseArguments()
        // Explicit maps plus -sn/-dn: default stream selection can pull in
        // subtitle or data tracks the MOV intermediate cannot hold.
        arguments += videoMap()
        if metadata.hasAudio {
            arguments += ["-map", "0:a:0"]
        }
        arguments += [
            "-sn", "-dn",
            "-vf", filter,
            "-c:v", "libx264", "-preset", "fast", "-crf", "16",
            "-video_track_timescale", "90000"
        ]
        if metadata.hasAudio {
            // PCM keeps the intermediate lossless so audio is only re-encoded once.
            arguments += ["-c:a", "pcm_s16le"]
        }
        arguments += [cfrURL.path]
        return FFmpegCommand(arguments: arguments, duration: metadata.duration)
    }

    private func writeFiltergraph(includeVideo: Bool, includeAudio: Bool, to url: URL) throws {
        let graph = SilenceSpeedupPlanner.filtergraph(
            segments: speedSegments,
            includeVideo: includeVideo,
            includeAudio: includeAudio,
            scaleFilter: includeVideo ? videoFilterChain() : nil
        )
        try graph.write(to: url, atomically: true, encoding: .utf8)
    }

    private func filtergraphMapArguments(graphURL: URL, includeAudio: Bool) -> [String] {
        var arguments = ["-filter_complex_script", graphURL.path, "-map", "[outv]"]
        if includeAudio {
            arguments += ["-map", "[outa]"]
        }
        return arguments
    }

    private func scratchDirectory() -> URL {
        scratchDirectoryURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    public func calculatedVideoBitrateKbps() throws -> Int {
        try calculatedVideoBitrateKbps(duration: metadata.duration)
    }

    private func calculatedVideoBitrateKbps(duration: Double) throws -> Int {
        guard duration > 0, duration.isFinite else {
            throw CompressionError.invalidDuration
        }
        // Settings come from UserDefaults, which can hold anything. Int() traps on
        // NaN or out-of-range values, so reject them before converting.
        guard settings.targetSizeMB.isFinite, settings.targetSizeMB > 0, settings.targetSizeMB <= 1_000_000 else {
            throw CompressionError.targetSizeTooSmall(minimumMB: 1)
        }

        let audioKbps = metadata.hasAudio ? settings.audioBitrate.rawValue : 0
        let totalBits = settings.targetSizeMB * 1024 * 1024 * 8
        let usableBits = totalBits * 0.97
        let totalKbps = usableBits / duration / 1000
        let videoKbps = Int(floor(totalKbps - Double(audioKbps)))

        guard videoKbps >= 150 else {
            let minimumBits = Double(150 + audioKbps) * 1000 * duration / 0.97
            let minimumMB = minimumBits / 8 / 1024 / 1024
            throw CompressionError.targetSizeTooSmall(minimumMB: minimumMB)
        }

        return videoKbps
    }

    private func baseArguments(durationLimit: Double? = nil, inputPath: String? = nil) -> [String] {
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-progress", "pipe:1",
            "-nostats"
        ]
        arguments += FFmpegInputPolicy.protocolWhitelistArguments
        arguments += ["-i", inputPath ?? inputURL.path]
        if let durationLimit {
            arguments += ["-t", formattedSeconds(durationLimit)]
        }
        return arguments
    }

    private func videoMap() -> [String] {
        ["-map", "0:v:0"]
    }

    private func optionalAudioMap() -> [String] {
        ["-map", "0:a?"]
    }

    private func audioArguments() -> [String] {
        [
            "-c:a", "aac",
            "-b:a", settings.audioBitrate.ffmpegValue
        ]
    }

    private func qualityVideoArguments() -> [String] {
        var arguments = [
            "-c:v", settings.outputPreset.ffmpegVideoCodec,
            "-preset", "medium",
            "-crf", "\(settings.crf)",
            "-pix_fmt", "yuv420p"
        ]
        arguments += outputPresetExtraVideoArguments()
        arguments += colorTagArguments()
        return arguments
    }

    private func bitrateVideoArguments(videoBitrateKbps: Int) -> [String] {
        var arguments = [
            "-c:v", settings.outputPreset.ffmpegVideoCodec,
            "-preset", "medium",
            "-b:v", "\(videoBitrateKbps)k",
            "-pix_fmt", "yuv420p"
        ]
        arguments += outputPresetExtraVideoArguments()
        arguments += colorTagArguments()
        return arguments
    }

    /// Tags tone-mapped output as SDR so players do not treat it as HDR.
    private func colorTagArguments() -> [String] {
        guard appliesToneMapping else { return [] }
        return ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
    }

    private func outputPresetExtraVideoArguments() -> [String] {
        switch settings.outputPreset.videoCodec {
        case .h264:
            return []
        case .hevc:
            return ["-tag:v", "hvc1"]
        }
    }

    private func firstPassArguments(passLog: URL) -> [String] {
        switch settings.outputPreset.videoCodec {
        case .h264:
            return [
                "-pass", "1",
                "-passlogfile", passLog.path,
                "-an",
                "-f", "null",
                "/dev/null"
            ]
        case .hevc:
            return [
                "-x265-params", "pass=1:stats=\(passLog.path)",
                "-an",
                "-f", "null",
                "/dev/null"
            ]
        }
    }

    private func secondPassArguments(passLog: URL) -> [String] {
        switch settings.outputPreset.videoCodec {
        case .h264:
            return [
                "-pass", "2",
                "-passlogfile", passLog.path
            ]
        case .hevc:
            return [
                "-x265-params", "pass=2:stats=\(passLog.path)"
            ]
        }
    }

    private func fastStartArguments() -> [String] {
        ["-movflags", "+faststart"]
    }

    private func appendVideoFilters(to arguments: inout [String]) {
        guard let filter = videoFilterChain() else { return }
        arguments += ["-vf", filter]
    }

    /// 4:2:0 encoders reject odd sizes, so odd sources lose one pixel row/column.
    public static let evenDimensionsExpression = "scale=w=trunc(iw/2)*2:h=trunc(ih/2)*2"

    private var appliesToneMapping: Bool {
        toneMapHDR && metadata.isHDR
    }

    /// Scale (resolution cap, or even-size fix) followed by HDR tone mapping.
    public func videoFilterChain() -> String? {
        var filters: [String] = []
        if let scale = resolutionScaleExpression() {
            filters.append(scale)
        } else if !metadata.hasEvenDimensions {
            filters.append(Self.evenDimensionsExpression)
        }
        if appliesToneMapping, let transfer = metadata.colorTransfer {
            filters.append(
                "zscale=tin=\(transfer):pin=bt2020:min=bt2020nc:t=linear:npl=100,"
                    + "format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,"
                    + "zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
            )
        }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    private func resolutionScaleExpression() -> String? {
        guard let maxHeight = settings.resolutionCap.maxHeight else { return nil }
        return "scale=w=trunc((iw*min(1\\,\(maxHeight)/ih))/2)*2:h=trunc((ih*min(1\\,\(maxHeight)/ih))/2)*2"
    }

    private func passLogCleanupURLs(for baseURL: URL) -> [URL] {
        [
            baseURL,
            URL(fileURLWithPath: "\(baseURL.path)-0.log"),
            URL(fileURLWithPath: "\(baseURL.path)-0.log.mbtree"),
            URL(fileURLWithPath: "\(baseURL.path).log"),
            URL(fileURLWithPath: "\(baseURL.path).log.mbtree"),
            URL(fileURLWithPath: "\(baseURL.path).cutree")
        ]
    }

    private func formattedSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
