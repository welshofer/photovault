import Foundation

// MARK: - Album Reconstruction

/// Utility to reconstruct albums from JSON manifests stored in Google Drive
actor AlbumReconstructor {
    
    private let driveClient: GoogleDriveClient
    private let rootFolderID: String
    
    init(driveClient: GoogleDriveClient, rootFolderID: String) {
        self.driveClient = driveClient
        self.rootFolderID = rootFolderID
    }
    
    // MARK: - Load Manifests
    
    /// Load the master catalog
    func loadMasterCatalog() async throws -> MasterCatalog {
        let catalogFileID = try await driveClient.findFile(
            name: "_catalog.json",
            parentID: rootFolderID
        )
        guard let fileID = catalogFileID else {
            throw ReconstructionError.catalogNotFound
        }
        
        let data = try await driveClient.downloadFile(fileID: fileID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MasterCatalog.self, from: data)
    }
    
    /// List all album manifests
    func listAlbumManifests() async throws -> [AlbumManifestInfo] {
        let albumsFolderID = try await driveClient.findFolder(name: "albums", parentID: rootFolderID)
        guard let folderID = albumsFolderID else {
            throw ReconstructionError.albumsFolderNotFound
        }
        
        return try await listManifestsRecursively(in: folderID, path: [])
    }
    
    private func listManifestsRecursively(
        in folderID: String,
        path: [String]
    ) async throws -> [AlbumManifestInfo] {
        var results: [AlbumManifestInfo] = []
        
        let items = try await driveClient.listFolder(folderID: folderID)
        
        for item in items {
            if item.mimeType == "application/vnd.google-apps.folder" {
                // Recurse into subfolder
                let subResults = try await listManifestsRecursively(
                    in: item.id,
                    path: path + [item.name]
                )
                results.append(contentsOf: subResults)
            } else if item.name.hasSuffix(".json") {
                // Found a manifest
                let albumName = String(item.name.dropLast(5))  // Remove .json
                results.append(AlbumManifestInfo(
                    fileID: item.id,
                    albumName: albumName,
                    folderPath: path,
                    fullPath: (path + [item.name]).joined(separator: "/")
                ))
            }
        }
        
        return results
    }
    
    /// Load a specific album manifest
    func loadManifest(fileID: String) async throws -> AlbumManifest {
        let data = try await driveClient.downloadFile(fileID: fileID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AlbumManifest.self, from: data)
    }
    
    // MARK: - Reconstruction Strategies
    
    /// Strategy 1: Generate download URLs for all photos in an album
    func getAlbumDownloadURLs(manifest: AlbumManifest) async throws -> [PhotoDownloadInfo] {
        return manifest.assets.map { asset in
            PhotoDownloadInfo(
                filename: asset.filename,
                driveFileID: asset.driveFileID,
                drivePath: asset.drivePath,
                downloadURL: "https://drive.google.com/uc?export=download&id=\(asset.driveFileID)",
                creationDate: asset.creationDate,
                sortOrder: asset.sortOrder
            )
        }
    }
    
    /// Strategy 2: Create a Google Drive shortcut-based album
    /// This creates shortcuts in a folder, pointing to the original files
    func createShortcutAlbum(
        manifest: AlbumManifest,
        destinationFolderID: String
    ) async throws -> String {
        // Create album folder
        let albumFolderID = try await driveClient.createFolder(
            name: manifest.title,
            parentID: destinationFolderID
        )
        
        // Create shortcuts for each asset
        for asset in manifest.assets {
            try await driveClient.createShortcut(
                name: asset.filename,
                targetFileID: asset.driveFileID,
                parentFolderID: albumFolderID
            )
        }
        
        return albumFolderID
    }
    
    /// Strategy 3: Export album to local folder
    func exportAlbumToLocal(
        manifest: AlbumManifest,
        destinationPath: URL,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws {
        // Create destination folder
        try FileManager.default.createDirectory(
            at: destinationPath,
            withIntermediateDirectories: true
        )
        
        let total = manifest.assets.count
        
        for (index, asset) in manifest.assets.enumerated() {
            let data = try await driveClient.downloadFile(fileID: asset.driveFileID)
            let fileURL = destinationPath.appendingPathComponent(asset.filename)
            try data.write(to: fileURL)
            
            // Set creation date if available
            if let creationDate = asset.creationDate {
                try FileManager.default.setAttributes(
                    [.creationDate: creationDate],
                    ofItemAtPath: fileURL.path
                )
            }
            
            progressHandler(index + 1, total)
        }
    }
    
    /// Strategy 4: Generate HTML gallery
    func generateHTMLGallery(manifest: AlbumManifest) -> String {
        let photoCards = manifest.assets.map { asset -> String in
            let dateStr = asset.creationDate.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "Unknown date"
            
            return """
            <div class="photo-card">
                <a href="https://drive.google.com/file/d/\(asset.driveFileID)/view" target="_blank">
                    <img src="https://drive.google.com/thumbnail?id=\(asset.driveFileID)&sz=w400" 
                         alt="\(asset.filename)" loading="lazy">
                </a>
                <div class="photo-info">
                    <span class="filename">\(asset.filename)</span>
                    <span class="date">\(dateStr)</span>
                </div>
            </div>
            """
        }.joined(separator: "\n")
        
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(manifest.title)</title>
            <style>
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body { 
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    background: #1a1a1a; color: #fff; padding: 20px;
                }
                h1 { 
                    text-align: center; margin-bottom: 10px; font-weight: 300;
                }
                .meta {
                    text-align: center; color: #888; margin-bottom: 30px;
                }
                .gallery {
                    display: grid;
                    grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
                    gap: 20px;
                }
                .photo-card {
                    background: #2a2a2a; border-radius: 8px; overflow: hidden;
                }
                .photo-card img {
                    width: 100%; height: 250px; object-fit: cover;
                    transition: transform 0.2s;
                }
                .photo-card:hover img { transform: scale(1.05); }
                .photo-info {
                    padding: 12px; display: flex; flex-direction: column; gap: 4px;
                }
                .filename { font-size: 14px; }
                .date { font-size: 12px; color: #888; }
            </style>
        </head>
        <body>
            <h1>\(manifest.title)</h1>
            <p class="meta">\(manifest.assetCount) photos • Last updated: \(ISO8601DateFormatter().string(from: manifest.lastUpdated))</p>
            <div class="gallery">
                \(photoCards)
            </div>
        </body>
        </html>
        """
    }
}

// MARK: - Supporting Types

struct AlbumManifestInfo {
    let fileID: String
    let albumName: String
    let folderPath: [String]
    let fullPath: String
}

struct PhotoDownloadInfo {
    let filename: String
    let driveFileID: String
    let drivePath: String
    let downloadURL: String
    let creationDate: Date?
    let sortOrder: Int
}

enum ReconstructionError: LocalizedError {
    case catalogNotFound
    case albumsFolderNotFound
    case manifestNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .catalogNotFound: return "Master catalog (_catalog.json) not found"
        case .albumsFolderNotFound: return "Albums folder not found"
        case .manifestNotFound(let name): return "Manifest not found: \(name)"
        }
    }
}

// MARK: - Drive Client Extensions

struct DriveItem: Codable {
    let id: String
    let name: String
    let mimeType: String
}

private struct DriveItemList: Codable {
    let files: [DriveItem]
    let nextPageToken: String?
}

extension GoogleDriveClient {

    /// Find a file by name in a folder
    func findFile(name: String, parentID: String) async throws -> String? {
        let query = "name = '\(name.escapedForQuery())' and '\(parentID)' in parents and trashed = false and mimeType != 'application/vnd.google-apps.folder'"

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)")
        ]

        let token = try await ensureValidTokenPublic()
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        let result = try JSONDecoder().decode(DriveItemList.self, from: data)
        return result.files.first?.id
    }

    /// Download file contents by ID
    func downloadFile(fileID: String) async throws -> Data {
        let token = try await ensureValidTokenPublic()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DriveError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, nil)
        }
        return data
    }

    /// List contents of a folder
    func listFolder(folderID: String) async throws -> [DriveItem] {
        let token = try await ensureValidTokenPublic()
        var allItems: [DriveItem] = []
        var pageToken: String? = nil

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var queryItems = [
                URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType)"),
                URLQueryItem(name: "pageSize", value: "1000")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw DriveError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, nil)
            }

            let result = try JSONDecoder().decode(DriveItemList.self, from: data)
            allItems.append(contentsOf: result.files)
            pageToken = result.nextPageToken
        } while pageToken != nil

        return allItems
    }

    /// Create a shortcut to a file
    func createShortcut(name: String, targetFileID: String, parentFolderID: String) async throws {
        let token = try await ensureValidTokenPublic()

        let url = URL(string: "https://www.googleapis.com/drive/v3/files")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.shortcut",
            "parents": [parentFolderID],
            "shortcutDetails": ["targetId": targetFileID]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DriveError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, nil)
        }
    }
}

// MARK: - Example Album Manifest JSON

/*

{
  "albumID": "F3D2E1C0-B9A8-4567-8901-234567890ABC",
  "title": "Vacation Hawaii 2023",
  "folderPath": ["Vacations", "2023"],
  "albumType": "album",
  "lastUpdated": "2024-01-15T10:30:00Z",
  "assetCount": 247,
  "assets": [
    {
      "localID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "filename": "IMG_4521.HEIC",
      "drivePath": "media/2023/W48/IMG_4521.HEIC",
      "driveFileID": "1ABC123def456GHI789jkl",
      "creationDate": "2023-12-01T08:30:00Z",
      "mediaType": "image",
      "width": 4032,
      "height": 3024,
      "duration": null,
      "isFavorite": true,
      "sortOrder": 0
    },
    {
      "localID": "B2C3D4E5-F6A7-8901-BCDE-F23456789012",
      "filename": "IMG_4522.HEIC",
      "drivePath": "media/2023/W48/IMG_4522.HEIC",
      "driveFileID": "2DEF456ghi789JKL012mno",
      "creationDate": "2023-12-01T09:15:00Z",
      "mediaType": "image",
      "width": 4032,
      "height": 3024,
      "duration": null,
      "isFavorite": false,
      "sortOrder": 1
    },
    {
      "localID": "C3D4E5F6-A7B8-9012-CDEF-345678901234",
      "filename": "VID_4523.MOV",
      "drivePath": "media/2023/W48/VID_4523.MOV",
      "driveFileID": "3GHI789jkl012MNO345pqr",
      "creationDate": "2023-12-01T10:00:00Z",
      "mediaType": "video",
      "width": 1920,
      "height": 1080,
      "duration": 32.5,
      "isFavorite": false,
      "sortOrder": 2
    }
  ]
}

*/

// MARK: - Example Master Catalog JSON

/*

{
  "version": 1,
  "lastUpdated": "2024-01-15T12:00:00Z",
  "totalAssets": 300000,
  "totalBytes": 11811160064000,
  "assets": {
    "A1B2C3D4-E5F6-7890-ABCD-EF1234567890": {
      "filename": "IMG_4521.HEIC",
      "drivePath": "media/2023/W48/IMG_4521.HEIC",
      "driveFileID": "1ABC123def456GHI789jkl",
      "fileSize": 3542016,
      "md5Checksum": "d41d8cd98f00b204e9800998ecf8427e",
      "creationDate": "2023-12-01T08:30:00Z",
      "uploadedAt": "2024-01-15T10:30:00Z"
    },
    "B2C3D4E5-F6A7-8901-BCDE-F23456789012": {
      "filename": "IMG_4522.HEIC",
      "drivePath": "media/2023/W48/IMG_4522.HEIC",
      "driveFileID": "2DEF456ghi789JKL012mno",
      "fileSize": 3891456,
      "md5Checksum": "098f6bcd4621d373cade4e832627b4f6",
      "creationDate": "2023-12-01T09:15:00Z",
      "uploadedAt": "2024-01-15T10:31:00Z"
    }
  }
}

*/
