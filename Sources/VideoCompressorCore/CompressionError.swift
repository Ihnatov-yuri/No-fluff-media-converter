import Foundation

public enum CompressionError: Error, LocalizedError, Equatable {
    case missingBinary(String)
    case invalidProbeOutput
    case noVideoStream
    case invalidDuration
    case targetSizeTooSmall(minimumMB: Double)
    case processFailed(status: Int32, stderr: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingBinary(let name):
            return "Could not find \(name). Install FFmpeg with Homebrew or add it to PATH."
        case .invalidProbeOutput:
            return "FFprobe returned output that could not be read."
        case .noVideoStream:
            return "No video stream was found in this file."
        case .invalidDuration:
            return "The media duration could not be determined."
        case .targetSizeTooSmall(let minimumMB):
            return "Target size is too small. Use at least \(String(format: "%.1f", minimumMB)) MB for this file."
        case .processFailed(let status, let stderr):
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                return "FFmpeg failed with exit code \(status)."
            }
            return "FFmpeg failed with exit code \(status): \(details)"
        case .cancelled:
            return "Compression was cancelled."
        }
    }
}
