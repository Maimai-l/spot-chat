import Foundation
import Testing
@testable import SpotAgent

/// Spot Chat's side of the bridge into the user's DeepSeek Harness.
struct DshBridgeTests {
    func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString.prefix(8))")
    }

    @Test func theTokenGoesAsOneLineOfJSON() throws {
        let line = DshBridge.tokenLine("abc\"def")
        #expect(!line.contains("\n"))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
        #expect(object == ["token": "abc\"def"])
    }

    @Test func nothingListeningReadsAsNotRunning() {
        let bridge = DshBridge(folder: temporaryFolder())
        #expect(bridge.check(token: "token") == .failure(.notRunning))
    }

    #if canImport(CryptoKit)
    @Test func onlyTheTokensHashIsWrittenWhereOnlyTheUserCanRead() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bridge = DshBridge(folder: folder)
        try bridge.writeTokenHash(of: "secret")
        let written = try String(contentsOf: bridge.tokenHash, encoding: .utf8)
        // SHA-256 of "secret".
        #expect(written == "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b\n")
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: bridge.tokenHash.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(fileMode == 0o600)
    }
    #endif
}
