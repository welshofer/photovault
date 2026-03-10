# Claude Code Implementation Guide

## Project Overview

PhotoVault is a macOS app that backs up an Apple Photos library to Google Drive. This document provides guidance for Claude Code to implement, extend, or modify the project.

---

## Quick Start

### 1. Create Xcode Project

```bash
# Create new macOS App
# - Product Name: PhotoVault
# - Team: Select your team
# - Bundle Identifier: com.yourname.photovault
# - Interface: SwiftUI
# - Language: Swift
# - Include Tests: Yes
```

### 2. Add Dependencies

Add Swift Package:
- GRDB: `https://github.com/groue/GRDB.swift` (version 6.x)

### 3. Configure Entitlements

```xml
<!-- PhotoVault.entitlements -->
<key>com.apple.security.personal-information.photos-library</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.app-sandbox</key>
<false/>
```

### 4. Configure Info.plist

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>PhotoVault needs access to back up your photos to Google Drive.</string>
```

### 5. Add URL Scheme

In target Info:
- URL Schemes: `com.yourname.photovault`

---

## Implementation Order

### Phase 1: Core Infrastructure

1. **Data Models** (`BucketStorageSchema.swift`)
   - Implement `DateBucket`, `AlbumManifest`, `MasterCatalog`
   - Implement `FilenameResolver` for collision handling

2. **Database** (`SyncDatabase.swift`)
   - Set up GRDB with migrations
   - Implement `AssetRecordV2`, `AlbumRecordV2`
   - Create all CRUD operations

3. **PhotoKit** (`PhotoKitEnumeration.swift`)
   - Implement authorization flow
   - Implement album enumeration with folder hierarchy
   - Implement asset metadata extraction
   - Implement file export

### Phase 2: Google Drive Integration

4. **OAuth** (part of `GoogleDriveClient.swift`)
   - Implement authorization URL generation
   - Implement token exchange
   - Implement token refresh
   - Store tokens in Keychain

5. **Drive Operations** (`GoogleDriveClient.swift`)
   - Implement folder create/find
   - Implement resumable upload init
   - Implement chunk upload
   - Implement upload status query
   - Implement high-level `uploadFile`

### Phase 3: Sync Service

6. **Sync Orchestrator** (`PhotoVaultBucketSyncService.swift`)
   - Implement cataloging phase
   - Implement bucket planning
   - Implement folder creation
   - Implement concurrent upload with TaskGroup
   - Implement manifest generation
   - Implement master catalog generation

### Phase 4: UI

7. **SwiftUI Views** (`PhotoVaultApp.swift`)
   - Main app structure
   - Authentication view
   - Progress dashboard
   - Error display

### Phase 5: Utilities

8. **Album Reconstruction** (`AlbumReconstructor.swift`)
   - Manifest parsing
   - Download utilities
   - HTML gallery generation

---

## Key Implementation Details

### PhotoKit Authorization

```swift
let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
// .authorized or .limited are both usable
```

### Folder Hierarchy Traversal

```swift
// Top level
let topLevel = PHCollectionList.fetchTopLevelUserCollections(with: nil)

// Recursively process
topLevel.enumerateObjects { collection, _, _ in
    if let folder = collection as? PHCollectionList {
        // It's a folder, recurse into it
        let children = PHCollection.fetchCollections(in: folder, options: nil)
        // Process children...
    } else if let album = collection as? PHAssetCollection {
        // It's an album
    }
}
```

### Asset Export

```swift
let resource = PHAssetResource.assetResources(for: asset).first!
let options = PHAssetResourceRequestOptions()
options.isNetworkAccessAllowed = true  // Download from iCloud

PHAssetResourceManager.default().writeData(
    for: resource,
    toFile: destinationURL,
    options: options
) { error in
    // Handle completion
}
```

### Resumable Upload

```swift
// 1. Initiate
POST /upload/drive/v3/files?uploadType=resumable
Headers:
  - Authorization: Bearer {token}
  - X-Upload-Content-Length: {total_size}
  - X-Upload-Content-Type: {mime_type}
Body: {"name": "file.jpg", "parents": ["folder_id"]}
Response: 200 + Location header with upload URI

// 2. Upload chunks
PUT {upload_uri}
Headers:
  - Content-Range: bytes {start}-{end}/{total}
Body: {chunk_data}
Response: 308 (incomplete) or 200/201 (complete)

// 3. Query status (for resume)
PUT {upload_uri}
Headers:
  - Content-Range: bytes */{total}
Response: 308 + Range header showing uploaded bytes
```

### Concurrent Uploads

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    var inFlight = 0
    var iterator = assets.makeIterator()
    
    // Start initial batch
    while inFlight < maxConcurrent, let asset = iterator.next() {
        group.addTask { try await self.uploadAsset(asset) }
        inFlight += 1
    }
    
    // Replace completed with new
    for try await _ in group {
        inFlight -= 1
        if let next = iterator.next() {
            group.addTask { try await self.uploadAsset(next) }
            inFlight += 1
        }
    }
}
```

### MD5 Checksum

```swift
import CryptoKit

func computeMD5(fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    
    var hasher = Insecure.MD5()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
```

---

## Common Issues and Solutions

### Issue: "Photos access denied"

**Solution**: Check entitlements and Info.plist, prompt user to enable in System Preferences.

### Issue: "Rate limit exceeded"

**Solution**: Implement exponential backoff, reduce concurrent uploads.

```swift
func withRetry<T>(maxAttempts: Int, operation: () async throws -> T) async throws -> T {
    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch {
            if attempt == maxAttempts { throw error }
            let delay = pow(2.0, Double(attempt - 1))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
    fatalError()
}
```

### Issue: "Upload session expired"

**Solution**: Catch the error, restart upload from beginning for that file.

### Issue: "Filename collision"

**Solution**: Use `FilenameResolver` to append `_2`, `_3`, etc.

### Issue: "iCloud asset not available"

**Solution**: Set `isNetworkAccessAllowed = true`, or skip with warning.

---

## Testing Recommendations

### Unit Tests

```swift
// DateBucket tests
func testDateBucketFromDate() {
    let date = ISO8601DateFormatter().date(from: "2023-12-15T10:00:00Z")!
    let bucket = DateBucket.from(date: date)
    XCTAssertEqual(bucket?.year, 2023)
    XCTAssertEqual(bucket?.week, 50)
}

// FilenameResolver tests
func testFilenameCollision() {
    var resolver = FilenameResolver()
    let first = resolver.resolve(filename: "IMG.jpg", inBucket: "media/2023/W50")
    let second = resolver.resolve(filename: "IMG.jpg", inBucket: "media/2023/W50")
    XCTAssertEqual(first, "IMG.jpg")
    XCTAssertEqual(second, "IMG_2.jpg")
}
```

### Integration Tests

- Create test Photos library with known content
- Use Google Drive sandbox/test project
- Verify folder structure after sync
- Verify manifest contents

---

## File Structure

```
PhotoVault/
├── PhotoVault.xcodeproj
├── PhotoVault/
│   ├── App/
│   │   └── PhotoVaultApp.swift
│   ├── Models/
│   │   └── BucketStorageSchema.swift
│   ├── Services/
│   │   ├── PhotoKitEnumeration.swift
│   │   ├── PhotoVaultBucketSyncService.swift
│   │   └── AlbumReconstructor.swift
│   ├── Infrastructure/
│   │   ├── SyncDatabase.swift
│   │   └── GoogleDriveClient.swift
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── SyncDashboard.swift
│   │   ├── Sidebar.swift
│   │   └── AuthenticationView.swift
│   ├── Resources/
│   │   └── Assets.xcassets
│   ├── PhotoVault.entitlements
│   └── Info.plist
├── PhotoVaultTests/
│   └── ...
└── docs/
    ├── PRD.md
    ├── ARCHITECTURE.md
    ├── CODE_DOCUMENTATION.md
    ├── GOOGLE_CLOUD_SETUP.md
    └── CLAUDE_CODE_GUIDE.md
```

---

## Extension Ideas

If you want to extend the project:

1. **Incremental Sync**
   - Track last sync date
   - Query Photos for new/modified assets
   - Update manifests for changed albums

2. **Verification Mode**
   - Compare local checksums to `_catalog.json`
   - Report mismatches
   - Option to re-upload corrupted files

3. **Multiple Destinations**
   - Abstract storage interface
   - Implement S3, B2, local NAS backends

4. **Menu Bar Agent**
   - Lightweight status indicator
   - Quick sync button
   - Progress notifications

5. **Scheduled Sync**
   - Background agent
   - Daily/weekly schedule
   - Power-aware (skip on battery)

---

## Questions to Ask User

Before making significant changes, ask:

1. Should smart albums (Favorites, Screenshots) be included?
2. What's the preferred root folder name in Drive?
3. How many concurrent uploads are acceptable?
4. Should iCloud-only photos be downloaded or skipped?
5. Is there a specific time window for syncing?
