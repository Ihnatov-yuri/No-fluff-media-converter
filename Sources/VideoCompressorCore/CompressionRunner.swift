import Foundation

public final class CompressionRunner: @unchecked Sendable {
    private let executableURL: URL
    private let lock = NSLock()
    private var currentProcess: Process?
    private var wasCancelled = false

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func cancel() {
        lock.lock()
        wasCancelled = true
        let process = currentProcess
        lock.unlock()
        process?.terminate()
    }

    public func run(
        plan: CompressionPlan,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        resetCancellation()

        defer {
            cleanup(plan.cleanupURLs)
        }

        for (index, command) in plan.commands.enumerated() {
            try checkCancellation()
            try await run(command: command) { commandProgress in
                let overall = (Double(index) + commandProgress) / Double(plan.commands.count)
                progress(min(max(overall, 0), 1))
            }
        }

        try checkCancellation()
        progress(1)
    }

    private func run(
        command: FFmpegCommand,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var didResume = false

                func resumeOnce(_ result: Result<Void, Error>) {
                    guard !didResume else { return }
                    didResume = true
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                let process = Process()
                process.executableURL = self.executableURL
                process.arguments = command.arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                let outputCollector = ProcessOutputCollector()

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    outputCollector.appendStdout(data, duration: command.duration, progress: progress)
                }

                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    outputCollector.appendStderr(data)
                }

                do {
                    self.lock.lock()
                    self.currentProcess = process
                    self.lock.unlock()

                    try process.run()
                    process.waitUntilExit()

                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil

                    self.lock.lock()
                    self.currentProcess = nil
                    let cancelled = self.wasCancelled
                    self.lock.unlock()

                    if cancelled {
                        resumeOnce(.failure(CompressionError.cancelled))
                    } else if process.terminationStatus == 0 {
                        resumeOnce(.success(()))
                    } else {
                        resumeOnce(.failure(CompressionError.processFailed(
                            status: process.terminationStatus,
                            stderr: outputCollector.stderrSnapshot()
                        )))
                    }
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil

                    self.lock.lock()
                    self.currentProcess = nil
                    self.lock.unlock()

                    resumeOnce(.failure(error))
                }
            }
        }
    }

    private func checkCancellation() throws {
        if isCancelled() {
            throw CompressionError.cancelled
        }
    }

    private func resetCancellation() {
        lock.lock()
        wasCancelled = false
        lock.unlock()
    }

    private func isCancelled() -> Bool {
        lock.lock()
        let cancelled = wasCancelled
        lock.unlock()
        return cancelled
    }

    private func cleanup(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    fileprivate static func progressValue(from line: String, duration: Double) -> Double? {
        if line == "progress=end" {
            return 1
        }

        if let value = line.value(after: "out_time_ms=") ?? line.value(after: "out_time_us="),
           let microseconds = Double(value),
           duration > 0 {
            return microseconds / 1_000_000 / duration
        }

        if let value = line.value(after: "out_time="),
           let seconds = seconds(fromTimestamp: value),
           duration > 0 {
            return seconds / duration
        }

        return nil
    }

    private static func seconds(fromTimestamp timestamp: String) -> Double? {
        let parts = timestamp.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutRemainder = ""
    private var stderrText = ""

    func appendStdout(
        _ data: Data,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        stdoutRemainder += chunk
        let lines = stdoutRemainder.split(separator: "\n", omittingEmptySubsequences: false)
        stdoutRemainder = String(lines.last ?? "")
        let completedLines = lines.dropLast().map(String.init)
        lock.unlock()

        for line in completedLines {
            if let value = CompressionRunner.progressValue(from: line, duration: duration) {
                progress(value)
            }
        }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stderrText += chunk
        if stderrText.count > 8_000 {
            stderrText = String(stderrText.suffix(8_000))
        }
        lock.unlock()
    }

    func stderrSnapshot() -> String {
        lock.lock()
        let snapshot = stderrText
        lock.unlock()
        return snapshot
    }
}
