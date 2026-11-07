import AppKit
import Foundation

/// Screen-space layout of the farm folder's Finder window (icon view).
struct FinderSnapshot: Sendable, Equatable {
    /// Finder window frame in Cocoa global coordinates.
    var windowFrame: CGRect
    /// The icon area (window minus title/toolbar and sidebar), Cocoa global coordinates.
    /// Icons projected outside it (e.g. a scrolled window) are not decorated.
    var contentFrame: CGRect
    /// Icon centres keyed by file name, Cocoa global coordinates.
    var icons: [String: CGPoint]
    /// Raw Finder `position` values (window coordinates) keyed by file name.
    var rawPositions: [String: CGPoint]
    var iconSize: CGFloat
    var windowNumber: Int?
}

/// Syncs real Finder icon positions via AppleScript so effects can hover above files.
///
/// Polls only while enabled. Requires the user to allow "Automation → Finder";
/// if denied, the bridge reports it and the grid layout keeps working.
@MainActor
final class DesktopIconBridge {
    private let root: URL
    private var timer: Timer?
    private var inFlight = false
    private var isActive = false
    private(set) var snapshot: FinderSnapshot?
    private(set) var status = "未启用"
    var onUpdate: ((FinderSnapshot?) -> Void)?

    init(root: URL) {
        self.root = root
    }

    func start() {
        stop()
        isActive = true
        status = "等待 Finder 打开农场文件夹（图标视图）"
        poll()
    }

    func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
        if snapshot != nil {
            snapshot = nil
            onUpdate?(nil)
        }
        status = "未启用"
    }

    /// Adaptive cadence: fast while the farm window is open, slow otherwise, very slow
    /// after a denial or timeout — so no `osascript` process is spawned needlessly.
    private func scheduleNextPoll(after interval: TimeInterval) {
        timer?.invalidate()
        guard isActive else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Opens the farm folder in Finder as an icon-view window.
    func openFarmWindow() {
        let script = """
        tell application "Finder"
            activate
            set farmFolder to (POSIX file "\(Self.escape(root.path))") as alias
            open farmFolder
            set current view of front Finder window to icon view
        end tell
        """
        Task.detached {
            _ = await DesktopIconBridge.runAppleScript(script)
        }
    }

    /// Moves an item back to a raw Finder position (used to return the watering can).
    func setRawPosition(of name: String, to point: CGPoint) {
        let script = """
        tell application "Finder"
            set farmFolder to (POSIX file "\(Self.escape(root.path))") as alias
            set position of item "\(Self.escape(name))" of farmFolder to {\(Int(point.x)), \(Int(point.y))}
        end tell
        """
        Task.detached {
            _ = await DesktopIconBridge.runAppleScript(script)
        }
    }

    private func poll() {
        guard isActive, !inFlight else { return }
        inFlight = true
        let script = Self.queryScript(path: root.path)
        Task { [weak self] in
            let result = await DesktopIconBridge.runAppleScript(script)
            self?.finish(result)
        }
    }

    private func finish(_ result: (output: String, error: String, timedOut: Bool)) {
        inFlight = false
        guard isActive else { return }
        if result.error.contains("-1743") || result.error.contains("Not authorized") {
            status = "未获得「自动化 → Finder」授权，已退回网格坐标模式"
            publish(nil)
            scheduleNextPoll(after: 15)
            return
        }
        if result.timedOut {
            status = "Finder 暂无响应，稍后重试"
            publish(nil)
            scheduleNextPoll(after: 10)
            return
        }
        let parsed = Self.parse(result.output)
        if let parsed {
            status = "已同步 Finder 中 \(parsed.icons.count) 个图标坐标"
        } else {
            // Window closed, minimised or not in icon view: degrade to the grid layout.
            status = "等待 Finder 打开农场文件夹（图标视图）"
        }
        publish(parsed)
        scheduleNextPoll(after: parsed == nil ? 5 : 1.5)
    }

    private func publish(_ parsed: FinderSnapshot?) {
        guard parsed != snapshot else { return }
        snapshot = parsed
        onUpdate?(parsed)
    }

    // MARK: - AppleScript

    nonisolated static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated static func queryScript(path: String) -> String {
        """
        tell application "Finder"
            set out to ""
            set farmFolder to (POSIX file "\(escape(path))") as alias
            repeat with w in (every Finder window)
                try
                    if ((target of w) as alias) is farmFolder and (current view of w) is icon view and (collapsed of w) is false then
                        set b to bounds of w
                        set sw to 0
                        try
                            set sw to sidebar width of w
                        end try
                        set tb to toolbar visible of w
                        set isz to icon size of (icon view options of w)
                        set out to "W" & tab & (item 1 of b) & tab & (item 2 of b) & tab & (item 3 of b) & tab & (item 4 of b) & tab & sw & tab & tb & tab & isz & linefeed
                        repeat with f in (every item of (target of w))
                            set p to position of f
                            set out to out & "I" & tab & (name of f) & tab & (item 1 of p) & tab & (item 2 of p) & linefeed
                        end repeat
                        exit repeat
                    end if
                end try
            end repeat
            return out
        end tell
        """
    }

    nonisolated static func runAppleScript(_ source: String, timeout: TimeInterval = 5) async -> (output: String, error: String, timedOut: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ("", error.localizedDescription, false))
                    return
                }
                let box = ScriptRunBox(process: process)
                // Finder can hang (busy, or an unanswered Automation consent prompt): never
                // let one query block the bridge forever.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    box.terminateIfRunning()
                }
                // Drain stderr concurrently so a chatty stderr can never fill its pipe
                // buffer and deadlock the stdout read below.
                let stderrDone = DispatchGroup()
                stderrDone.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.setStderr(err.fileHandleForReading.readDataToEndOfFile())
                    stderrDone.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stderrDone.wait()
                continuation.resume(returning: (
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: box.stderr, encoding: .utf8) ?? "",
                    box.timedOut
                ))
            }
        }
    }

    /// Parses the tab-separated script output into Cocoa coordinates.
    @MainActor
    static func parse(_ output: String) -> FinderSnapshot? {
        var window: (left: Double, top: Double, right: Double, bottom: Double, sidebar: Double, toolbar: Bool, iconSize: Double)?
        var raw: [String: CGPoint] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "W", parts.count >= 8 {
                let numbers = parts[1...5].compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
                guard numbers.count == 5 else { continue }
                window = (numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], parts[6] == "true", Double(parts[7]) ?? 64)
            } else if parts.first == "I", parts.count >= 4,
                      let x = Double(parts[2].replacingOccurrences(of: ",", with: ".")),
                      let y = Double(parts[3].replacingOccurrences(of: ",", with: ".")) {
                raw[parts[1]] = CGPoint(x: x, y: y)
            }
        }
        guard let window else { return nil }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 900
        let titleHeight: Double = window.toolbar ? 52 : 28
        let contentLeft = window.left + window.sidebar
        let contentTop = window.top + titleHeight
        var icons: [String: CGPoint] = [:]
        for (name, point) in raw {
            let x = contentLeft + Double(point.x)
            let y = contentTop + Double(point.y)
            icons[name] = CGPoint(x: x, y: mainHeight - y)
        }
        let frame = CGRect(x: window.left, y: mainHeight - window.bottom, width: window.right - window.left, height: window.bottom - window.top)
        let content = CGRect(
            x: contentLeft,
            y: mainHeight - window.bottom,
            width: max(0, window.right - contentLeft),
            height: max(0, window.bottom - contentTop)
        )
        return FinderSnapshot(windowFrame: frame, contentFrame: content, icons: icons, rawPositions: raw,
                              iconSize: CGFloat(window.iconSize), windowNumber: finderWindowNumber(matching: window))
    }

    /// Finds the CG window number of the Finder window with matching bounds (no Screen Recording needed).
    private static func finderWindowNumber(matching window: (left: Double, top: Double, right: Double, bottom: Double, sidebar: Double, toolbar: Bool, iconSize: Double)) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerName as String] as? String) == "Finder",
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double],
                  let number = info[kCGWindowNumber as String] as? Int else { continue }
            let x = bounds["X"] ?? 0, y = bounds["Y"] ?? 0, w = bounds["Width"] ?? 0, h = bounds["Height"] ?? 0
            if abs(x - window.left) < 8 && abs(y - window.top) < 8 && abs(w - (window.right - window.left)) < 8 && abs(h - (window.bottom - window.top)) < 8 {
                return number
            }
        }
        return nil
    }
}
