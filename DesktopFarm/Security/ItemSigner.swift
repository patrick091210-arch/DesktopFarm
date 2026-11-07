import CryptoKit
import Foundation

/// UUID + HMAC-SHA256 signing for every game file and folder marker.
/// The key is a per-install random secret kept in Application Support.
struct ItemSigner: Sendable {
    private let key: SymmetricKey

    init(keyData: Data) {
        self.key = SymmetricKey(data: keyData)
    }

    /// Loads the install secret, creating a new random one on first launch.
    static func loadOrCreate(at url: URL) throws -> ItemSigner {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return ItemSigner(keyData: data)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        let data = Data(bytes)
        try data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ItemSigner(keyData: data)
    }

    func signature(for message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    func verify(_ signature: String, message: String) -> Bool {
        guard let provided = Data(hexString: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(provided, authenticating: Data(message.utf8), using: key)
    }

    func sign(_ payload: GameFilePayload) -> GameFilePayload {
        var signed = payload
        signed.hmacSignature = signature(for: payload.signingMessage)
        return signed
    }

    func isValid(_ payload: GameFilePayload) -> Bool {
        payload.format == GameFilePayload.formatTag
            && payload.subject != nil
            && verify(payload.hmacSignature, message: payload.signingMessage)
    }

    func sign(_ marker: FolderMarker) -> FolderMarker {
        var signed = marker
        signed.hmacSignature = signature(for: marker.signingMessage)
        return signed
    }

    func isValid(_ marker: FolderMarker) -> Bool {
        marker.format == GameFilePayload.formatTag
            && verify(marker.hmacSignature, message: marker.signingMessage)
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Self.nibble(chars[index]), let low = Self.nibble(chars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}
