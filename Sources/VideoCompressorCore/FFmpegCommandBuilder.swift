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

    public init(
        settings: CompressionSettings,
        inputURL: URL,
        outputURL: URL,
        metadata: MediaMetadata,
        passLogBaseURL: URL? = nil
    ) {
        self.settings = settings
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.metadata = metadata
        self.passLogBaseURL = passLogBaseURL
    }

    public func build() throws -> CompressionPlan {
        if settings.outputPreset.isAudioOnly {
            return CompressionPlan(commands: [audioOnlyCommand(outputURL: outputURL, durationLimit: nil)])
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

        appendResolutionFilter(to: &arguments)
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
        appendResolutionFilter(to: &arguments)
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
        appendResolutionFilter(to: &firstPass)
        firstPass += firstPassArguments(passLog: passLog)

        var secondPass = baseArguments()
        secondPass += videoMap()
        secondPass += optionalAudioMap()
        secondPass += bitrateVideoArguments(videoBitrateKbps: videoBitrate)
        appendResolutionFilter(to: &secondPass)
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

    public func calculatedVideoBitrateKbps() throws -> Int {
        guard metadata.duration > 0 else {
            throw CompressionError.invalidDuration
        }

        let audioKbps = metadata.hasAudio ? settings.audioBitrate.rawValue : 0
        let totalBits = settings.targetSizeMB * 1024 * 1024 * 8
        let usableBits = totalBits * 0.97
        let totalKbps = usableBits / metadata.duration / 1000
        let videoKbps = Int(floor(totalKbps - Double(audioKbps)))

        guard videoKbps >= 150 else {
            let minimumBits = Double(150 + audioKbps) * 1000 * metadata.duration / 0.97
            let minimumMB = minimumBits / 8 / 1024 / 1024
            throw CompressionError.targetSizeTooSmall(minimumMB: minimumMB)
        }

        return videoKbps
    }

    private func baseArguments(durationLimit: Double? = nil) -> [String] {
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-progress", "pipe:1",
            "-nostats",
            "-i", inputURL.path
        ]
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
        return arguments
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

    private func appendResolutionFilter(to arguments: inout [String]) {
        guard let maxHeight = settings.resolutionCap.maxHeight else { return }
        let filter = "scale=w=trunc((iw*min(1\\,\(maxHeight)/ih))/2)*2:h=trunc((ih*min(1\\,\(maxHeight)/ih))/2)*2"
        arguments += ["-vf", filter]
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
