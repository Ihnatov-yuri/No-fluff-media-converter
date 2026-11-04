import Foundation

public struct MediaMetadata: Equatable, Sendable {
    public var duration: Double
    public var videoCodec: String?
    public var audioCodec: String?
    public var hasAudio: Bool
    public var width: Int?
    public var height: Int?
    public var pixelFormat: String?
    public var formatName: String?
    public var frameRate: Double?
    /// ffprobe `color_transfer` of the video stream (e.g. `smpte2084`, `arib-std-b67`).
    public var colorTransfer: String?

    /// PQ (HDR10, Dolby Vision base layers) or HLG transfer.
    public var isHDR: Bool {
        guard let colorTransfer else { return false }
        return colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67"
    }

    /// True when both dimensions are known and even. 4:2:0 encoders reject odd sizes.
    public var hasEvenDimensions: Bool {
        guard let width, let height else { return false }
        return width % 2 == 0 && height % 2 == 0
    }

    public init(
        duration: Double,
        videoCodec: String?,
        audioCodec: String?,
        hasAudio: Bool,
        width: Int?,
        height: Int?,
        pixelFormat: String?,
        formatName: String? = nil,
        frameRate: Double? = nil,
        colorTransfer: String? = nil
    ) {
        self.duration = duration
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.hasAudio = hasAudio
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.formatName = formatName
        self.frameRate = frameRate
        self.colorTransfer = colorTransfer
    }
}
