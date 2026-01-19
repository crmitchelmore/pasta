import Combine
import Foundation

@preconcurrency import PastaCore
import PastaDetectors

final class AppViewModel: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []

    let database: DatabaseManager

    private let imageStorage: ImageStorageManager
    private let clipboardMonitor: ClipboardMonitor
    private let contentTypeDetector: ContentTypeDetector

    private var cancellables: Set<AnyCancellable> = []
    private let processingQueue = DispatchQueue(label: "pasta.app.processing")

    init() {
        self.database = (try? DatabaseManager()) ?? (try! DatabaseManager.inMemory())
        self.imageStorage = (try? ImageStorageManager()) ?? (try! ImageStorageManager(imagesDirectoryURL: .temporaryDirectory))

        self.clipboardMonitor = ClipboardMonitor()
        self.contentTypeDetector = ContentTypeDetector()

        subscribe()
        refresh()
        clipboardMonitor.start()
    }

    func refresh() {
        let latest = (try? database.fetchRecent(limit: 1_000)) ?? []
        DispatchQueue.main.async {
            self.entries = latest
        }
    }

    private func subscribe() {
        clipboardMonitor.publisher
            .sink { [weak self] entry in
                guard let self else { return }
                self.processingQueue.async {
                    let enriched: [ClipboardEntry]
                    do {
                        enriched = try self.enrich(entry)
                    } catch {
                        enriched = [entry]
                    }

                    for e in enriched {
                        try? self.database.insert(e)
                    }

                    self.refresh()
                }
            }
            .store(in: &cancellables)
    }

    private func enrich(_ entry: ClipboardEntry) throws -> [ClipboardEntry] {
        var entry = entry

        if entry.contentType == .image, let data = entry.rawData {
            entry.imagePath = try imageStorage.saveImage(data)
            entry.rawData = nil
            return [entry]
        }

        let output = contentTypeDetector.detect(in: entry.content)

        if output.primaryType == .envVarBlock, !output.splitEntries.isEmpty {
            return output.splitEntries.map { split in
                ClipboardEntry(
                    content: split.content,
                    contentType: split.contentType,
                    timestamp: entry.timestamp,
                    sourceApp: entry.sourceApp,
                    metadata: split.metadataJSON
                )
            }
        }

        entry.contentType = output.primaryType
        entry.metadata = output.metadataJSON

        return [entry]
    }
}
