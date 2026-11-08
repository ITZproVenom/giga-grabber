import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var manager = DownloadManager()
    @StateObject private var linkRouter = PendingLinkRouter.shared
    @State private var incomingLink: String?
    @State private var autoQueueIncomingLink = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $manager.selectedTab) {
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(0)
            ImportView(initialLink: $incomingLink, autoQueue: $autoQueueIncomingLink)
                .tabItem { Label("Add link", systemImage: "plus.circle") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(2)
        }
        .environmentObject(manager)
        .tint(manager.settings.themeTint)
        .preferredColorScheme(manager.settings.preferredColorScheme)
        .onOpenURL { url in
            if url.scheme == "gigagrabber",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let query = components.queryItems ?? []
                func value(_ name: String) -> String? {
                    query.first(where: { $0.name == name })?.value
                }
                var updated = manager.settings
                if let raw = value("max-workers"), let number = Int(raw) { updated.maxWorkers = number }
                if let raw = value("concurrency-budget"), let number = Int(raw) { updated.concurrencyBudget = number }
                if let raw = value("max-retries"), let number = Int(raw) { updated.maxRetries = number }
                if let raw = value("timeout"), let number = Double(raw) { updated.timeoutSeconds = number }
                if let raw = value("min-retry-delay"), let number = Double(raw) { updated.minRetryDelaySeconds = number }
                if let raw = value("max-retry-delay"), let number = Double(raw) { updated.maxRetryDelaySeconds = number }
                if let raw = value("proxy-mode") {
                    switch raw.lowercased() {
                    case "none": updated.proxyMode = .none
                    case "single": updated.proxyMode = .single
                    case "random": updated.proxyMode = .random
                    default: break
                    }
                }
                if let raw = value("proxies") {
                    updated.proxies = raw.split(separator: "|").map(String.init)
                }
                updated.normalize()
                manager.settings = updated
                incomingLink = value("url") ?? url.absoluteString
            } else {
                incomingLink = url.absoluteString
            }
            autoQueueIncomingLink = false
            manager.selectedTab = 1
        }
        .onAppear {
            if let (pending, autoQueue) = linkRouter.consumePersistedLink() {
                incomingLink = pending.absoluteString
                autoQueueIncomingLink = autoQueue
                manager.selectedTab = 1
            }
        }
        .onChange(of: linkRouter.pendingURL) { url in
            guard let url else { return }
            incomingLink = url.absoluteString
            autoQueueIncomingLink = linkRouter.pendingAutoQueue
            manager.selectedTab = 1
            linkRouter.pendingURL = nil
            linkRouter.pendingAutoQueue = false
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: manager.applicationDidEnterBackground()
            case .active: manager.applicationDidBecomeActive()
            default: break
            }
        }
        .task {
            if manager.settings.checkForUpdates {
                await manager.checkForUpdates()
            }
        }
    }
}

extension GGSettings {
    var preferredColorScheme: ColorScheme? {
        switch theme {
        case "System": return nil
        case "Light", "Solarized Light", "Gruvbox Light", "Catppuccin Latte",
             "Tokyo Night Light", "Kanagawa Lotus": return .light
        default: return .dark
        }
    }

    var themeTint: Color {
        let hex: UInt32
        switch theme {
        case "Dracula": hex = 0xBD93F9
        case "Nord": hex = 0x88C0D0
        case "Solarized Light", "Solarized Dark": hex = 0x268BD2
        case "Gruvbox Light": hex = 0xD65D0E
        case "Gruvbox Dark": hex = 0xD79921
        case "Catppuccin Latte": hex = 0x8839EF
        case "Catppuccin Frappe": hex = 0xCA9EE6
        case "Catppuccin Macchiato": hex = 0xC6A0F6
        case "Catppuccin Mocha": hex = 0xCBA6F7
        case "Tokyo Night": hex = 0x7AA2F7
        case "Tokyo Night Storm": hex = 0x7DCFFF
        case "Tokyo Night Light": hex = 0x2E7DE9
        case "Kanagawa Wave": hex = 0x7E9CD8
        case "Kanagawa Dragon": hex = 0x8BA4B0
        case "Kanagawa Lotus": hex = 0x4D699B
        case "Moonfly": hex = 0x80A0FF
        case "Nightfly": hex = 0x82AAFF
        case "Oxocarbon": hex = 0x08BDBA
        case "Ferra": hex = 0xD08770
        case "Dark": hex = 0x0A84FF
        case "Light": hex = 0x007AFF
        case "Vanilla": hex = 0x557568
        default: hex = 0x0A84FF
        }
        return Color(red: Double((hex >> 16) & 0xFF) / 255,
                     green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var showingFolderPicker = false
    @State private var showingStopConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if manager.transfers.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing downloading", systemImage: "arrow.down.to.line")
                    } description: {
                        Text("Paste a public MEGA file or folder link to get started.")
                    } actions: {
                        Button("Add MEGA link") { manager.selectedTab = 1 }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(manager.runningCount) active worker\(manager.runningCount == 1 ? "" : "s")")
                                        .font(.headline)
                                    Text("\(manager.activeSpeed.formattedRate) total")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { manager.toggleAll() } label: {
                                    Label(manager.hasActiveTransfers ? "Pause all" : "Resume all",
                                          systemImage: manager.hasActiveTransfers ? "pause.fill" : "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(manager.transfers.allSatisfy {
                                    $0.status == .completed || $0.status == .failed
                                })
                            }
                            HStack {
                                Label("Save to", systemImage: "folder")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(manager.destinationName).lineLimit(1)
                                Button("Change") { showingFolderPicker = true }
                            }
                            .font(.subheadline)
                        }

                        Section("Transfers") {
                            ForEach(manager.transfers) { item in
                                TransferRow(item: item)
                                    .listRowSeparator(.visible)
                            }
                        }

                        if manager.transfers.contains(where: { $0.status == .completed || $0.status == .failed }) {
                            Section {
                                Button("Clear finished items", role: .destructive) {
                                    manager.clearFinished()
                                }
                            }
                        }

                        Section {
                            Button("Stop workers and clear unfinished queue", role: .destructive) {
                                showingStopConfirmation = true
                            }
                            .disabled(manager.transfers.allSatisfy { $0.status == .completed })
                        }
                    }
                }
            }
            .navigationTitle("Giga Grabber")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { manager.selectedTab = 1 } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add MEGA link")
                }
            }
            .fileImporter(isPresented: $showingFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { manager.setDestination(url) }
                case .failure(let error):
                    manager.globalError = error.localizedDescription
                }
            }
            .confirmationDialog("Stop all unfinished downloads?",
                                isPresented: $showingStopConfirmation,
                                titleVisibility: .visible) {
                Button("Stop workers and clear queue", role: .destructive) { manager.stopWorkers() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Unfinished queue entries and temporary partial files will be removed.")
            }
            .alert("Giga Grabber", isPresented: Binding(
                get: { manager.globalError != nil },
                set: { if !$0 { manager.globalError = nil } }
            )) {
                Button("OK", role: .cancel) { manager.globalError = nil }
            } message: {
                Text(manager.globalError ?? "")
            }
        }
    }
}

struct TransferRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let item: GGTransfer

    private var icon: String {
        switch item.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle"
        default: return "arrow.down.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(item.status == .completed ? .green :
                                     item.status == .failed ? .orange : .tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.node.name).font(.headline).lineLimit(2)
                    Text(item.relativeDirectory.isEmpty ? statusText :
                         "\(item.relativeDirectory) · \(statusText)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Menu {
                    if item.status == .downloading || item.status == .queued || item.status == .retrying {
                        Button("Pause", systemImage: "pause") { manager.pause(item.id) }
                    } else if item.status == .paused || item.status == .failed {
                        Button("Resume", systemImage: "play") { manager.resume(item.id) }
                    }
                    if item.status == .completed, let path = item.finalPath {
                        ShareLink(item: URL(fileURLWithPath: path)) {
                            Label("Share file", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Cancel and remove", role: .destructive) { manager.cancel(item.id) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }

            if manager.settings.showProgressBars {
                ProgressView(value: item.progress)
                    .tint(item.status == .failed ? .orange : .accentColor)
            }

            HStack(spacing: 12) {
                if manager.settings.showDownloadSizes {
                    Text("\(item.downloadedBytes.ggFileSize) / \(item.node.size.ggFileSize)")
                }
                Text("\(Int(item.progress * 100))%")
                Spacer()
                if item.status == .downloading {
                    Text(item.speedBytesPerSecond.formattedRate)
                } else if item.retryCount > 0 {
                    Text("Retry \(item.retryCount)")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if let message = item.errorMessage, item.status == .failed || item.status == .paused {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if item.status == .completed, let path = item.finalPath {
                ShareLink(item: URL(fileURLWithPath: path)) {
                    Label("Save or share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch item.status {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .retrying: return "Retrying"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

private struct ImportedGroup: Identifiable {
    let directory: String
    let files: [ImportedMegaFile]
    var id: String { directory }
    var depth: Int { directory.split(separator: "/").count }
}

struct ImportView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Binding var initialLink: String?
    @Binding var autoQueue: Bool
    @State private var link = ""
    @State private var files: [ImportedMegaFile] = []
    @State private var selected = Set<String>()
    @State private var errorMessage: String?
    @State private var didResolve = false

    private var groupedFiles: [ImportedGroup] {
        var directories = Set(files.map(\.relativeDirectory))
        for file in files where !file.relativeDirectory.isEmpty {
            var parts = file.relativeDirectory.split(separator: "/")
            while !parts.isEmpty {
                directories.insert(parts.map(String.init).joined(separator: "/"))
                parts.removeLast()
            }
        }
        return directories.sorted().map { directory in
            ImportedGroup(directory: directory,
                          files: files.filter { $0.relativeDirectory == directory })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("https://mega.nz/file/... or /folder/...", text: $link, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .lineLimit(2...4)
                        Button {
                            if let pasted = UIPasteboard.general.string { link = pasted }
                        } label: { Image(systemName: "doc.on.clipboard") }
                            .accessibilityLabel("Paste link")
                    }
                    Button { Task { await resolve() } } label: {
                        HStack {
                            if manager.isResolvingLink { ProgressView().padding(.trailing, 4) }
                            Text(manager.isResolvingLink ? "Reading MEGA link…" : "Load link")
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                        }
                    }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              manager.isResolvingLink)
                } header: {
                    Text("MEGA public link")
                } footer: {
                    Text("Public file and shared-folder links are supported. The decryption key stays on this device.")
                }

                if didResolve {
                    Section {
                        HStack {
                            Text("\(files.count) files found").font(.headline)
                            Spacer()
                            Button(selected.count == files.count ? "Deselect all" : "Select all") {
                                if selected.count == files.count { selected.removeAll() }
                                else { selected = Set(files.map(\.id)) }
                            }
                        }

                        ForEach(groupedFiles) { group in
                            if !group.directory.isEmpty {
                                HStack {
                                    Label(group.directory, systemImage: "folder")
                                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Spacer()
                                    Button("Select folder") {
                                        let prefix = group.directory + "/"
                                        let ids = Set(files.filter {
                                            $0.relativeDirectory == group.directory ||
                                            $0.relativeDirectory.hasPrefix(prefix)
                                        }.map(\.id))
                                        if ids.isSubset(of: selected) { selected.subtract(ids) }
                                        else { selected.formUnion(ids) }
                                    }
                                    .font(.caption)
                                }
                                .padding(.leading, CGFloat(max(0, group.depth - 1)) * 10)
                            }
                            ForEach(group.files) { file in
                                Button {
                                    if selected.contains(file.id) { selected.remove(file.id) }
                                    else { selected.insert(file.id) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selected.contains(file.id) ?
                                              "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(file.id) ? Color.accentColor : Color.secondary)
                                        Image(systemName: "doc").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.node.name).foregroundStyle(.primary).lineLimit(2)
                                            Text(file.node.size.ggFileSize)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, CGFloat(group.depth) * 10)
                            }
                        }
                    } footer: {
                        Text("Downloads keep their original shared-folder paths.")
                    }

                    Section {
                        Button {
                            let chosen = files.filter { selected.contains($0.id) }
                            manager.enqueue(chosen)
                            files = []
                            selected = []
                            didResolve = false
                            link = ""
                            manager.selectedTab = 0
                        } label: {
                            Label("Download selected (\(selected.count))",
                                  systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .navigationTitle("Add download")
            .onAppear {
                if let value = initialLink, !value.isEmpty {
                    link = value
                    initialLink = nil
                    Task { await resolve() }
                }
            }
            .onChange(of: initialLink) { value in
                guard let value, !value.isEmpty else { return }
                link = value
                initialLink = nil
                Task { await resolve() }
            }
            .alert("Unable to load link", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    @MainActor
    private func resolve() async {
        do {
            let loaded = try await manager.importLink(link.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !loaded.isEmpty else {
                errorMessage = "No downloadable files were found in this link."
                return
            }
            files = loaded
            selected = Set(loaded.map(\.id))
            if autoQueue {
                manager.enqueue(loaded)
                files = []
                selected = []
                didResolve = false
                link = ""
                autoQueue = false
                manager.selectedTab = 0
                return
            }
            didResolve = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var proxyInput = ""
    @State private var showProxyError = false
    @State private var isImportingProxyFile = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Performance") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Maximum workers")
                            Spacer()
                            Text("\(manager.settings.maxWorkers)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: intBinding(\.maxWorkers), in: 1...10, step: 1)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Concurrency budget")
                            Spacer()
                            Text("\(manager.settings.concurrencyBudget)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: intBinding(\.concurrencyBudget), in: 1...100, step: 1)
                    }
                    Stepper("Maximum retries: \(manager.settings.maxRetries)",
                            value: intBinding(\.maxRetries), in: 0...20)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Request timeout")
                            Spacer()
                            Text("\(Int(manager.settings.timeoutSeconds)) sec").foregroundStyle(.secondary)
                        }
                        Slider(value: doubleBinding(\.timeoutSeconds), in: 5...300, step: 5)
                    }
                }

                Section("Retry policy") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Minimum retry delay")
                            Spacer()
                            Text("\(Int(manager.settings.minRetryDelaySeconds)) sec").foregroundStyle(.secondary)
                        }
                        Slider(value: doubleBinding(\.minRetryDelaySeconds), in: 1...60, step: 1)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Maximum retry delay")
                            Spacer()
                            Text("\(Int(manager.settings.maxRetryDelaySeconds)) sec").foregroundStyle(.secondary)
                        }
                        Slider(value: doubleBinding(\.maxRetryDelaySeconds),
                               in: max(1, manager.settings.minRetryDelaySeconds)...600, step: 1)
                    }
                }

                Section {
                    Picker("Proxy mode", selection: Binding(
                        get: { manager.settings.proxyMode },
                        set: { manager.settings.proxyMode = $0 }
                    )) {
                        ForEach(ProxyMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }

                    if manager.settings.proxyMode == .single {
                        TextField("http://host:port or socks5://host:port", text: $proxyInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .onSubmit { saveSingleProxy() }
                        Button("Save proxy") { saveSingleProxy() }
                    } else if manager.settings.proxyMode == .random {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(manager.settings.proxies.enumerated()), id: \.offset) { index, proxy in
                                HStack {
                                    Text(proxy).font(.caption.monospaced()).lineLimit(2)
                                    Spacer()
                                    Button(role: .destructive) {
                                        manager.settings.proxies.remove(at: index)
                                    } label: { Image(systemName: "trash") }
                                }
                            }
                            HStack {
                                TextField("Add proxy URL", text: $proxyInput)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                Button("Add") { addRandomProxy() }
                                    .disabled(proxyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            Button {
                                isImportingProxyFile = true
                            } label: {
                                Label("Import proxy list from .txt", systemImage: "doc.text")
                            }
                        }
                    } else {
                        Text("Direct connection. Configured proxy addresses are retained for later use.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Random mode chooses from the configured proxies for MEGA API requests and file transfers. A failed transfer is retried with a new selection.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Proxy routing")
                } footer: {
                    Text("Supported URLs: http://, https://, socks5:// and socks5h://. Credentials can be embedded in the URL. Respect MEGA's terms and your proxy provider's limits.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: Binding(
                        get: { manager.settings.theme },
                        set: { manager.settings.theme = $0 }
                    )) {
                        ForEach(GGSettings.themes, id: \.self) { theme in Text(theme).tag(theme) }
                    }
                }

                Section("Downloads") {
                    Toggle("Remember unfinished downloads", isOn: boolBinding(\.persistDownloadSessions))
                    Toggle("Show download progress bars", isOn: boolBinding(\.showProgressBars))
                    Toggle("Show download sizes", isOn: boolBinding(\.showDownloadSizes))
                    Toggle("Automatically check for updates", isOn: boolBinding(\.checkForUpdates))
                }

                Section("Updates") {
                    Button {
                        Task { await manager.checkForUpdates(manual: true) }
                    } label: {
                        Label("Check for updates", systemImage: "arrow.clockwise")
                    }
                    if let updateMessage = manager.updateMessage {
                        Text(updateMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Reset all settings", role: .destructive) {
                        manager.resetSettings()
                        proxyInput = ""
                    }
                } footer: {
                    Text("Restores worker, concurrency, retry, proxy, theme and display settings to their defaults.")
                }

                Section("About") {
                    LabeledContent("Application", value: "Giga Grabber for iOS")
                    LabeledContent("Engine", value: "MEGA public-link downloader")
                    Link(destination: URL(string: "https://github.com/chanderlud/giga-grabber")!) {
                        Label("Original Giga Grabber project", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $isImportingProxyFile,
                          allowedContentTypes: [.plainText],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let contents = try String(contentsOf: url, encoding: .utf8)
                        let parsed = contents.split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                            .compactMap { ProxyEndpoint.parse($0)?.normalized }
                        for proxy in parsed where !manager.settings.proxies.contains(proxy) {
                            manager.settings.proxies.append(proxy)
                        }
                        if parsed.isEmpty { showProxyError = true }
                    } catch {
                        manager.globalError = "Could not read proxy list: \\(error.localizedDescription)"
                    }
                case .failure(let error):
                    manager.globalError = error.localizedDescription
                }
            }
            .onAppear {
                if manager.settings.proxyMode == .single {
                    proxyInput = manager.settings.proxies.first ?? ""
                }
            }
            .onChange(of: manager.settings.proxyMode) { mode in
                if mode == .single { proxyInput = manager.settings.proxies.first ?? "" }
            }
            .alert("Proxy URL", isPresented: $showProxyError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Enter a valid http://, https://, socks5:// or socks5h:// proxy URL including its host and port.")
            }
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<GGSettings, Int>) -> Binding<Double> {
        Binding(get: { Double(manager.settings[keyPath: keyPath]) },
                set: { manager.settings[keyPath: keyPath] = Int($0) })
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<GGSettings, Double>) -> Binding<Double> {
        Binding(get: { manager.settings[keyPath: keyPath] },
                set: { manager.settings[keyPath: keyPath] = $0 })
    }

    private func boolBinding(_ keyPath: WritableKeyPath<GGSettings, Bool>) -> Binding<Bool> {
        Binding(get: { manager.settings[keyPath: keyPath] },
                set: { manager.settings[keyPath: keyPath] = $0 })
    }

    private func saveSingleProxy() {
        guard let parsed = ProxyEndpoint.parse(proxyInput) else {
            showProxyError = true
            return
        }
        manager.settings.proxies = [parsed.normalized]
    }

    private func addRandomProxy() {
        guard let parsed = ProxyEndpoint.parse(proxyInput) else {
            showProxyError = true
            return
        }
        if !manager.settings.proxies.contains(parsed.normalized) {
            manager.settings.proxies.append(parsed.normalized)
        }
        proxyInput = ""
    }
}

private extension Double {
    var formattedRate: String {
        let value = ByteCountFormatter.string(fromByteCount: Int64(max(0, self)), countStyle: .file)
        return "\(value)/s"
    }
}
