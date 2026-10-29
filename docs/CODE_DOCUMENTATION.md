# PhotoVault Code Documentation

## Source Files Overview

| File | Purpose | Lines | Dependencies |
|------|---------|-------|--------------|
| `PhotoKitEnumeration.swift` | PhotoKit integration for library access | ~250 | Photos.framework |
| `BucketStorageSchema.swift` | Data models and bucket planning | ~300 | Foundation |
| `SyncDatabase.swift` | SQLite persistence (v1) | ~350 | GRDB |
| `GoogleDriveClient.swift` | Google Drive API wrapper | ~400 | Foundation, AuthenticationServices |
| `PhotoVaultSyncService.swift` | Main sync orchestrator (v1) | ~350 | All above |
| `PhotoVaultBucketSyncService.swift` | Bucket-based sync orchestrator (v2) | ~450 | All above |
| `AlbumReconstructor.swift` | Album restoration utilities | ~250 | GoogleDriveClient |
| `PhotoVaultApp.swift` | SwiftUI application shell | ~200 | SwiftUI |

---

## PhotoKitEnumeration.swift

### Purpose
Provides read access to the Apple Photos library via PhotoKit framework. Handles authorization, album enumeration, asset metadata extraction, and original file export.

### Key Types

#### `AlbumInfo`
```swift
struct AlbumInfo: Identifiable, Sendable {
    let id: String                    // PHAssetCollection.localIdentifier
    let title: String                 // Album name
    let assetCount: Int               // Number of photos/videos
    let albumType: PHAssetCollectionType
    let subtype: PHAssetCollectionSubtype
    let folderPath: [String]          // Parent folder hierarchy
}
```

#### `AssetInfo`
```swift
struct AssetInfo: Identifiable, Sendable {
    let id: String                    // PHAsset.localIdentifier
    let creationDate: Date?           // Photo taken date
    let mediaType: PHAssetMediaType   // .image, .video, etc.
    let filename: String?             // Original filename
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let estimatedSize: Int64?         // File size in bytes
}
```

#### `PhotosCatalogService`
Main service for enumerating the library.

```swift
@MainActor
final class PhotosCatalogService: ObservableObject {
    // Request Photos library access
    func requestAuthorization() async -> Bool
    
    // Enumerate all albums with folder hierarchy
    func enumerateAllAlbums() async -> [AlbumInfo]
    
    // Get assets in a specific album
    func fetchAssets(in albumID: String) -> [AssetInfo]
    
    // Fetch ALL assets with progress callback
    func fetchAllAssets(progressHandler: @escaping (Int, Int) -> Void) async -> [AssetInfo]
}
```

#### `AssetExportService`
Exports original files from the library.

```swift
actor AssetExportService {
    // Export original file to temp directory
    func exportOriginal(assetID: String, to destinationDir: URL) async throws -> URL
    
    // Export with progress tracking (for large videos)
    func exportOriginal(
        assetID: String,
        to destinationDir: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL
}
```

### Key Implementation Details

1. **Folder Hierarchy Traversal**: Uses `PHCollectionList.fetchTopLevelUserCollections()` and recursively processes `PHCollectionList` (folders) vs `PHAssetCollection` (albums).

2. **File Access**: Uses `PHAssetResourceManager.writeData(for:toFile:)` to stream original files to disk without loading into memory.

3. **iCloud Assets**: Set `options.isNetworkAccessAllowed = true` to download iCloud-stored originals.

---

## BucketStorageSchema.swift

### Purpose
Defines the year/week bucket storage strategy and data models for the bucket-based approach.

### Key Types

#### `DateBucket`
Represents a year/week folder.

```swift
struct DateBucket: Hashable, Comparable {
    let year: Int
    let week: Int
    
    var weekFolder: String     // "W07" (with leading zero)
    var path: String           // "2023/W07"
    var mediaPath: String      // "media/2023/W07"
    
    static func from(date: Date?) -> DateBucket?
    static let undated = "media/undated"
}
```

#### `BucketPlanner`
Analyzes assets and plans distribution.

```swift
struct BucketPlanner {
    struct BucketPlan {
        let bucketsToCreate: [DateBucket]
        let distribution: [String: [String]]  // bucket → assetIDs
        let undatedAssets: [String]
        let stats: BucketStats
    }
    
    static func plan(assets: [AssetInfo]) -> BucketPlan
}
```

#### `AlbumManifest`
JSON schema for album files.

```swift
struct AlbumManifest: Codable {
    let albumID: String
    let title: String
    let folderPath: [String]
    let albumType: String
    let lastUpdated: Date
    let assetCount: Int
    let assets: [AssetReference]
    
    struct AssetReference: Codable {
        let localID: String
        let filename: String
        let drivePath: String      // "media/2023/W48/IMG_0001.jpg"
        let driveFileID: String
        let creationDate: Date?
        let mediaType: String
        let width: Int
        let height: Int
        let duration: Double?
        let isFavorite: Bool
        let sortOrder: Int
    }
}
```

#### `MasterCatalog`
JSON schema for the master index.

```swift
struct MasterCatalog: Codable {
    let version: Int
    let lastUpdated: Date
    let totalAssets: Int
    let totalBytes: Int64
    let assets: [String: CatalogEntry]  // localIdentifier → entry
    
    struct CatalogEntry: Codable {
        let filename: String
        let drivePath: String
        let driveFileID: String
        let fileSize: Int64
        let md5Checksum: String
        let creationDate: Date?
        let uploadedAt: Date
    }
}
```

#### `FilenameResolver`
Handles filename collisions within buckets.

```swift
struct FilenameResolver {
    // Returns unique filename, appending _2, _3, etc. if needed
    mutating func resolve(filename: String, inBucket bucket: String) -> String
    
    // Pre-populate with existing files
    mutating func registerExisting(filenames: [String], inBucket bucket: String)
}
```

---

## SyncDatabase.swift

### Purpose
SQLite persistence layer using GRDB. Tracks upload state, enables resume capability, and provides deduplication lookup.

### Key Types

#### `AssetRecord` / `AssetRecordV2`
Database record for an asset.

```swift
struct AssetRecordV2: Codable, FetchableRecord, PersistableRecord {
    var localIdentifier: String    // Primary key
    var filename: String?
    var mediaType: Int
    var fileSize: Int64?
    var creationDate: Date?
    var md5Checksum: String?
    var bucketPath: String?        // "media/2023/W48"
    var uploadStatus: UploadStatus
    var driveFileID: String?
    var drivePath: String?         // Full path including filename
    var uploadedAt: Date?
    var lastError: String?
    var retryCount: Int
    var resumableUploadURI: String?
    var uploadedBytes: Int64
    
    enum UploadStatus: Int {
        case pending = 0
        case inProgress = 1
        case completed = 2
        case failed = 3
        case skipped = 4
    }
}
```

#### `SyncDatabaseV2`
Main database access layer.

```swift
actor SyncDatabaseV2 {
    init(path: String) throws
    
    // Asset operations
    func upsertAssets(_ assets: [AssetRecordV2]) throws
    func fetchPendingAssets(limit: Int) throws -> [AssetRecordV2]
    func fetchFailedAssets(maxRetries: Int) throws -> [AssetRecordV2]
    func findByChecksum(_ checksum: String) throws -> AssetRecordV2?
    func markAssetUploading(id: String) throws
    func markAssetCompleted(id: String, driveFileID: String, drivePath: String, checksum: String) throws
    func markAssetFailed(id: String, error: String) throws
    
    // Album operations
    func upsertAlbums(_ albums: [AlbumRecordV2]) throws
    func fetchAssetsInAlbum(albumID: String) throws -> [AssetRecordV2]
    func setAlbumManifest(albumID: String, manifestDriveID: String, manifestPath: String) throws
    
    // Album-asset mapping
    func addAssetToAlbum(assetID: String, albumID: String, sortOrder: Int) throws
}
```

### Database Schema

```sql
CREATE TABLE assets (
    localIdentifier TEXT PRIMARY KEY,
    filename TEXT,
    mediaType INTEGER NOT NULL,
    fileSize INTEGER,
    creationDate DATETIME,
    md5Checksum TEXT,
    bucketPath TEXT,
    uploadStatus INTEGER NOT NULL DEFAULT 0,
    driveFileID TEXT,
    drivePath TEXT,
    uploadedAt DATETIME,
    lastError TEXT,
    retryCount INTEGER NOT NULL DEFAULT 0,
    resumableUploadURI TEXT,
    uploadedBytes INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_assets_status ON assets(uploadStatus);
CREATE INDEX idx_assets_checksum ON assets(md5Checksum);
CREATE INDEX idx_assets_bucket ON assets(bucketPath);
```

---

## GoogleDriveClient.swift

### Purpose
Wrapper for Google Drive REST API with OAuth 2.0 authentication and resumable upload support.

### Key Types

#### `GoogleDriveClient`
Main API client.

```swift
actor GoogleDriveClient {
    init(clientID: String, clientSecret: String)
    
    // OAuth
    func makeAuthorizationRequest() throws -> AuthorizationRequest  // URL + state
    func exchangeCodeForTokens(code: String, state: String) async throws
    func cancelPendingAuthorization()
    func saveTokens(to keychain: KeychainWrapper) throws
    func loadTokens(from keychain: KeychainWrapper) throws
    
    // Folder operations
    func createFolder(name: String, parentID: String?) async throws -> String
    func findFolder(name: String, parentID: String?) async throws -> String?
    func createFolderPath(_ path: [String], rootParentID: String?) async throws -> String
    
    // Resumable upload
    func initiateResumableUpload(
        filename: String,
        mimeType: String,
        fileSize: Int64,
        parentFolderID: String
    ) async throws -> String  // Returns upload URI
    
    func uploadChunk(
        uploadURI: String,
        data: Data,
        offset: Int64,
        totalSize: Int64
    ) async throws -> UploadChunkResult
    
    func queryUploadStatus(uploadURI: String, totalSize: Int64) async throws -> Int64
    
    // High-level upload
    func uploadFile(
        fileURL: URL,
        filename: String,
        mimeType: String,
        parentFolderID: String,
        existingUploadURI: String?,
        progressHandler: @escaping (Int64, Int64) -> Void
    ) async throws -> String  // Returns file ID
}
```

### OAuth Flow

1. Generate a fresh `state` and PKCE code verifier (32 random bytes each, base64url) for the attempt
2. Generate authorization URL with `drive.file` scope, `state`, and `code_challenge` (S256)
3. User authenticates in browser; the loopback server accepts only `GET /` with the matching `state`
4. Exchange authorization code for tokens, sending the `code_verifier`; the attempt is single use and the `state` is re-checked in constant time
5. Store refresh token in Keychain
6. Auto-refresh access token when expired

The `state`/PKCE helpers and callback parsing live in `OAuthSecurity.swift` and are covered by `Tests/OAuthSecurityTests.swift`.

### Resumable Upload Protocol

1. **Initiate**: POST to `/upload/drive/v3/files?uploadType=resumable`
2. **Upload chunks**: PUT to upload URI with `Content-Range` header
3. **Resume**: Query upload URI to get bytes uploaded, continue from there
4. **Complete**: Final chunk returns file metadata with ID

### Rate Limiting

Built-in throttling with 100ms minimum between requests. Exponential backoff on 5xx errors.

---

## PhotoVaultBucketSyncService.swift

### Purpose
Main orchestrator that coordinates all sync phases using the bucket storage strategy.

### Key Types

#### `SyncConfiguration`
```swift
struct SyncConfiguration: Codable {
    var rootFolderName: String = "Apple Photos Backup"
    var includeSmartAlbums: Bool = true
    var maxConcurrentUploads: Int = 3
    var uploadChunkSize: Int = 10 * 1024 * 1024  // 10 MB
    var maxRetries: Int = 5
    var skipICloudOnlyAssets: Bool = false
    var databasePath: String
}
```

#### `SyncProgress`
Observable progress tracking.

```swift
@MainActor @Observable
final class SyncProgress {
    var phase: SyncPhase
    var totalAlbums: Int
    var processedAlbums: Int
    var totalAssets: Int
    var uploadedAssets: Int
    var failedAssets: Int
    var totalBytes: Int64
    var uploadedBytes: Int64
    var currentAssetFilename: String?
    var currentAssetProgress: Double
    var estimatedTimeRemaining: TimeInterval?
    var errors: [SyncError]
}
```

#### `PhotoVaultBucketSyncService`
Main service.

```swift
actor PhotoVaultBucketSyncService {
    init(config: SyncConfiguration, driveClient: GoogleDriveClient, progress: SyncProgress) throws
    
    func startFullSync() async throws
    func pause()
    func cancel()
}
```

### Sync Phases

1. **Cataloging**: Enumerate Photos library, store in database
2. **Planning**: Calculate bucket distribution
3. **Creating Folders**: Create year/week folders in Drive
4. **Uploading**: Upload assets to buckets with deduplication
5. **Generating Manifests**: Create album JSON files
6. **Generate Master Catalog**: Create `_catalog.json`

### Concurrency

Uses Swift's `TaskGroup` for parallel uploads:

```swift
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
```

---

## AlbumReconstructor.swift

### Purpose
Utilities for reading manifests and reconstructing albums from the backup.

### Key Types

#### `AlbumReconstructor`
```swift
actor AlbumReconstructor {
    init(driveClient: GoogleDriveClient, rootFolderID: String)
    
    // Load manifests
    func loadMasterCatalog() async throws -> MasterCatalog
    func listAlbumManifests() async throws -> [AlbumManifestInfo]
    func loadManifest(fileID: String) async throws -> AlbumManifest
    
    // Reconstruction strategies
    func getAlbumDownloadURLs(manifest: AlbumManifest) async throws -> [PhotoDownloadInfo]
    func createShortcutAlbum(manifest: AlbumManifest, destinationFolderID: String) async throws -> String
    func exportAlbumToLocal(manifest: AlbumManifest, destinationPath: URL, progressHandler: (Int, Int) -> Void) async throws
    func generateHTMLGallery(manifest: AlbumManifest) -> String
}
```

### Reconstruction Strategies

1. **Download URLs**: Generate direct download links for all photos
2. **Shortcut Album**: Create Drive folder with shortcuts pointing to originals
3. **Local Export**: Download all files to a local folder
4. **HTML Gallery**: Generate browsable HTML with Drive thumbnails

---

## PhotoVaultApp.swift

### Purpose
SwiftUI application shell demonstrating how components integrate.

### Key Views

- `PhotoVaultApp`: Main app entry point
- `ContentView`: Navigation split view
- `Sidebar`: Progress statistics
- `SyncDashboard`: Progress ring, controls
- `AuthenticationView`: OAuth sign-in

### Usage Flow

```swift
@main
struct PhotoVaultApp: App {
    @State private var syncProgress = SyncProgress()
    
    var body: some Scene {
        WindowGroup {
            ContentView(progress: syncProgress)
        }
    }
}
```

---

## Dependencies

### GRDB.swift

SQLite wrapper providing:
- Record protocol for struct-to-table mapping
- Type-safe queries
- Migrations
- Thread-safe access

**Installation**: Swift Package Manager
```
https://github.com/groue/GRDB.swift
```

### System Frameworks

- `Photos.framework`: PhotoKit access
- `AuthenticationServices`: OAuth flow (ASWebAuthenticationSession)
- `CryptoKit`: MD5 checksums (Insecure.MD5)
- `Foundation`: Networking, file I/O

---

## File Organization

```
PhotoVault/
├── App/
│   └── PhotoVaultApp.swift
├── Models/
│   └── BucketStorageSchema.swift
├── Services/
│   ├── PhotoKitEnumeration.swift
│   ├── PhotoVaultBucketSyncService.swift
│   └── AlbumReconstructor.swift
├── Infrastructure/
│   ├── SyncDatabase.swift
│   └── GoogleDriveClient.swift
├── Views/
│   ├── ContentView.swift
│   ├── SyncDashboard.swift
│   ├── Sidebar.swift
│   └── AuthenticationView.swift
└── Utilities/
    └── Extensions.swift
```
