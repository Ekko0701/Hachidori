// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hachidori",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
        .executable(name: "Hachidori", targets: ["HachidoriApp"]),
    ],
    dependencies: [
        // Phase 1: proxy engine
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // Phase 2: TLS MITM
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        // Phase 5 (persistence) will add:
        //   .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "ProxyCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            // NIO channel-handler glue is written against the classic (non-strict)
            // concurrency model; keep this target in Swift 5 language mode for now.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "HachidoriApp",
            dependencies: ["ProxyCore"]
        ),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: [
                "ProxyCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
