import Foundation
import Photos
import CryptoKit
import GRDB

// MARK: - Bucket-Based Sync Service

actor PhotoVaultBucketSyncService {
    
    private let config: SyncConfiguration
    private let database: SyncDatabaseV2
    private let catalogService: PhotosCatalogService
    private let exportService: AssetExportService
    private let driveClient: GoogleDriveClient
    
    private var isCancelled = false
    private var isPaused = false
    
    // Folder ID cache
    private var rootFolderID: String?
    private var mediaFolderID: String?
    private var albumsFolderID: String?
    private var bucketFolderCache: [String: String] = [:]  // bucket path → folder ID
    
    // Filename deduplication
    private var filenameResolver = FilenameResolver()
    
    // Progress
    private let progress: SyncProgress
    
    init(
        config: SyncConfiguration,
        driveClient: GoogleDriveClient,
        progress: SyncProgress
    ) throws {
        self.config = config
        self.database = try SyncDatabaseV2(path: config.databasePath)
        self.catalogService = PhotosCatalogService()
        self.exportService = AssetExportService()
        self.driveClient = driveClient
        self.progress = progress
    }
    
    // MARK: - Main Sync Flow
    
    func startFullSync() async throws {
        isCancelled = false
        isPaused = false
        
        // Phase 1: Catalog photos library
        await updatePhase(.cataloging)
        let (assets, albums) = try await catalogPhotosLibrary()
        
        // Phase 2: Plan bucket distribution
        await updatePhase(.planning)
        let plan = BucketPlanner.plan(assets: assets)
        await logBucketStats(plan.stats)
        
        // Phase 3: Create Drive folder structure
        await updatePhase(.creatingFolders)
        try await createDriveFolderStructure(buckets: plan.bucketsToCreate)
        
        // Phase 4: Upload assets to buckets
        await updatePhase(.uploading)
        try await uploadAllAssets()
        
        // Phase 5: Generate and upload album manifests
        await updatePhase(.generatingManifests)
        try await generateAlbumManifests(albums: albums)
        
        // Phase 6: Generate master catalog
        try await generateMasterCatalog()
        
        await updatePhase(.completed)
    }
    
    // MARK: - Phase 1: Catalog
    
    private func catalogPhotosLibrary() async throws -> ([AssetInfo], [AlbumInfo]) {
        guard await catalogService.requestAuthorization() else {
            throw SyncServiceError.photosAccessDenied
        }
        
        // Get all albums
        let albums = await catalogService.enumerateAllAlbums()
        await MainActor.run { progress.totalAlbums = albums.count }
        
        // Store albums
        var albumRecords: [AlbumRecordV2] = []
        for album in albums {
            if !config.includeSmartAlbums && album.albumType == .smartAlbum { continue }
            
            let record = AlbumRecordV2(
                localIdentifier: album.id,
                title: album.title,
                folderPath: encodeJSON(album.folderPath),
                albumType: album.albumType.rawValue,
                subtype: album.subtype.rawValue,
                assetCount: album.assetCount,
                manifestDriveID: nil,
                manifestPath: nil,
                manifestLastUpdated: nil,
                createdAt: Date()
            )
            albumRecords.append(record)
        }
        try await database.upsertAlbums(albumRecords)
        
        // Get all unique assets and build album membership
        var seenIDs = Set<String>()
        var allAssets: [AssetInfo] = []
        var assetRecords: [AssetRecordV2] = []
        var totalBytes: Int64 = 0
        
        for (index, album) in albums.enumerated() {
            try checkCancellation()
            
            let assets = catalogService.fetchAssets(in: album.id)
            
            for (sortOrder, asset) in assets.enumerated() {
                // Track membership
                try await database.addAssetToAlbum(
                    assetID: asset.id,
                    albumID: album.id,
                    sortOrder: sortOrder
                )
                
                // Deduplicate
                guard !seenIDs.contains(asset.id) else { continue }
                seenIDs.insert(asset.id)
                allAssets.append(asset)
                
                let size = asset.estimatedSize ?? 0
                totalBytes += size
                
                // Determine bucket
                let bucket = DateBucket.from(date: asset.creationDate)
                
                let record = AssetRecordV2(
                    localIdentifier: asset.id,
                    filename: asset.filename,
                    mediaType: asset.mediaType.rawValue,
                    fileSize: size,
                    creationDate: asset.creationDate,
                    md5Checksum: nil,
                    bucketPath: bucket?.mediaPath ?? DateBucket.undated,
                    uploadStatus: .pending,
                    driveFileID: nil,
                    drivePath: nil,
                    uploadedAt: nil,
                    lastError: nil,
                    retryCount: 0,
                    resumableUploadURI: nil,
                    uploadedBytes: 0
                )
                assetRecords.append(record)
            }
            
            await MainActor.run { progress.processedAlbums = index + 1 }
        }
        
        try await database.upsertAssets(assetRecords)
        
        await MainActor.run {
            progress.totalAssets = assetRecords.count
            progress.totalBytes = totalBytes
        }
        
        return (allAssets, albums)
    }
    
    // MARK: - Phase 3: Create Folders
    
    private func createDriveFolderStructure(buckets: [DateBucket]) async throws {
        // Create root
        if let existing = try await driveClient.findFolder(name: config.rootFolderName) {
            rootFolderID = existing
        } else {
            rootFolderID = try await driveClient.createFolder(name: config.rootFolderName)
        }

        guard let rootID = rootFolderID else {
            throw SyncServiceError.folderCreationFailed
        }

        // Create media/ and albums/ top-level folders
        if let existing = try await driveClient.findFolder(name: "media", parentID: rootID) {
            mediaFolderID = existing
        } else {
            mediaFolderID = try await driveClient.createFolder(name: "media", parentID: rootID)
        }

        if let existing = try await driveClient.findFolder(name: "albums", parentID: rootID) {
            albumsFolderID = existing
        } else {
            albumsFolderID = try await driveClient.createFolder(name: "albums", parentID: rootID)
        }

        // Create undated folder
        let undatedID = try await driveClient.createFolderPath(
            ["undated"],
            rootParentID: mediaFolderID
        )
        bucketFolderCache[DateBucket.undated] = undatedID

        // Create year/week buckets
        let bucketsByYear = Dictionary(grouping: buckets) { $0.year }

        for (year, yearBuckets) in bucketsByYear.sorted(by: { $0.key < $1.key }) {
            try checkCancellation()

            // Create year folder
            let yearFolderID: String
            if let existing = try await driveClient.findFolder(name: String(year), parentID: mediaFolderID) {
                yearFolderID = existing
            } else {
                yearFolderID = try await driveClient.createFolder(name: String(year), parentID: mediaFolderID)
            }

            // Create week folders within year
            for bucket in yearBuckets {
                let weekFolderID: String
                if let existing = try await driveClient.findFolder(name: bucket.weekFolder, parentID: yearFolderID) {
                    weekFolderID = existing
                } else {
                    weekFolderID = try await driveClient.createFolder(name: bucket.weekFolder, parentID: yearFolderID)
                }
                bucketFolderCache[bucket.mediaPath] = weekFolderID
            }
        }
    }
    
    // MARK: - Phase 4: Upload Assets
    
    private func uploadAllAssets() async throws {
        let batchSize = 100
        var totalUploaded = 0

        while !isCancelled {
            // Debug limit: stop after N assets
            if config.debugMaxAssets > 0 && totalUploaded >= config.debugMaxAssets {
                print("🛑 Debug limit reached (\(config.debugMaxAssets) assets). Stopping uploads.")
                break
            }

            try await waitIfPaused()

            let limit = config.debugMaxAssets > 0
                ? min(batchSize, config.debugMaxAssets - totalUploaded)
                : batchSize

            let pending = try await database.fetchPendingAssets(limit: limit)
            if pending.isEmpty {
                let failed = try await database.fetchFailedAssets(maxRetries: config.maxRetries)
                if failed.isEmpty { break }
                try await uploadBatch(failed)
                totalUploaded += failed.count
            } else {
                try await uploadBatch(pending)
                totalUploaded += pending.count
            }
        }
    }
    
    private func uploadBatch(_ assets: [AssetRecordV2]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var iterator = assets.makeIterator()
            
            while inFlight < config.maxConcurrentUploads, let asset = iterator.next() {
                group.addTask { try await self.uploadSingleAsset(asset) }
                inFlight += 1
            }
            
            for try await _ in group {
                inFlight -= 1
                if let next = iterator.next(), !isCancelled {
                    group.addTask { try await self.uploadSingleAsset(next) }
                    inFlight += 1
                }
            }
        }
    }
    
    private func uploadSingleAsset(_ asset: AssetRecordV2) async throws {
        do {
            try await database.markAssetUploading(id: asset.localIdentifier)
            
            // Export to temp
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            
            let exportedURL = try await exportService.exportOriginal(
                assetID: asset.localIdentifier,
                to: tempDir
            )
            
            // Compute checksum
            let checksum = try computeMD5(fileURL: exportedURL)
            
            // Check for duplicate by checksum
            if let existing = try await database.findByChecksum(checksum) {
                // Already uploaded — just copy the reference
                try await database.markAssetCompleted(
                    id: asset.localIdentifier,
                    driveFileID: existing.driveFileID!,
                    drivePath: existing.drivePath!,
                    checksum: checksum
                )
                await incrementProgress(bytes: asset.fileSize ?? 0)
                return
            }
            
            // Get bucket folder ID
            let bucketPath = asset.bucketPath ?? DateBucket.undated
            guard let bucketFolderID = bucketFolderCache[bucketPath] else {
                throw SyncServiceError.bucketNotFound(bucketPath)
            }
            
            // Resolve filename (handle collisions)
            let originalFilename = asset.filename ?? "unknown"
            let resolvedFilename = filenameResolver.resolve(
                filename: originalFilename,
                inBucket: bucketPath
            )
            
            // Upload
            let fileSize = try FileManager.default.attributesOfItem(
                atPath: exportedURL.path
            )[.size] as! Int64
            
            let driveFileID = try await driveClient.uploadFile(
                fileURL: exportedURL,
                filename: resolvedFilename,
                mimeType: exportedURL.mimeType,
                parentFolderID: bucketFolderID
            ) { uploaded, total in
                Task { @MainActor in
                    self.progress.currentAssetProgress = Double(uploaded) / Double(total)
                }
            }
            
            // Full path for manifest references
            let drivePath = "\(bucketPath)/\(resolvedFilename)"
            
            try await database.markAssetCompleted(
                id: asset.localIdentifier,
                driveFileID: driveFileID,
                drivePath: drivePath,
                checksum: checksum
            )
            
            await incrementProgress(bytes: fileSize)
            
        } catch {
            try await database.markAssetFailed(
                id: asset.localIdentifier,
                error: error.localizedDescription
            )
            await recordError(message: error.localizedDescription)
        }
    }
    
    // MARK: - Phase 5: Album Manifests
    
    private func generateAlbumManifests(albums: [AlbumInfo]) async throws {
        guard let albumsFolderID else {
            throw SyncServiceError.folderCreationFailed
        }
        
        for album in albums {
            try checkCancellation()
            
            // Get all assets in this album with their Drive locations
            let assetRecords = try await database.fetchAssetsInAlbum(albumID: album.id)
            
            // Build asset references
            let assetRefs: [AlbumManifest.AssetReference] = assetRecords.enumerated().compactMap { index, asset in
                guard let drivePath = asset.drivePath,
                      let driveFileID = asset.driveFileID else {
                    return nil  // Skip assets that weren't uploaded
                }
                
                return AlbumManifest.AssetReference(
                    localID: asset.localIdentifier,
                    filename: asset.filename ?? "unknown",
                    drivePath: drivePath,
                    driveFileID: driveFileID,
                    creationDate: asset.creationDate,
                    mediaType: mediaTypeString(asset.mediaType),
                    width: 0,   // Could fetch from PhotoKit if needed
                    height: 0,
                    duration: nil,
                    isFavorite: false,
                    sortOrder: index
                )
            }
            
            let manifest = AlbumManifest(
                albumID: album.id,
                title: album.title,
                folderPath: album.folderPath,
                albumType: albumTypeString(album.albumType),
                lastUpdated: Date(),
                assetCount: assetRefs.count,
                assets: assetRefs
            )
            
            // Determine manifest path
            let manifestPath = buildManifestPath(album: album)
            
            // Create parent folders if needed (for nested album hierarchy)
            let parentFolderID: String
            if album.folderPath.isEmpty {
                parentFolderID = albumsFolderID
            } else {
                parentFolderID = try await driveClient.createFolderPath(
                    album.folderPath,
                    rootParentID: albumsFolderID
                )
            }
            
            // Encode and upload manifest
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(manifest)
            
            let manifestFileID = try await uploadJSONFile(
                data: jsonData,
                filename: "\(sanitizeFilename(album.title)).json",
                parentFolderID: parentFolderID
            )
            
            // Update database
            try await database.setAlbumManifest(
                albumID: album.id,
                manifestDriveID: manifestFileID,
                manifestPath: manifestPath
            )
        }
    }
    
    // MARK: - Phase 6: Master Catalog
    
    private func generateMasterCatalog() async throws {
        guard let rootID = rootFolderID else { return }
        
        let allAssets = try await database.fetchAllCompletedAssets()
        
        var catalogEntries: [String: MasterCatalog.CatalogEntry] = [:]
        var totalBytes: Int64 = 0
        
        for asset in allAssets {
            guard let drivePath = asset.drivePath,
                  let driveFileID = asset.driveFileID else { continue }
            
            catalogEntries[asset.localIdentifier] = MasterCatalog.CatalogEntry(
                filename: asset.filename ?? "unknown",
                drivePath: drivePath,
                driveFileID: driveFileID,
                fileSize: asset.fileSize ?? 0,
                md5Checksum: asset.md5Checksum ?? "",
                creationDate: asset.creationDate,
                uploadedAt: asset.uploadedAt ?? Date()
            )
            totalBytes += asset.fileSize ?? 0
        }
        
        let catalog = MasterCatalog(
            lastUpdated: Date(),
            totalAssets: catalogEntries.count,
            totalBytes: totalBytes,
            assets: catalogEntries
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(catalog)
        
        _ = try await uploadJSONFile(
            data: jsonData,
            filename: "_catalog.json",
            parentFolderID: rootID
        )
    }
    
    // MARK: - Helpers
    
    private func uploadJSONFile(
        data: Data,
        filename: String,
        parentFolderID: String
    ) async throws -> String {
        // Write to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        return try await driveClient.uploadFile(
            fileURL: tempURL,
            filename: filename,
            mimeType: "application/json",
            parentFolderID: parentFolderID
        ) { _, _ in }
    }
    
    private func buildManifestPath(album: AlbumInfo) -> String {
        let pathComponents = ["albums"] + album.folderPath + ["\(sanitizeFilename(album.title)).json"]
        return pathComponents.joined(separator: "/")
    }
    
    private func sanitizeFilename(_ name: String) -> String {
        // Remove/replace characters that are problematic for filenames
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }
    
    private func mediaTypeString(_ rawValue: Int) -> String {
        switch PHAssetMediaType(rawValue: rawValue) {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }
    
    private func albumTypeString(_ type: PHAssetCollectionType) -> String {
        switch type {
        case .album: return "album"
        case .smartAlbum: return "smartAlbum"
        case .moment: return "moment"
        @unknown default: return "unknown"
        }
    }
    
    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
    
    private func computeMD5(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        
        var hasher = Insecure.MD5()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024),
                  !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    
    private func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
    
    private func waitIfPaused() async throws {
        while isPaused && !isCancelled {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try checkCancellation()
    }
    
    @MainActor
    private func updatePhase(_ phase: SyncProgress.SyncPhase) {
        progress.phase = phase
    }
    
    @MainActor
    private func incrementProgress(bytes: Int64) {
        progress.uploadedAssets += 1
        progress.uploadedBytes += bytes
        progress.currentAssetProgress = 0
    }
    
    @MainActor
    private func recordError(message: String) {
        progress.failedAssets += 1
    }
    
    @MainActor
    private func logBucketStats(_ stats: BucketPlanner.BucketStats) {
        print("📊 Bucket distribution:")
        print("   Total buckets: \(stats.totalBuckets)")
        print("   Years: \(stats.yearsSpanned)")
        print("   Assets per bucket: \(stats.minAssetsPerBucket)-\(stats.maxAssetsPerBucket) (avg: \(Int(stats.avgAssetsPerBucket)))")
    }
    
    func pause() { isPaused = true }
    func cancel() { isCancelled = true }
}

// MARK: - Updated Database

actor SyncDatabaseV2 {
    private let dbQueue: DatabaseQueue
    
    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }
    
    private func migrate() throws {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v2_buckets") { db in
            try db.create(table: "assets", ifNotExists: true) { t in
                t.column("localIdentifier", .text).primaryKey()
                t.column("filename", .text)
                t.column("mediaType", .integer).notNull()
                t.column("fileSize", .integer)
                t.column("creationDate", .datetime)
                t.column("md5Checksum", .text)
                t.column("bucketPath", .text)
                t.column("uploadStatus", .integer).notNull().defaults(to: 0)
                t.column("driveFileID", .text)
                t.column("drivePath", .text)
                t.column("uploadedAt", .datetime)
                t.column("lastError", .text)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("resumableUploadURI", .text)
                t.column("uploadedBytes", .integer).notNull().defaults(to: 0)
            }
            
            try db.create(table: "albums", ifNotExists: true) { t in
                t.column("localIdentifier", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("albumType", .integer).notNull()
                t.column("subtype", .integer).notNull()
                t.column("assetCount", .integer).notNull()
                t.column("manifestDriveID", .text)
                t.column("manifestPath", .text)
                t.column("manifestLastUpdated", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            
            try db.create(table: "album_assets", ifNotExists: true) { t in
                t.column("albumIdentifier", .text).notNull()
                t.column("assetIdentifier", .text).notNull()
                t.column("sortOrder", .integer).notNull()
                t.primaryKey(["albumIdentifier", "assetIdentifier"])
            }
            
            try db.create(index: "idx_assets_status", on: "assets", columns: ["uploadStatus"], ifNotExists: true)
            try db.create(index: "idx_assets_checksum", on: "assets", columns: ["md5Checksum"], ifNotExists: true)
            try db.create(index: "idx_assets_bucket", on: "assets", columns: ["bucketPath"], ifNotExists: true)
        }
        
        try migrator.migrate(dbQueue)
    }
    
    func upsertAssets(_ assets: [AssetRecordV2]) throws {
        try dbQueue.write { db in
            for asset in assets {
                try asset.save(db)
            }
        }
    }
    
    func upsertAlbums(_ albums: [AlbumRecordV2]) throws {
        try dbQueue.write { db in
            for album in albums {
                try album.save(db)
            }
        }
    }
    
    func addAssetToAlbum(assetID: String, albumID: String, sortOrder: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO album_assets 
                    (albumIdentifier, assetIdentifier, sortOrder) 
                    VALUES (?, ?, ?)
                    """,
                arguments: [albumID, assetID, sortOrder]
            )
        }
    }
    
    func fetchPendingAssets(limit: Int) throws -> [AssetRecordV2] {
        try dbQueue.read { db in
            try AssetRecordV2
                .filter(Column("uploadStatus") == AssetRecordV2.UploadStatus.pending.rawValue)
                .limit(limit)
                .fetchAll(db)
        }
    }
    
    func fetchFailedAssets(maxRetries: Int) throws -> [AssetRecordV2] {
        try dbQueue.read { db in
            try AssetRecordV2
                .filter(Column("uploadStatus") == AssetRecordV2.UploadStatus.failed.rawValue)
                .filter(Column("retryCount") < maxRetries)
                .fetchAll(db)
        }
    }
    
    func findByChecksum(_ checksum: String) throws -> AssetRecordV2? {
        try dbQueue.read { db in
            try AssetRecordV2
                .filter(Column("md5Checksum") == checksum)
                .filter(Column("uploadStatus") == AssetRecordV2.UploadStatus.completed.rawValue)
                .fetchOne(db)
        }
    }
    
    func markAssetUploading(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE assets SET uploadStatus = ? WHERE localIdentifier = ?",
                arguments: [AssetRecordV2.UploadStatus.inProgress.rawValue, id]
            )
        }
    }
    
    func markAssetCompleted(
        id: String,
        driveFileID: String,
        drivePath: String,
        checksum: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE assets 
                    SET uploadStatus = ?, driveFileID = ?, drivePath = ?, 
                        md5Checksum = ?, uploadedAt = ?
                    WHERE localIdentifier = ?
                    """,
                arguments: [
                    AssetRecordV2.UploadStatus.completed.rawValue,
                    driveFileID, drivePath, checksum, Date(), id
                ]
            )
        }
    }
    
    func markAssetFailed(id: String, error: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE assets 
                    SET uploadStatus = ?, lastError = ?, retryCount = retryCount + 1
                    WHERE localIdentifier = ?
                    """,
                arguments: [AssetRecordV2.UploadStatus.failed.rawValue, error, id]
            )
        }
    }
    
    func fetchAssetsInAlbum(albumID: String) throws -> [AssetRecordV2] {
        try dbQueue.read { db in
            try AssetRecordV2.fetchAll(db, sql: """
                SELECT assets.* FROM assets
                INNER JOIN album_assets ON album_assets.assetIdentifier = assets.localIdentifier
                WHERE album_assets.albumIdentifier = ?
                ORDER BY album_assets.sortOrder
                """, arguments: [albumID])
        }
    }
    
    func fetchAllCompletedAssets() throws -> [AssetRecordV2] {
        try dbQueue.read { db in
            try AssetRecordV2
                .filter(Column("uploadStatus") == AssetRecordV2.UploadStatus.completed.rawValue)
                .fetchAll(db)
        }
    }
    
    func setAlbumManifest(albumID: String, manifestDriveID: String, manifestPath: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE albums 
                    SET manifestDriveID = ?, manifestPath = ?, manifestLastUpdated = ?
                    WHERE localIdentifier = ?
                    """,
                arguments: [manifestDriveID, manifestPath, Date(), albumID]
            )
        }
    }
}

