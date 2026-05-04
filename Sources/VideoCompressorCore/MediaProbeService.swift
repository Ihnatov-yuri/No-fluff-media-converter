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
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CompressionError.processFailed(status: process.terminationStatus, stderr: stderr)
        }

        guard !data.isEmpty else {
            throw CompressionError.invalidProbeOutput
        }

        let probeOutput = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        let video = probeOutput.streams.first(where: { $0.codecType == "video" })
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
            formatName: probeOutput.format?.formatName
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

    var durationValue: Double? {
        guard let duration else { return nil }
        return Double(duration)
    }

    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
        case codecType = "codec_type"
        case width
        case height
        case pixelFormat = "pix_fmt"
        case duration
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
