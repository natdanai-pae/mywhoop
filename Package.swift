// swift-tools-version:6.0
import PackageDescription

// GenieMax Core — the pure, deterministic health-analytics engine: recovery, sleep staging, HRV, strain/load,
// nap detection, and the E2EE vault model. No UI, no BLE, no device protocol — just the math, with golden-vector
// tests. Consumable as a SwiftPM dependency.
let package = Package(
  name: "GenieMax",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "GenieMax", targets: ["GenieMax"]),
  ],
  dependencies: [
    // Argon2id (memory-hard KDF) + XChaCha20-Poly1305 for the E2EE vault. swift-sodium vendors libsodium.
    .package(url: "https://github.com/jedisct1/swift-sodium", from: "0.9.1"),
  ],
  targets: [
    .target(name: "GenieMax", dependencies: [.product(name: "Sodium", package: "swift-sodium")]),
    .testTarget(name: "GenieMaxTests", dependencies: ["GenieMax"], resources: [.copy("Fixtures")]),
  ]
)
