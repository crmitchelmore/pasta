# PastaSync

CloudKit synchronization package for the Pasta clipboard manager.

## Overview

PastaSync provides bidirectional CloudKit sync between macOS Pasta and companion iOS apps. It uses CloudKit's private database for efficient, incremental sync with delta tracking.

## Features

- **Zone-based Sync**: Uses custom `PastaZone` for efficient change tracking
- **Delta Sync**: Incremental updates using CloudKit change tokens
- **Asset Handling**: Images and large data as CKAssets
- **Batch Operations**: Handles large clipboard histories efficiently
- **Push Notifications**: CloudKit subscriptions for near-real-time sync
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
let (modified, deleted) = try await syncManager.fetchChanges()

// Apply changes to local database
for entry in modified {
    database.upsert(entry)
}
for id in deleted {
    database.delete(id)
}
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
Default: `iCloud.com.pasta.clipboard`

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

- **Change Tokens**: Stored in UserDefaults, persisted across launches
- **Assets**: Only large data (images) use CKAssets
- **Batching**: Prevents CloudKit timeout on large syncs
- **Quality of Service**: `.utility` for background, `.userInitiated` for pulls

## Testing

```swift
// Reset sync state (useful for testing)
syncManager.resetSync()
```

## License

Part of the Pasta clipboard manager project.
