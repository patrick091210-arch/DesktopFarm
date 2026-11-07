import AppKit
import SpriteKit

/// Borderless, transparent, non-activating full-screen panel at desktop-icon level + 1.
final class DesktopOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isRestorable = false
        setFrame(screen.frame, display: false)
    }
}

/// SKView that accepts first mouse and file drops from Finder.
final class OverlaySKView: SKView {
    var dropValidator: (([URL], CGPoint) -> Bool)?
    var dropHandler: (([URL], CGPoint) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsTransparency = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func urls(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    private func globalPoint(_ info: NSDraggingInfo) -> CGPoint {
        guard let window else { return .zero }
        return window.convertPoint(toScreen: info.draggingLocation)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        (dropValidator?(urls(from: sender), globalPoint(sender)) ?? false) ? .generic : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler?(urls(from: sender), globalPoint(sender)) ?? false
    }
}
