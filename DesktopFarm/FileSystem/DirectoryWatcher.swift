import CoreServices
import Foundation

/// FSEvents watcher for the whole farm tree.
///
/// Events caused purely by metadata (custom-icon xattrs written by
/// `NSWorkspace.setIcon`, Finder's `.DS_Store`, `Icon\r`) are filtered out so
/// that icon refreshes never feed back into a rescan loop.
@MainActor
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var onChange: (@MainActor () -> Void)?
    private var debounceWork: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private(set) var isRunning = false
    private(set) var lastEventAt: Date?

    init(debounceInterval: TimeInterval = 0.35) {
        self.debounceInterval = debounceInterval
    }

    func start(root: URL, onChange: @escaping @MainActor () -> Void) -> Bool {
        stop()
        self.onChange = onChange
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var relevant = false
            for index in 0..<count {
                let path = String(cString: paths[index])
                if DirectoryWatcher.isRelevant(path: path, flags: rawFlags[index]) {
                    relevant = true
                    break
                }
            }
            guard relevant else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                watcher.noteEvent()
            }
        }
        // The stream retains the watcher for its whole lifetime (released on invalidate),
        // so a callback can never reach a deallocated object.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<DirectoryWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        // IgnoreSelf: our own writes (icons, items) never trigger a rescan — the engine
        // already rescans after its own operations. Only the user's / Finder's changes do.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        isRunning = true
        return true
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        isRunning = false
    }

    nonisolated static func isRelevant(path: String, flags: FSEventStreamEventFlags) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" || name == "Icon\r" { return false }
        let contentFlags = UInt32(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged
        )
        return flags & contentFlags != 0
    }

    private func noteEvent() {
        lastEventAt = Date()
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
