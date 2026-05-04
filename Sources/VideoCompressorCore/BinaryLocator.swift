import Foundation

public enum BinaryLocator {
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
