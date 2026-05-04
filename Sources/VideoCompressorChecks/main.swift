import Foundation
import VideoCompressorCore

@main
enum VideoCompressorChecks {
    @MainActor
    static func main() async throws {
        let checks = CheckSuite()

        try checks.run("quality command builds Windows-readable MP4 arguments") {
            let metadata = sampleMetadata
            let inputURL = URL(fileURLWithPath: "/tmp/input.mov")
            let outputURL = URL(fileURLWithPath: "/tmp/output.mp4")
            let plan = try FFmpegCommandBuilder(
                settings: .defaults,
                inputURL: inputURL,
                outputURL: outputURL,
                metadata: metadata
            ).build()

            try checks.expect(plan.commands.count == 1)
            let arguments = plan.commands[0].arguments
            try checks.expect(arguments.containsSequence(["-c:v", "libx264"]))
            try checks.expect(arguments.containsSequence(["-c:a", "aac"]))
            try checks.expect(arguments.containsSequence(["-pix_fmt", "yuv420p"]))
            try checks.expect(arguments.containsSequence(["-movflags", "+faststart"]))
            try checks.expect(arguments.containsSequence(["-map", "0:a?"]))
            try checks.expect(arguments.last == outputURL.path)
        }

        try checks.run("target-size command builds two-pass plan") {
            let settings = CompressionSettings(
                mode: .targetSize,
                qualityPreset: .balanced,
                targetSizeMB: 5,
                resolutionCap: .original,
                audioBitrate: .kbps128,
                outputPreset: .mp4H264
            )
            let passLog = URL(fileURLWithPath: "/tmp/test-passlog")
            let plan = try FFmpegCommandBuilder(
                settings: settings,
                inputURL: URL(fileURLWithPath: "/tmp/input.mov"),
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                metadata: sampleMetadata,
                passLogBaseURL: passLog
            ).build()

            try checks.expect(plan.commands.count == 2)
            try checks.expect(plan.videoBitrateKbps != nil)
            try checks.expect(plan.commands[0].arguments.containsSequence(["-pass", "1"]))
            try checks.expect(plan.commands[0].arguments.containsSequence(["-f", "null"]))
            try checks.expect(plan.commands[1].arguments.containsSequence(["-pass", "2"]))
            try checks.expect(plan.commands[1].arguments.containsSequence(["-passlogfile", passLog.path]))
        }

        try checks.run("target-size rejects impossible size") {
            let settings = CompressionSettings(
                mode: .targetSize,
                qualityPreset: .balanced,
                targetSizeMB: 0.01,
                resolutionCap: .original,
                audioBitrate: .kbps192,
                outputPreset: .mp4H264
            )

            do {
                _ = try FFmpegCommandBuilder(
                    settings: settings,
                    inputURL: URL(fileURLWithPath: "/tmp/input.mov"),
                    outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                    metadata: sampleMetadata
                ).build()
                throw CheckFailure("expected targetSizeTooSmall")
            } catch CompressionError.targetSizeTooSmall {
                return
            }
        }

        try checks.run("resolution cap adds no-upscale scale filter") {
            let settings = CompressionSettings(
                mode: .quality,
                qualityPreset: .balanced,
                targetSizeMB: 50,
                resolutionCap: .max720,
                audioBitrate: .kbps128,
                outputPreset: .mp4H264
            )
            let plan = try FFmpegCommandBuilder(
                settings: settings,
                inputURL: URL(fileURLWithPath: "/tmp/input.mov"),
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                metadata: sampleMetadata
            ).build()
            let arguments = plan.commands[0].arguments
            try checks.expect(arguments.contains("-vf"))
            try checks.expect(arguments.contains { $0.contains("min(1\\,720/ih)") })
        }

        try checks.run("output naming avoids overwrites") {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let source = temporaryDirectory.appendingPathComponent("clip.mov")
            let firstExisting = temporaryDirectory.appendingPathComponent("clip-compressed.mp4")
            try Data().write(to: source)
            try Data().write(to: firstExisting)

            let output = OutputURLBuilder.compressedOutputURL(for: source)
            try checks.expect(output.lastPathComponent == "clip-compressed-2.mp4")
        }

        try checks.run("output preset controls extension and HEVC arguments") {
            let settings = CompressionSettings(
                mode: .quality,
                qualityPreset: .balanced,
                targetSizeMB: 50,
                resolutionCap: .original,
                audioBitrate: .kbps128,
                outputPreset: .mp4HEVC
            )
            let outputURL = URL(fileURLWithPath: "/tmp/output.mp4")
            let plan = try FFmpegCommandBuilder(
                settings: settings,
                inputURL: URL(fileURLWithPath: "/tmp/input.mov"),
                outputURL: outputURL,
                metadata: sampleMetadata
            ).build()

            let arguments = plan.commands[0].arguments
            try checks.expect(settings.crf == 26)
            try checks.expect(arguments.containsSequence(["-c:v", "libx265"]))
            try checks.expect(arguments.containsSequence(["-tag:v", "hvc1"]))
            try checks.expect(settings.outputPreset.fileExtension == "mp4")
        }

        try checks.run("mp3 preset builds audio-only command") {
            let settings = CompressionSettings(
                mode: .quality,
                qualityPreset: .balanced,
                targetSizeMB: 50,
                resolutionCap: .original,
                audioBitrate: .kbps192,
                outputPreset: .mp3
            )
            let outputURL = URL(fileURLWithPath: "/tmp/output.mp3")
            let plan = try FFmpegCommandBuilder(
                settings: settings,
                inputURL: URL(fileURLWithPath: "/tmp/input.mov"),
                outputURL: outputURL,
                metadata: sampleMetadata
            ).build()

            try checks.expect(plan.commands.count == 1)
            let arguments = plan.commands[0].arguments
            try checks.expect(arguments.contains("-vn"))
            try checks.expect(arguments.containsSequence(["-c:a", "libmp3lame"]))
            try checks.expect(arguments.containsSequence(["-b:a", "192k"]))
            try checks.expect(arguments.containsSequence(["-map", "0:a:0"]))
            try checks.expect(!arguments.containsSequence(["-c:v", "libx264"]))
            try checks.expect(arguments.last == outputURL.path)
            try checks.expect(settings.outputPreset.fileExtension == "mp3")
            try checks.expect(settings.outputPreset.isAudioOnly)
        }

        try checks.run("sample command limits duration") {
            let sampleURL = URL(fileURLWithPath: "/tmp/sample.mp4")
            let plan = try FFmpegCommandBuilder(
                settings: .defaults,
                inputURL: URL(fileURLWithPath: "/tmp/input.mov"),
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                metadata: sampleMetadata
            ).buildSample(outputURL: sampleURL, duration: 4)

            try checks.expect(plan.commands.count == 1)
            let arguments = plan.commands[0].arguments
            try checks.expect(arguments.containsSequence(["-t", "4.000"]))
            try checks.expect(arguments.last == sampleURL.path)
            try checks.expect(plan.commands[0].duration == 4)
        }

        if let tools = requiredTools() {
            try await checks.run("quality compression produces H.264/AAC MP4") {
                let directory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }

                let input = directory.appendingPathComponent("input.mov")
                let output = directory.appendingPathComponent("output.mp4")
                try generateSyntheticVideo(ffmpeg: tools.ffmpeg, output: input, duration: 1)

                let metadata = try MediaProbeService(ffprobeURL: tools.ffprobe).probe(input)
                let plan = try FFmpegCommandBuilder(
                    settings: .defaults,
                    inputURL: input,
                    outputURL: output,
                    metadata: metadata
                ).build()

                try await CompressionRunner(executableURL: tools.ffmpeg).run(plan: plan) { _ in }

                let outputMetadata = try MediaProbeService(ffprobeURL: tools.ffprobe).probe(output)
                try checks.expect(outputMetadata.videoCodec == "h264")
                try checks.expect(outputMetadata.audioCodec == "aac")
                try checks.expect(outputMetadata.pixelFormat == "yuv420p")
            }

            try await checks.run("mp3 compression produces audio-only mp3") {
                let directory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }

                let input = directory.appendingPathComponent("input.mov")
                let output = directory.appendingPathComponent("output.mp3")
                try generateSyntheticVideo(ffmpeg: tools.ffmpeg, output: input, duration: 1)

                let metadata = try MediaProbeService(ffprobeURL: tools.ffprobe).probe(input)
                let settings = CompressionSettings(
                    mode: .quality,
                    qualityPreset: .balanced,
                    targetSizeMB: 50,
                    resolutionCap: .original,
                    audioBitrate: .kbps128,
                        outputPreset: .mp3
                )
                let plan = try FFmpegCommandBuilder(
                    settings: settings,
                    inputURL: input,
                    outputURL: output,
                    metadata: metadata
                ).build()

                try await CompressionRunner(executableURL: tools.ffmpeg).run(plan: plan) { _ in }

                let outputMetadata = try MediaProbeService(ffprobeURL: tools.ffprobe).probe(output)
                try checks.expect(outputMetadata.videoCodec == nil)
                try checks.expect(outputMetadata.audioCodec == "mp3")
                try checks.expect(outputMetadata.hasAudio)
            }

            try checks.run("probe accepts audio-only input") {
                let directory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }

                let input = directory.appendingPathComponent("input.wav")
                try generateSyntheticAudio(ffmpeg: tools.ffmpeg, output: input, duration: 1)

                let metadata = try MediaProbeService(ffprobeURL: tools.ffprobe).probe(input)
                try checks.expect(metadata.videoCodec == nil)
                try checks.expect(metadata.hasAudio)
                try checks.expect(metadata.duration > 0)
            }

            try await checks.run("target-size compression produces H.264/AAC MP4") {
                let directory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }

                let input = directory.appendingPathComponent("input.mov")
                let output = directory.appendingPathComponent("target.mp4")
                try generateSyntheticVideo(ffmpeg: tools.ffmpeg, output: input, duration: 1)

                let metadata = try MediaProbeService(ffprobeURL: tools.ffprobe).probe(input)
                let settings = CompressionSettings(
                    mode: .targetSize,
                    qualityPreset: .balanced,
                    targetSizeMB: 1,
                    resolutionCap: .max720,
                    audioBitrate: .kbps128,
                    outputPreset: .mp4H264
                )
                let plan = try FFmpegCommandBuilder(
                    settings: settings,
                    inputURL: input,
                    outputURL: output,
                    metadata: metadata,
                    passLogBaseURL: directory.appendingPathComponent("passlog")
                ).build()

                try await CompressionRunner(executableURL: tools.ffmpeg).run(plan: plan) { _ in }

                let outputMetadata = try MediaProbeService(ffprobeURL: tools.ffprobe).probe(output)
                try checks.expect(outputMetadata.videoCodec == "h264")
                try checks.expect(outputMetadata.audioCodec == "aac")
                try checks.expect(outputMetadata.pixelFormat == "yuv420p")
                try checks.expect(outputMetadata.formatName?.contains("mp4") == true)
            }
        } else {
            print("Skipping FFmpeg integration checks because ffmpeg or ffprobe was not found.")
        }

        try await checks.run("cancel terminates active process") {
            let sleepURL = URL(fileURLWithPath: "/bin/sleep")
            guard FileManager.default.isExecutableFile(atPath: sleepURL.path) else { return }

            let runner = CompressionRunner(executableURL: sleepURL)
            let plan = CompressionPlan(commands: [FFmpegCommand(arguments: ["5"], duration: 5)])

            let task = Task {
                try await runner.run(plan: plan) { _ in }
            }

            try await Task.sleep(nanoseconds: 200_000_000)
            runner.cancel()

            do {
                try await task.value
                throw CheckFailure("expected cancellation")
            } catch CompressionError.cancelled {
                return
            }
        }

        checks.finish()
    }

    private static let sampleMetadata = MediaMetadata(
        duration: 10,
        videoCodec: "h264",
        audioCodec: "aac",
        hasAudio: true,
        width: 1920,
        height: 1080,
        pixelFormat: "yuv420p",
        formatName: "mov,mp4,m4a,3gp,3g2,mj2"
    )

    private static func requiredTools() -> (ffmpeg: URL, ffprobe: URL)? {
        guard let ffmpeg = BinaryLocator.resolve(preferredPath: "/opt/homebrew/bin/ffmpeg", executableName: "ffmpeg"),
              let ffprobe = BinaryLocator.resolve(preferredPath: "/opt/homebrew/bin/ffprobe", executableName: "ffprobe") else {
            return nil
        }
        return (ffmpeg, ffprobe)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func generateSyntheticAudio(ffmpeg: URL, output: URL, duration: Int) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner",
            "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=1000:sample_rate=48000",
            "-t", "\(duration)",
            output.path
        ]

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CompressionError.processFailed(status: process.terminationStatus, stderr: message)
        }
    }

    private static func generateSyntheticVideo(ffmpeg: URL, output: URL, duration: Int) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner",
            "-y",
            "-f", "lavfi",
            "-i", "testsrc=size=320x180:rate=30",
            "-f", "lavfi",
            "-i", "sine=frequency=1000:sample_rate=48000",
            "-t", "\(duration)",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            output.path
        ]

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CompressionError.processFailed(status: process.terminationStatus, stderr: message)
        }
    }
}

@MainActor
private final class CheckSuite {
    private var passed = 0

    func run(_ name: String, body: () throws -> Void) throws {
        print("Checking: \(name)")
        try body()
        passed += 1
    }

    func run(_ name: String, body: () async throws -> Void) async throws {
        print("Checking: \(name)")
        try await body()
        passed += 1
    }

    func expect(_ condition: @autoclosure () -> Bool, _ message: String = "expectation failed") throws {
        if !condition() {
            throw CheckFailure(message)
        }
    }

    func finish() {
        print("All \(passed) checks passed.")
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, count >= sequence.count else { return false }
        for start in 0...(count - sequence.count) {
            if Array(self[start..<(start + sequence.count)]) == sequence {
                return true
            }
        }
        return false
    }
}
