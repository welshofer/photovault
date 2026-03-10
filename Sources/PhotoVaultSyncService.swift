import Foundation
import Photos
import CryptoKit

// MARK: - Sync Configuration

struct SyncConfiguration: Codable, Sendable {
    /// Root folder name in Google Drive (e.g., "Apple Photos Backup")
    var rootFolderName: String = "Apple Photos Backup"
    
    /// Whether to include smart albums (Favorites, Screenshots, etc.)
    var includeSmartAlbums: Bool = true
    
    /// Maximum concurrent uploads
    var maxConcurrentUploads: Int = 3
    
    /// Chunk size for resumable uploads (in bytes)
    var uploadChunkSize: Int = 10 * 1024 * 1024  // 10 MB
    
    /// Maximum retries for failed uploads
    var maxRetries: Int = 5
    
    /// Skip assets that are in iCloud but not downloaded
    var skipICloudOnlyAssets: Bool = false
    
    /// Path to the sync database
    var databasePath: String
    
    init(appSupportDir: URL) {
        databasePath = appSupportDir.appendingPathComponent("PhotoVault.sqlite").path
    }
}

// MARK: - Sync Progress

@MainActor
@Observable
final class SyncProgress {
    var phase: SyncPhase = .idle
    var totalAlbums: Int = 0
    var processedAlbums: Int = 0
    var totalAssets: Int = 0
    var uploadedAssets: Int = 0
    var failedAssets: Int = 0
    var totalBytes: Int64 = 0
    var uploadedBytes: Int64 = 0
    var currentAssetFilename: String?
    var currentAssetProgress: Double = 0
    var estimatedTimeRemaining: TimeInterval?
    var errors: [SyncError] = []

    enum SyncPhase: String, Sendable {
        case idle = "Idle"
        case cataloging = "Cataloging Photos Library"
        case planning = "Planning Bucket Distribution"
        case creatingFolders = "Creating Folder Structure"
        case uploading = "Uploading"
        case generatingManifests = "Generating Album Manifests"
        case paused = "Paused"
        case completed = "Completed"
        case failed = "Failed"
    }

    var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(uploadedBytes) / Double(totalBytes)
    }

    var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: uploadedBytes)) / \(formatter.string(fromByteCount: totalBytes))"
    }
}

struct SyncError: Identifiable, Sendable {
    let id = UUID()
    let assetID: String?
    let message: String
    let timestamp: Date
}

// MARK: - Main Sync Orchestrator

actor PhotoVaultSyncService {
    
    private let config: SyncConfiguration
    private let database: SyncDatabase
    private let catalogService: PhotosCatalogService
    private let exportService: AssetExportService
    private let driveClient: GoogleDriveClient
    
    private var isCancelled: Bool = false
    private var isPaused: Bool = false
    
    private var rootFolderID: String?
    private var sessionID: Int64?
    
    // Progress tracking
    private let progress: SyncProgress
    private var uploadStartTime: Date?
    
    init(
        config: SyncConfiguration,
        driveClient: GoogleDriveClient,
        progress: SyncProgress
    ) throws {
        self.config = config
        self.database = try SyncDatabase(path: config.databasePath)
        self.catalogService = PhotosCatalogService()
        self.exportService = AssetExportService()
        self.driveClient = driveClient
        self.progress = progress
    }
    
    // MARK: - Main Sync Entry Point
    
    func startFullSync() async throws {
        isCancelled = false
        isPaused = false
        uploadStartTime = Date()
        
        // Phase 1: Catalog
        await updatePhase(.cataloging)
        try await catalogPhotosLibrary()
        
        // Phase 2: Create folder structure
        await updatePhase(.creatingFolders)
        try await createDriveFolderStructure()
        
        // Phase 3: Upload assets
        await updatePhase(.uploading)
        try await uploadAllPendingAssets()
        
        // Complete
        if let sessionID {
            try await database.completeSession(sessionID: sessionID, status: .completed)
        }
        await updatePhase(.completed)
    }
    
    func resumeSync() async throws {
        isCancelled = false
        isPaused = false
        
        // Check for in-progress uploads that need resuming
        let inProgress = try await database.fetchInProgressAssets()
        for asset in inProgress {
            // Mark as pending to retry
            try await database.markAssetFailed(id: asset.localIdentifier, error: "Interrupted")
        }
        
        await updatePhase(.uploading)
        try await uploadAllPendingAssets()
    }
    
    func pause() {
        isPaused = true
        Task { @MainActor in
            progress.phase = .paused
        }
    }
    
    func cancel() {
        isCancelled = true
    }
    
    // MARK: - Phase 1: Catalog
    
    private func catalogPhotosLibrary() async throws {
        // Request authorization
        guard await catalogService.requestAuthorization() else {
            throw SyncServiceError.photosAccessDenied
        }
        
        // Enumerate all albums
        let albums = await catalogService.enumerateAllAlbums()
        
        await MainActor.run {
            progress.totalAlbums = albums.count
        }
        
        // Store albums in database
        var albumRecords: [AlbumRecord] = []
        for album in albums {
            // Skip smart albums if configured
            if !config.includeSmartAlbums && album.albumType == .smartAlbum {
                continue
            }
            
            let record = AlbumRecord(
                localIdentifier: album.id,
                title: album.title,
                folderPath: encodeFolderPath(album.folderPath),
                albumType: album.albumType.rawValue,
                subtype: album.subtype.rawValue,
                googleDriveFolderID: nil,
                createdAt: Date(),
                syncedAt: nil
            )
            albumRecords.append(record)
        }
        try await database.upsertAlbums(albumRecords)
        
        // Enumerate all unique assets
        var seenAssetIDs = Set<String>()
        var assetRecords: [AssetRecord] = []
        var totalBytes: Int64 = 0
        
        for (index, album) in albums.enumerated() {
            try checkCancellation()
            
            let assets = catalogService.fetchAssets(in: album.id)
            
            for (assetIndex, asset) in assets.enumerated() {
                // Track album membership
                try await database.addAssetToAlbum(
                    assetID: asset.id,
                    albumID: album.id,
                    sortOrder: assetIndex
                )
                
                // Only add asset once (deduplication)
                guard !seenAssetIDs.contains(asset.id) else { continue }
                seenAssetIDs.insert(asset.id)
                
                let size = asset.estimatedSize ?? 0
                totalBytes += size
                
                let record = AssetRecord(
                    localIdentifier: asset.id,
                    filename: asset.filename,
                    mediaType: asset.mediaType.rawValue,
                    fileSize: size,
                    creationDate: asset.creationDate,
                    md5Checksum: nil,  // Computed during export
                    uploadStatus: .pending,
                    googleDriveFileID: nil,
                    uploadedAt: nil,
                    lastError: nil,
                    retryCount: 0,
                    resumableUploadURI: nil,
                    uploadedBytes: 0
                )
                assetRecords.append(record)
            }
            
            await MainActor.run {
                progress.processedAlbums = index + 1
            }
        }
        
        // Batch insert all assets
        try await database.upsertAssets(assetRecords)
        
        // Create sync session
        sessionID = try await database.startNewSession(
            totalAssets: assetRecords.count,
            totalBytes: totalBytes
        )
        
        await MainActor.run {
            progress.totalAssets = assetRecords.count
            progress.totalBytes = totalBytes
        }
    }
    
    // MARK: - Phase 2: Create Folders
    
    private func createDriveFolderStructure() async throws {
        // Create or find root folder
        if let existingRoot = try await driveClient.findFolder(name: config.rootFolderName) {
            rootFolderID = existingRoot
        } else {
            rootFolderID = try await driveClient.createFolder(name: config.rootFolderName)
        }
        
        guard let rootID = rootFolderID else {
            throw SyncServiceError.folderCreationFailed
        }
        
        // Create folders for each album
        let albums = try await database.fetchAlbumsWithoutDriveFolder()
        
        for album in albums {
            try checkCancellation()
            
            let folderPath = decodeFolderPath(album.folderPath)
            let fullPath = folderPath + [album.title]
            
            let folderID = try await driveClient.createFolderPath(fullPath, rootParentID: rootID)
            try await database.setAlbumDriveFolder(albumID: album.localIdentifier, driveFolderID: folderID)
        }
    }
    
    // MARK: - Phase 3: Upload
    
    private func uploadAllPendingAssets() async throws {
        let batchSize = 100
        
        while !isCancelled {
            try await waitIfPaused()
            
            // Fetch next batch of pending assets
            let pending = try await database.fetchPendingAssets(limit: batchSize)
            
            if pending.isEmpty {
                // Check for failed assets to retry
                let failed = try await database.fetchFailedAssets(maxRetries: config.maxRetries)
                if failed.isEmpty {
                    break  // All done
                }
                // Retry failed ones
                try await uploadBatch(failed)
            } else {
                try await uploadBatch(pending)
            }
        }
    }
    
    private func uploadBatch(_ assets: [AssetRecord]) async throws {
        // Use TaskGroup for concurrent uploads
        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var assetIterator = assets.makeIterator()
            
            // Start initial batch
            while inFlight < config.maxConcurrentUploads, let asset = assetIterator.next() {
                group.addTask {
                    try await self.uploadSingleAsset(asset)
                }
                inFlight += 1
            }
            
            // Process results and add more tasks
            for try await _ in group {
                inFlight -= 1
                
                if let nextAsset = assetIterator.next(), !isCancelled {
                    group.addTask {
                        try await self.uploadSingleAsset(nextAsset)
                    }
                    inFlight += 1
                }
            }
        }
    }
    
    private func uploadSingleAsset(_ asset: AssetRecord) async throws {
        do {
            // Mark as in-progress
            try await database.markAssetUploading(id: asset.localIdentifier, resumableURI: nil)
            
            await MainActor.run {
                progress.currentAssetFilename = asset.filename
                progress.currentAssetProgress = 0
            }
            
            // Export to temp file
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            let exportedURL = try await exportService.exportOriginal(
                assetID: asset.localIdentifier,
                to: tempDir
            ) { exportProgress in
                Task { @MainActor in
                    self.progress.currentAssetProgress = exportProgress * 0.1  // 10% for export
                }
            }
            
            // Compute checksum for deduplication
            let checksum = try computeMD5(fileURL: exportedURL)
            
            // Check if we already uploaded this file (deduplication)
            if let existing = try await database.findExistingUpload(checksum: checksum) {
                // Already uploaded — just mark complete with same Drive ID
                try await database.markAssetCompleted(
                    id: asset.localIdentifier,
                    googleDriveFileID: existing.googleDriveFileID!
                )
                await incrementUploadedCount()
                return
            }
            
            // Get the target folder (first album this asset belongs to)
            let albums = try await database.fetchAlbumsForAsset(assetID: asset.localIdentifier)
            guard let targetAlbum = albums.first,
                  let targetFolderID = targetAlbum.googleDriveFolderID else {
                throw SyncServiceError.noTargetFolder(asset.localIdentifier)
            }
            
            // Upload to Google Drive
            let fileSize = try FileManager.default.attributesOfItem(atPath: exportedURL.path)[.size] as! Int64
            
            let driveFileID = try await driveClient.uploadFile(
                fileURL: exportedURL,
                filename: asset.filename ?? "unknown",
                mimeType: exportedURL.mimeType,
                parentFolderID: targetFolderID,
                existingUploadURI: asset.resumableUploadURI
            ) { uploaded, total in
                Task { @MainActor in
                    // 10-100% for upload
                    self.progress.currentAssetProgress = 0.1 + (Double(uploaded) / Double(total)) * 0.9
                }
            }
            
            // Mark complete
            try await database.markAssetCompleted(
                id: asset.localIdentifier,
                googleDriveFileID: driveFileID
            )
            
            await incrementUploadedCount(bytes: fileSize)
            
        } catch {
            try await database.markAssetFailed(
                id: asset.localIdentifier,
                error: error.localizedDescription
            )
            await recordError(assetID: asset.localIdentifier, message: error.localizedDescription)
        }
    }
    
    // MARK: - Helpers
    
    private func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
    
    private func waitIfPaused() async throws {
        while isPaused && !isCancelled {
            try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second
        }
        try checkCancellation()
    }
    
    private func updatePhase(_ phase: SyncProgress.SyncPhase) async {
        await MainActor.run { progress.phase = phase }
    }
    
    private func incrementUploadedCount(bytes: Int64 = 0) async {
        let startTime = uploadStartTime
        await MainActor.run {
            progress.uploadedAssets += 1
            progress.uploadedBytes += bytes
            progress.currentAssetProgress = 0
            progress.currentAssetFilename = nil

            // Update ETA
            if let startTime, progress.uploadedBytes > 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                let bytesPerSecond = Double(progress.uploadedBytes) / elapsed
                let remainingBytes = Double(progress.totalBytes - progress.uploadedBytes)
                if bytesPerSecond > 0 {
                    progress.estimatedTimeRemaining = remainingBytes / bytesPerSecond
                }
            }
        }
    }
    
    private func recordError(assetID: String?, message: String) async {
        await MainActor.run {
            progress.failedAssets += 1
            progress.errors.append(SyncError(
                assetID: assetID,
                message: message,
                timestamp: Date()
            ))
            if progress.errors.count > 100 {
                progress.errors.removeFirst()
            }
        }
    }
    
    private func encodeFolderPath(_ path: [String]) -> String {
        let data = try! JSONEncoder().encode(path)
        return String(data: data, encoding: .utf8)!
    }
    
    private func decodeFolderPath(_ encoded: String) -> [String] {
        let data = encoded.data(using: .utf8)!
        return try! JSONDecoder().decode([String].self, from: data)
    }
    
    private func computeMD5(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        
        var hasher = Insecure.MD5()
        
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024) else { return false }
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
}

// MARK: - Sync Errors

enum SyncServiceError: LocalizedError {
    case photosAccessDenied
    case folderCreationFailed
    case noTargetFolder(String)
    case bucketNotFound(String)

    var errorDescription: String? {
        switch self {
        case .photosAccessDenied:
            return "Photos library access denied"
        case .folderCreationFailed:
            return "Failed to create root folder in Google Drive"
        case .noTargetFolder(let id):
            return "No target folder for asset \(id)"
        case .bucketNotFound(let path):
            return "Bucket folder not found: \(path)"
        }
    }
}
