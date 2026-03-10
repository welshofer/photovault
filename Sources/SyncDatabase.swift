import Foundation
import GRDB

// MARK: - Database Records

/// Tracks each unique asset and its upload status
struct AssetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "assets"
    
    var localIdentifier: String      // Primary key from PhotoKit
    var filename: String?
    var mediaType: Int               // PHAssetMediaType raw value
    var fileSize: Int64?
    var creationDate: Date?
    var md5Checksum: String?         // For integrity verification
    
    // Upload tracking
    var uploadStatus: UploadStatus
    var googleDriveFileID: String?
    var uploadedAt: Date?
    var lastError: String?
    var retryCount: Int
    
    // Resumable upload state
    var resumableUploadURI: String?
    var uploadedBytes: Int64
    
    enum UploadStatus: Int, Codable, Sendable {
        case pending = 0
        case inProgress = 1
        case completed = 2
        case failed = 3
        case skipped = 4            // e.g., iCloud asset unavailable
    }
}

/// Tracks albums/folders and their Google Drive folder mapping
struct AlbumRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "albums"
    
    var localIdentifier: String      // Primary key from PhotoKit
    var title: String
    var folderPath: String           // JSON-encoded [String] for hierarchy
    var albumType: Int
    var subtype: Int
    
    var googleDriveFolderID: String?
    var createdAt: Date
    var syncedAt: Date?
}

/// Many-to-many relationship: which assets belong to which albums
struct AlbumAssetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "album_assets"
    
    var albumIdentifier: String
    var assetIdentifier: String
    var sortOrder: Int               // Preserve album ordering
}

/// Sync session metadata for resumability
struct SyncSession: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sync_sessions"
    
    var id: Int64?
    var startedAt: Date
    var completedAt: Date?
    var totalAssets: Int
    var uploadedAssets: Int
    var failedAssets: Int
    var totalBytes: Int64
    var uploadedBytes: Int64
    var status: SessionStatus
    
    enum SessionStatus: Int, Codable, Sendable {
        case inProgress = 0
        case completed = 1
        case paused = 2
        case failed = 3
    }
}

// MARK: - Database Manager

actor SyncDatabase {
    private let dbQueue: DatabaseQueue
    
    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrator.migrate(dbQueue)
    }
    
    /// For in-memory testing
    init() throws {
        dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
    }
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1_initial") { db in
            // Assets table
            try db.create(table: "assets") { t in
                t.column("localIdentifier", .text).primaryKey()
                t.column("filename", .text)
                t.column("mediaType", .integer).notNull()
                t.column("fileSize", .integer)
                t.column("creationDate", .datetime)
                t.column("md5Checksum", .text)
                t.column("uploadStatus", .integer).notNull().defaults(to: 0)
                t.column("googleDriveFileID", .text)
                t.column("uploadedAt", .datetime)
                t.column("lastError", .text)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("resumableUploadURI", .text)
                t.column("uploadedBytes", .integer).notNull().defaults(to: 0)
            }
            
            // Albums table
            try db.create(table: "albums") { t in
                t.column("localIdentifier", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("folderPath", .text).notNull()  // JSON array
                t.column("albumType", .integer).notNull()
                t.column("subtype", .integer).notNull()
                t.column("googleDriveFolderID", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("syncedAt", .datetime)
            }
            
            // Album-Asset junction table
            try db.create(table: "album_assets") { t in
                t.column("albumIdentifier", .text).notNull()
                    .references("albums", onDelete: .cascade)
                t.column("assetIdentifier", .text).notNull()
                    .references("assets", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.primaryKey(["albumIdentifier", "assetIdentifier"])
            }
            
            // Sync sessions
            try db.create(table: "sync_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull()
                t.column("completedAt", .datetime)
                t.column("totalAssets", .integer).notNull()
                t.column("uploadedAssets", .integer).notNull().defaults(to: 0)
                t.column("failedAssets", .integer).notNull().defaults(to: 0)
                t.column("totalBytes", .integer).notNull()
                t.column("uploadedBytes", .integer).notNull().defaults(to: 0)
                t.column("status", .integer).notNull()
            }
            
            // Indexes for common queries
            try db.create(index: "idx_assets_status", on: "assets", columns: ["uploadStatus"])
            try db.create(index: "idx_assets_checksum", on: "assets", columns: ["md5Checksum"])
            try db.create(index: "idx_album_assets_asset", on: "album_assets", columns: ["assetIdentifier"])
        }
        
        return migrator
    }
    
    // MARK: - Asset Operations
    
    func upsertAsset(_ asset: AssetRecord) throws {
        try dbQueue.write { db in
            try asset.save(db)
        }
    }
    
    func upsertAssets(_ assets: [AssetRecord]) throws {
        try dbQueue.write { db in
            for asset in assets {
                try asset.save(db)
            }
        }
    }
    
    func fetchAsset(id: String) throws -> AssetRecord? {
        try dbQueue.read { db in
            try AssetRecord.fetchOne(db, key: id)
        }
    }
    
    func fetchPendingAssets(limit: Int) throws -> [AssetRecord] {
        try dbQueue.read { db in
            try AssetRecord
                .filter(Column("uploadStatus") == AssetRecord.UploadStatus.pending.rawValue)
                .limit(limit)
                .fetchAll(db)
        }
    }
    
    func fetchFailedAssets(maxRetries: Int) throws -> [AssetRecord] {
        try dbQueue.read { db in
            try AssetRecord
                .filter(Column("uploadStatus") == AssetRecord.UploadStatus.failed.rawValue)
                .filter(Column("retryCount") < maxRetries)
                .fetchAll(db)
        }
    }
    
    func fetchInProgressAssets() throws -> [AssetRecord] {
        try dbQueue.read { db in
            try AssetRecord
                .filter(Column("uploadStatus") == AssetRecord.UploadStatus.inProgress.rawValue)
                .fetchAll(db)
        }
    }
    
    func markAssetUploading(id: String, resumableURI: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE assets 
                    SET uploadStatus = ?, resumableUploadURI = ?
                    WHERE localIdentifier = ?
                    """,
                arguments: [AssetRecord.UploadStatus.inProgress.rawValue, resumableURI, id]
            )
        }
    }
    
    func markAssetCompleted(id: String, googleDriveFileID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE assets 
                    SET uploadStatus = ?, googleDriveFileID = ?, uploadedAt = ?, 
                        resumableUploadURI = NULL, lastError = NULL
                    WHERE localIdentifier = ?
                    """,
                arguments: [
                    AssetRecord.UploadStatus.completed.rawValue,
                    googleDriveFileID,
                    Date(),
                    id
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
                arguments: [AssetRecord.UploadStatus.failed.rawValue, error, id]
            )
        }
    }
    
    func updateUploadProgress(id: String, uploadedBytes: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE assets SET uploadedBytes = ? WHERE localIdentifier = ?",
                arguments: [uploadedBytes, id]
            )
        }
    }
    
    /// Check if asset already uploaded (by checksum) — for deduplication
    func findExistingUpload(checksum: String) throws -> AssetRecord? {
        try dbQueue.read { db in
            try AssetRecord
                .filter(Column("md5Checksum") == checksum)
                .filter(Column("uploadStatus") == AssetRecord.UploadStatus.completed.rawValue)
                .fetchOne(db)
        }
    }
    
    // MARK: - Album Operations
    
    func upsertAlbum(_ album: AlbumRecord) throws {
        try dbQueue.write { db in
            try album.save(db)
        }
    }
    
    func upsertAlbums(_ albums: [AlbumRecord]) throws {
        try dbQueue.write { db in
            for album in albums {
                try album.save(db)
            }
        }
    }
    
    func fetchAlbum(id: String) throws -> AlbumRecord? {
        try dbQueue.read { db in
            try AlbumRecord.fetchOne(db, key: id)
        }
    }
    
    func fetchAlbumsWithoutDriveFolder() throws -> [AlbumRecord] {
        try dbQueue.read { db in
            try AlbumRecord
                .filter(Column("googleDriveFolderID") == nil)
                .fetchAll(db)
        }
    }
    
    func setAlbumDriveFolder(albumID: String, driveFolderID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE albums 
                    SET googleDriveFolderID = ?, syncedAt = ?
                    WHERE localIdentifier = ?
                    """,
                arguments: [driveFolderID, Date(), albumID]
            )
        }
    }
    
    // MARK: - Album-Asset Mapping
    
    func addAssetToAlbum(assetID: String, albumID: String, sortOrder: Int) throws {
        try dbQueue.write { db in
            let record = AlbumAssetRecord(
                albumIdentifier: albumID,
                assetIdentifier: assetID,
                sortOrder: sortOrder
            )
            try record.save(db)
        }
    }
    
    func fetchAlbumsForAsset(assetID: String) throws -> [AlbumRecord] {
        try dbQueue.read { db in
            try AlbumRecord
                .joining(required: AlbumRecord.hasMany(
                    AlbumAssetRecord.self,
                    using: ForeignKey(["albumIdentifier"])
                ).filter(Column("assetIdentifier") == assetID))
                .fetchAll(db)
        }
    }
    
    func fetchAssetsInAlbum(albumID: String) throws -> [AssetRecord] {
        try dbQueue.read { db in
            try AssetRecord
                .joining(required: AssetRecord.hasMany(
                    AlbumAssetRecord.self,
                    using: ForeignKey(["assetIdentifier"])
                ).filter(Column("albumIdentifier") == albumID))
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }
    
    // MARK: - Sync Session Operations
    
    func startNewSession(totalAssets: Int, totalBytes: Int64) throws -> Int64 {
        try dbQueue.write { db in
            var session = SyncSession(
                id: nil,
                startedAt: Date(),
                completedAt: nil,
                totalAssets: totalAssets,
                uploadedAssets: 0,
                failedAssets: 0,
                totalBytes: totalBytes,
                uploadedBytes: 0,
                status: .inProgress
            )
            try session.insert(db)
            return session.id!
        }
    }
    
    func updateSessionProgress(
        sessionID: Int64,
        uploadedAssets: Int,
        failedAssets: Int,
        uploadedBytes: Int64
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE sync_sessions 
                    SET uploadedAssets = ?, failedAssets = ?, uploadedBytes = ?
                    WHERE id = ?
                    """,
                arguments: [uploadedAssets, failedAssets, uploadedBytes, sessionID]
            )
        }
    }
    
    func completeSession(sessionID: Int64, status: SyncSession.SessionStatus) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE sync_sessions 
                    SET completedAt = ?, status = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), status.rawValue, sessionID]
            )
        }
    }
    
    func fetchCurrentSession() throws -> SyncSession? {
        try dbQueue.read { db in
            try SyncSession
                .filter(Column("status") == SyncSession.SessionStatus.inProgress.rawValue)
                .order(Column("startedAt").desc)
                .fetchOne(db)
        }
    }
    
    // MARK: - Statistics
    
    struct SyncStats: Sendable {
        let totalAssets: Int
        let pendingAssets: Int
        let completedAssets: Int
        let failedAssets: Int
        let inProgressAssets: Int
        let totalBytes: Int64
        let uploadedBytes: Int64
    }
    
    func fetchStats() throws -> SyncStats {
        try dbQueue.read { db in
            let total = try AssetRecord.fetchCount(db)
            let pending = try AssetRecord
                .filter(Column("uploadStatus") == AssetRecord.UploadStatus.pending.rawValue)
                .fetchCount(db)
            let completed = try AssetRecord
                .filter(Column("uploadStatus") == AssetRecord.UploadStatus.completed.rawValue)
                .fetchCount(db)
            let failed = try AssetRecord
                .filter(Column("uploadStatus") == AssetRecord.UploadStatus.failed.rawValue)
                .fetchCount(db)
            let inProgress = try AssetRecord
                .filter(Column("uploadStatus") == AssetRecord.UploadStatus.inProgress.rawValue)
                .fetchCount(db)
            
            let totalBytes = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(fileSize), 0) FROM assets"
            ) ?? 0
            
            let uploadedBytes = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(fileSize), 0) FROM assets WHERE uploadStatus = ?",
                arguments: [AssetRecord.UploadStatus.completed.rawValue]
            ) ?? 0
            
            return SyncStats(
                totalAssets: total,
                pendingAssets: pending,
                completedAssets: completed,
                failedAssets: failed,
                inProgressAssets: inProgress,
                totalBytes: totalBytes,
                uploadedBytes: uploadedBytes
            )
        }
    }
}
