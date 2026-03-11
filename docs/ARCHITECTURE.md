# PhotoVault Architecture

## System Overview

```mermaid
graph TB
    subgraph "macOS Application"
        UI[SwiftUI Interface]
        Orchestrator[PhotoVaultBucketSyncService]
        
        subgraph "Data Layer"
            Catalog[PhotosCatalogService]
            Export[AssetExportService]
            DB[(SyncDatabase<br/>SQLite/GRDB)]
        end
        
        subgraph "Network Layer"
            OAuth[OAuth Manager]
            Drive[GoogleDriveClient]
        end
    end
    
    subgraph "External Systems"
        Photos[(Apple Photos<br/>Library)]
        GDrive[(Google Drive<br/>30TB)]
        GAuth[Google OAuth 2.0]
    end
    
    UI --> Orchestrator
    Orchestrator --> Catalog
    Orchestrator --> Export
    Orchestrator --> DB
    Orchestrator --> Drive
    
    Catalog --> Photos
    Export --> Photos
    Drive --> GDrive
    OAuth --> GAuth
    Drive --> OAuth
```

---

## Sync Flow Sequence

```mermaid
sequenceDiagram
    participant User
    participant UI as SwiftUI
    participant Sync as SyncService
    participant Photos as PhotoKit
    participant DB as SQLite
    participant Drive as Google Drive
    
    User->>UI: Start Sync
    UI->>Sync: startFullSync()
    
    rect rgb(240, 248, 255)
        Note over Sync,Photos: Phase 1: Cataloging
        Sync->>Photos: requestAuthorization()
        Photos-->>Sync: authorized
        Sync->>Photos: fetchAssetCollections()
        Photos-->>Sync: albums[]
        loop Each Album
            Sync->>Photos: fetchAssets(album)
            Photos-->>Sync: assets[]
            Sync->>DB: upsertAssets()
        end
    end
    
    rect rgb(255, 248, 240)
        Note over Sync,DB: Phase 2: Bucket Planning
        Sync->>DB: fetchAllAssets()
        DB-->>Sync: assets[]
        Sync->>Sync: BucketPlanner.plan()
        Note right of Sync: Group by year/week
    end
    
    rect rgb(240, 255, 240)
        Note over Sync,Drive: Phase 3: Create Folders
        Sync->>Drive: createFolder("Apple Photos Backup")
        Drive-->>Sync: rootFolderID
        loop Each Year/Week Bucket
            Sync->>Drive: createFolderPath([year, week])
            Drive-->>Sync: bucketFolderID
        end
    end
    
    rect rgb(255, 240, 255)
        Note over Sync,Drive: Phase 4: Upload Assets
        loop Batch of 100 Assets
            Sync->>DB: fetchPendingAssets(100)
            DB-->>Sync: assets[]
            par Concurrent Uploads (3)
                Sync->>Photos: exportOriginal(assetID)
                Photos-->>Sync: tempFileURL
                Sync->>Sync: computeMD5()
                Sync->>DB: checkDuplicate(checksum)
                alt Not Duplicate
                    Sync->>Drive: uploadFile(resumable)
                    Drive-->>Sync: driveFileID
                end
                Sync->>DB: markCompleted()
            end
        end
    end
    
    rect rgb(255, 255, 240)
        Note over Sync,Drive: Phase 5: Generate Manifests
        loop Each Album
            Sync->>DB: fetchAssetsInAlbum()
            Sync->>Sync: buildManifestJSON()
            Sync->>Drive: uploadJSON(manifest)
        end
        Sync->>Sync: buildCatalogJSON()
        Sync->>Drive: uploadJSON(_catalog.json)
    end
    
    Sync-->>UI: completed
    UI-->>User: Success!
```

---

## Component Architecture

```mermaid
graph LR
    subgraph "Presentation Layer"
        App[PhotoVaultApp]
        Content[ContentView]
        Dashboard[SyncDashboard]
        Sidebar[Sidebar]
    end
    
    subgraph "Service Layer"
        SyncService[PhotoVaultBucketSyncService]
        CatalogService[PhotosCatalogService]
        ExportService[AssetExportService]
        ReconService[AlbumReconstructor]
    end
    
    subgraph "Data Layer"
        Database[SyncDatabaseV2]
        Models[Data Models]
    end
    
    subgraph "Infrastructure Layer"
        DriveClient[GoogleDriveClient]
        KeychainMgr[KeychainWrapper]
    end
    
    App --> Content
    Content --> Dashboard
    Content --> Sidebar
    Dashboard --> SyncService
    
    SyncService --> CatalogService
    SyncService --> ExportService
    SyncService --> Database
    SyncService --> DriveClient
    
    CatalogService --> Models
    ExportService --> Models
    Database --> Models
    
    DriveClient --> KeychainMgr
```

---

## Data Flow

```mermaid
flowchart TD
    subgraph "Apple Photos Library"
        PHAlbum[PHAssetCollection]
        PHAsset[PHAsset]
        PHResource[PHAssetResource]
    end
    
    subgraph "Local Processing"
        AlbumInfo[AlbumInfo]
        AssetInfo[AssetInfo]
        TempFile[Temp File on Disk]
        Checksum[MD5 Checksum]
    end
    
    subgraph "Local Database"
        AssetRecord[(AssetRecordV2)]
        AlbumRecord[(AlbumRecordV2)]
        AlbumAsset[(album_assets)]
    end
    
    subgraph "Google Drive"
        MediaFolder[media/YYYY/WXX/]
        AlbumFolder[albums/]
        MediaFile[Photo/Video File]
        ManifestFile[Album.json]
        CatalogFile[_catalog.json]
    end
    
    PHAlbum --> AlbumInfo
    PHAsset --> AssetInfo
    AlbumInfo --> AlbumRecord
    AssetInfo --> AssetRecord
    
    PHAsset --> PHResource
    PHResource --> TempFile
    TempFile --> Checksum
    
    TempFile --> MediaFile
    MediaFile --> MediaFolder
    
    AssetRecord --> ManifestFile
    AlbumRecord --> ManifestFile
    ManifestFile --> AlbumFolder
    
    AssetRecord --> CatalogFile
```

---

## Google Drive Storage Structure

```mermaid
graph TD
    Root["Apple Photos Backup/"]
    
    Root --> Media["media/"]
    Root --> Albums["albums/"]
    Root --> Catalog["_catalog.json"]
    
    Media --> Y2023["2023/"]
    Media --> Y2024["2024/"]
    Media --> Undated["undated/"]
    
    Y2023 --> W48["W48/"]
    Y2023 --> W49["W49/"]
    Y2023 --> W50["W50/"]
    
    W48 --> IMG1["IMG_0001.HEIC"]
    W48 --> IMG2["IMG_0002.HEIC"]
    W48 --> VID1["VID_0003.MOV"]
    
    Albums --> Favorites["Favorites.json"]
    Albums --> Screenshots["Screenshots.json"]
    Albums --> Vacations["Vacations/"]
    
    Vacations --> Hawaii["Hawaii 2023.json"]
    Vacations --> Japan["Japan 2024.json"]
```

---

## Upload State Machine

```mermaid
stateDiagram-v2
    [*] --> Pending: Asset cataloged
    
    Pending --> InProgress: Upload started
    InProgress --> Completed: Upload successful
    InProgress --> Failed: Error occurred
    
    Failed --> Pending: Retry (if retryCount < max)
    Failed --> Skipped: Max retries exceeded
    
    Completed --> [*]
    Skipped --> [*]
    
    note right of InProgress
        Stores resumableUploadURI
        and uploadedBytes for
        resume capability
    end note
    
    note right of Completed
        Stores driveFileID
        and drivePath
    end note
```

---

## OAuth 2.0 Flow (Desktop App with Loopback Server)

```mermaid
sequenceDiagram
    participant App as PhotoVault
    participant Server as Loopback HTTP Server<br/>127.0.0.1:random_port
    participant Browser as System Browser
    participant Google as Google OAuth
    participant Drive as Google Drive API

    App->>Server: Start HTTP server on 127.0.0.1:0
    Server-->>App: Assigned port (e.g., 52847)
    App->>Browser: Open authorization URL<br/>redirect_uri=http://127.0.0.1:52847
    Browser->>Google: User signs in + grants consent
    Google->>Server: HTTP redirect with ?code=AUTH_CODE
    Server->>Browser: "Authentication Successful" HTML
    Server->>App: Return authorization code
    App->>Server: Shut down server

    App->>Google: POST /token (exchange code for tokens)
    Google-->>App: access_token + refresh_token
    App->>App: Store refresh_token in macOS Keychain

    loop API Requests
        App->>Drive: Request with access_token
        alt Token Valid
            Drive-->>App: Response
        else Token Expired (401)
            App->>Google: POST /token (refresh)
            Google-->>App: New access_token
            App->>Drive: Retry request
            Drive-->>App: Response
        end
    end
```

---

## Resumable Upload Protocol

```mermaid
sequenceDiagram
    participant App as PhotoVault
    participant Drive as Google Drive
    
    Note over App,Drive: Initiate Upload
    App->>Drive: POST /upload/drive/v3/files?uploadType=resumable
    Note right of App: Headers: X-Upload-Content-Length, X-Upload-Content-Type
    Drive-->>App: 200 OK + Location header (upload URI)
    App->>App: Store resumableUploadURI in DB
    
    Note over App,Drive: Upload Chunks
    loop Each 10MB Chunk
        App->>Drive: PUT {upload_uri}<br/>Content-Range: bytes X-Y/Total
        alt Chunk Received
            Drive-->>App: 308 Resume Incomplete<br/>Range: bytes=0-Y
            App->>App: Update uploadedBytes in DB
        else Upload Complete
            Drive-->>App: 200 OK + File metadata
            App->>App: Store driveFileID
        end
    end
    
    Note over App,Drive: Resume After Interruption
    App->>Drive: PUT {upload_uri}<br/>Content-Range: bytes */Total
    Drive-->>App: 308 + Range header (bytes uploaded)
    App->>App: Seek to resume position
    App->>Drive: Continue uploading chunks
```

---

## Deduplication Logic

```mermaid
flowchart TD
    Start[Export Asset to Temp File] --> Checksum[Compute MD5 Checksum]
    Checksum --> Query{Checksum exists<br/>in database?}
    
    Query -->|Yes| Lookup[Lookup existing driveFileID]
    Lookup --> Reference[Create reference to existing file]
    Reference --> Manifest[Add to album manifest with existing path]
    
    Query -->|No| Upload[Upload to Google Drive]
    Upload --> Store[Store driveFileID + checksum in DB]
    Store --> Manifest
    
    Manifest --> Cleanup[Delete temp file]
    Cleanup --> Done[Mark asset completed]
```

---

## Error Recovery Flow

```mermaid
flowchart TD
    Error[Error Occurred] --> Type{Error Type?}
    
    Type -->|Network Timeout| Retry1[Wait + Retry]
    Type -->|Rate Limited| Backoff[Exponential Backoff]
    Type -->|Token Expired| Refresh[Refresh OAuth Token]
    Type -->|Session Expired| Restart[Restart Upload]
    Type -->|File Not Found| Skip[Mark as Skipped]
    Type -->|Disk Full| Pause[Pause + Alert User]
    
    Retry1 --> Check1{Retry Count<br/>< Max?}
    Check1 -->|Yes| Attempt[Retry Operation]
    Check1 -->|No| Fail[Mark as Failed]
    
    Backoff --> Wait[Wait 2^n seconds]
    Wait --> Attempt
    
    Refresh --> Attempt
    Restart --> Attempt
    
    Attempt --> Success{Success?}
    Success -->|Yes| Continue[Continue Sync]
    Success -->|No| Error
```

---

## Album Reconstruction Flow

```mermaid
flowchart TD
    Start[Load Album Manifest JSON] --> Parse[Parse manifest.assets]
    Parse --> Loop{For each asset}
    
    Loop --> Resolve[Resolve drivePath]
    Resolve --> Download[Download from Google Drive]
    Download --> Save[Save to local folder]
    Save --> Meta[Set file creation date]
    Meta --> Loop
    
    Loop -->|Done| Complete[Album Reconstructed]
    
    subgraph "Alternative: HTML Gallery"
        Parse --> HTML[Generate HTML]
        HTML --> Embed[Embed Drive thumbnails]
        Embed --> Export[Export gallery.html]
    end
    
    subgraph "Alternative: Drive Shortcuts"
        Parse --> Shortcuts[Create shortcut folder]
        Shortcuts --> CreateShortcut[Create shortcut for each asset]
    end
```

---

## Module Dependencies

```mermaid
graph BT
    subgraph "Foundation"
        Models[Data Models]
        Utils[Utilities]
    end
    
    subgraph "Infrastructure"
        Keychain[KeychainWrapper]
        DriveClient[GoogleDriveClient]
        Database[SyncDatabaseV2]
    end
    
    subgraph "Domain"
        Catalog[PhotosCatalogService]
        Export[AssetExportService]
        Bucket[BucketPlanner]
        Filename[FilenameResolver]
    end
    
    subgraph "Application"
        SyncService[PhotoVaultBucketSyncService]
        Reconstruct[AlbumReconstructor]
    end
    
    subgraph "Presentation"
        App[PhotoVaultApp]
        Views[SwiftUI Views]
    end
    
    DriveClient --> Keychain
    DriveClient --> Models
    Database --> Models
    
    Catalog --> Models
    Export --> Models
    Bucket --> Models
    
    SyncService --> Catalog
    SyncService --> Export
    SyncService --> Database
    SyncService --> DriveClient
    SyncService --> Bucket
    SyncService --> Filename
    
    Reconstruct --> DriveClient
    Reconstruct --> Models
    
    Views --> SyncService
    App --> Views
```
