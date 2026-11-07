import Foundation

/// Thread-safe holder shared between the `osascript` runner, its timeout and its
/// stderr reader (all on background queues).
final class ScriptRunBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var stderrData = Data()
    private var didTimeOut = false

    init(process: Process) {
        self.process = process
    }

    func terminateIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning {
            didTimeOut = true
            process.terminate()
        }
    }

    func setStderr(_ data: Data) {
        lock.lock()
        stderrData = data
        lock.unlock()
    }

    var stderr: Data {
        lock.lock()
        defer { lock.unlock() }
        return stderrData
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }
}
