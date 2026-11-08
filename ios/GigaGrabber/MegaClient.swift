import Foundation
import CommonCrypto

enum MegaClientError: LocalizedError {
    case malformedLink
    case invalidKey
    case apiCode(Int)
    case invalidAttributes
    case missingNode(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .malformedLink: return "This is not a supported public MEGA file or folder link."
        case .invalidKey: return "The decryption key in the MEGA link is invalid."
        case .apiCode(let code): return "MEGA API error \(code)."
        case .invalidAttributes: return "MEGA returned attributes that could not be decrypted."
        case .missingNode(let handle): return "The selected MEGA item (\(handle)) is no longer available."
        case .invalidResponse: return "MEGA returned an unexpected response."
        }
    }
}

final class MegaClient {
    private let http: ProxyHTTPClient
    private static let apiOrigin = "https://g.api.mega.co.nz/cs"
    private static let requestID = RequestCounter()

    init(settings: GGSettings) { self.http = ProxyHTTPClient(settings: settings) }

    func fetchPublicNodes(from rawLink: String) async throws -> [ImportedMegaFile] {
        let parsed = try Self.parsePublicLink(rawLink)
        if parsed.isFile {
            let response = try await callAPI(query: [:], body: [[
                "a": "g", "g": 1, "ssl": 2, "p": parsed.handle
            ]])
            let file = try Self.decodeFirst(DownloadResponse.self, from: response)
            let material = try Self.fileKeyMaterial(parsed.key)
            let name = try MegaCrypto.decryptAttributes(file.attributes, key: material.key)
            let node = MegaNode(name: name, handle: parsed.handle, parent: nil,
                                isFolder: false, size: file.size, aesKey: material.key,
                                aesIV: material.iv, rootHandle: parsed.handle)
            return [ImportedMegaFile(sourceURL: rawLink, node: node, relativeDirectory: "")]
        }

        let responseData = try await callAPI(query: ["n": parsed.handle], body: [[
            "a": "f", "c": 1, "r": 1
        ]])
        let decoded = try Self.decodeFirst(FolderResponse.self, from: responseData)
        let rootKey = parsed.key
        guard rootKey.count == 16 else { throw MegaClientError.invalidKey }

        var shareKeys: [String: Data] = [parsed.handle: rootKey]
        for shared in decoded.sharedKeys {
            guard let encrypted = Data.ggBase64URL(shared.key), encrypted.count == 16 else { continue }
            let decrypted = try MegaCrypto.aesECB(encrypted, key: rootKey, encrypt: false)
            shareKeys[shared.handle] = decrypted
        }
        for entry in decoded.nodes {
            guard let sharingKey = entry.sharingKey,
                  let encrypted = Data.ggBase64URL(sharingKey), encrypted.count == 16 else { continue }
            let decrypted = try MegaCrypto.aesECB(encrypted, key: rootKey, encrypt: false)
            shareKeys[entry.handle] = decrypted
        }

        let orderedHandles = [parsed.handle] + shareKeys.keys.filter { $0 != parsed.handle }.sorted()
        var nodes: [String: MegaNode] = [:]
        for entry in decoded.nodes {
            guard entry.kind == 0 || entry.kind == 1, let encodedKey = entry.key else { continue }
            let candidates = try Self.nodeKeyCandidates(encodedKey, shareKeys: shareKeys,
                                                        orderedHandles: orderedHandles)
            var material: (Data, Data?, String)?
            for candidate in candidates {
                if entry.kind == 0 {
                    guard candidate.count == 32 else { continue }
                    var merged = [UInt8](candidate)
                    for i in 0..<16 { merged[i] ^= merged[i + 16] }
                    let key = Data(merged.prefix(16))
                    let iv = Data(merged[16..<24])
                    if let name = try? MegaCrypto.decryptAttributes(entry.attributes, key: key) {
                        material = (key, iv, name)
                        break
                    }
                } else {
                    guard candidate.count == 16 else { continue }
                    if let name = try? MegaCrypto.decryptAttributes(entry.attributes, key: candidate) {
                        material = (candidate, nil, name)
                        break
                    }
                }
            }
            guard let material else { continue }
            nodes[entry.handle] = MegaNode(
                name: material.2, handle: entry.handle, parent: entry.parent,
                isFolder: entry.kind == 1, size: entry.size ?? 0,
                aesKey: material.0, aesIV: material.1, rootHandle: parsed.handle
            )
        }

        // Ignore parent handles outside the shared tree, matching the desktop implementation.
        for (handle, var node) in nodes {
            if let parent = node.parent, nodes[parent] == nil { node.parent = nil }
            nodes[handle] = node
        }

        func directory(of node: MegaNode) -> String {
            var components: [String] = []
            var parent = node.parent
            var visited = Set<String>()
            while let handle = parent, let ancestor = nodes[handle],
                  visited.insert(handle).inserted {
                if ancestor.handle != parsed.handle { components.append(ancestor.name) }
                parent = ancestor.parent
            }
            return components.reversed().joined(separator: "/")
        }

        return nodes.values
            .filter { !$0.isFolder }
            .map { ImportedMegaFile(sourceURL: rawLink, node: $0, relativeDirectory: directory(of: $0)) }
            .sorted {
                let a = ($0.relativeDirectory + "/" + $0.node.name).lowercased()
                let b = ($1.relativeDirectory + "/" + $1.node.name).lowercased()
                return a < b
            }
    }

    func downloadURL(for node: MegaNode) async throws -> URL {
        var query: [String: String] = [:]
        let body: [[String: Any]]
        if node.parent == nil {
            body = [["a": "g", "g": 1, "ssl": 2, "p": node.handle]]
        } else {
            query["n"] = node.rootHandle
            body = [["a": "g", "g": 1, "ssl": 2, "n": node.handle]]
        }
        let data = try await callAPI(query: query, body: body)
        let response = try Self.decodeFirst(DownloadResponse.self, from: data)
        guard let url = URL(string: response.downloadURL) else { throw GGNetworkError.missingDownloadURL }
        return url
    }

    func downloadEncrypted(_ url: URL, to partialURL: URL, expectedSize: UInt64,
                           progress: @escaping @Sendable (UInt64, Double) -> Void) async throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: partialURL.path) {
            manager.createFile(atPath: partialURL.path, contents: nil)
        }
        let existing = (try? manager.attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if existing >= expectedSize { return }
        let offset = existing > 0 ? existing.saturatingSubtract(1_048_576) : 0
        if offset < existing {
            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.truncate(atOffset: offset)
            try handle.close()
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        try await http.download(request: request, encryptedPartialURL: partialURL,
                                remoteSize: expectedSize, resumeOffset: offset, progress: progress)
        let finalLength = (try? manager.attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard finalLength >= expectedSize else {
            throw URLError(.networkConnectionLost, userInfo: [
                NSLocalizedDescriptionKey: "The transfer ended before all bytes arrived."
            ])
        }
    }

    private func callAPI(query: [String: String], body: [[String: Any]]) async throws -> Data {
        var components = URLComponents(string: Self.apiOrigin)!
        var items = [URLQueryItem(name: "id", value: String(Self.requestID.next()))]
        for (key, value) in query { items.append(URLQueryItem(name: key, value: value)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await http.data(for: request)
    }

    private struct ParsedLink {
        let isFile: Bool
        let handle: String
        let key: Data
    }

    private static func parsePublicLink(_ raw: String) throws -> ParsedLink {
        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased(),
              ["mega.nz", "www.mega.nz", "mega.co.nz", "www.mega.co.nz"].contains(host) else {
            throw MegaClientError.malformedLink
        }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "file" || parts[0] == "folder" else {
            throw MegaClientError.malformedLink
        }
        let fragment = components.percentEncodedFragment ?? components.fragment ?? ""
        let keyPart = fragment.split(separator: "/").first.map(String.init) ?? ""
        guard let key = Data.ggBase64URL(keyPart), !key.isEmpty else { throw MegaClientError.invalidKey }
        let isFile = parts[0] == "file"
        guard (isFile && key.count == 32) || (!isFile && key.count == 16) else {
            throw MegaClientError.invalidKey
        }
        return ParsedLink(isFile: isFile, handle: String(parts[1]), key: key)
    }

    private static func fileKeyMaterial(_ keyData: Data) throws -> (key: Data, iv: Data) {
        guard keyData.count == 32 else { throw MegaClientError.invalidKey }
        var merged = [UInt8](keyData)
        for i in 0..<16 { merged[i] ^= merged[i + 16] }
        return (Data(merged.prefix(16)), Data(merged[16..<24]))
    }

    private static func nodeKeyCandidates(_ field: String, shareKeys: [String: Data],
                                          orderedHandles: [String]) throws -> [Data] {
        let entries = field.split(separator: "/").compactMap { entry -> (String, String)? in
            let pair = entry.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        }
        var result: [Data] = []
        var seen = Set<Data>()
        for (handle, encoded) in entries {
            guard let shareKey = shareKeys[handle], let raw = Data.ggBase64URL(encoded),
                  raw.count == 16 || raw.count == 32 else { continue }
            let decoded = try MegaCrypto.aesECB(raw, key: shareKey, encrypt: false)
            if seen.insert(decoded).inserted { result.append(decoded) }
        }
        for (_, encoded) in entries {
            guard let raw = Data.ggBase64URL(encoded), raw.count == 16 || raw.count == 32 else { continue }
            for handle in orderedHandles {
                guard let shareKey = shareKeys[handle] else { continue }
                let candidate = try MegaCrypto.aesECB(raw, key: shareKey, encrypt: false)
                if seen.insert(candidate).inserted { result.append(candidate) }
            }
        }
        return result
    }

    private static func decodeFirst<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [Any],
              let first = values.first else { throw MegaClientError.invalidResponse }
        if let number = first as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            throw MegaClientError.apiCode(number.intValue)
        }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: first))
    }

    private struct DownloadResponse: Decodable {
        enum CodingKeys: String, CodingKey { case downloadURL = "g", size = "s", attributes = "at" }
        let downloadURL: String
        let size: UInt64
        let attributes: String
    }

    private struct FolderResponse: Decodable {
        enum CodingKeys: String, CodingKey { case nodes = "f", sharedKeys = "ok" }
        let nodes: [FolderEntry]
        let sharedKeys: [SharedKey]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nodes = try c.decode([FolderEntry].self, forKey: .nodes)
            sharedKeys = try c.decodeIfPresent([SharedKey].self, forKey: .sharedKeys) ?? []
        }
    }

    private struct SharedKey: Decodable {
        enum CodingKeys: String, CodingKey { case handle = "h", key = "k" }
        let handle: String
        let key: String
    }

    private struct FolderEntry: Decodable {
        enum CodingKeys: String, CodingKey {
            case kind = "t", attributes = "a", handle = "h", parent = "p",
                 key = "k", size = "s", sharingKey = "sk"
        }
        let kind: Int
        let attributes: String
        let handle: String
        let parent: String?
        let key: String?
        let size: UInt64?
        let sharingKey: String?
    }
}

private final class RequestCounter {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

enum MegaCrypto {
    static func aesECB(_ input: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == kCCKeySizeAES128, input.count % kCCBlockSizeAES128 == 0 else {
            throw MegaClientError.invalidKey
        }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, output.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        output.count = moved
        return output
    }

    static func decryptAttributes(_ encoded: String, key: Data) throws -> String {
        guard let encrypted = Data.ggBase64URL(encoded), encrypted.count >= 16,
              encrypted.count % 16 == 0, key.count == 16 else {
            throw MegaClientError.invalidAttributes
        }
        var output = Data(count: encrypted.count + 16)
        var moved = 0
        let zeroIV = Data(repeating: 0, count: 16)
        let status = key.withUnsafeBytes { keyBytes in
            zeroIV.withUnsafeBytes { ivBytes in
                encrypted.withUnsafeBytes { inputBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inputBytes.baseAddress, encrypted.count,
                                outputBytes.baseAddress, output.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MegaClientError.invalidAttributes }
        output.count = moved
        let bytes = [UInt8](output)
        guard bytes.count >= 4, Array(bytes[0..<4]) == Array("MEGA".utf8) else {
            throw MegaClientError.invalidAttributes
        }
        let jsonBytes = bytes.dropFirst(4).prefix { $0 != 0 }
        guard let json = try? JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any],
              let name = json["n"] as? String else { throw MegaClientError.    static func decryptCTRFile(from encryptedURL: URL, to plainURL: URL,
                               key: Data, iv: Data,
                               chunkSize: Int = 1024 * 1024) throws {
        guard key.count == kCCKeySizeAES128, iv.count == 8 else {
            throw MegaClientError.invalidKey
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: plainURL.path) { try fm.removeItem(at: plainURL) }
        fm.createFile(atPath: plainURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: encryptedURL)
        let output = try FileHandle(forWritingTo: plainURL)
        defer { try? input.close(); try? output.close() }

        // MEGA AES-CTR: 8-byte IV followed by an eight-byte big-endian counter.
        var counter = Data(repeating: 0, count: 16)
        counter.replaceSubrange(0..<8, with: iv)
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            counter.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
                                        CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        ivBytes.baseAddress, keyBytes.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
        }
        defer { CCCryptorRelease(cryptor) }

        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            var decrypted = Data(count: chunk.count + kCCBlockSizeAES128)
            var moved = 0
            let status = chunk.withUnsafeBytes { inputBytes in
                decrypted.withUnsafeMutableBytes { outputBytes in
                    CCCryptorUpdate(cryptor, inputBytes.baseAddress, chunk.count,
                                    outputBytes.baseAddress, decrypted.count, &moved)
                }
            }
            guard status == kCCSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            decrypted.count = moved
            try output.write(contentsOf: decrypted)
        }
        try output.synchronize()
    }lse
        }
        return Data(output)
    }
}

private extension Data {
    static func ggBase64URL(_ string: String) -> Data? {
        var value = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: value)
    }
}

private extension UInt64 {
    func saturatingSubtract(_ rhs: UInt64) -> UInt64 { self > rhs ? self - rhs : 0 }
}
