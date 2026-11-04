import Foundation

/// Input options every ffmpeg/ffprobe call uses for user-supplied files.
public enum FFmpegInputPolicy {
    /// Only plain local files. Blocks network protocols (http, rtmp, ...) that a
    /// crafted container or playlist could otherwise make ffmpeg contact.
    public static let protocolWhitelistArguments = ["-protocol_whitelist", "file"]

    /// Demuxers that pull in other files or URLs by reference. A crafted
    /// playlist could copy unrelated local media into the output, so these are
    /// rejected at probe time.
    public static let blockedFormats: Set<String> = ["hls", "applehttp", "concat", "ffmetadata", "tee"]

    public static func isBlocked(formatName: String?) -> Bool {
        guard let formatName else { return false }
        return formatName.split(separator: ",").contains { blockedFormats.contains(String($0)) }
    }
}

public enum BinaryLocator {
    public static func resolve(executableName: String) -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(executableName),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return resolve(
            preferredPath: "/opt/homebrew/bin/\(executableName)",
            executableName: executableName
        )
    }

    public static func resolve(preferredPath: String, executableName: String) -> URL? {
        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: preferredPath) {
            return URL(fileURLWithPath: preferredPath)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executableName)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
