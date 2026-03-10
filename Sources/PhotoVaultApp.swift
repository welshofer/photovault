import SwiftUI

// MARK: - App Entry Point

@main
struct PhotoVaultApp: App {
    @State private var syncProgress = SyncProgress()
    
    var body: some Scene {
        WindowGroup {
            ContentView(progress: syncProgress)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}  // Remove File > New
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @Bindable var progress: SyncProgress
    @State private var syncService: PhotoVaultSyncService?
    @State private var isAuthenticated = false
    @State private var showingSettings = false
    @State private var errorMessage: String?
    
    // Google OAuth credentials (replace with your own)
    private let clientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"
    private let clientSecret = "YOUR_CLIENT_SECRET"
    
    var body: some View {
        NavigationSplitView {
            Sidebar(progress: progress)
        } detail: {
            if !isAuthenticated {
                AuthenticationView(
                    clientID: clientID,
                    clientSecret: clientSecret,
                    onAuthenticated: { driveClient in
                        Task {
                            await initializeSyncService(driveClient: driveClient)
                            isAuthenticated = true
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
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private func initializeSyncService(driveClient: GoogleDriveClient) async {
        do {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("PhotoVault")
            
            try FileManager.default.createDirectory(
                at: appSupport,
                withIntermediateDirectories: true
            )
            
            let config = SyncConfiguration(appSupportDir: appSupport)
            syncService = try PhotoVaultSyncService(
                config: config,
                driveClient: driveClient,
                progress: progress
            )
        } catch {
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
        Task {
            do {
                try await syncService?.resumeSync()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var progress: SyncProgress
    
    var body: some View {
        List {
            Section("Status") {
                Label(progress.phase.rawValue, systemImage: phaseIcon)
                    .foregroundStyle(phaseColor)
            }
            
            Section("Statistics") {
                LabeledContent("Albums", value: "\(progress.processedAlbums)/\(progress.totalAlbums)")
                LabeledContent("Assets", value: "\(progress.uploadedAssets)/\(progress.totalAssets)")
                LabeledContent("Failed", value: "\(progress.failedAssets)")
            }
            
            Section("Storage") {
                LabeledContent("Uploaded", value: progress.formattedProgress)
            }
            
            if !progress.errors.isEmpty {
                Section("Recent Errors") {
                    ForEach(progress.errors.suffix(5)) { error in
                        VStack(alignment: .leading) {
                            Text(error.message)
                                .font(.caption)
                                .foregroundStyle(.red)
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
    
    private var phaseIcon: String {
        switch progress.phase {
        case .idle: return "moon.zzz"
        case .cataloging: return "folder.badge.gearshape"
        case .planning: return "chart.bar"
        case .creatingFolders: return "folder.badge.plus"
        case .uploading: return "arrow.up.circle"
        case .generatingManifests: return "doc.text"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var phaseColor: Color {
        switch progress.phase {
        case .idle: return .secondary
        case .cataloging, .planning, .creatingFolders, .uploading, .generatingManifests: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Sync Dashboard

struct SyncDashboard: View {
    @Bindable var progress: SyncProgress
    let onStartSync: () -> Void
    let onPauseSync: () -> Void
    let onResumeSync: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // Progress ring
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 20)
                Circle()
                    .trim(from: 0, to: progress.progressFraction)
                    .stroke(progressGradient, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear, value: progress.progressFraction)
                
                VStack {
                    Text("\(Int(progress.progressFraction * 100))%")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text(progress.formattedProgress)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)
            
            // Current file
            if let filename = progress.currentAssetFilename {
                VStack(spacing: 4) {
                    Text("Uploading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(filename)
                        .font(.headline)
                        .lineLimit(1)
                    ProgressView(value: progress.currentAssetProgress)
                        .frame(maxWidth: 300)
                }
            }
            
            // Time remaining
            if let remaining = progress.estimatedTimeRemaining, remaining > 0 {
                Text("About \(formatDuration(remaining)) remaining")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            // Controls
            HStack(spacing: 16) {
                switch progress.phase {
                case .idle, .completed, .failed:
                    Button(action: onStartSync) {
                        Label("Start Sync", systemImage: "play.fill")
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
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var progressGradient: AngularGradient {
        AngularGradient(
            colors: [.blue, .purple, .blue],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
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
    @Environment(\.openURL) private var openURL
    
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
    
    private func startAuthentication() {
        isAuthenticating = true
        
        let driveClient = GoogleDriveClient(clientID: clientID, clientSecret: clientSecret)
        
        Task {
            // In a real app, you'd use ASWebAuthenticationSession
            // For now, this is a placeholder showing the flow
            let authURL = await driveClient.authorizationURL()
            openURL(authURL)
            
            // The actual OAuth callback handling would happen via URL scheme
            // and call driveClient.exchangeCodeForTokens(code:)
            
            // For demo purposes:
            await onAuthenticated(driveClient)
            isAuthenticating = false
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView(progress: SyncProgress())
}
