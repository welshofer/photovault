# Contributing to PhotoVault

Thanks for your interest in contributing! PhotoVault is an open-source macOS app for backing up Apple Photos to Google Drive.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/photovault.git`
3. Create a feature branch: `git checkout -b feature/your-feature`
4. Follow the [setup guide](docs/SETUP.md) to configure your development environment

## Development Requirements

- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Google Cloud project with Drive API enabled (see [Google Cloud Setup](docs/GOOGLE_CLOUD_SETUP.md))

## Code Style

- **Swift 5.9+** with strict concurrency (`targeted` mode)
- Use `actor` for shared mutable state, `@MainActor` for UI code
- Prefer `async/await` over closures for asynchronous work
- Use `GRDB` patterns for database operations (records conform to `FetchableRecord` + `PersistableRecord`)
- No force unwraps in production code paths (acceptable in tests)

## Architecture

PhotoVault follows a layered architecture:

```
Presentation (SwiftUI)  -->  Services (actors)  -->  Infrastructure (Drive, DB)
         |                        |                          |
     PhotoVaultApp          BucketSyncService           GoogleDriveClient
     SyncDashboard          PhotosCatalogService        SyncDatabase
     Sidebar                AssetExportService          KeychainWrapper
```

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed diagrams.

## Pull Request Process

1. **Keep PRs focused** — one feature or fix per PR
2. **Test manually** — run a sync with `debugMaxAssets = 10` to verify changes work end-to-end
3. **Update docs** — if you change behavior, update relevant docs
4. **Don't commit credentials** — `.env`, API keys, and OAuth secrets must never be committed

## Areas for Contribution

Check the [Issues](https://github.com/welshofer/photovault/issues) tab, or here are some areas that need work:

### High Priority
- **Orphan asset sweep** — Assets not in any album aren't currently captured
- **Batch database inserts** — `addAssetToAlbum` does individual writes (slow for large albums)
- **Incremental sync** — Detect and upload only new/changed assets
- **Unit tests** — No test coverage yet

### Medium Priority
- **Menu bar agent** — Lightweight status indicator
- **Multiple storage backends** — S3, B2, local NAS
- **Backup verification** — Checksum audit of existing backup
- **Scheduling** — Automatic daily/weekly sync

### Nice to Have
- **Shared album support** — Complex due to permissions
- **HTML gallery generator** — Better reconstruction UX
- **Progress notifications** — macOS notifications for milestones

## Reporting Issues

When filing an issue, include:
- macOS version
- Xcode version
- Photos library size (approximate)
- Console logs (filter by `[PhotoVault]` or `[GoogleDrive]`)
- The sync phase where the issue occurred

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
