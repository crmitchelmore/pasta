# PastaSync

CloudKit synchronization package for the Pasta clipboard manager.

## Overview

PastaSync provides bidirectional CloudKit sync between macOS Pasta and companion iOS apps. It uses CloudKit's private database for efficient, incremental sync with delta tracking.

## Features

- **Zone-based Sync**: Uses custom `PastaZone` for efficient change tracking
- **Delta Sync**: Incremental updates using CloudKit change tokens
- **Asset Handling**: Images and large data as CKAssets
- **Batch Operations**: Handles large clipboard histories efficiently
- **Automatic Receiving**: macOS uploads pending history and downloads at launch and every 60 seconds while running; iOS syncs when it becomes active
- **Diagnostics**: Read-only account fingerprints, signed/configured environment, local/cloud membership counts and redacted transport errors
- **Observable**: SwiftUI-friendly with `@Published` state properties

## Usage

### Basic Setup

```swift
import PastaSync

let syncManager = SyncManager()

// Check iCloud availability
let status = try await syncManager.checkAccountStatus()
guard status == .available else { return }

// Setup CloudKit zone
try await syncManager.setupZone()

// Register for push notifications
try await syncManager.registerSubscription()
```

### Push to CloudKit (macOS)

```swift
// Push single entry
try await syncManager.pushEntry(clipboardEntry)

// Push multiple entries
try await syncManager.pushEntries(entries, batchSize: 200)

// Delete entry
try await syncManager.deleteEntry(id: uuid)
```

### Pull from CloudKit (iOS or macOS)

```swift
// Applies one transaction by record UUID, including its change token.
// A failed transaction is replayed on the next attempt.
try await syncManager.pullChanges(into: database)

// Reload the displayed history after the operation returns.
```

### Observing Sync State

```swift
struct SyncStatusView: View {
    @ObservedObject var syncManager: SyncManager
    
    var body: some View {
        switch syncManager.syncState {
        case .idle:
            Text("Ready")
        case .syncing:
            ProgressView("Syncing...")
        case .error(let message):
            Text("Error: \(message)")
        }
        
        if let date = syncManager.lastSyncDate {
            Text("Last sync: \(date, style: .relative)")
        }
    }
}
```

## Architecture

### SyncManager

Main orchestrator for all sync operations:
- Zone setup and management
- Push/pull operations
- Change token persistence
- Subscription management
- Observable state for UI

### RecordMapper

Maps between `ClipboardEntry` domain models and CloudKit `CKRecord`:
- Converts ContentType enum to/from string
- Handles UUID serialization
- Creates CKAssets for large binary data
- Extracts metadata efficiently

## CloudKit Schema

**Record Type**: `ClipboardEntry`

| Field | Type | Notes |
|-------|------|-------|
| `id` | Record ID | UUID string |
| `content` | String | Text content |
| `contentType` | String | ContentType.rawValue |
| `contentHash` | String | SHA-256 for dedup |
| `timestamp` | Date | Creation time |
| `copyCount` | Int | Usage counter |
| `sourceApp` | String? | Optional |
| `metadata` | String? | Optional JSON |
| `parentEntryId` | String? | UUID for grouping |
| `contentSize` | Int | Bytes (for UI) |
| `imageAsset` | Asset? | Binary data |

**Zone**: `PastaZone` (custom zone for change tracking)

## Configuration

### Container Identifier
Both app hosts explicitly use `iCloud.com.pasta.ios` with the private database and `PastaZone`. Production releases request the `Production` environment. A bare `SyncManager()` uses CloudKit’s default container; production hosts must pass their shared identifier.

Override in initialization:
```swift
SyncManager(containerIdentifier: "iCloud.com.yourapp.clipboard")
```

### Batch Size
Default: 200 records per batch

Adjust for network conditions:
```swift
try await syncManager.pushEntries(entries, batchSize: 100)
```

## Error Handling

CloudKit errors are propagated as-is. Common scenarios:

- `.notAuthenticated`: User not signed into iCloud
- `.networkUnavailable`: No internet connection
- `.quotaExceeded`: User's iCloud storage full
- `.serverRecordChanged`: Conflict (handled internally)

## Performance Considerations

- **Change Tokens**: Stored in SQLite in the same transaction as downloaded changes
- **Assets**: Only large data (images) use CKAssets
- **Batching**: Prevents CloudKit timeout on large syncs
- **Quality of Service**: `.utility` for background, `.userInitiated` for pulls

## Diagnosing device mismatches

Open Settings → iCloud → Sync Diagnostics on Mac, or Settings → Sync Diagnostics on iOS. Compare container, environment and account fingerprint first, then the fresh cloud record count and the counts missing on either side. The iOS environment is labelled as the requested release configuration because iOS does not expose a public runtime entitlement lookup.

The inventory requests only system record metadata, never clipboard fields or assets, and never changes history or the saved download checkpoint. A scan failure is shown as an error, not an empty cloud. Local “marked synced” counts are bookkeeping, not server totals. Reports can be refreshed or copied explicitly. Counts are snapshots and can change while another device syncs.

Reset Sync clears only the download checkpoint. It preserves local history and cloud records; it does not re-upload rows already marked synced or delete/recreate the zone. Both apps pause the download if an upload leaves pending rows, including unreadable image assets, so an older cloud version cannot replace the pending local payload. Do not reset sync flags indiscriminately to repair a mismatch: stale rows could overwrite cloud records. Establish which records are missing first.

## Testing

```swift
// Reset sync state (useful for testing)
try syncManager.resetSync(in: database)
```

## License

Part of the Pasta clipboard manager project.
