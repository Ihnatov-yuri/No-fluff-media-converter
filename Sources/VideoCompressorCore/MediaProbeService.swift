import Foundation

public final class MediaProbeService: @unchecked Sendable {
    private let ffprobeURL: URL

    public init(ffprobeURL: URL) {
        self.ffprobeURL = ffprobeURL
    }

    public func probe(_ inputURL: URL) throws -> MediaMetadata {
        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            inputURL.path
        ]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()

        // Drain the pipes before waiting: ffprobe blocks once the 64 KB pipe
        // buffer fills, so waiting first deadlocks on files with many streams.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: errorData, encoding: .utf8) ?? ""
            throw CompressionError.processFailed(status: process.terminationStatus, stderr: stderr)
        }

        guard !data.isEmpty else {
            throw CompressionError.invalidProbeOutput
        }

        let probeOutput = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        // Cover art in MP3/M4A/FLAC files shows up as a "video" stream flagged
        // attached_pic. Treating it as video would route music to the MP4 path.
        let video = probeOutput.streams.first(where: { $0.codecType == "video" && !$0.isAttachedPicture })
        let audio = probeOutput.streams.first(where: { $0.codecType == "audio" })

        guard video != nil || audio != nil else {
            throw CompressionError.noVideoStream
        }

        let duration = video?.durationValue
            ?? audio?.durationValue
            ?? probeOutput.format?.durationValue

        guard let duration, duration > 0 else {
            throw CompressionError.invalidDuration
        }

        return MediaMetadata(
            duration: duration,
            videoCodec: video?.codecName,
            audioCodec: audio?.codecName,
            hasAudio: audio != nil,
            width: video?.width,
            height: video?.height,
            pixelFormat: video?.pixelFormat,
            formatName: probeOutput.format?.formatName,
            frameRate: video?.frameRateValue,
            colorTransfer: video?.colorTransfer
        )
    }
}

private struct FFProbeOutput: Decodable {
    var streams: [FFProbeStream]
    var format: FFProbeFormat?
}

private struct FFProbeStream: Decodable {
    var codecName: String?
    var codecType: String?
    var width: Int?
    var height: Int?
    var pixelFormat: String?
    var duration: String?
    var frameRate: String?
    var averageFrameRate: String?
    var colorTransfer: String?
    var disposition: [String: Int]?

    var isAttachedPicture: Bool {
        disposition?["attached_pic"] == 1
    }

    var durationValue: Double? {
        guard let duration else { return nil }
        return Double(duration)
    }

    /// Prefers `avg_frame_rate`: on variable-frame-rate sources `r_frame_rate`
    /// is often a timebase value such as 600/1 or 1000/1.
    var frameRateValue: Double? {
        Self.rate(from: averageFrameRate) ?? Self.rate(from: frameRate)
    }

    private static func rate(from text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator > 0, numerator > 0 else {
            return nil
        }
        return numerator / denominator
    }

    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
        case codecType = "codec_type"
        case width
        case height
        case pixelFormat = "pix_fmt"
        case duration
        case frameRate = "r_frame_rate"
        case averageFrameRate = "avg_frame_rate"
        case colorTransfer = "color_transfer"
        case disposition
    }
}

private struct FFProbeFormat: Decodable {
    var duration: String?
    var formatName: String?

    var durationValue: Double? {
        guard let duration else { return nil }
        return Double(duration)
    }

    enum CodingKeys: String, CodingKey {
        case duration
        case formatName = "format_name"
    }
}
