// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pasta",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PastaApp", targets: ["PastaApp"]),
        .library(name: "PastaCore", targets: ["PastaCore"]),
        .library(name: "PastaUI", targets: ["PastaUI"]),
        .library(name: "PastaDetectors", targets: ["PastaDetectors"])
    ],
    dependencies: [
        // SQLite database
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        // Global keyboard shortcuts (modern, App Store compatible)
        // Pin to 2.0.x - versions 2.1+ require Swift tools 6.1
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.1"),
        // Fuzzy text search
        .package(url: "https://github.com/krisk/fuse-swift.git", from: "1.4.0")
    ],
    targets: [
        // Main application
        .executableTarget(
            name: "PastaApp",
            dependencies: [
                "PastaCore",
                "PastaUI",
                "PastaDetectors",
                "KeyboardShortcuts"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        
        // Core business logic, models, and services
        .target(
            name: "PastaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Fuse", package: "fuse-swift"),
                "KeyboardShortcuts"
            ]
        ),
        
        // SwiftUI views and view models
        .target(
            name: "PastaUI",
            dependencies: [
                "PastaCore",
                "PastaDetectors",
                "KeyboardShortcuts"
            ]
        ),
        
        // Content type detection algorithms
        .target(
            name: "PastaDetectors",
            dependencies: [
                "PastaCore",
                .product(name: "Fuse", package: "fuse-swift")
            ]
        ),
        
        // Tests
        .testTarget(
            name: "PastaCoreTests",
            dependencies: [
                "PastaCore",
                "KeyboardShortcuts"
            ]
        ),
        .testTarget(
            name: "PastaDetectorsTests",
            dependencies: ["PastaDetectors"]
        )
    ]
)
