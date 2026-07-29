import Foundation
import XCTest

@testable import GolfTrace

@MainActor
final class GolfKnowledgeControllerTests: XCTestCase {
  func testMigratesLegacyTranscriptOnlyEndpointToLocalVisualMCP() {
    let defaults = makeDefaults()
    defaults.set(
      "https://youtube-transcript-mcp.ergut.workers.dev/mcp",
      forKey: "GolfTrace.Knowledge.mcpEndpoint"
    )

    let controller = makeController(defaults: defaults)

    XCTAssertEqual(controller.mcpEndpoint, YouTubeFrameMCPClient.defaultEndpoint)
    XCTAssertEqual(
      defaults.string(forKey: "GolfTrace.Knowledge.mcpEndpoint"),
      YouTubeFrameMCPClient.defaultEndpoint
    )
  }

  func testPreservesEndpointExplicitlyChosenByUser() {
    let defaults = makeDefaults()
    let customEndpoint = "http://192.168.1.50:8765/mcp"
    defaults.set(customEndpoint, forKey: "GolfTrace.Knowledge.mcpEndpoint")

    let controller = makeController(defaults: defaults)

    XCTAssertEqual(controller.mcpEndpoint, customEndpoint)
  }

  func testRequiresSavedProfileBeforeAddingYouTubeLinks() {
    let controller = makeController(defaults: makeDefaults())

    controller.addURLs(from: "https://www.youtube.com/watch?v=Do05z9G-ev4")

    XCTAssertTrue(controller.profiles.isEmpty)
    XCTAssertTrue(controller.sources.isEmpty)
    XCTAssertTrue(controller.statusText.contains("บันทึกโปรไฟล์"))
  }

  func testProfileCanContainMultipleLinksAndReuseSourceAcrossProfiles() throws {
    let controller = makeController(defaults: makeDefaults())
    let tempoProfileID = try XCTUnwrap(
      controller.createProfile(name: "โปรจังหวะนุ่ม", teachingStyle: "เน้น tempo")
    )
    controller.addURLs(
      from: """
        https://www.youtube.com/watch?v=Do05z9G-ev4
        https://youtu.be/abcdefghijk
        """,
      to: tempoProfileID,
      processImmediately: false
    )

    XCTAssertEqual(controller.sources.count, 2)
    XCTAssertEqual(controller.selectedSources.count, 2)
    XCTAssertEqual(controller.selectedProfile?.sourceCount, 2)

    let ironProfileID = try XCTUnwrap(
      controller.createProfile(name: "โปรเหล็กแม่น", teachingStyle: "เน้นเหล็ก")
    )
    controller.addURLs(
      from: "https://www.youtube.com/watch?v=Do05z9G-ev4",
      to: ironProfileID,
      processImmediately: false
    )

    XCTAssertEqual(controller.sources.count, 2, "ลิงก์เดิมต้องแชร์ผลอ่าน ไม่สร้าง source ซ้ำ")
    XCTAssertEqual(controller.selectedSources.map(\.videoID), ["Do05z9G-ev4"])
    XCTAssertEqual(controller.selectedProfile?.sourceCount, 1)

    let sharedSourceID = try XCTUnwrap(controller.selectedSources.first?.id)
    controller.remove(sharedSourceID, from: ironProfileID)
    XCTAssertEqual(controller.sources.count, 2, "source ที่อีกโปรไฟล์ใช้อยู่ต้องไม่ถูกลบ")
    controller.selectProfile(tempoProfileID)
    XCTAssertEqual(controller.selectedSources.count, 2)
  }

  func testMigratesLegacySourceArrayIntoSavedProfileAndPersistsNewLibrary() throws {
    let defaults = makeDefaults()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfKnowledgeLegacyMigrationTests-\(UUID().uuidString)")
    let storeURL = root.appendingPathComponent("knowledge.json")
    let framesURL = root.appendingPathComponent("frames", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacySource = makeVisualSource()
    try JSONEncoder().encode([legacySource]).write(to: storeURL)

    let migrated = GolfKnowledgeController(
      aiSettings: GolfAISettings(defaults: defaults),
      defaults: defaults,
      storeURL: storeURL,
      framesRootURL: framesURL
    )

    XCTAssertEqual(migrated.profiles.count, 1)
    XCTAssertTrue(migrated.profiles[0].isLegacyImport)
    XCTAssertEqual(migrated.profiles[0].sourceIDs, [legacySource.id])
    XCTAssertEqual(migrated.selectedSources.map(\.id), [legacySource.id])
    XCTAssertTrue(migrated.statusText.contains("ข้อมูลเดิมยังอยู่ครบ"))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: storeURL.deletingPathExtension()
          .appendingPathExtension("legacy-v1.json").path
      )
    )

    let reloaded = GolfKnowledgeController(
      aiSettings: GolfAISettings(defaults: defaults),
      defaults: defaults,
      storeURL: storeURL,
      framesRootURL: framesURL
    )
    XCTAssertEqual(reloaded.profiles, migrated.profiles)
    XCTAssertEqual(reloaded.sources, migrated.sources)
    XCTAssertEqual(reloaded.selectedProfileID, migrated.selectedProfileID)
  }

  func testExcerptsUseOnlySelectedProfileAndCarryProfileAttribution() throws {
    let defaults = makeDefaults()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfKnowledgeProfileExcerptTests-\(UUID().uuidString)")
    let storeURL = root.appendingPathComponent("knowledge.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let tempoSource = makeVisualSource(videoID: "Do05z9G-ev4", title: "Tempo lesson")
    let ironSource = makeVisualSource(videoID: "abcdefghijk", title: "Iron lesson")
    let now = Date(timeIntervalSince1970: 1_000)
    let tempoProfile = AIGolfProKnowledgeProfile(
      id: UUID(),
      name: "โปร Tempo",
      teachingStyle: "จังหวะนุ่ม",
      sourceIDs: [tempoSource.id],
      createdAt: now,
      updatedAt: now,
      isLegacyImport: false
    )
    let ironProfile = AIGolfProKnowledgeProfile(
      id: UUID(),
      name: "โปร Iron",
      teachingStyle: "เน้นเหล็ก",
      sourceIDs: [ironSource.id],
      createdAt: now,
      updatedAt: now,
      isLegacyImport: false
    )
    try JSONEncoder().encode(
      TestStoredKnowledgeLibrary(
        schemaVersion: 2,
        profiles: [tempoProfile, ironProfile],
        sources: [tempoSource, ironSource]
      )
    ).write(to: storeURL)
    let controller = GolfKnowledgeController(
      aiSettings: GolfAISettings(defaults: defaults),
      defaults: defaults,
      storeURL: storeURL,
      framesRootURL: root.appendingPathComponent("frames", isDirectory: true)
    )

    var excerpts = controller.excerpts(
      for: "takeaway connected",
      clubFamily: "iron",
      cameraView: "downTheLine"
    )
    XCTAssertFalse(excerpts.isEmpty)
    XCTAssertTrue(excerpts.allSatisfy { $0.sourceID == tempoSource.id })
    XCTAssertTrue(excerpts.allSatisfy { $0.profileID == tempoProfile.id })
    XCTAssertTrue(excerpts.allSatisfy { $0.profileName == tempoProfile.name })
    XCTAssertTrue(excerpts.allSatisfy { $0.sourceTitle.hasPrefix("โปร Tempo · ") })

    controller.selectProfile(ironProfile.id)
    excerpts = controller.excerpts(
      for: "takeaway connected",
      clubFamily: "iron",
      cameraView: "downTheLine"
    )
    XCTAssertFalse(excerpts.isEmpty)
    XCTAssertTrue(excerpts.allSatisfy { $0.sourceID == ironSource.id })
    XCTAssertTrue(excerpts.allSatisfy { $0.profileName == "โปร Iron" })
  }

  func testTamperedStoredVideoIDCannotDeleteOutsideFrameRoot() throws {
    let defaults = makeDefaults()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfKnowledgeTraversalTests-\(UUID().uuidString)")
    let storeURL = root.appendingPathComponent("knowledge.json")
    let framesURL = root.appendingPathComponent("frames", isDirectory: true)
    let sentinelURL = root.appendingPathComponent("sentinel.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: sentinelURL)

    let source = YouTubeKnowledgeSource(
      id: UUID(),
      videoID: "../../sentinel.txt",
      canonicalURL: "https://www.youtube.com/watch?v=Do05z9G-ev4",
      title: "tampered",
      language: "en",
      providerName: "test",
      status: .ready,
      importedAt: nil,
      transcriptHash: nil,
      characterCount: 0,
      chunks: [],
      claims: []
    )
    try JSONEncoder().encode([source]).write(to: storeURL)

    let controller = GolfKnowledgeController(
      aiSettings: GolfAISettings(defaults: defaults),
      defaults: defaults,
      storeURL: storeURL,
      framesRootURL: framesURL
    )
    controller.remove(source.id)

    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
    XCTAssertTrue(controller.sources.isEmpty)
  }

  func testVLMDisabledDoesNotCallAnalyzer() async throws {
    let defaults = makeDefaults()
    let settings = GolfAISettings(defaults: defaults)
    settings.vlmEnabled = false
    settings.vlmEndpoint = "http://127.0.0.1:8000/v1/chat/completions"
    let analyzer = RecordingVisualClaimAnalyzer(mode: .success)
    let source = makeVisualSource()
    let controller = try makeController(
      defaults: defaults,
      settings: settings,
      source: source,
      vlmClient: analyzer
    )

    await controller.analyzeVisualGroundings(
      source.id,
      frameInputs: source.frames!.map(Self.frameInput)
    )

    let disabledCallCount = await analyzer.callCount()
    XCTAssertEqual(disabledCallCount, 0)
    let stored = try XCTUnwrap(controller.sources.first)
    XCTAssertEqual(stored.status, .ready)
    XCTAssertEqual(stored.frames, source.frames)
    XCTAssertEqual(stored.claims, source.claims)
    XCTAssertEqual(stored.visualGroundingStatus, .notRequested)
  }

  func testVLMFailurePreservesFramesClaimsAndLastGoodGrounding() async throws {
    let defaults = makeDefaults()
    let settings = GolfAISettings(defaults: defaults)
    settings.vlmEnabled = true
    settings.vlmEndpoint = "http://127.0.0.1:8000/v1/chat/completions"
    settings.vlmModel = "Qwen/Qwen3-VL-8B-Instruct"
    let analyzer = RecordingVisualClaimAnalyzer(mode: .failure)
    var source = makeVisualSource()
    let lastGood = Self.grounding(
      id: "last-good",
      claimID: source.claims[0].id,
      frameHashes: [source.frames![0].sha256]
    )
    source.visualGroundingStatus = .ready
    source.visualGroundings = [lastGood]
    let controller = try makeController(
      defaults: defaults,
      settings: settings,
      source: source,
      vlmClient: analyzer
    )

    await controller.analyzeVisualGroundings(
      source.id,
      frameInputs: source.frames!.map(Self.frameInput)
    )

    let failedCallCount = await analyzer.callCount()
    XCTAssertEqual(failedCallCount, 1)
    let stored = try XCTUnwrap(controller.sources.first)
    XCTAssertEqual(stored.status, .ready)
    XCTAssertEqual(stored.visualStatus, .ready)
    XCTAssertEqual(stored.frames, source.frames)
    XCTAssertEqual(stored.claims, source.claims)
    XCTAssertEqual(stored.visualGroundings, [lastGood])
    guard case .failed = stored.visualGroundingStatus else {
      return XCTFail("VLM failure must be separate from source and Apple Vision status")
    }
    XCTAssertTrue(controller.statusText.contains("Apple Vision ยังพร้อม"))
  }

  func testVLMMapsAtMostSixClaimsWithThreeLinkedFramesSequentially() async throws {
    let defaults = makeDefaults()
    let settings = GolfAISettings(defaults: defaults)
    settings.vlmEnabled = true
    settings.vlmEndpoint = "http://127.0.0.1:8000/v1/chat/completions"
    settings.vlmModel = "Qwen/Qwen3-VL-8B-Instruct"
    let analyzer = RecordingVisualClaimAnalyzer(mode: .success)
    let source = makeVisualSource(claimCount: 7, frameCount: 4)
    let controller = try makeController(
      defaults: defaults,
      settings: settings,
      source: source,
      vlmClient: analyzer
    )

    await controller.analyzeVisualGroundings(
      source.id,
      frameInputs: source.frames!.map(Self.frameInput)
    )

    let calls = await analyzer.recordedCalls()
    let maxConcurrentCalls = await analyzer.maximumConcurrentCalls()
    XCTAssertEqual(calls.count, 6)
    XCTAssertEqual(maxConcurrentCalls, 1)
    XCTAssertTrue(calls.allSatisfy { $0.claimIDs.count == 1 })
    XCTAssertTrue(calls.allSatisfy { $0.frameHashes.count == 3 })
    XCTAssertTrue(calls.allSatisfy { $0.transcript == "Keep the takeaway connected." })
    XCTAssertEqual(calls.map(\.claimIDs).flatMap { $0 }, source.claims.prefix(6).map(\.id))

    let stored = try XCTUnwrap(controller.sources.first)
    XCTAssertEqual(stored.visualGroundingStatus, .ready)
    XCTAssertEqual(stored.readyVisualGroundingCount, 6)
    XCTAssertEqual(
      Set(stored.visualGroundings?.flatMap(\.analyzedFrameHashes) ?? []),
      Set(source.frames!.prefix(3).map(\.sha256))
    )
  }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "GolfKnowledgeControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeController(defaults: UserDefaults) -> GolfKnowledgeController {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfKnowledgeControllerTests-\(UUID().uuidString)")
    return GolfKnowledgeController(
      aiSettings: GolfAISettings(defaults: defaults),
      defaults: defaults,
      storeURL: root.appendingPathComponent("knowledge.json"),
      framesRootURL: root.appendingPathComponent("frames", isDirectory: true)
    )
  }

  private func makeController(
    defaults: UserDefaults,
    settings: GolfAISettings,
    source: YouTubeKnowledgeSource,
    vlmClient: any VisualClaimAnalyzing
  ) throws -> GolfKnowledgeController {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfKnowledgeControllerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let storeURL = root.appendingPathComponent("knowledge.json")
    try JSONEncoder().encode([source]).write(to: storeURL)
    return GolfKnowledgeController(
      aiSettings: settings,
      defaults: defaults,
      vlmClient: vlmClient,
      storeURL: storeURL,
      framesRootURL: root.appendingPathComponent("frames", isDirectory: true)
    )
  }

  private func makeVisualSource(
    claimCount: Int = 1,
    frameCount: Int = 1,
    videoID: String = "Do05z9G-ev4",
    title: String = "Golf lesson"
  ) -> YouTubeKnowledgeSource {
    let claims = (0..<claimCount).map { index in
      GolfTeachingClaim(
        id: "claim-\(index)",
        text: "Keep the takeaway connected \(index)",
        sourceChunkID: "chunk-1",
        startSeconds: 12,
        clubFamilies: ["iron"],
        cameraViews: ["downTheLine"],
        topics: ["takeaway"],
        limitations: ["Single camera view"]
      )
    }
    let claimIDs = claims.map(\.id)
    let frames = (0..<frameCount).map { index in
      ReferenceFrameObservation(
        id: "frame-\(index)",
        timestampSeconds: 12 + Double(index),
        relativeImagePath: "\(videoID)/private-\(index).jpg",
        mimeType: "image/jpeg",
        sha256: String(repeating: String(index + 1), count: 64),
        pixelWidth: 640,
        pixelHeight: 360,
        joints: [],
        metrics: Self.emptyMetrics,
        recognizedText: ["Takeaway"],
        linkedClaimIDs: claimIDs,
        qualityFlags: [],
        poseModelVersion: "Vision test"
      )
    }
    return YouTubeKnowledgeSource(
      id: UUID(),
      videoID: videoID,
      canonicalURL: "https://www.youtube.com/watch?v=\(videoID)",
      title: title,
      language: "en",
      providerName: "test",
      status: .ready,
      importedAt: Date(timeIntervalSince1970: 100),
      transcriptHash: "transcript-hash",
      characterCount: 28,
      chunks: [
        YouTubeTranscriptChunk(
          id: "chunk-1",
          startSeconds: 12,
          endSeconds: 18,
          text: "Keep the takeaway connected."
        )
      ],
      claims: claims,
      visualStatus: .ready,
      frames: frames
    )
  }

  private static func frameInput(_ frame: ReferenceFrameObservation) -> GX10VLMFrameInput {
    GX10VLMFrameInput(
      data: Data([0x01, 0x02, 0x03]),
      mimeType: frame.mimeType,
      timestampSeconds: frame.timestampSeconds,
      sha256: frame.sha256
    )
  }

  private static func grounding(
    id: String,
    claimID: String,
    frameHashes: [String]
  ) -> VisualClaimGrounding {
    VisualClaimGrounding(
      id: id,
      visiblePeople: 1,
      swingPhase: "takeaway",
      clubVisible: true,
      onScreenGuides: [],
      description: "Hands and club move together in this view.",
      supportedClaimIDs: [claimID],
      contradictedClaimIDs: [],
      confidence: 0.8,
      limitations: ["Single 2D camera view"],
      model: "Qwen/Qwen3-VL-8B-Instruct",
      analyzedFrameHashes: frameHashes,
      analyzedAt: Date(timeIntervalSince1970: 200)
    )
  }

  private static let emptyMetrics = ReferencePoseMetrics(
    handCenterX: nil,
    handCenterY: nil,
    headCenterX: nil,
    headCenterY: nil,
    pelvisCenterX: nil,
    pelvisCenterY: nil,
    torsoTilt2DDegrees: nil,
    shoulderSpan2D: nil,
    hipSpan2D: nil,
    leftElbowAngle2DDegrees: nil,
    rightElbowAngle2DDegrees: nil,
    leftKneeAngle2DDegrees: nil,
    rightKneeAngle2DDegrees: nil
  )

  private struct TestStoredKnowledgeLibrary: Codable {
    let schemaVersion: Int
    let profiles: [AIGolfProKnowledgeProfile]
    let sources: [YouTubeKnowledgeSource]
  }
}

private actor RecordingVisualClaimAnalyzer: VisualClaimAnalyzing {
  enum Mode: Equatable, Sendable {
    case success
    case failure
  }

  struct Call: Sendable {
    let frameHashes: [String]
    let transcript: String
    let claimIDs: [String]
  }

  private let mode: Mode
  private var calls: [Call] = []
  private var activeCalls = 0
  private var maxActiveCalls = 0

  init(mode: Mode) {
    self.mode = mode
  }

  func analyze(
    frames: [GX10VLMFrameInput],
    transcript: String,
    claims: [GolfTeachingClaim],
    endpoint: URL,
    model: String
  ) async throws -> VisualClaimGrounding {
    activeCalls += 1
    maxActiveCalls = max(maxActiveCalls, activeCalls)
    defer { activeCalls -= 1 }
    calls.append(
      Call(
        frameHashes: frames.map(\.sha256),
        transcript: transcript,
        claimIDs: claims.map(\.id)
      )
    )

    if mode == .failure { throw VisualClaimAnalyzerTestError.failed }
    let claimID = claims.first?.id ?? "missing"
    return VisualClaimGrounding(
      id: "grounding-\(claimID)",
      visiblePeople: 1,
      swingPhase: "takeaway",
      clubVisible: true,
      onScreenGuides: [],
      description: "The frame is consistent with this claim.",
      supportedClaimIDs: [claimID],
      contradictedClaimIDs: [],
      confidence: 0.75,
      limitations: ["Single 2D camera view"],
      model: model,
      analyzedFrameHashes: frames.map(\.sha256),
      analyzedAt: Date(timeIntervalSince1970: 300)
    )
  }

  func callCount() -> Int { calls.count }
  func recordedCalls() -> [Call] { calls }
  func maximumConcurrentCalls() -> Int { maxActiveCalls }
}

private enum VisualClaimAnalyzerTestError: LocalizedError {
  case failed

  var errorDescription: String? { "VLM test failure" }
}
