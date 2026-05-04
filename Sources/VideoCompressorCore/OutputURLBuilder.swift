import Foundation

public enum OutputURLBuilder {
    public static func compressedOutputURL(
        for inputURL: URL,
        settings: CompressionSettings = .defaults,
        fileManager: FileManager = .default
    ) -> URL {
        let directory = inputURL.deletingLastPathComponent()
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let initial = directory
            .appendingPathComponent("\(baseName)-compressed")
            .appendingPathExtension(settings.outputPreset.fileExtension)

        guard fileManager.fileExists(atPath: initial.path) else {
            return initial
        }

        var suffix = 2
        while true {
            let candidate = directory
                .appendingPathComponent("\(baseName)-compressed-\(suffix)")
                .appendingPathExtension(settings.outputPreset.fileExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    public static func previewOutputURL(
        for inputURL: URL,
        settings: CompressionSettings = .defaults
    ) -> URL {
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("video-compressor-\(baseName)-sample-\(UUID().uuidString)")
            .appendingPathExtension(settings.outputPreset.fileExtension)
    }
}
