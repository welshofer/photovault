import Foundation
import GRDB

// MARK: - Google Drive Folder Structure
/*
 
 Apple Photos Backup/
 ├── media/
 │   ├── 2020/
 │   │   ├── W01/
 │   │   │   ├── IMG_0001.jpg
 │   │   │   ├── IMG_0002.heic
 │   │   │   └── VID_0003.mov
 │   │   ├── W02/
 │   │   │   └── ...
 │   │   └── W52/
 │   ├── 2021/
 │   │   └── ...
 │   └── undated/          <- For photos without creation date
 │       └── ...
 │
 ├── albums/
 │   ├── Favorites.json
 │   ├── Vacation Hawaii 2023.json
 │   ├── Family/                      <- Nested folders mirror Photos hierarchy
 │   │   ├── Kids.json
 │   │   └── Holidays.json
 │   └── ...
 │
 └── _catalog.json          <- Master index: all assets with their bucket paths
 
*/

// MARK: - Album Manifest Schema

/// JSON structure for an album manifest file
struct AlbumManifest: Codable {
    /// Original PhotoKit local identifier
    let albumID: String
    
    /// Album title from Photos
    let title: String
    
    /// Original folder hierarchy in Photos (e.g., ["Vacations", "2023"])
    let folderPath: [String]
    
    /// Album type (user, smart, etc.)
    let albumType: String
    
    /// When this manifest was last updated
    let lastUpdated: Date
    
    /// Total number of assets in this album
    let assetCount: Int
    
    /// References to all assets in this album
    let assets: [AssetReference]
    
    struct AssetReference: Codable {
        /// PhotoKit local identifier
        let localID: String
        
        /// Original filename
        let filename: String
        
        /// Path within Google Drive (e.g., "media/2023/W48/IMG_0001.jpg")
        let drivePath: String
        
        /// Google Drive file ID for direct API access
        let driveFileID: String
        
        /// Photo/video creation date
        let creationDate: Date?
        
        /// "image", "video", "livePhoto", etc.
        let mediaType: String
        
        /// Dimensions
        let width: Int
        let height: Int
        
        /// Duration in seconds (for video)
        let duration: Double?
        
        /// Is this a favorite in Photos?
        let isFavorite: Bool
        
        /// Position in the album (for ordering)
        let sortOrder: Int
    }
}

// MARK: - Master Catalog Schema

/// Master index of all uploaded assets
struct MasterCatalog: Codable {
    let version: Int = 1
    let lastUpdated: Date
    let totalAssets: Int
    let totalBytes: Int64
    
    /// Quick lookup: PhotoKit ID → bucket path + Drive ID
    let assets: [String: CatalogEntry]
    
    struct CatalogEntry: Codable {
        let filename: String
        let drivePath: String      // e.g., "media/2023/W48/IMG_0001.jpg"
        let driveFileID: String
        let fileSize: Int64
        let md5Checksum: String
        let creationDate: Date?
        let uploadedAt: Date
    }
}

// MARK: - Year/Week Bucket Calculator

struct DateBucket: Hashable, Comparable {
    let year: Int
    let week: Int
    
    /// Folder name (e.g., "W07" with leading zero)
    var weekFolder: String {
        String(format: "W%02d", week)
    }
    
    /// Full path component (e.g., "2023/W07")
    var path: String {
        "\(year)/\(weekFolder)"
    }
    
    /// Full media path (e.g., "media/2023/W07")
    var mediaPath: String {
        "media/\(path)"
    }
    
    static func < (lhs: DateBucket, rhs: DateBucket) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        return lhs.week < rhs.week
    }
    
    /// Create bucket from a date
    static func from(date: Date?) -> DateBucket? {
        guard let date else { return nil }
        
        let calendar = Calendar(identifier: .iso8601)
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        
        guard let year = components.yearForWeekOfYear,
              let week = components.weekOfYear else {
            return nil
        }
        
        return DateBucket(year: year, week: week)
    }
    
    /// Special bucket for undated assets
    static let undated = "media/undated"
}

// MARK: - Bucket Planning

/// Analyzes assets and plans the bucket distribution
struct BucketPlanner {
    
    struct BucketPlan {
        /// Buckets that need to be created
        let bucketsToCreate: [DateBucket]
        
        /// Distribution: bucket → asset IDs
        let distribution: [String: [String]]  // bucket path → [assetID]
        
        /// Assets without dates go here
        let undatedAssets: [String]
        
        /// Statistics
        let stats: BucketStats
    }
    
    struct BucketStats {
        let totalBuckets: Int
        let minAssetsPerBucket: Int
        let maxAssetsPerBucket: Int
        let avgAssetsPerBucket: Double
        let yearsSpanned: ClosedRange<Int>
    }
    
    /// Plan bucket distribution for a set of assets
    static func plan(assets: [AssetInfo]) -> BucketPlan {
        var bucketMap: [DateBucket: [String]] = [:]
        var undated: [String] = []
        
        for asset in assets {
            if let bucket = DateBucket.from(date: asset.creationDate) {
                bucketMap[bucket, default: []].append(asset.id)
            } else {
                undated.append(asset.id)
            }
        }
        
        // Convert to path-keyed dictionary
        var distribution: [String: [String]] = [:]
        for (bucket, assetIDs) in bucketMap {
            distribution[bucket.mediaPath] = assetIDs
        }
        if !undated.isEmpty {
            distribution[DateBucket.undated] = undated
        }
        
        // Calculate stats
        let sortedBuckets = bucketMap.keys.sorted()
        let counts = bucketMap.values.map { $0.count }
        
        let stats = BucketStats(
            totalBuckets: bucketMap.count + (undated.isEmpty ? 0 : 1),
            minAssetsPerBucket: counts.min() ?? 0,
            maxAssetsPerBucket: counts.max() ?? 0,
            avgAssetsPerBucket: counts.isEmpty ? 0 : Double(counts.reduce(0, +)) / Double(counts.count),
            yearsSpanned: (sortedBuckets.first?.year ?? 0)...(sortedBuckets.last?.year ?? 0)
        )
        
        return BucketPlan(
            bucketsToCreate: sortedBuckets,
            distribution: distribution,
            undatedAssets: undated,
            stats: stats
        )
    }
}

// MARK: - Updated Database Records

/// Simplified asset record for bucket-based storage
struct AssetRecordV2: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "assets"
    
    var localIdentifier: String
    var filename: String?
    var mediaType: Int
    var fileSize: Int64?
    var creationDate: Date?
    var md5Checksum: String?
    
    // Bucket info
    var bucketPath: String?          // e.g., "media/2023/W48" or "media/undated"
    
    // Upload tracking
    var uploadStatus: UploadStatus
    var driveFileID: String?
    var drivePath: String?           // Full path including filename
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
        case skipped = 4
    }
}

/// Album record - now just tracks the JSON manifest location
struct AlbumRecordV2: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "albums"
    
    var localIdentifier: String
    var title: String
    var folderPath: String           // JSON-encoded [String]
    var albumType: Int
    var subtype: Int
    var assetCount: Int
    
    // Manifest tracking
    var manifestDriveID: String?     // Drive file ID of the JSON manifest
    var manifestPath: String?        // e.g., "albums/Vacations/Hawaii 2023.json"
    var manifestLastUpdated: Date?
    
    var createdAt: Date
}

// MARK: - Filename Collision Handling

/// Handles duplicate filenames within the same bucket
struct FilenameResolver {
    
    /// Track used filenames per bucket
    private var usedNames: [String: Set<String>] = [:]  // bucket → filenames
    
    /// Get a unique filename for the bucket, appending suffix if needed
    mutating func resolve(filename: String, inBucket bucket: String) -> String {
        var used = usedNames[bucket, default: []]
        
        if !used.contains(filename) {
            used.insert(filename)
            usedNames[bucket] = used
            return filename
        }
        
        // Need to deduplicate: IMG_0001.jpg → IMG_0001_2.jpg
        let nameWithoutExt = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        
        var counter = 2
        var candidate: String
        repeat {
            candidate = ext.isEmpty 
                ? "\(nameWithoutExt)_\(counter)"
                : "\(nameWithoutExt)_\(counter).\(ext)"
            counter += 1
        } while used.contains(candidate)
        
        used.insert(candidate)
        usedNames[bucket] = used
        return candidate
    }
    
    /// Pre-populate with existing files in a bucket (from Drive listing)
    mutating func registerExisting(filenames: [String], inBucket bucket: String) {
        usedNames[bucket, default: []].formUnion(filenames)
    }
}

// MARK: - Usage Example

/*
 
 // 1. Catalog and plan buckets
 let assets = catalogService.fetchAllAssets()
 let plan = BucketPlanner.plan(assets: assets)
 
 print("Distribution across \(plan.stats.totalBuckets) buckets")
 print("Years: \(plan.stats.yearsSpanned)")
 print("Avg per bucket: \(plan.stats.avgAssetsPerBucket)")
 
 // 2. Create bucket folders in Drive
 for bucket in plan.bucketsToCreate {
     let folderID = try await driveClient.createFolderPath(
         ["media", String(bucket.year), bucket.weekFolder],
         rootParentID: rootFolderID
     )
     // Cache folderID for uploads
 }
 
 // 3. Upload assets to their buckets
 for (bucketPath, assetIDs) in plan.distribution {
     for assetID in assetIDs {
         // Export and upload to bucketPath
         // Store drivePath = "\(bucketPath)/\(filename)"
     }
 }
 
 // 4. Generate album manifests
 for album in albums {
     let assetRefs = fetchAssetsInAlbum(album.id).map { asset in
         AlbumManifest.AssetReference(
             localID: asset.localIdentifier,
             filename: asset.filename,
             drivePath: asset.drivePath!,  // From completed upload
             driveFileID: asset.driveFileID!,
             ...
         )
     }
     
     let manifest = AlbumManifest(
         albumID: album.id,
         title: album.title,
         folderPath: album.folderPath,
         assets: assetRefs,
         ...
     )
     
     // Upload as JSON to albums/[folderPath]/[title].json
     let jsonData = try JSONEncoder().encode(manifest)
     try await driveClient.uploadData(jsonData, to: manifestPath)
 }
 
 // 5. Generate master catalog
 let catalog = MasterCatalog(
     lastUpdated: Date(),
     totalAssets: completedAssets.count,
     totalBytes: totalUploadedBytes,
     assets: completedAssets.reduce(into: [:]) { dict, asset in
         dict[asset.localIdentifier] = CatalogEntry(...)
     }
 )
 try await driveClient.uploadData(encodedCatalog, to: "_catalog.json")
 
 */
