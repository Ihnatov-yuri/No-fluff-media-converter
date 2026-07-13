import Foundation

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
