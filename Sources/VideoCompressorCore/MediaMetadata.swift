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

    public init(
        duration: Double,
        videoCodec: String?,
        audioCodec: String?,
        hasAudio: Bool,
        width: Int?,
        height: Int?,
        pixelFormat: String?,
        formatName: String? = nil,
        frameRate: Double? = nil
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
    }
}
