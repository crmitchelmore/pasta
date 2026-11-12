import Foundation
import GRDB
import XCTest
@testable import PastaCore

final class DatabaseRecoveryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastaRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testCorruptionIsQuarantinedWithSidecarsAndReplaced() throws {
        let directory = try temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("pasta.sqlite")
        let original = Data("This is a damaged SQLite database; preserve it for recovery.".utf8)
        try original.write(to: databaseURL)

        let database = try DatabaseManager(databaseURL: databaseURL)
        let quarantines = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pasta.sqlite.corrupt-") }
        XCTAssertEqual(quarantines.count, 1)
        let quarantine = try XCTUnwrap(quarantines.first)
        XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("pasta.sqlite")), original)
        XCTAssertEqual(try database.countEntries(), 0)
        let entry = ClipboardEntry(content: "captured after recovery", contentType: .text)
        try database.insert(entry)
        XCTAssertEqual(try database.fetch(id: entry.id)?.content, entry.content)

        let sidecarDirectory = try temporaryDirectory()
        let sidecarURL = sidecarDirectory.appendingPathComponent("pasta.sqlite")
        let suffixes = ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes {
            try Data("recoverable bytes: \(suffix)".utf8).write(to: URL(fileURLWithPath: sidecarURL.path + suffix))
        }
        let sidecarQuarantine = try DatabaseManager.quarantineCorruptedDatabase(databaseURL: sidecarURL)
        for suffix in suffixes {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path + suffix))
            XCTAssertEqual(
                try Data(contentsOf: sidecarQuarantine.appendingPathComponent("pasta.sqlite" + suffix)),
                Data("recoverable bytes: \(suffix)".utf8)
            )
        }
    }

    func testOnlyIntegrityErrorsPermitRecovery() throws {
        for code in [ResultCode.SQLITE_CORRUPT, .SQLITE_NOTADB] {
            XCTAssertTrue(DatabaseManager.isCorruptionError(DatabaseError(resultCode: code)))
        }
        for code in [ResultCode.SQLITE_FULL, .SQLITE_IOERR, .SQLITE_BUSY, .SQLITE_CANTOPEN, .SQLITE_ERROR] {
            XCTAssertFalse(DatabaseManager.isCorruptionError(
                DatabaseError(resultCode: code, message: "Could not access corrupt database")
            ))
        }
        XCTAssertFalse(DatabaseManager.isCorruptionError(NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError,
            userInfo: [NSLocalizedDescriptionKey: "Not a database: corrupt/malformed storage"]
        )))

        // An unopenable path is an availability failure: init throws and nothing is moved.
        let directory = try temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("pasta.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: false)
        let sentinel = databaseURL.appendingPathComponent("preserve-me")
        let original = Data("existing storage contents".utf8)
        try original.write(to: sentinel)
        XCTAssertThrowsError(try DatabaseManager(databaseURL: databaseURL))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["pasta.sqlite"])
    }
}
