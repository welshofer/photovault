# PhotoVault: Apple Photos to Google Drive Backup System

## Product Requirements Document

**Version:** 1.0  
**Last Updated:** March 2026  
**Author:** Jay  
**Status:** Ready for Implementation

---

## Executive Summary

PhotoVault is a macOS application that creates a complete, deduplicated backup of an Apple Photos library to Google Drive. It preserves album organization through JSON manifests while storing actual media files in a date-based folder structure (year/week), eliminating duplicate storage when photos appear in multiple albums.

### Key Metrics

| Metric | Target |
|--------|--------|
| Library Size | 11 TB |
| Photo Count | ~300,000 assets |
| Target Storage | Google Drive (30 TB available) |
| Deduplication | 100% (single copy per unique file) |

---

## Problem Statement

Apple Photos provides excellent organization through albums, smart albums, and folder hierarchies. However:

1. **No native Google Drive integration** — Apple Photos only syncs to iCloud
2. **Album structure is proprietary** — Exporting loses organization
3. **Duplicate storage is wasteful** — A photo in 10 albums shouldn't consume 10x storage
4. **Large libraries need resumability** — 11TB cannot upload in one session
5. **Reconstruction must be possible** — If we ever need to restore, album structure should be recoverable

---

## Goals

### Primary Goals

1. **Complete Backup** — Every photo and video in the library, with original quality
2. **Zero Duplicate Storage** — Each unique file stored exactly once
3. **Album Reconstruction** — JSON manifests enable full album restoration
4. **Resumable Uploads** — Stop and restart anytime without data loss
5. **Human-Navigable Structure** — Year/week folders are browsable without special tools

### Non-Goals

1. **Two-Way Sync** — This is backup only, not bidirectional sync
2. **Real-Time Updates** — Manual trigger, not automatic background sync
3. **Photo Editing** — No modification of original files
4. **iCloud Download Management** — Assumes photos are locally available (or handles gracefully)
5. **Cross-Platform** — macOS only (PhotoKit requirement)

---

## Features

### Core Features

#### F1: PhotoKit Integration
- Full read access to Photos library via PhotoKit framework
- Enumerate all albums, smart albums, and folder hierarchies
- Access original, unmodified files (not re-encoded)
- Retrieve metadata: creation date, location, dimensions, favorites

#### F2: Year/Week Bucket Storage
- Photos organized by creation date into `media/YYYY/WXX/` folders
- ISO 8601 week numbering for consistency
- `media/undated/` folder for photos without creation dates
- Filename collision handling within buckets (append `_2`, `_3`, etc.)

#### F3: Album JSON Manifests
- Each album stored as a JSON file in `albums/` folder
- Preserves folder hierarchy from Photos (nested folders)
- Contains references to actual files (Drive path + file ID)
- Includes sort order, favorites, metadata

#### F4: Master Catalog
- Single `_catalog.json` at root with all asset references
- Quick lookup: PhotoKit ID → Drive location
- Includes checksums for integrity verification

#### F5: Deduplication
- MD5 checksum computed for each file before upload
- If checksum already exists in catalog, skip upload and reference existing file
- Same photo in multiple albums = one upload, multiple manifest entries

#### F6: Resumable Uploads
- Google Drive resumable upload API (10MB chunks)
- Upload state persisted in local SQLite database
- Resume interrupted uploads from last successful chunk
- Automatic retry with exponential backoff

#### F7: Progress Tracking
- Real-time progress: assets uploaded, bytes transferred
- Estimated time remaining based on throughput
- Error log with failed assets and reasons
- Pause/resume capability

### Secondary Features

#### F8: Album Reconstruction
- Utility to parse manifests and reconstruct albums
- Export album to local folder
- Generate HTML gallery
- Create Drive shortcuts (virtual album)

#### F9: Incremental Sync (Future)
- Detect new photos since last sync
- Update manifests for changed albums
- Handle deleted photos (mark in catalog, don't delete from Drive)

---

## What PhotoVault Does NOT Do

| Capability | Status | Reason |
|------------|--------|--------|
| Sync changes back to Photos | ❌ | One-way backup only |
| Delete photos from Drive | ❌ | Append-only for safety |
| Download iCloud-only photos | ⚠️ | Skips with warning (configurable) |
| Preserve edit history | ❌ | Exports current state only |
| Handle Shared Albums | ❌ | Privacy/permissions complexity |
| Sync automatically | ❌ | Manual trigger required |
| Windows/Linux support | ❌ | Requires macOS PhotoKit |

---

## User Stories

### US1: Initial Full Backup
> As a photographer with 300K photos, I want to back up my entire library to Google Drive so I have an off-site copy independent of iCloud.

**Acceptance Criteria:**
- All photos/videos uploaded to correct year/week buckets
- All albums represented as JSON manifests
- Master catalog generated
- Progress visible throughout (estimated 2-5 days for 11TB)

### US2: Resume Interrupted Backup
> As a user whose Mac went to sleep during upload, I want to resume where I left off without re-uploading completed files.

**Acceptance Criteria:**
- Resumable upload URIs stored in database
- Incomplete uploads resume from last chunk
- Completed uploads skipped on restart

### US3: Find a Photo by Date
> As a user browsing Google Drive, I want to find photos from a specific time period by navigating folders.

**Acceptance Criteria:**
- Navigate to `media/2023/W48/` to find early December 2023 photos
- Filenames preserved from original

### US4: Reconstruct an Album
> As a user restoring to a new Mac, I want to recreate my "Vacation Hawaii 2023" album from the backup.

**Acceptance Criteria:**
- Parse `albums/Vacations/Hawaii 2023.json`
- Download files from referenced Drive paths
- Recreate album in Photos (or local folder)

### US5: Verify Backup Integrity
> As a user concerned about data integrity, I want to verify my backup matches my library.

**Acceptance Criteria:**
- Compare local Photos library count to `_catalog.json` asset count
- Spot-check MD5 checksums
- Report any discrepancies

---

## Technical Requirements

### Platform Requirements

| Requirement | Specification |
|-------------|---------------|
| macOS Version | macOS 14.0+ (Sonoma) |
| Swift Version | Swift 5.9+ |
| Xcode Version | Xcode 15.0+ |
| Architecture | Apple Silicon (Universal) |

### Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| GRDB.swift | 6.x | SQLite database wrapper |
| Photos.framework | System | PhotoKit access |
| AuthenticationServices | System | OAuth flow |
| CryptoKit | System | MD5 checksums |

### Google Cloud Requirements

| Requirement | Details |
|-------------|---------|
| Google Cloud Project | New or existing project |
| APIs Enabled | Google Drive API |
| OAuth Consent Screen | External, with `drive.file` scope |
| OAuth Credentials | Desktop application type |
| Quota | Default (10,000 queries/100 seconds) |

### Storage Estimates

| Item | Size Estimate |
|------|---------------|
| Media files | 11 TB |
| Album manifests | ~15 MB (300 albums × 50KB avg) |
| Master catalog | ~100 MB (300K entries) |
| Local SQLite DB | ~50 MB |

---

## Data Models

### Google Drive Folder Structure

```
Apple Photos Backup/
├── media/
│   ├── 2018/
│   │   ├── W01/
│   │   ├── W02/
│   │   └── ...W52/
│   ├── 2019/
│   ├── ...
│   ├── 2025/
│   └── undated/
├── albums/
│   ├── Favorites.json
│   ├── Screenshots.json
│   ├── Recents.json
│   ├── Vacations/
│   │   ├── Hawaii 2023.json
│   │   └── Japan 2024.json
│   └── Family/
│       ├── Kids.json
│       └── Holidays/
│           └── Christmas 2023.json
└── _catalog.json
```

### Album Manifest Schema

```json
{
  "albumID": "string (PhotoKit localIdentifier)",
  "title": "string",
  "folderPath": ["string array of parent folders"],
  "albumType": "album | smartAlbum | moment",
  "lastUpdated": "ISO 8601 datetime",
  "assetCount": "integer",
  "assets": [
    {
      "localID": "string (PhotoKit localIdentifier)",
      "filename": "string",
      "drivePath": "media/2023/W48/IMG_0001.HEIC",
      "driveFileID": "string (Google Drive file ID)",
      "creationDate": "ISO 8601 datetime | null",
      "mediaType": "image | video | livePhoto",
      "width": "integer",
      "height": "integer",
      "duration": "number (seconds) | null",
      "isFavorite": "boolean",
      "sortOrder": "integer"
    }
  ]
}
```

### Master Catalog Schema

```json
{
  "version": 1,
  "lastUpdated": "ISO 8601 datetime",
  "totalAssets": "integer",
  "totalBytes": "integer (int64)",
  "assets": {
    "<PhotoKit localIdentifier>": {
      "filename": "string",
      "drivePath": "string",
      "driveFileID": "string",
      "fileSize": "integer (int64)",
      "md5Checksum": "string (hex)",
      "creationDate": "ISO 8601 datetime | null",
      "uploadedAt": "ISO 8601 datetime"
    }
  }
}
```

### Local SQLite Schema

```sql
-- Track individual assets
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

-- Track albums
CREATE TABLE albums (
    localIdentifier TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    folderPath TEXT NOT NULL,
    albumType INTEGER NOT NULL,
    subtype INTEGER NOT NULL,
    assetCount INTEGER NOT NULL,
    manifestDriveID TEXT,
    manifestPath TEXT,
    manifestLastUpdated DATETIME,
    createdAt DATETIME NOT NULL
);

-- Many-to-many: assets in albums
CREATE TABLE album_assets (
    albumIdentifier TEXT NOT NULL,
    assetIdentifier TEXT NOT NULL,
    sortOrder INTEGER NOT NULL,
    PRIMARY KEY (albumIdentifier, assetIdentifier)
);

-- Indexes
CREATE INDEX idx_assets_status ON assets(uploadStatus);
CREATE INDEX idx_assets_checksum ON assets(md5Checksum);
CREATE INDEX idx_assets_bucket ON assets(bucketPath);
```

---

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `rootFolderName` | "Apple Photos Backup" | Top-level Drive folder name |
| `includeSmartAlbums` | true | Include Favorites, Screenshots, etc. |
| `maxConcurrentUploads` | 3 | Parallel upload streams |
| `uploadChunkSize` | 10 MB | Resumable upload chunk size |
| `maxRetries` | 5 | Retry attempts for failed uploads |
| `skipICloudOnlyAssets` | false | Skip or fail on iCloud-only photos |

---

## Error Handling

| Error Type | Handling |
|------------|----------|
| Photos access denied | Show Settings deep link, abort |
| OAuth token expired | Automatic refresh, retry |
| Rate limit exceeded | Exponential backoff, continue |
| Upload session expired (>24h) | Restart upload for that file |
| Network timeout | Retry with backoff |
| Disk full (temp) | Pause, alert user |
| File not found in Photos | Mark as skipped, continue |
| iCloud asset unavailable | Skip or download (configurable) |

---

## Security Considerations

1. **OAuth Tokens** — Stored in macOS Keychain, not plain text
2. **Minimal Scope** — Only `drive.file` scope (access to files created by app)
3. **No Deletion** — App cannot delete files outside its scope
4. **Local Database** — Stored in Application Support, not world-readable
5. **No Telemetry** — No data sent except to Google Drive API

---

## Performance Considerations

| Aspect | Approach |
|--------|----------|
| Memory | Stream files to disk, never load 11TB into memory |
| Concurrency | 3 parallel uploads (configurable) |
| Rate Limiting | Built-in throttling (100ms between requests) |
| Batch Processing | 100 assets per batch, checkpoint after each |
| Checksum | Streaming MD5, 1MB chunks |
| Database | SQLite with indexes, GRDB for Swift |

---

## Testing Strategy

### Unit Tests
- DateBucket calculation
- Filename collision resolution
- JSON encoding/decoding
- Checksum computation

### Integration Tests
- PhotoKit enumeration (mock or real small library)
- Google Drive API (sandbox project)
- Database operations

### Manual Testing
- Full sync of small library (~1000 photos)
- Resume after interruption
- Album manifest verification
- Reconstruction utility

---

## Future Enhancements

1. **Incremental Sync** — Detect and upload only new/changed photos
2. **Deletion Tracking** — Mark deleted photos in catalog (don't remove)
3. **Shared Albums** — Support with proper permissions
4. **Multiple Destinations** — S3, B2, local NAS
5. **Verification Mode** — Checksum audit of existing backup
6. **Menu Bar Agent** — Lightweight status indicator
7. **Scheduling** — Automatic daily/weekly sync

---

## Success Criteria

| Criterion | Measure |
|-----------|---------|
| Completeness | 100% of library assets in Drive |
| Deduplication | No duplicate files across albums |
| Resumability | Can pause/resume without data loss |
| Reconstruction | Albums rebuildable from manifests |
| Performance | Sustained upload at network speed |
| Reliability | <0.1% permanent failure rate |

---

## Appendix: Glossary

| Term | Definition |
|------|------------|
| Asset | A photo or video in Apple Photos |
| Bucket | A year/week folder (e.g., `2023/W48`) |
| Manifest | JSON file describing an album's contents |
| Catalog | Master index of all uploaded assets |
| PhotoKit | Apple's framework for Photos library access |
| Resumable Upload | Google Drive API feature for large file uploads |
| LocalIdentifier | Unique ID for an asset in PhotoKit |
