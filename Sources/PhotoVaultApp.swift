import SwiftUI
import AuthenticationServices

// MARK: - App Entry Point

@main
struct PhotoVaultApp: App {
    @State private var syncProgress = SyncProgress()
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(progress: syncProgress, appState: appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}  // Remove File > New
        }

        Settings {
            SettingsView(appState: appState)
                .frame(minWidth: 450, minHeight: 350)
        }
    }
}

// MARK: - Shared App State

@MainActor
@Observable
final class AppState {
    var driveClient: GoogleDriveClient?
    var isAuthenticated = false

    func signOut() {
        if let driveClient {
            let keychain = KeychainWrapper()
            Task {
                await driveClient.clearTokens(from: keychain)
            }
        }
        driveClient = nil
        isAuthenticated = false
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @Bindable var progress: SyncProgress
    var appState: AppState
    @State private var syncService: PhotoVaultBucketSyncService?
    @State private var isCheckingAuth = true
    @State private var errorMessage: String?

    // Google OAuth credentials
    private var clientID: String {
        ProcessInfo.processInfo.environment["GOOGLE_CLIENT_ID"]
            ?? "REDACTED_CLIENT_ID.apps.googleusercontent.com"
    }
    private var clientSecret: String {
        ProcessInfo.processInfo.environment["GOOGLE_CLIENT_SECRET"]
            ?? "REDACTED_CLIENT_SECRET"
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(progress: progress)
        } detail: {
            if isCheckingAuth {
                ProgressView("Checking authentication...")
            } else if !appState.isAuthenticated {
                AuthenticationView(
                    clientID: clientID,
                    clientSecret: clientSecret,
                    onAuthenticated: { driveClient in
                        Task { @MainActor in
                            print("[PhotoVault] Auth succeeded, initializing...")
                            await initializeSyncService(driveClient: driveClient)
                            print("[PhotoVault] Setting isAuthenticated = true")
                            appState.isAuthenticated = true
                        }
                    }
                )
            } else {
                SyncDashboard(
                    progress: progress,
                    onStartSync: startSync,
                    onPauseSync: pauseSync,
                    onResumeSync: resumeSync
                )
            }
        }
        .task {
            await tryRestoreSession()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: appState.isAuthenticated) { _, newValue in
            if !newValue {
                // Signed out from Settings
                Task { await syncService?.pause() }
                syncService = nil
            }
        }
    }

    private func tryRestoreSession() async {
        let driveClient = GoogleDriveClient(clientID: clientID, clientSecret: clientSecret)
        let keychain = KeychainWrapper()
        do {
            try await driveClient.loadTokens(from: keychain)
            await initializeSyncService(driveClient: driveClient)
            appState.isAuthenticated = true
        } catch {
            // No saved tokens or invalid — need fresh auth
        }
        isCheckingAuth = false
    }

    private func initializeSyncService(driveClient: GoogleDriveClient) async {
        appState.driveClient = driveClient
        do {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("PhotoVault")

            try FileManager.default.createDirectory(
                at: appSupport,
                withIntermediateDirectories: true
            )

            print("[PhotoVault] Initializing sync service at \(appSupport.path)")
            var config = SyncConfiguration(appSupportDir: appSupport)
            config.debugMaxAssets = 10  // TODO: Remove for production
            config.skipICloudOnlyAssets = true  // Don't download from iCloud on this machine
            syncService = try PhotoVaultBucketSyncService(
                config: config,
                driveClient: driveClient,
                progress: progress
            )
            print("[PhotoVault] Sync service initialized successfully")
        } catch {
            print("[PhotoVault] Sync service init FAILED: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    private func startSync() {
        Task {
            do {
                try await syncService?.startFullSync()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pauseSync() {
        Task {
            await syncService?.pause()
        }
    }

    private func resumeSync() {
        startSync()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var appState: AppState

    @State private var email: String?
    @State private var displayName: String?
    @State private var storageTotal: Int64 = 0
    @State private var storageUsed: Int64 = 0
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading account info...")
                Spacer()
            } else if !appState.isAuthenticated {
                Spacer()
                Text("Not signed in.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Form {
                    Section("Google Account") {
                        if let email {
                            LabeledContent("Email", value: email)
                                .textSelection(.enabled)
                        }
                        if let displayName {
                            LabeledContent("Name", value: displayName)
                        }
                    }

                    Section("Google Drive Storage") {
                        LabeledContent("Used", value: formatBytes(storageUsed))
                        LabeledContent("Total", value: formatBytes(storageTotal))
                        LabeledContent("Available", value: formatBytes(storageTotal - storageUsed))

                        ProgressView(value: storageTotal > 0 ? Double(storageUsed) / Double(storageTotal) : 0)
                            .tint(storageUsageColor)
                    }

                    Section("Sync Configuration") {
                        LabeledContent("Drive Root Folder", value: "Apple Photos Backup")
                        LabeledContent("Storage Layout", value: "media/YYYY/WXX/")
                    }

                    if let error {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            appState.signOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .task {
            await loadAccountInfo()
        }
    }

    private func loadAccountInfo() async {
        guard let driveClient = appState.driveClient else {
            isLoading = false
            return
        }
        do {
            let userInfo = try await driveClient.fetchUserInfo()
            email = userInfo.email
            displayName = userInfo.name

            let quota = try await driveClient.fetchStorageQuota()
            storageTotal = quota.totalBytes
            storageUsed = quota.usedBytes
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private var storageUsageColor: Color {
        guard storageTotal > 0 else { return .blue }
        let fraction = Double(storageUsed) / Double(storageTotal)
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return .blue
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var progress: SyncProgress

    var body: some View {
        List {
            Section("Library") {
                if progress.totalAlbums > 0 {
                    LabeledContent("Albums", value: "\(progress.totalAlbums)")
                }
                if progress.uniqueAssets > 0 {
                    LabeledContent("Unique Assets", value: "\(progress.uniqueAssets.formatted())")
                }
                if progress.totalBytes > 0 {
                    LabeledContent("Library Size", value: formatBytes(progress.totalBytes))
                }
            }

            Section("Sync Progress") {
                LabeledContent("Uploaded") {
                    Text("\(progress.uploadedAssets.formatted()) assets")
                        .foregroundStyle(progress.uploadedAssets > 0 ? .primary : .secondary)
                }
                LabeledContent("Data Sent", value: formatBytes(progress.uploadedBytes))
                if progress.failedAssets > 0 {
                    LabeledContent("Failed") {
                        Text("\(progress.failedAssets)")
                            .foregroundStyle(.red)
                    }
                }
            }

            if !progress.errors.isEmpty {
                Section("Recent Errors") {
                    ForEach(progress.errors.suffix(3)) { error in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(error.message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                            Text(error.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("PhotoVault")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Phase Pipeline

struct PhasePipeline: View {
    let currentPhase: SyncProgress.SyncPhase

    private let phases = SyncProgress.workflowPhases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                let state = phaseState(phase)

                // Step circle + label
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(state == .active ? Color.accentColor : state == .done ? Color.green : Color.secondary.opacity(0.2))
                            .frame(width: 28, height: 28)

                        if state == .done {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(state == .active ? .white : .secondary)
                        }
                    }

                    Text(phase.rawValue)
                        .font(.caption2)
                        .foregroundStyle(state == .active ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                // Connector line between steps
                if index < phases.count - 1 {
                    Rectangle()
                        .fill(state == .done ? Color.green : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                        .frame(maxWidth: 40)
                        .padding(.bottom, 18) // align with circle center
                }
            }
        }
        .padding(.horizontal)
    }

    private enum StepState { case pending, active, done }

    private func phaseState(_ phase: SyncProgress.SyncPhase) -> StepState {
        guard let currentIndex = phases.firstIndex(of: currentPhase),
              let phaseIndex = phases.firstIndex(of: phase) else {
            // Terminal states: completed = all done, failed/idle/paused = show last active
            if currentPhase == .completed { return .done }
            return .pending
        }
        if phaseIndex < currentIndex { return .done }
        if phaseIndex == currentIndex { return .active }
        return .pending
    }
}

// MARK: - Sync Dashboard

struct SyncDashboard: View {
    @Bindable var progress: SyncProgress
    let onStartSync: () -> Void
    let onPauseSync: () -> Void
    let onResumeSync: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // Phase pipeline (only visible when running)
            if progress.phase != .idle {
                PhasePipeline(currentPhase: progress.phase)
                    .padding(.bottom, 8)
            }

            // Progress ring with context-aware center
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 20)
                Circle()
                    .trim(from: 0, to: ringFraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: ringFraction)

                ringCenter
            }
            .frame(width: 200, height: 200)

            // Phase detail text
            phaseDetailView

            // Time remaining (upload phase only)
            if progress.phase == .uploading,
               let remaining = progress.estimatedTimeRemaining, remaining > 0 {
                Text("About \(formatDuration(remaining)) remaining")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Controls
            HStack(spacing: 16) {
                switch progress.phase {
                case .idle, .completed, .failed:
                    Button(action: onStartSync) {
                        Label(progress.phase == .completed ? "Sync Again" : "Start Sync",
                              systemImage: "play.fill")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                case .uploading, .cataloging, .planning, .creatingFolders, .generatingManifests:
                    Button(action: onPauseSync) {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                case .paused:
                    Button(action: onResumeSync) {
                        Label("Resume", systemImage: "play.fill")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.bottom, 8)

            Spacer()
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ring Fraction (context-aware)

    private var ringFraction: Double {
        switch progress.phase {
        case .idle:
            return 0
        case .cataloging:
            guard progress.totalAlbums > 0 else { return 0 }
            return Double(progress.processedAlbums) / Double(progress.totalAlbums)
        case .planning:
            return 0 // indeterminate — just show the phase label
        case .creatingFolders:
            guard progress.totalFolders > 0 else { return 0 }
            return Double(progress.foldersCreated) / Double(progress.totalFolders)
        case .uploading:
            return progress.progressFraction
        case .generatingManifests:
            guard progress.totalManifests > 0 else { return 0 }
            return Double(progress.manifestsGenerated) / Double(progress.totalManifests)
        case .completed:
            return 1.0
        case .paused:
            return progress.progressFraction
        case .failed:
            return progress.progressFraction
        }
    }

    // MARK: - Ring Color

    private var ringColor: some ShapeStyle {
        switch progress.phase {
        case .completed:
            return AnyShapeStyle(Color.green)
        case .failed:
            return AnyShapeStyle(Color.red)
        case .paused:
            return AnyShapeStyle(Color.orange)
        default:
            return AnyShapeStyle(AngularGradient(
                colors: [.blue, .purple, .blue],
                center: .center,
                startAngle: .degrees(0),
                endAngle: .degrees(360)
            ))
        }
    }

    // MARK: - Ring Center (context-aware)

    @ViewBuilder
    private var ringCenter: some View {
        switch progress.phase {
        case .idle:
            VStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Ready")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .cataloging:
            VStack(spacing: 2) {
                Text("\(progress.processedAlbums)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("of \(progress.totalAlbums) albums")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .planning:
            VStack(spacing: 4) {
                ProgressView()
                    .controlSize(.large)
                Text("Planning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .creatingFolders:
            VStack(spacing: 2) {
                Text("\(progress.foldersCreated)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("of \(progress.totalFolders) folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .uploading:
            VStack(spacing: 2) {
                Text("\(Int(progress.progressFraction * 100))%")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text(progress.formattedProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(progress.uploadedAssets.formatted()) assets")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

        case .generatingManifests:
            VStack(spacing: 2) {
                Text("\(progress.manifestsGenerated)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("of \(progress.totalManifests) manifests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .paused:
            VStack(spacing: 4) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("Paused")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .completed:
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .failed:
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                Text("Failed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Phase Detail

    @ViewBuilder
    private var phaseDetailView: some View {
        switch progress.phase {
        case .uploading:
            if let filename = progress.currentAssetFilename {
                VStack(spacing: 4) {
                    Text(filename)
                        .font(.headline)
                        .lineLimit(1)
                    ProgressView(value: progress.currentAssetProgress)
                        .frame(maxWidth: 300)
                }
            }

        case .cataloging, .creatingFolders, .generatingManifests:
            if let detail = progress.phaseDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        default:
            EmptyView()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}

// MARK: - Authentication View

struct AuthenticationView: View {
    let clientID: String
    let clientSecret: String
    let onAuthenticated: (GoogleDriveClient) async -> Void

    @State private var isAuthenticating = false
    @State private var authError: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Connect to Google Drive")
                .font(.title)

            Text("PhotoVault needs access to your Google Drive to back up your photos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            if let authError {
                Text(authError)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .frame(maxWidth: 400)
            }

            Button(action: startAuthentication) {
                if isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Sign in with Google", systemImage: "arrow.right.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAuthenticating)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func startAuthentication() {
        isAuthenticating = true
        authError = nil

        Task {
            do {
                let driveClient = GoogleDriveClient(clientID: clientID, clientSecret: clientSecret)

                // Start a local HTTP server to receive the OAuth callback
                let server = OAuthLoopbackServer()
                let port = try server.start()

                // Tell the drive client which port we're listening on
                await driveClient.setRedirectPort(port)

                // Build the auth URL and open in default browser
                let authURL = await driveClient.authorizationURL()
                NSWorkspace.shared.open(authURL)

                // Wait for Google to redirect back to our local server
                let code = try await server.waitForCode()

                // Exchange the code for tokens
                try await driveClient.exchangeCodeForTokens(code: code)

                // Save tokens to keychain
                let keychain = KeychainWrapper()
                try await driveClient.saveTokens(to: keychain)

                await onAuthenticated(driveClient)
            } catch {
                authError = error.localizedDescription
            }
            isAuthenticating = false
        }
    }
}

// MARK: - OAuth Loopback Server

/// Minimal HTTP server on localhost to receive Google OAuth redirect for Desktop app clients.
/// Uses blocking accept() on a detached task to avoid RunLoop/notification issues.
final class OAuthLoopbackServer: @unchecked Sendable {
    private var serverSocket: Int32 = -1

    /// Starts the server, returns the port it's listening on.
    func start() throws -> UInt16 {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { throw URLError(.cannotConnectToHost) }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // Let OS pick a port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            throw URLError(.cannotConnectToHost)
        }

        guard Darwin.listen(serverSocket, 1) == 0 else {
            close(serverSocket)
            throw URLError(.cannotConnectToHost)
        }

        // Get the actual port the OS assigned
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(serverSocket, withUnsafeMutablePointer(to: &boundAddr) {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self)
        }, &addrLen)

        return UInt16(bigEndian: boundAddr.sin_port)
    }

    /// Blocks (on a background thread) until Google redirects, then returns the auth code.
    func waitForCode() async throws -> String {
        let sock = serverSocket
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Blocking accept — waits for Google's redirect
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(sock, $0, &clientLen)
                    }
                }

                guard clientSocket >= 0 else {
                    continuation.resume(throwing: URLError(.cannotConnectToHost))
                    return
                }

                // Read the HTTP request
                var buffer = [UInt8](repeating: 0, count: 8192)
                let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)
                let requestString: String
                if bytesRead > 0 {
                    requestString = String(bytes: buffer[..<bytesRead], encoding: .utf8) ?? ""
                } else {
                    requestString = ""
                }

                // Parse the code from: GET /?code=XXXX&scope=... HTTP/1.1
                var code: String?
                if let firstLine = requestString.components(separatedBy: "\r\n").first,
                   let urlPart = firstLine.split(separator: " ").dropFirst().first,
                   let components = URLComponents(string: "http://localhost\(urlPart)") {
                    code = components.queryItems?.first(where: { $0.name == "code" })?.value
                }

                // Send response to the browser
                let body: String
                if code != nil {
                    body = """
                    <html><body style="font-family:-apple-system,sans-serif;text-align:center;padding:60px;">
                    <h1>Authentication Successful</h1>
                    <p>You can close this tab and return to PhotoVault.</p>
                    </body></html>
                    """
                } else {
                    body = """
                    <html><body style="font-family:-apple-system,sans-serif;text-align:center;padding:60px;">
                    <h1>Authentication Failed</h1>
                    <p>No authorization code received.</p>
                    </body></html>
                    """
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = response.withCString { ptr in
                    send(clientSocket, ptr, strlen(ptr), 0)
                }
                close(clientSocket)
                close(sock)

                if let code {
                    continuation.resume(returning: code)
                } else {
                    continuation.resume(throwing: URLError(.userAuthenticationRequired))
                }
            }
        }
    }

    deinit {
        if serverSocket >= 0 {
            close(serverSocket)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(progress: SyncProgress(), appState: AppState())
}
