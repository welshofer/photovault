# PhotoVault

**Apple Photos → Google Drive Backup with Album Preservation**

A macOS application that creates a complete, deduplicated backup of your Apple Photos library to Google Drive while preserving album organization through JSON manifests.

---

## Features

- 📸 **Full PhotoKit Integration** — Direct access to Photos library, no export needed
- 🗂️ **Year/Week Bucket Storage** — Photos organized by creation date
- 📋 **Album JSON Manifests** — Album structure preserved and reconstructable
- 🔄 **Resumable Uploads** — Stop and restart anytime
- 🚫 **Zero Duplicates** — Each photo stored once, referenced many times
- 📊 **Progress Tracking** — Real-time stats and ETA

---

## Target Scale

| Metric | Target |
|--------|--------|
| Library Size | 11 TB |
| Photo Count | ~300,000 |
| Storage Destination | Google Drive |

---

## Storage Structure

```
Apple Photos Backup/
├── media/
│   ├── 2023/
│   │   ├── W01/
│   │   ├── W02/
│   │   └── ...
│   └── undated/
├── albums/
│   ├── Favorites.json
│   └── Vacations/
│       └── Hawaii 2023.json
└── _catalog.json
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [PRD.md](docs/PRD.md) | Product Requirements Document |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture with Mermaid diagrams |
| [CODE_DOCUMENTATION.md](docs/CODE_DOCUMENTATION.md) | Source code documentation |
| [GOOGLE_CLOUD_SETUP.md](docs/GOOGLE_CLOUD_SETUP.md) | Google Cloud project setup |
| [CLAUDE_CODE_GUIDE.md](docs/CLAUDE_CODE_GUIDE.md) | Implementation guide for Claude Code |

---

## Source Files

| File | Purpose |
|------|---------|
| `PhotoKitEnumeration.swift` | PhotoKit integration |
| `BucketStorageSchema.swift` | Data models and bucket planning |
| `SyncDatabase.swift` | SQLite persistence (GRDB) |
| `GoogleDriveClient.swift` | Google Drive API wrapper |
| `PhotoVaultBucketSyncService.swift` | Main sync orchestrator |
| `AlbumReconstructor.swift` | Album restoration utilities |
| `PhotoVaultApp.swift` | SwiftUI application |

---

## Quick Start

### 1. Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- Google Cloud project with Drive API enabled
- Google One storage (20TB+ for 11TB library)

### 2. Google Cloud Setup

See [GOOGLE_CLOUD_SETUP.md](docs/GOOGLE_CLOUD_SETUP.md) for detailed instructions.

### 3. Create Xcode Project

```bash
# New macOS App
# Bundle ID: com.yourname.photovault
# SwiftUI, Swift
```

### 4. Add Dependencies

- GRDB.swift: `https://github.com/groue/GRDB.swift`

### 5. Configure Entitlements

```xml
<key>com.apple.security.personal-information.photos-library</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

### 6. Add Source Files

Copy files from `Sources/` into your Xcode project.

### 7. Configure OAuth

Update `PhotoVaultApp.swift` with your Google credentials.

### 8. Build & Run

```
⌘B → ⌘R
```

---

## How It Works

1. **Catalog** — Enumerate all albums and assets via PhotoKit
2. **Plan** — Calculate year/week bucket distribution
3. **Create Folders** — Build folder structure in Google Drive
4. **Upload** — Stream originals to buckets with deduplication
5. **Generate Manifests** — Create JSON files for each album
6. **Catalog** — Generate master `_catalog.json` index

---

## Album Manifest Example

```json
{
  "albumID": "ABC123",
  "title": "Vacation Hawaii 2023",
  "folderPath": ["Vacations", "2023"],
  "assetCount": 247,
  "assets": [
    {
      "localID": "XYZ789",
      "filename": "IMG_4521.HEIC",
      "drivePath": "media/2023/W48/IMG_4521.HEIC",
      "driveFileID": "1ABC123...",
      "creationDate": "2023-12-01T08:30:00Z"
    }
  ]
}
```

---

## Reconstructing Albums

Albums can be restored using the JSON manifests:

```swift
let reconstructor = AlbumReconstructor(driveClient: client, rootFolderID: rootID)
let manifest = try await reconstructor.loadManifest(fileID: "...")

// Option 1: Export to local folder
try await reconstructor.exportAlbumToLocal(manifest: manifest, destinationPath: localURL)

// Option 2: Generate HTML gallery
let html = reconstructor.generateHTMLGallery(manifest: manifest)

// Option 3: Create Drive shortcuts
try await reconstructor.createShortcutAlbum(manifest: manifest, destinationFolderID: folderID)
```

---

## Performance

| Aspect | Approach |
|--------|----------|
| Memory | Stream files, never load full library |
| Concurrency | 3 parallel uploads (configurable) |
| Checksum | MD5 in 1MB chunks |
| Resume | Per-file resumable upload state |

---

## License

MIT — Use freely, no warranty.

---

## Contributing

This is a personal project, but suggestions welcome via Issues.
