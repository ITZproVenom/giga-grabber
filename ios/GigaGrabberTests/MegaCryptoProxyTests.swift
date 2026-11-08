import XCTest
@testable import GigaGrabber

final class MegaCryptoTests: XCTestCase {
    func testAES128ECBMatchesNISTVector() throws {
        let key = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let plaintext = Data(hex: "00112233445566778899aabbccddeeff")
        let expectedCiphertext = Data(hex: "69c4e0d86a7b0430d8cdb78070b4c55a")

        let encrypted = try MegaCrypto.aesECB(plaintext, key: key, encrypt: true)
        XCTAssertEqual(encrypted, expectedCiphertext)
        XCTAssertEqual(try MegaCrypto.aesECB(encrypted, key: key, encrypt: false), plaintext)
    }

    func testCTRDecryptsAcrossNonBlockAlignedChunks() throws {
        let plaintext = Data("The quick brown fox jumps over the lazy dog.".utf8)
        let ciphertext = try XCTUnwrap(
            Data(base64Encoded: "Qw3Xn9VwnDlnly+dvlsvnxB/FzecjS8zSm4Z9/zIc//C74/EkQWqDB3BvrU=")
        )
        let key = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let iv = Data(hex: "f0f1f2f3f4f5f6f7")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GigaGrabberCryptoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let encryptedURL = directory.appendingPathComponent("encrypted.partial")
        let decryptedURL = directory.appendingPathComponent("decrypted.partial")
        try ciphertext.write(to: encryptedURL)

        try MegaCrypto.decryptCTRFile(
            from: encryptedURL,
            to: decryptedURL,
            key: key,
            iv: iv,
            chunkSize: 7
        )

        XCTAssertEqual(try Data(contentsOf: decryptedURL), plaintext)
    }

    func testCryptoRejectsInvalidAESKeyAndIVLengths() {
        XCTAssertThrowsError(
            try MegaCrypto.aesECB(Data(repeating: 0, count: 16),
                                  key: Data(repeating: 0, count: 15),
                                  encrypt: true)
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GigaGrabberInvalidCrypto-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input")
        let output = directory.appendingPathComponent("output")
        try? Data(repeating: 0, count: 16).write(to: input)

        XCTAssertThrowsError(
            try MegaCrypto.decryptCTRFile(
                from: input,
                to: output,
                key: Data(repeating: 0, count: 16),
                iv: Data(repeating: 0, count: 7)
            )
        )
    }
}

final class ProxyAndSettingsTests: XCTestCase {
    func testProxySchemesUseExpectedDefaultPorts() throws {
        XCTAssertEqual(ProxyEndpoint.parse("http://proxy.example")?.port, 8080)
        XCTAssertEqual(ProxyEndpoint.parse("https://proxy.example")?.port, 443)
        XCTAssertEqual(ProxyEndpoint.parse("socks5://proxy.example")?.port, 1080)
        XCTAssertEqual(ProxyEndpoint.parse("socks5h://proxy.example")?.port, 1080)
    }

    func testProxyParserPreservesCredentialsAndRejectsUnsupportedURLs() throws {
        let proxy = try XCTUnwrap(ProxyEndpoint.parse("https://alice:secret@proxy.example:9443"))
        XCTAssertEqual(proxy.scheme, "https")
        XCTAssertEqual(proxy.host, "proxy.example")
        XCTAssertEqual(proxy.port, 9443)
        XCTAssertEqual(proxy.username, "alice")
        XCTAssertEqual(proxy.password, "secret")
        XCTAssertNil(ProxyEndpoint.parse("ftp://proxy.example:21"))
        XCTAssertNil(ProxyEndpoint.parse("http:///missing-host"))
        XCTAssertNil(ProxyEndpoint.parse("http://proxy.example:70000"))
    }

    func testSettingsNormalizationKeepsAllLimitsWithinDesktopBounds() {
        var settings = GGSettings()
        settings.maxWorkers = 99
        settings.concurrencyBudget = 0
        settings.maxRetries = 99
        settings.timeoutSeconds = 1
        settings.minRetryDelaySeconds = 90
        settings.maxRetryDelaySeconds = 2
        settings.proxyMode = .single
        settings.proxies = [
            "http://one.example:8080",
            "socks5://two.example:1080",
            "not a proxy"
        ]

        settings.normalize()

        XCTAssertEqual(settings.maxWorkers, 10)
        XCTAssertEqual(settings.concurrencyBudget, 1)
        XCTAssertEqual(settings.maxRetries, 20)
        XCTAssertEqual(settings.timeoutSeconds, 5)
        XCTAssertEqual(settings.minRetryDelaySeconds, 60)
        XCTAssertEqual(settings.maxRetryDelaySeconds, 60)
        XCTAssertEqual(settings.proxies, ["http://one.example:8080"])
    }
}

final class TransferModelTests: XCTestCase {
    func testTransferProgressAndEmptyFileBehavior() throws {
        let node = MegaNode(
            name: "sample.bin",
            handle: "abc123",
            parent: nil,
            isFolder: false,
            size: 100,
            aesKey: Data(repeating: 0, count: 16),
            aesIV: Data(repeating: 0, count: 8),
            rootHandle: "abc123"
        )
        let source = ImportedMegaFile(sourceURL: "https://mega.nz/file/abc123#key",
                                      node: node,
                                      relativeDirectory: "")
        var transfer = GGTransfer(sourceURL: source.sourceURL, file: source)
        XCTAssertEqual(transfer.progress, 0)
        transfer.downloadedBytes = 25
        XCTAssertEqual(transfer.progress, 0.25, accuracy: 0.0001)
        transfer.status = .completed
        transfer.downloadedBytes = 100
        XCTAssertEqual(transfer.progress, 1, accuracy: 0.0001)

        let emptyNode = MegaNode(
            name: "empty.bin",
            handle: "empty",
            parent: nil,
            isFolder: false,
            size: 0,
            aesKey: Data(repeating: 0, count: 16),
            aesIV: Data(repeating: 0, count: 8),
            rootHandle: "empty"
        )
        let emptyFile = ImportedMegaFile(sourceURL: "https://mega.nz/file/empty#key",
                                         node: emptyNode,
                                         relativeDirectory: "")
        var emptyTransfer = GGTransfer(sourceURL: emptyFile.sourceURL, file: emptyFile)
        XCTAssertEqual(emptyTransfer.progress, 0)
        emptyTransfer.status = .completed
        XCTAssertEqual(emptyTransfer.progress, 1)
    }

    func testSessionRecordNeverSerializesFileDecryptionKeys() throws {
        let record = DownloadSessionRecord(
            sourceURL: "https://mega.nz/file/abc123#public-key",
            nodeHandle: "abc123",
            relativeDirectory: "folder/subfolder",
            expectedSize: 4096
        )
        let encoded = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(json["nodeHandle"] as? String, "abc123")
        XCTAssertEqual(json["expectedSize"] as? UInt64, 4096)
        XCTAssertNil(json["aesKey"])
        XCTAssertNil(json["aesIV"])
    }
}

private extension Data {
    init(hex: String) {
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let byte = UInt8(hex[index..<next], radix: 16)!
            result.append(byte)
            index = next
        }
        self = result
    }
}
