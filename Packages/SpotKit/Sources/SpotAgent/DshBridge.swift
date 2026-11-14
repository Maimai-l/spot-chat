import Foundation
import Logging
import SpotCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// The way into the DeepSeek Harness the user runs, through Spot Chat's plugin there (`agent/bridge`): a
/// Unix socket only the user's account can reach. A connection first sends Spot Chat's token, and once the
/// plugin admits it, speaks ACP with a dsh-acp server of its own.
///
/// Sandboxed commands can read files and open local sockets, so a token on disk would let one drive dsh and
/// approve its own escapes. Spot Chat keeps the token in the Keychain and writes only its SHA-256 beside the
/// socket, which the plugin compares with.
public struct DshBridge: Sendable, Equatable {
    public enum Failure: LocalizedError, Equatable, Sendable {
        /// Nothing listens: DeepSeek Harness isn't open, or doesn't have the plugin.
        case notRunning
        /// The plugin turned the token down.
        case refused
        /// The plugin didn't answer the token in time.
        case noAnswer
        case pairing(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning:
                return String(localized: "Can’t connect to DeepSeek Harness. Open it, and make sure it has the Spot Chat plugin.")
            case .refused:
                return String(localized: "DeepSeek Harness didn’t accept Spot Chat.")
            case .noAnswer:
                return String(localized: "DeepSeek Harness didn’t answer.")
            case let .pairing(detail):
                return String(localized: "Couldn’t pair with DeepSeek Harness: \(detail)")
            }
        }
    }

    /// The folder the plugin listens in, shared with it.
    public let folder: URL

    public init(folder: URL = DshBridge.standardFolder) {
        self.folder = folder
    }

    /// Where the plugin looks unless told otherwise.
    public static var standardFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Spot Chat/dsh-bridge", isDirectory: true)
    }

    var socket: URL { folder.appendingPathComponent("bridge.sock") }

    /// Whether the plugin is listening: its socket is there, which it is while DeepSeek Harness runs with it.
    public var isListening: Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: socket.path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSocket
    }
    var tokenHash: URL { folder.appendingPathComponent("token.sha256") }

    // MARK: Pairing

    /// Writes the SHA-256 of `token` where the plugin reads it, in a folder only the user can open.
    public func writeTokenHash(of token: String) throws {
        #if canImport(CryptoKit)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let current = try? String(contentsOf: tokenHash, encoding: .utf8)
        guard current?.trimmingCharacters(in: .whitespacesAndNewlines) != digest else { return }
        try (digest + "\n").write(to: tokenHash, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenHash.path)
        SpotLog.agent.info("Paired with DeepSeek Harness", metadata: ["folder": "\(folder.path)"])
        #else
        throw Failure.pairing("SHA-256 isn't available")
        #endif
    }

    // MARK: Connecting

    /// Opens a connection and presents `token`. Returns the connection, ready for ACP, and the version of
    /// dsh's ACP server the plugin found.
    func connect(token: String, timeout: TimeInterval = 10) throws -> (FileHandle, String) {
        let descriptor = try openSocket(timeout: timeout)
        do {
            try send(Data((Self.tokenLine(token) + "\n").utf8), to: descriptor)
            let line = try readLine(from: descriptor)
            guard let data = line.data(using: .utf8),
                  let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  answer["ok"] as? Bool == true
            else {
                SpotLog.agent.error("DeepSeek Harness refused the connection", metadata: ["answer": "\(SpotLog.clip(line))"])
                throw Failure.refused
            }
            // From here the connection is read as data arrives, not with a timeout.
            setReceiveTimeout(0, on: descriptor)
            return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), answer["version"] as? String ?? "")
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Whether the plugin answers and accepts `token`; the connection is closed again at once.
    public func check(token: String) -> Result<String, Failure> {
        do {
            let (handle, version) = try connect(token: token, timeout: 3)
            try? handle.close()
            return .success(version)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.notRunning)
        }
    }

    static func tokenLine(_ token: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["token": token])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func openSocket(timeout: TimeInterval) throws -> Int32 {
        #if os(Linux)
        let descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else {
            SpotLog.agent.error("Couldn't make a socket", metadata: ["errno": "\(errno)"])
            throw Failure.notRunning
        }
        #if canImport(Darwin)
        // A write after the plugin closes must fail, not end the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        setReceiveTimeout(timeout, on: descriptor)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count <= capacity else {
            close(descriptor)
            SpotLog.agent.error("The bridge's socket path is too long", metadata: ["path": "\(socket.path)"])
            throw Failure.notRunning
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            SpotLog.agent.notice("DeepSeek Harness isn't listening", metadata: ["socket": "\(socket.path)", "errno": "\(code)"])
            throw Failure.notRunning
        }
        return descriptor
    }

    private func setReceiveTimeout(_ seconds: TimeInterval, on descriptor: Int32) {
        var time = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    private func send(_ data: Data, to descriptor: Int32) throws {
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else {
            SpotLog.agent.error("Couldn't send the token to DeepSeek Harness", metadata: ["errno": "\(errno)"])
            throw Failure.notRunning
        }
    }

    /// Reads one byte at a time up to the newline, so nothing after the plugin's answer is taken from ACP.
    private func readLine(from descriptor: Int32) throws -> String {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < 4096 {
            let count = read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A { return String(decoding: line, as: UTF8.self) }
                line.append(byte)
            } else if count == 0 {
                // The plugin closed the connection without answering, as it does after a wrong token.
                throw Failure.refused
            } else {
                SpotLog.agent.error("DeepSeek Harness didn't answer the token", metadata: ["errno": "\(errno)"])
                throw Failure.noAnswer
            }
        }
        throw Failure.refused
    }
}

/// Spot Chat's token for the bridge, kept in the login Keychain.
public enum DshBridgeToken {
    private static let service = "Spot Chat dsh bridge"
    private static let account = "token"

    /// The token, made and saved the first time.
    public static func current() throws -> String {
        if let saved = try read() { return saved }
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try save(token)
        SpotLog.agent.info("Made a token for DeepSeek Harness")
        return token
    }

    private static func read() throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            SpotLog.agent.error("Couldn't read the bridge token from the Keychain", metadata: ["status": "\(status)"])
            throw DshBridge.Failure.pairing(keychainMessage(status))
        }
        return String(decoding: data, as: UTF8.self)
        #else
        return nil
        #endif
    }

    private static func save(_ token: String) throws {
        #if canImport(Security)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            SpotLog.agent.error("Couldn't save the bridge token in the Keychain", metadata: ["status": "\(status)"])
            throw DshBridge.Failure.pairing(keychainMessage(status))
        }
        #else
        throw DshBridge.Failure.pairing("there is no Keychain")
        #endif
    }

    #if canImport(Security)
    private static func keychainMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "\(status)"
    }
    #endif
}
