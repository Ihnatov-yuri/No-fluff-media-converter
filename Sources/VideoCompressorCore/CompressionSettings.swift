import Foundation

public enum CompressionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case quality
    case targetSize

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quality:
            return "Quality"
        case .targetSize:
            return "Target Size"
        }
    }
}

public enum VideoCodecPreset: String, Codable, Sendable {
    case h264
    case hevc
}

public enum QualityPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case smallest
    case smaller
    case balanced
    case high
    case veryHigh

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .smallest:
            return "Smallest"
        case .smaller:
            return "Smaller"
        case .balanced:
            return "Balanced"
        case .high:
            return "High Quality"
        case .veryHigh:
            return "Very High"
        }
    }

    public var detailText: String {
        switch self {
        case .smallest:
            return "Aggressive compression"
        case .smaller:
            return "Smaller files"
        case .balanced:
            return "Good default"
        case .high:
            return "Larger, cleaner"
        case .veryHigh:
            return "Least compression"
        }
    }

    public func crf(for codec: VideoCodecPreset) -> Int {
        switch (self, codec) {
        case (.smallest, .h264):
            return 30
        case (.smaller, .h264):
            return 26
        case (.balanced, .h264):
            return 22
        case (.high, .h264):
            return 20
        case (.veryHigh, .h264):
            return 18
        case (.smallest, .hevc):
            return 32
        case (.smaller, .hevc):
            return 29
        case (.balanced, .hevc):
            return 26
        case (.high, .hevc):
            return 23
        case (.veryHigh, .hevc):
            return 20
        }
    }
}

public enum OutputPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case mp4H264
    case mp4HEVC
    case movH264
    case mp3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mp4H264:
            return "MP4 - Best Compatibility"
        case .mp4HEVC:
            return "MP4 - Smaller File"
        case .movH264:
            return "MOV - Mac Friendly"
        case .mp3:
            return "MP3 - Audio Only"
        }
    }

    public var shortName: String {
        switch self {
        case .mp4H264:
            return "MP4 H.264"
        case .mp4HEVC:
            return "MP4 HEVC"
        case .movH264:
            return "MOV H.264"
        case .mp3:
            return "MP3 Audio"
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC:
            return "mp4"
        case .movH264:
            return "mov"
        case .mp3:
            return "mp3"
        }
    }

    public var isAudioOnly: Bool {
        self == .mp3
    }

    public var videoCodec: VideoCodecPreset {
        switch self {
        case .mp4H264, .movH264, .mp3:
            return .h264
        case .mp4HEVC:
            return .hevc
        }
    }

    public var ffmpegVideoCodec: String {
        switch videoCodec {
        case .h264:
            return "libx264"
        case .hevc:
            return "libx265"
        }
    }

    public var videoCodecDisplayName: String {
        if isAudioOnly { return "Audio only" }
        switch videoCodec {
        case .h264:
            return "H.264"
        case .hevc:
            return "HEVC/H.265"
        }
    }

    public var compatibilitySummary: String {
        switch self {
        case .mp4H264:
            return "Windows-readable MP4"
        case .mp4HEVC:
            return "Smaller MP4 for modern players"
        case .movH264:
            return "Mac-friendly MOV"
        case .mp3:
            return "Audio-only MP3"
        }
    }

    public var isBestWindowsChoice: Bool {
        self == .mp4H264
    }
}

public enum ResolutionCap: String, CaseIterable, Codable, Identifiable, Sendable {
    case original
    case max1080
    case max720
    case max480

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original:
            return "Original"
        case .max1080:
            return "1080p max"
        case .max720:
            return "720p max"
        case .max480:
            return "480p max"
        }
    }

    public var maxHeight: Int? {
        switch self {
        case .original:
            return nil
        case .max1080:
            return 1080
        case .max720:
            return 720
        case .max480:
            return 480
        }
    }
}

public enum AudioBitrate: Int, CaseIterable, Codable, Identifiable, Sendable {
    case kbps96 = 96
    case kbps128 = 128
    case kbps160 = 160
    case kbps192 = 192
    case kbps256 = 256
    case kbps320 = 320

    public var id: Int { rawValue }
    public var displayName: String { "\(rawValue) kbps" }
    public var ffmpegValue: String { "\(rawValue)k" }
}

public enum SilenceSpeed: Double, CaseIterable, Codable, Identifiable, Sendable {
    case x1_25 = 1.25
    case x1_5 = 1.5
    case x2 = 2
    case x3 = 3
    case x4 = 4
    case x8 = 8

    public var id: Double { rawValue }

    public var displayName: String {
        if rawValue == rawValue.rounded() {
            return "\(Int(rawValue))x"
        }
        return "\(rawValue.formatted(.number.precision(.fractionLength(0...2))))x"
    }

    public var multiplier: Double { rawValue }
}

public struct CompressionSettings: Equatable, Codable, Sendable {
    public var mode: CompressionMode
    public var qualityPreset: QualityPreset
    public var targetSizeMB: Double
    public var resolutionCap: ResolutionCap
    public var audioBitrate: AudioBitrate
    public var outputPreset: OutputPreset
    public var speedUpSilence: Bool
    public var silenceSpeed: SilenceSpeed

    public init(
        mode: CompressionMode = .quality,
        qualityPreset: QualityPreset = .balanced,
        targetSizeMB: Double = 50,
        resolutionCap: ResolutionCap = .original,
        audioBitrate: AudioBitrate = .kbps192,
        outputPreset: OutputPreset = .mp4H264,
        speedUpSilence: Bool = false,
        silenceSpeed: SilenceSpeed = .x2
    ) {
        self.mode = mode
        self.qualityPreset = qualityPreset
        self.targetSizeMB = targetSizeMB
        self.resolutionCap = resolutionCap
        self.audioBitrate = audioBitrate
        self.outputPreset = outputPreset
        self.speedUpSilence = speedUpSilence
        self.silenceSpeed = silenceSpeed
    }

    public static let defaults = CompressionSettings()

    public var crf: Int {
        qualityPreset.crf(for: outputPreset.videoCodec)
    }

    public func resolved(for metadata: MediaMetadata?) -> CompressionSettings {
        guard let metadata, metadata.videoCodec == nil else { return self }
        var copy = self
        copy.outputPreset = .mp3
        return copy
    }
}
