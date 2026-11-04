import Foundation

/// Asks an ffmpeg binary which optional filters it was built with. Results are
/// cached per binary path, so the query runs once per launch.
public enum FFmpegCapabilities {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var filterCache: [String: Set<String>] = [:]

    /// True when the build has `zscale` (libzimg) and `tonemap`, needed for HDR to SDR.
    public static func supportsHDRToneMapping(ffmpegURL: URL) -> Bool {
        let filters = availableFilters(ffmpegURL: ffmpegURL)
        return filters.contains("zscale") && filters.contains("tonemap")
    }

    public static func availableFilters(ffmpegURL: URL) -> Set<String> {
        lock.lock()
        if let cached = filterCache[ffmpegURL.path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let filters = queryFilters(ffmpegURL: ffmpegURL)

        lock.lock()
        filterCache[ffmpegURL.path] = filters
        lock.unlock()
        return filters
    }

    /// Parses `ffmpeg -filters` lines such as ` .SC zscale  V->V  Apply resizing...`.
    public static func parseFilterList(_ output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 3,
                  columns[0].count == 3,
                  columns[2].contains("->") else { continue }
            names.insert(String(columns[1]))
        }
        return names
    }

    private static func queryFilters(ffmpegURL: URL) -> Set<String> {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-hide_banner", "-nostdin", "-filters"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return parseFilterList(String(data: data, encoding: .utf8) ?? "")
    }
}
