import Foundation
import SwiftUI

enum ProxyMode: String, CaseIterable, Codable, Identifiable {
    case none = "None"
    case single = "Single"
    case random = "Random"
    var id: String { rawValue }
}

struct GGSettings: Codable {
    var maxWorkers = 10
    var concurrencyBudget = 10
    var maxRetries = 3
    var timeoutSeconds = 20.0
    var minRetryDelaySeconds = 10.0
    var maxRetryDelaySeconds = 30.0
    var proxyMode: ProxyMode = .none
    var proxies: [String] = []
    var theme = "Vanilla"
    var checkForUpdates = true
    var persistDownloadSessions = false
    var showProgressBars = true
    var showDownloadSizes = true
    var destinationBookmark: Data?

    static let themes = [
        "Vanilla", "System", "Light", "Dark", "Dracula", "Nord",
        "Solarized Light", "Solarized Dark", "Gruvbox Light", "Gruvbox Dark",
        "Catppuccin Latte", "Catppuccin Frappe", "Catppuccin Macchiato",
        "Catppuccin Mocha", "Tokyo Night", "Tokyo Night Storm",
        "Tokyo Night Light", "Kanagawa Wave", "Kanagawa Dragon",
        "Kanagawa Lotus", "Moonfly", "Nightfly", "Oxocarbon", "Ferra"
    ]

    mutating func normalize() {
        maxWorkers = min(10, max(1, maxWorkers))
        concurrencyBudget = min(100, max(1, concurrencyBudget))
        maxRetries = min(20, max(0, maxRetries))
        timeoutSeconds = min(300, max(5, timeoutSeconds))
        minRetryDelaySeconds = min(60, max(0.1, minRetryDelaySeconds))
        maxRetryDelaySeconds = min(600, max(minRetryDelaySeconds, maxRetryDelaySeconds))
        proxies = proxies.compactMap { ProxyEndpoint.parse($0)?.normalized }
        if proxyMode == .single, proxies.count > 1 {
            proxies = Array(proxies.prefix(1))
        }
    }
}

struct MegaNode: Identifiable, Codable, Hashable {
    var id: String { handle }
    let name: String
    let handle: String
    var parent: String?
    let isFolder: Bool
    let size: UInt64
    let aesKey: Data
    let aesIV: Data?
    let rootHandle: String
}

struct ImportedMegaFile: Identifiable, Hashable {
    var id: String { node.handle }
    let sourceURL: String
    let node: MegaNode
    let relativeDirectory: String
}

enum TransferStatus: String, Codable {
    case queued, downloading, paused, retrying, completed, failed
}

struct GGTransfer: Identifiable, Codable, Hashable {
    var id: UUID
    let sourceURL: String
    let node: MegaNode
    let relativeDirectory: String
    var status: TransferStatus
    var downloadedBytes: UInt64
    var speedBytesPerSecond: Double
    var retryCount: Int
    var errorMessage: String?
    var finalPath: String?

    init(sourceURL: String, file: ImportedMegaFile) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.node = file.node
        self.relativeDirectory = file.relativeDirectory
        self.status = .queued
        self.downloadedBytes = 0
        self.speedBytesPerSecond = 0
        self.retryCount = 0
        self.errorMessage = nil
        self.finalPath = nil
    }

    var progress: Double {
        guard node.size > 0 else { return status == .completed ? 1 : 0 }
        return min(1, Double(downloadedBytes) / Double(node.size))
    }
}

/// Mirrors the desktop session file's security model: the session file stores the
/// public source URL and node handle, never a copied AES file key. The key is
/// re-fetched from the user's original MEGA link when the app restores the queue.
struct DownloadSessionRecord: Codable, Hashable {
    let sourceURL: String
    let nodeHandle: String
    let relativeDirectory: String
    let expectedSize: UInt64
}

struct DownloadSessionSnapshot: Codable {
    let version: Int
    var records: [DownloadSessionRecord]
}

extension UInt64 {
    var ggFileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: self), countStyle: .file)
    }
}
