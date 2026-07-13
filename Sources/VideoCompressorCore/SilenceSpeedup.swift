import Foundation

public struct SilenceInterval: Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct SpeedSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speed: Double

    public init(start: Double, end: Double, speed: Double) {
        self.start = start
        self.end = end
        self.speed = speed
    }
}

public enum SilenceSpeedupDefaults {
    /// Audio below this level counts as silence.
    public static let noiseFloor = "-45dB"
    /// Quiet stretches shorter than this are left untouched.
    public static let minimumSilenceDuration = 1.0
    /// Trailing part of each silence kept at normal speed so speech onsets are never clipped.
    public static let margin = 1.0
}

public enum SilenceSpeedupPlanner {
    private static let minimumSegmentLength = 0.05

    /// Converts detected silences into an alternating list of normal-speed and
    /// sped-up segments covering the whole timeline. Returns [] when there is
    /// nothing worth speeding up, in which case callers should compress normally.
    public static func segments(
        silences: [SilenceInterval],
        duration: Double,
        silentSpeed: Double,
        margin: Double = SilenceSpeedupDefaults.margin
    ) -> [SpeedSegment] {
        guard silentSpeed > 1.001, duration > 0 else { return [] }

        let adjusted = silences.compactMap { silence -> SilenceInterval? in
            let effectiveEnd = silence.end - margin
            guard effectiveEnd > silence.start + 0.1 else { return nil }
            return SilenceInterval(start: silence.start, end: min(effectiveEnd, duration))
        }

        var segments: [SpeedSegment] = []
        var current = 0.0

        for silence in adjusted {
            if silence.start > current + minimumSegmentLength {
                segments.append(SpeedSegment(start: current, end: silence.start, speed: 1.0))
            }
            segments.append(SpeedSegment(start: silence.start, end: silence.end, speed: silentSpeed))
            current = silence.end
        }

        if current < duration - minimumSegmentLength {
            segments.append(SpeedSegment(start: current, end: duration, speed: 1.0))
        }

        segments = segments.filter { ($0.end - $0.start) >= minimumSegmentLength }

        guard segments.contains(where: { $0.speed != 1.0 }) else { return [] }
        return segments
    }

    public static func estimatedDuration(of segments: [SpeedSegment]) -> Double {
        segments.reduce(0) { $0 + ($1.end - $1.start) / $1.speed }
    }

    /// atempo only accepts factors up to 2.0 per instance, so higher speeds chain instances.
    public static func atempoChain(for speed: Double) -> String {
        guard speed > 1.001 else { return "anull" }
        var filters: [String] = []
        var remaining = speed
        while remaining > 2.0 {
            filters.append("atempo=2.0")
            remaining /= 2.0
        }
        if remaining > 1.001 {
            filters.append("atempo=\(formatted(remaining))")
        }
        return filters.joined(separator: ",")
    }

    public static func filtergraph(
        segments: [SpeedSegment],
        includeVideo: Bool,
        includeAudio: Bool,
        scaleFilter: String? = nil
    ) -> String {
        var chains: [String] = []

        for (index, segment) in segments.enumerated() {
            let start = formatted(segment.start)
            let end = formatted(segment.end)

            if includeVideo {
                if segment.speed == 1.0 {
                    chains.append("[0:v]trim=start=\(start):end=\(end),setpts=PTS-STARTPTS[v\(index)]")
                } else {
                    let pts = formatted(1.0 / segment.speed)
                    chains.append("[0:v]trim=start=\(start):end=\(end),setpts=\(pts)*(PTS-STARTPTS)[v\(index)]")
                }
            }

            if includeAudio {
                if segment.speed == 1.0 {
                    chains.append("[0:a]atrim=start=\(start):end=\(end),asetpts=PTS-STARTPTS[a\(index)]")
                } else {
                    let atempo = atempoChain(for: segment.speed)
                    chains.append("[0:a]atrim=start=\(start):end=\(end),asetpts=PTS-STARTPTS,\(atempo)[a\(index)]")
                }
            }
        }

        let concatInputs = segments.indices
            .map { (includeVideo ? "[v\($0)]" : "") + (includeAudio ? "[a\($0)]" : "") }
            .joined()
        let videoCount = includeVideo ? 1 : 0
        let audioCount = includeAudio ? 1 : 0

        let videoLabel = (includeVideo && scaleFilter != nil) ? "[concatv]" : "[outv]"
        var outputs = ""
        if includeVideo { outputs += videoLabel }
        if includeAudio { outputs += "[outa]" }

        var graph = chains
        graph.append("\(concatInputs)concat=n=\(segments.count):v=\(videoCount):a=\(audioCount)\(outputs)")
        if includeVideo, let scaleFilter {
            graph.append("[concatv]\(scaleFilter)[outv]")
        }

        return graph.joined(separator: ";\n")
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

public final class SilenceDetector: @unchecked Sendable {
    private let ffmpegURL: URL

    public init(ffmpegURL: URL) {
        self.ffmpegURL = ffmpegURL
    }

    public func detectSilences(
        in inputURL: URL,
        mediaDuration: Double,
        noiseFloor: String = SilenceSpeedupDefaults.noiseFloor,
        minimumDuration: Double = SilenceSpeedupDefaults.minimumSilenceDuration
    ) throws -> [SilenceInterval] {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-nostdin",
            "-i", inputURL.path,
            "-vn",
            "-af", "silencedetect=noise=\(noiseFloor):d=\(String(format: "%.3f", minimumDuration))",
            "-f", "null",
            "-"
        ]

        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        try process.run()
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let log = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CompressionError.processFailed(status: process.terminationStatus, stderr: log)
        }

        return Self.parse(log: log, mediaDuration: mediaDuration)
    }

    public static func parse(log: String, mediaDuration: Double) -> [SilenceInterval] {
        var starts: [Double] = []
        var ends: [Double] = []

        for line in log.split(separator: "\n") {
            if let value = numericValue(in: line, after: "silence_start: ") {
                starts.append(value)
            }
            if let value = numericValue(in: line, after: "silence_end: ") {
                ends.append(value)
            }
        }

        // A file that ends during silence logs a start with no matching end.
        if starts.count == ends.count + 1 {
            ends.append(mediaDuration)
        }

        return zip(starts, ends).compactMap { start, end in
            end > start ? SilenceInterval(start: start, end: end) : nil
        }
    }

    private static func numericValue(in line: Substring, after token: String) -> Double? {
        guard let range = line.range(of: token) else { return nil }
        let text = line[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(text)
    }
}
