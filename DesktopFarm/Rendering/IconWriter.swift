import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes custom Finder icons *in place*, without the delete/re-create that
/// `NSWorkspace.setIcon` performs.
///
/// `setIcon` clears the custom-icon flag, rewrites the resource fork and, for
/// folders, deletes and re-creates the hidden `Icon\r` file on every call. Finder
/// briefly sees "no custom icon" each time — visible as flicker on files and as the
/// default blue folder icon on folders, which can stick when updates are frequent.
///
/// This writer encodes an `icns`, wraps it in a classic resource fork
/// (`'icns'` resource id -16455) and replaces `com.apple.ResourceFork` with one
/// atomic `setxattr`. The custom-icon flag is only ever *set*, never cleared, and a
/// folder's `Icon\r` file is created once and then reused.
enum IconWriter {
    static let customIconFlag: UInt8 = 0x04
    static let invisibleFlag: UInt8 = 0x40

    /// Encodes a CGImage into `icns` data with the standard sizes.
    static func icnsData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        let sizes = [512, 256, 128, 32, 16]
        guard let destination = CGImageDestinationCreateWithData(data, UTType.icns.identifier as CFString, sizes.count, nil) else { return nil }
        for size in sizes {
            guard let scaled = scale(image, to: size) else { return nil }
            CGImageDestinationAddImage(destination, scaled, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func scale(_ image: CGImage, to size: Int) -> CGImage? {
        if image.width == size && image.height == size { return image }
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }

    /// Classic Mac resource fork containing one `'icns'` resource with id -16455.
    static func resourceFork(icns: Data) -> Data {
        let dataOffset: UInt32 = 256
        let dataLength = UInt32(4 + icns.count)
        let mapOffset = dataOffset + dataLength
        let mapLength: UInt32 = 50

        var out = Data()
        func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { out.append(contentsOf: $0) } }

        // Header + reserved area.
        u32(dataOffset); u32(mapOffset); u32(dataLength); u32(mapLength)
        out.append(Data(count: Int(dataOffset) - 16))
        // Data section: length-prefixed resource body.
        u32(UInt32(icns.count))
        out.append(icns)
        // Resource map.
        u32(dataOffset); u32(mapOffset); u32(dataLength); u32(mapLength)
        u32(0)          // next map handle
        u16(0)          // file ref
        u16(0)          // attributes
        u16(28)         // type list offset (from map start)
        u16(50)         // name list offset (empty)
        u16(0)          // number of types - 1
        out.append(contentsOf: Array("icns".utf8))
        u16(0)          // number of resources of this type - 1
        u16(10)         // reference list offset (from type list start)
        u16(UInt16(bitPattern: -16455)) // resource id
        u16(0xFFFF)     // no name
        out.append(0)   // attributes
        out.append(contentsOf: [0, 0, 0]) // data offset (24-bit) = 0
        u32(0)          // handle
        return out
    }

    // MARK: - Applying

    /// Applies a rendered icon to a regular file or a folder. Thread-safe (pure file I/O).
    @discardableResult
    static func apply(icns: Data, to path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        let fork = resourceFork(icns: icns)
        if isDirectory {
            let iconPath = (path as NSString).appendingPathComponent("Icon\r")
            if !FileManager.default.fileExists(atPath: iconPath) {
                guard FileManager.default.createFile(atPath: iconPath, contents: Data()) else { return false }
            }
            guard setXattr(iconPath, "com.apple.ResourceFork", fork) else { return false }
            setFinderFlag(iconPath, invisibleFlag)
            setFinderFlag(path, customIconFlag)
            // The system icon cache keys folders on their own metadata, not on Icon\r:
            // bump the folder's modification time so the new icon is picked up.
            // lutimes: never follows a symlink swapped in after the lstat above.
            lutimes(path, nil)
        } else {
            guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
            guard setXattr(path, "com.apple.ResourceFork", fork) else { return false }
            setFinderFlag(path, customIconFlag)
        }
        return true
    }

    /// True when the item currently carries a custom icon on disk.
    static func hasCustomIcon(at path: String) -> Bool {
        guard let info = getXattr(path, "com.apple.FinderInfo"), info.count >= 9, info[8] & customIconFlag != 0 else { return false }
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        let target = (st.st_mode & S_IFMT) == S_IFDIR ? (path as NSString).appendingPathComponent("Icon\r") : path
        return xattrSize(target, "com.apple.ResourceFork") > 0
    }

    // MARK: - xattr helpers

    private static func setFinderFlag(_ path: String, _ flag: UInt8) {
        var info = getXattr(path, "com.apple.FinderInfo") ?? Data(count: 32)
        if info.count < 32 { info.append(Data(count: 32 - info.count)) }
        guard info[8] & flag == 0 else { return }
        info[8] |= flag
        _ = setXattr(path, "com.apple.FinderInfo", info)
    }

    private static func setXattr(_ path: String, _ name: String, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            setxattr(path, name, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW) == 0
        }
    }

    private static func xattrSize(_ path: String, _ name: String) -> Int {
        getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    }

    private static func getXattr(_ path: String, _ name: String) -> Data? {
        let size = xattrSize(path, name)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }
}
