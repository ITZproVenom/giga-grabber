import Foundation
import Combine
import UIKit

@MainActor
final class DownloadManager: ObservableObject {
    @Published var transfers: [GGTransfer] = []
    @Published var selectedTab = 0
    @Published var settings: GGSettings {
        didSet {
            settings.normalize()
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: "GigaGrabber.settings")
            }
        }
    }
    @Published var destinationName = "Downloads"
    @Published var globalError: String?
    @Published var isResolvingLink = false
    @Published var updateMessage: String?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var activeWeights: [UUID: Int] = [:]
    private var cancelledIDs = Set<UUID>()
    private let sessionURL: URL
    private var destinationOverride: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        if let saved = UserDefaults.standard.data(forKey: "GigaGrabber.settings"),
           let value = try? JSONDecoder().decode(GGSettings.self, from: saved) {
            var normalized = value
            normalized.normalize()
            settings = normalized
        } else {
            settings = GGSettings()
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: applicationSupport,
                                                 withIntermediateDirectories: true)
        sessionURL = applicationSupport.appendingPathComponent("download-session.json")
        restoreDestinationBookmark()
        restoreSession()
    }

    var runningCount: Int { tasks.count }
    var activeSpeed: Double {
        transfers.filter { $0.status == .downloading }.reduce(0) { $0 + $1.speedBytesPerSecond }
    }
    var hasActiveTransfers: Bool {
        transfers.contains { $0.status == .downloading || $0.status == .retrying || $0.status == .queued }
    }

    func setDestination(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        destinationOverride = url
        destinationName = url.lastPathComponent
        if let bookmark = try? url.bookmarkData(options: [],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil) {
            settings.destinationBookmark = bookmark
        }
    }

    private func restoreDestinationBookmark() {
        guard let bookmark = settings.destinationBookmark else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            destinationOverride = url
            destinationName = url.lastPathComponent
            _ = url.startAccessingSecurityScopedResource()
            if stale, let refreshed = try? url.bookmarkData(options: [],
                                                             includingResourceValuesForKeys: nil,
                                                             relativeTo: nil) {
                settings.destinationBookmark = refreshed
            }
        }
    }

    private func rootDirectory() -> URL {
        if let destinationOverride { return destinationOverride }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    func importLink(_ link: String) async throws -> [ImportedMegaFile] {
        isResolvingLink = true
        defer { isResolvingLink = false }
        return try await MegaClient(settings: settings).fetchPublicNodes(from: link)
    }

    func enqueue(_ files: [ImportedMegaFile]) {
        let existing = Set(transfers.map { $0.node.handle })
        for file in files where !existing.contains(file.node.handle) {
            transfers.append(GGTransfer(sourceURL: file.sourceURL, file: file))
        }
        persistSession()
        schedule()
    }

    func pause(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        if transfers[index].status == .completed || transfers[index].status == .failed { return }
        transfers[index].status = .paused
        transfers[index].speedBytesPerSecond = 0
        tasks[id]?.cancel()
        persistSession()
    }

    func resume(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].status == .paused || transfers[index].status == .failed else { return }
        transfers[index].status = .queued
        transfers[index].errorMessage = nil
        transfers[index].speedBytesPerSecond = 0
        schedule()
        persistSession()
    }

    func pauseAll() {
        for index in transfers.indices where transfers[index].status == .queued ||
            transfers[index].status == .downloading || transfers[index].status == .retrying {
            let id = transfers[index].id
            transfers[index].status = .paused
            transfers[index].speedBytesPerSecond = 0
            tasks[id]?.cancel()
        }
        persistSession()
    }

    func resumeAll() {
        for index in transfers.indices where transfers[index].status == .paused {
            transfers[index].status = .queued
            transfers[index].errorMessage = nil
        }
        schedule()
        persistSession()
    }

    func toggleAll() {
        if hasActiveTransfers { pauseAll() } else { resumeAll() }
    }

    func cancel(_ id: UUID) {
        cancelledIDs.insert(id)
        tasks[id]?.cancel()
        if tasks[id] == nil { removeTransferAndPartialFiles(id) }
    }

    func clearFinished() {
        transfers.removeAll { $0.status == .completed || $0.status == .failed }
        persistSession()
    }

    func stopWorkers() {
        let pendingIDs = transfers
            .filter { tasks[$0.id] == nil && $0.status != .completed }
            .map(\.id)
        for id in pendingIDs { removeTransferAndPartialFiles(id) }

        for id in Array(tasks.keys) {
            cancelledIDs.insert(id)
            tasks[id]?.cancel()
        }
        if tasks.isEmpty { persistSession() }
    }

    /// iOS grants only finite background execution time to ordinary app work.
    /// Active tasks are allowed to continue during that grace period, then paused
    /// with their encrypted partial files intact if the system expires the task.
    func applicationDidEnterBackground() {
        persistSession()
        guard backgroundTask == .invalid, !tasks.isEmpty else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GigaGrabber transfers") {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pauseAll()
                self.endBackgroundTask()
            }
        }
    }

    func applicationDidBecomeActive() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func schedule() {
        let workerLimit = min(10, max(1, settings.maxWorkers))
        let budget = min(100, max(1, settings.concurrencyBudget))
        while tasks.count < workerLimit {
            let candidate = transfers.first { item in
                guard item.status == .queued, tasks[item.id] == nil else { return false }
                let weight = min(downloadWeight(item.node.size), budget)
                return activeWeights.values.reduce(0, +) + weight <= budget
            }
            guard let candidate else { break }
            let weight = min(downloadWeight(candidate.node.size), budget)
            activeWeights[candidate.id] = weight
            tasks[candidate.id] = Task { [weak self] in
                await self?.runTransfer(candidate.id)
            }
        }
    }

    private func downloadWeight(_ size: UInt64) -> Int {
        let mb = UInt64(1024 * 1024)
        let raw: Int
        if size < 5 * mb { raw = 1 }
        else if size < 20 * mb { raw = 2 }
        else if size < 100 * mb { raw = 5 }
        else { raw = 10 }
        return min(raw, settings.concurrencyBudget)
    }

    private func runTransfer(_ id: UUID) async {
        defer {
            tasks[id] = nil
            activeWeights[id] = nil
            schedule()
        }
        guard let item = transfer(id) else { return }

        let client = MegaClient(settings: settings)
        let directory = rootDirectory().appendingPathComponent(safeRelativePath(item.relativeDirectory),
                                                               isDirectory: true)
        let safeName = safeComponent(item.node.name)
        let encryptedURL = directory.appendingPathComponent(".\(safeName).giga.enc.partial")
        let plainURL = directory.appendingPathComponent(".\(safeName).partial")
        let finalURL = directory.appendingPathComponent(safeName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                update(id) {
                    $0.status = .completed
                    $0.downloadedBytes = $0.node.size
                    $0.finalPath = finalURL.path
                }
                persistSession()
                return
            }

            var lastError: Error?
            // Giga Grabber's retry counter counts completed failures, then applies
            // minDelay * 2^retryCount capped by maxRetryDelay. This produces at
            // most maxRetries total attempts, not maxRetries additional attempts.
            for attempt in 0...settings.maxRetries {
                if Task.isCancelled { throw CancellationError() }
                do {
                    update(id) {
                        $0.status = .downloading
                        $0.retryCount = attempt
                        $0.errorMessage = nil
                    }
                    let remoteURL = try await client.downloadURL(for: item.node)
                    try await client.downloadEncrypted(remoteURL, to: encryptedURL,
                                                        expectedSize: item.node.size) { [weak self] bytes, speed in
                        Task { @MainActor in
                            self?.update(id) {
                                $0.downloadedBytes = bytes
                                $0.speedBytesPerSecond = speed
                            }
                        }
                    }
                    if Task.isCancelled { throw CancellationError() }
                    guard let iv = item.node.aesIV else { throw MegaClientError.invalidKey }
                    try MegaCrypto.decryptCTRFile(from: encryptedURL, to: plainURL,
                                                   key: item.node.aesKey, iv: iv)
                    let size = (try FileManager.default.attributesOfItem(atPath: plainURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
                    guard size == item.node.size else {
                        throw URLError(.cannotDecodeContentData, userInfo: [
                            NSLocalizedDescriptionKey: "Decrypted file size did not match MEGA's file size."
                        ])
                    }
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        try FileManager.default.removeItem(at: finalURL)
                    }
                    try FileManager.default.moveItem(at: plainURL, to: finalURL)
                    try? FileManager.default.removeItem(at: encryptedURL)
                    update(id) {
                        $0.status = .completed
                        $0.downloadedBytes = $0.node.size
                        $0.speedBytesPerSecond = 0
                        $0.errorMessage = nil
                        $0.finalPath = finalURL.path
                    }
                    persistSession()
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch let urlError as URLError where urlError.code == .cancelled {
                    throw CancellationError()
                } catch let network as GGNetworkError {
                    if case .outOfBandwidth = network {
                        update(id) {
                            $0.status = .paused
                            $0.speedBytesPerSecond = 0
                            $0.errorMessage = network.localizedDescription
                        }
                        persistSession()
                        return
                    }
                    lastError = network
                } catch {
                    lastError = error
                }

                let retryNumber = attempt + 1
                guard retryNumber < settings.maxRetries else { break }
                let factor = pow(2.0, Double(min(retryNumber, 31)))
                let delay = min(settings.maxRetryDelaySeconds,
                                settings.minRetryDelaySeconds * factor)
                update(id) {
                    $0.status = .retrying
                    $0.retryCount = retryNumber
                    $0.errorMessage = lastError?.localizedDescription
                    $0.speedBytesPerSecond = 0
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            update(id) {
                $0.status = .failed
                $0.speedBytesPerSecond = 0
                $0.errorMessage = lastError?.localizedDescription ?? "Download failed."
            }
            persistSession()
        } catch is CancellationError {
            if cancelledIDs.contains(id) {
                removeTransferAndPartialFiles(id)
            } else {
                update(id) { $0.status = .paused; $0.speedBytesPerSecond = 0 }
                persistSession()
            }
        } catch let urlError as URLError where urlError.code == .cancelled {
            if cancelledIDs.contains(id) {
                removeTransferAndPartialFiles(id)
            } else {
                update(id) { $0.status = .paused; $0.speedBytesPerSecond = 0 }
                persistSession()
            }
        } catch {
            update(id) {
                $0.status = .failed
                $0.speedBytesPerSecond = 0
                $0.errorMessage = error.localizedDescription
            }
            persistSession()
        }
    }

    private func transfer(_ id: UUID) -> GGTransfer? {
        transfers.first { $0.id == id }
    }

    private func update(_ id: UUID, _ body: (inout GGTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        body(&transfers[index])
    }

    private func removeTransferAndPartialFiles(_ id: UUID) {
        if let item = transfer(id) {
            let directory = rootDirectory().appendingPathComponent(safeRelativePath(item.relativeDirectory),
                                                                   isDirectory: true)
            let name = safeComponent(item.node.name)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(".\(name).giga.enc.partial"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(".\(name).partial"))
        }
        transfers.removeAll { $0.id == id }
        cancelledIDs.remove(id)
        persistSession()
    }

    private func persistSession() {
        guard settings.persistDownloadSessions else {
            try? FileManager.default.removeItem(at: sessionURL)
            return
        }
        let records = transfers.filter { $0.status != .completed && $0.status != .failed }
            .map {
                DownloadSessionRecord(sourceURL: $0.sourceURL, nodeHandle: $0.node.handle,
                                      relativeDirectory: $0.relativeDirectory,
                                      expectedSize: $0.node.size)
            }
        let snapshot = DownloadSessionSnapshot(version: 1, records: records)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(),
                                                      withIntermediateDirectories: true)
            try? data.write(to: sessionURL,
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func restoreSession() {
        guard settings.persistDownloadSessions,
              let data = try? Data(contentsOf: sessionURL),
              let snapshot = try? JSONDecoder().decode(DownloadSessionSnapshot.self, from: data),
              snapshot.version == 1, !snapshot.records.isEmpty else { return }
        Task { await restore(records: snapshot.records) }
    }

    private func restore(records: [DownloadSessionRecord]) async {
        var resolved: [String: [String: ImportedMegaFile]] = [:]
        for sourceURL in Set(records.map(\.sourceURL)) {
            do {
                let files = try await MegaClient(settings: settings).fetchPublicNodes(from: sourceURL)
                resolved[sourceURL] = Dictionary(uniqueKeysWithValues: files.map { ($0.node.handle, $0) })
            } catch {
                updateMessage = "Could not restore some MEGA links: \(error.localizedDescription)"
            }
        }

        for record in records {
            guard let file = resolved[record.sourceURL]?[record.nodeHandle],
                  file.node.size == record.expectedSize,
                  !transfers.contains(where: { $0.node.handle == record.nodeHandle }) else { continue }
            var item = GGTransfer(sourceURL: record.sourceURL, file: file)
            item.status = .paused
            item.errorMessage = "Restored after app relaunch. Tap Resume to continue."
            let directory = rootDirectory().appendingPathComponent(safeRelativePath(item.relativeDirectory))
            let encrypted = directory.appendingPathComponent(".\(safeComponent(item.node.name)).giga.enc.partial")
            item.downloadedBytes = (try? FileManager.default.attributesOfItem(atPath: encrypted.path)[.size] as? NSNumber)?.uint64Value ?? 0
            transfers.append(item)
        }
        persistSession()
    }

    func checkForUpdates(manual: Bool = false) async {
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/ITZproVenom/giga-grabber/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("GigaGrabber-iOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                updateMessage = "No iOS release has been published yet."
                return
            }
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(GGRelease.self, from: data)
            updateMessage = "Latest iOS release: \(release.tagName)"
        } catch {
            updateMessage = manual ? "Unable to check GitHub releases: \(error.localizedDescription)" : nil
        }
    }

    private struct GGRelease: Decodable {
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
        let tagName: String
    }

    private func safeRelativePath(_ path: String) -> String {
        path.split(separator: "/").map { safeComponent(String($0)) }.joined(separator: "/")
    }

    private func safeComponent(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }
}
