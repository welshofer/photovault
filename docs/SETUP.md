# Development Setup

How to set up PhotoVault for local development.

---

## Requirements

| Tool | Version | Install |
|------|---------|---------|
| macOS | 14.0+ (Sonoma) | — |
| Xcode | 15.0+ | Mac App Store |
| XcodeGen | Latest | `brew install xcodegen` |
| Git | Latest | `xcode-select --install` |

---

## Clone and Build

```bash
# Clone
git clone https://github.com/welshofer/photovault.git
cd photovault

# Generate Xcode project from project.yml
xcodegen generate

# Open in Xcode
open PhotoVault.xcodeproj
```

In Xcode:
1. Select your **signing team** in Signing & Capabilities
2. Build: `Cmd+B`
3. Run: `Cmd+R`

---

## Google Cloud Credentials

Follow the [Google Cloud Setup Guide](GOOGLE_CLOUD_SETUP.md) to create OAuth credentials, then configure them via environment variables or source edit.

---

## Project Structure

```
photovault/
├── Sources/                    # All Swift source files
│   ├── PhotoVaultApp.swift     # App entry point, views, OAuth server
│   ├── GoogleDriveClient.swift # Drive API client
│   ├── PhotoVaultBucketSyncService.swift  # Main sync orchestrator
│   ├── PhotoVaultSyncService.swift        # Shared types + legacy v1
│   ├── SyncDatabase.swift      # SQLite via GRDB
│   ├── BucketStorageSchema.swift # Data models, bucket planning
│   ├── PhotoKitEnumeration.swift # PhotoKit enumeration + export
│   └── AlbumReconstructor.swift  # Album restoration
├── Resources/
│   ├── Info.plist              # App metadata
│   └── PhotoVault.entitlements # Sandbox entitlements
├── docs/                       # Documentation
├── project.yml                 # XcodeGen project definition
├── .gitignore
├── LICENSE
├── CONTRIBUTING.md
└── README.md
```

---

## Debug Mode

For testing without uploading your entire library, set these in `PhotoVaultApp.swift`:

```swift
config.debugMaxAssets = 10           // Upload only 10 assets
config.skipICloudOnlyAssets = true   // Skip iCloud-only assets
```

The app will run through all phases (catalog, plan, folders, upload, manifests) but stop after 10 uploads.

---

## Database

The SQLite database is stored at:

```
~/Library/Application Support/PhotoVault/PhotoVault.sqlite
```

To inspect it:
```bash
sqlite3 ~/Library/Application\ Support/PhotoVault/PhotoVault.sqlite
.tables
SELECT COUNT(*) FROM assets_v2;
SELECT COUNT(*) FROM assets_v2 WHERE uploadStatus = 2;  -- completed
```

To reset and start fresh:
```bash
rm ~/Library/Application\ Support/PhotoVault/PhotoVault.sqlite*
```

---

## Useful Console Filters

PhotoVault logs with prefixes you can filter in Console.app or terminal:

| Prefix | Source |
|--------|--------|
| `[PhotoVault]` | App lifecycle, sync phases |
| `[GoogleDrive]` | API calls, retries, rate limiting |
| `[BucketSync]` | Bucket planning, folder creation, uploads |

---

## Regenerating the Xcode Project

If you modify `project.yml`, regenerate:

```bash
xcodegen generate
```

This recreates `PhotoVault.xcodeproj` from the YAML definition. Your Xcode settings (signing team, scheme customizations) may need to be reapplied.

---

## Migrating to Another Machine

To move PhotoVault to a different Mac (e.g., from a laptop to a RAID workstation):

1. Push your latest code: `git push`
2. On the new machine: `git clone` + `xcodegen generate`
3. The SQLite database does **not** transfer — a fresh catalog scan will run
4. Existing Google Drive folders from previous runs will be found and reused (not duplicated)
5. Assets already uploaded (matched by checksum) will be skipped

> **Note:** PhotoKit `localIdentifier`s are tied to the iCloud Photos account, not the machine. If both Macs use the same Apple ID, the IDs will match.
