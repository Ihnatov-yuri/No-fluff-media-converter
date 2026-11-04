import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Stops a child process reliably.
enum ProcessTermination {
    /// Time ffmpeg gets to exit cleanly after SIGTERM before it is killed.
    static let gracePeriod: TimeInterval = 1.5

    /// Sends SIGTERM, then SIGKILL if the process is still running after the
    /// grace period. A child can inherit a signal mask that blocks SIGTERM
    /// (processes spawned from Dispatch worker threads do on Linux), in which
    /// case SIGTERM alone is ignored until ffmpeg finishes on its own.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let box = ProcessBox(process)
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + gracePeriod) {
            // isRunning stays true until the child is reaped, so the pid cannot
            // have been reused while this check passes.
            if box.process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
