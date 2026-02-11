// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pasta",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "PastaApp", targets: ["PastaApp"]),
        .library(name: "PastaCore", targets: ["PastaCore"]),
        .library(name: "PastaUI", targets: ["PastaUI"]),
        .library(name: "PastaDetectors", targets: ["PastaDetectors"]),
        .library(name: "PastaSync", targets: ["PastaSync"])
    ],
    dependencies: [
        // SQLite database
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        // Global keyboard shortcuts (Carbon-based, no resource bundle)
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.0"),
        // Auto-updates
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        // Crash reporting
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.40.0")
    ],
    targets: [
        // Main application
        .executableTarget(
            name: "PastaApp",
            dependencies: [
                "PastaCore",
                "PastaUI",
                "PastaDetectors",
                "PastaSync",
                "HotKey",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        
        // Core business logic, models, and services
        .target(
            name: "PastaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        
        // SwiftUI views and view models
        .target(
            name: "PastaUI",
            dependencies: [
                "PastaCore",
                "PastaDetectors"
            ]
        ),
        
        // Content type detection algorithms
        .target(
            name: "PastaDetectors",
            dependencies: [
                "PastaCore"
            ]
        ),
        
        // CloudKit sync for macOS and iOS
        .target(
            name: "PastaSync",
            dependencies: [
                "PastaCore"
            ]
        ),
        
        // Tests
        .testTarget(
            name: "PastaCoreTests",
            dependencies: [
                "PastaCore"
            ]
        ),
        .testTarget(
            name: "PastaDetectorsTests",
            dependencies: ["PastaDetectors"]
        )
    ]
)
