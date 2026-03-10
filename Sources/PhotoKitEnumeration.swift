import Photos
import Foundation

// MARK: - Data Models

/// Represents an album with its assets
struct AlbumInfo: Identifiable, Sendable {
    let id: String  // localIdentifier
    let title: String
    let assetCount: Int
    let albumType: PHAssetCollectionType
    let subtype: PHAssetCollectionSubtype
    
    /// Path components for folder hierarchy (e.g., ["Vacations", "2024", "Japan"])
    let folderPath: [String]
}

/// Lightweight asset reference (not the actual image data)
struct AssetInfo: Identifiable, Sendable {
    let id: String  // localIdentifier
    let creationDate: Date?
    let mediaType: PHAssetMediaType
    let filename: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    
    /// Estimated file size in bytes (from resource)
    let estimatedSize: Int64?
}

// MARK: - PhotoKit Catalog Service

/// Enumerates the Photos library structure without loading image data
final class PhotosCatalogService: ObservableObject, @unchecked Sendable {

    @MainActor @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @MainActor @Published private(set) var albums: [AlbumInfo] = []
    @MainActor @Published private(set) var totalAssetCount: Int = 0
    @MainActor @Published private(set) var isEnumerating: Bool = false
    
    // MARK: - Authorization
    
    func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run { authorizationStatus = status }
        return status == .authorized || status == .limited
    }
    
    // MARK: - Album Enumeration
    
    /// Enumerates all user albums and smart albums with folder hierarchy
    func enumerateAllAlbums() async -> [AlbumInfo] {
        await MainActor.run { isEnumerating = true }

        var results: [AlbumInfo] = []

        // 1. Top-level user albums (not in folders)
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        results.append(contentsOf: extractAlbums(from: userAlbums, folderPath: []))

        // 2. Smart albums (Favorites, Recents, Screenshots, etc.)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        results.append(contentsOf: extractAlbums(from: smartAlbums, folderPath: ["Smart Albums"]))

        // 3. Folder hierarchy — this is where it gets interesting
        let topLevelFolders = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        results.append(contentsOf: enumerateFolderHierarchy(topLevelFolders, path: []))

        await MainActor.run {
            albums = results
            totalAssetCount = results.reduce(0) { $0 + $1.assetCount }
            isEnumerating = false
        }

        return results
    }
    
    /// Recursively enumerate folder hierarchy
    private func enumerateFolderHierarchy(
        _ collections: PHFetchResult<PHCollection>,
        path: [String]
    ) -> [AlbumInfo] {
        var results: [AlbumInfo] = []
        
        collections.enumerateObjects { collection, _, _ in
            if let folder = collection as? PHCollectionList {
                // It's a folder — recurse into it
                let folderName = folder.localizedTitle ?? "Untitled Folder"
                let newPath = path + [folderName]
                
                let children = PHCollection.fetchCollections(
                    in: folder,
                    options: nil
                )
                results.append(contentsOf: self.enumerateFolderHierarchy(children, path: newPath))
                
            } else if let album = collection as? PHAssetCollection {
                // It's an album inside this folder
                let albumName = album.localizedTitle ?? "Untitled Album"
                let assetCount = PHAsset.fetchAssets(in: album, options: nil).count
                
                let info = AlbumInfo(
                    id: album.localIdentifier,
                    title: albumName,
                    assetCount: assetCount,
                    albumType: album.assetCollectionType,
                    subtype: album.assetCollectionSubtype,
                    folderPath: path
                )
                results.append(info)
            }
        }
        
        return results
    }
    
    /// Extract albums from a fetch result
    private func extractAlbums(
        from fetchResult: PHFetchResult<PHAssetCollection>,
        folderPath: [String]
    ) -> [AlbumInfo] {
        var results: [AlbumInfo] = []
        
        fetchResult.enumerateObjects { album, _, _ in
            let assetCount = PHAsset.fetchAssets(in: album, options: nil).count
            
            // Skip empty albums unless they're user-created
            guard assetCount > 0 || album.assetCollectionType == .album else { return }
            
            let info = AlbumInfo(
                id: album.localIdentifier,
                title: album.localizedTitle ?? "Untitled",
                assetCount: assetCount,
                albumType: album.assetCollectionType,
                subtype: album.assetCollectionSubtype,
                folderPath: folderPath
            )
            results.append(info)
        }
        
        return results
    }
    
    // MARK: - Asset Enumeration
    
    /// Fetch all assets in an album (metadata only, not image data)
    func fetchAssets(in albumID: String) -> [AssetInfo] {
        guard let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID],
            options: nil
        ).firstObject else {
            return []
        }
        
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        
        let assets = PHAsset.fetchAssets(in: album, options: options)
        var results: [AssetInfo] = []
        
        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let primaryResource = resources.first { $0.type == .photo || $0.type == .video }
                ?? resources.first
            
            let info = AssetInfo(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                mediaType: asset.mediaType,
                filename: primaryResource?.originalFilename,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                isFavorite: asset.isFavorite,
                estimatedSize: primaryResource?.value(forKey: "fileSize") as? Int64
            )
            results.append(info)
        }
        
        return results
    }
    
    /// Fetch ALL unique assets across the entire library
    func fetchAllAssets(progressHandler: @escaping (Int, Int) -> Void) async -> [AssetInfo] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        
        let allAssets = PHAsset.fetchAssets(with: options)
        let total = allAssets.count
        var results: [AssetInfo] = []
        results.reserveCapacity(total)
        
        // Process in batches to avoid blocking
        let batchSize = 1000
        var processed = 0
        
        allAssets.enumerateObjects { asset, index, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let primaryResource = resources.first { $0.type == .photo || $0.type == .video }
                ?? resources.first
            
            let info = AssetInfo(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                mediaType: asset.mediaType,
                filename: primaryResource?.originalFilename,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                isFavorite: asset.isFavorite,
                estimatedSize: primaryResource?.value(forKey: "fileSize") as? Int64
            )
            results.append(info)
            
            processed += 1
            if processed % batchSize == 0 {
                progressHandler(processed, total)
            }
        }
        
        progressHandler(total, total)
        return results
    }
}

// MARK: - Asset Export Service

/// Handles exporting original files from Photos library
actor AssetExportService {
    
    private let resourceManager = PHAssetResourceManager.default()
    
    /// Export original file to a temporary location
    /// Returns the file URL on success
    func exportOriginal(assetID: String, to destinationDir: URL) async throws -> URL {
        // Fetch the asset
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        ).firstObject else {
            throw ExportError.assetNotFound(assetID)
        }
        
        // Get the primary resource (original file)
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { 
            $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto
        }) ?? resources.first else {
            throw ExportError.noResourceAvailable(assetID)
        }
        
        let filename = resource.originalFilename
        let destinationURL = destinationDir.appendingPathComponent(filename)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: destinationURL)
        
        // Export using continuation for async/await
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false  // Never pull from iCloud — only export locally available originals  // Download from iCloud if needed
            
            resourceManager.writeData(for: resource, toFile: destinationURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: ExportError.exportFailed(assetID, error))
                } else {
                    continuation.resume(returning: destinationURL)
                }
            }
        }
    }
    
    /// Export with progress tracking (useful for large videos)
    func exportOriginal(
        assetID: String,
        to destinationDir: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: nil
        ).firstObject else {
            throw ExportError.assetNotFound(assetID)
        }
        
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { 
            $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto
        }) ?? resources.first else {
            throw ExportError.noResourceAvailable(assetID)
        }
        
        let filename = resource.originalFilename
        let destinationURL = destinationDir.appendingPathComponent(filename)
        
        try? FileManager.default.removeItem(at: destinationURL)
        
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false  // Never pull from iCloud — only export locally available originals
            options.progressHandler = { progress in
                Task { @MainActor in
                    progressHandler(progress)
                }
            }
            
            resourceManager.writeData(for: resource, toFile: destinationURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: ExportError.exportFailed(assetID, error))
                } else {
                    continuation.resume(returning: destinationURL)
                }
            }
        }
    }
    
    enum ExportError: LocalizedError {
        case assetNotFound(String)
        case noResourceAvailable(String)
        case exportFailed(String, Error)
        
        var errorDescription: String? {
            switch self {
            case .assetNotFound(let id):
                return "Asset not found: \(id)"
            case .noResourceAvailable(let id):
                return "No exportable resource for asset: \(id)"
            case .exportFailed(let id, let error):
                return "Export failed for \(id): \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Usage Example

/*
 
 // In your SwiftUI view or app initialization:
 
 let catalogService = PhotosCatalogService()
 
 Task {
     // 1. Request authorization
     guard await catalogService.requestAuthorization() else {
         print("Photos access denied")
         return
     }
     
     // 2. Enumerate all albums
     let albums = await catalogService.enumerateAllAlbums()
     
     for album in albums {
         let pathString = album.folderPath.isEmpty 
             ? album.title 
             : album.folderPath.joined(separator: "/") + "/" + album.title
         print("\(pathString) — \(album.assetCount) assets")
     }
     
     // 3. For each album, you can fetch its assets
     if let firstAlbum = albums.first {
         let assets = catalogService.fetchAssets(in: firstAlbum.id)
         print("First album has \(assets.count) assets")
         
         // 4. Export an original file
         let exportService = AssetExportService()
         if let firstAsset = assets.first {
             let tempDir = FileManager.default.temporaryDirectory
             let exportedURL = try await exportService.exportOriginal(
                 assetID: firstAsset.id,
                 to: tempDir
             )
             print("Exported to: \(exportedURL.path)")
             
             // Now upload exportedURL to Google Drive...
             // Then delete the temp file
         }
     }
 }
 
 */
