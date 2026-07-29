import CoreGraphics
import Foundation
import ImageIO
import Vision

enum ReferenceFramePoseError: LocalizedError, Equatable {
  case invalidImage
  case imageDimensionsTooLarge
  case visionFailed

  var errorDescription: String? {
    switch self {
    case .invalidImage: return "ภาพจาก MCP เปิดไม่ได้"
    case .imageDimensionsTooLarge: return "ภาพจาก MCP มีจำนวนพิกเซลเกินขอบเขตที่ปลอดภัย"
    case .visionFailed: return "Apple Vision อ่านท่าทางจากภาพนี้ไม่ได้"
    }
  }
}

/// อ่านร่างกายจากภาพอ้างอิงแยกจาก scheduler ของกล้องสด
/// จึงไม่ทำให้การจับวง 120 FPS หรือ state ของวงจริงปะปนกับวิดีโอสอน
actor ReferenceFramePoseAnalyzer {
  func analyze(
    frameData: Data,
    mimeType: String,
    timestampSeconds: Double,
    relativeImagePath: String,
    linkedClaimIDs: [String],
    sha256: String
  ) async throws -> ReferenceFrameObservation {
    try await Task.detached(priority: .utility) {
      try Self.performAnalysis(
        frameData: frameData,
        mimeType: mimeType,
        timestampSeconds: timestampSeconds,
        relativeImagePath: relativeImagePath,
        linkedClaimIDs: linkedClaimIDs,
        sha256: sha256
      )
    }.value
  }

  private static func performAnalysis(
    frameData: Data,
    mimeType: String,
    timestampSeconds: Double,
    relativeImagePath: String,
    linkedClaimIDs: [String],
    sha256: String
  ) throws -> ReferenceFrameObservation {
    guard let source = CGImageSourceCreateWithData(frameData as CFData, nil) else {
      throw ReferenceFramePoseError.invalidImage
    }
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0,
      height > 0
    else { throw ReferenceFramePoseError.invalidImage }
    guard width <= 4_096, height <= 4_096, width * height <= 16_777_216 else {
      throw ReferenceFramePoseError.imageDimensionsTooLarge
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ReferenceFramePoseError.invalidImage
    }

    let request = VNDetectHumanBodyPoseRequest()
    let textRequest = VNRecognizeTextRequest()
    textRequest.recognitionLevel = .accurate
    textRequest.usesLanguageCorrection = true
    textRequest.minimumTextHeight = 0.012
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
    do {
      try handler.perform([request, textRequest])
    } catch {
      throw ReferenceFramePoseError.visionFailed
    }

    let observations = request.results ?? []
    var flags: [String] = []
    if observations.isEmpty { flags.append("ไม่พบร่างกาย") }
    if observations.count > 1 { flags.append("พบหลายคน ต้องเลือกนักกอล์ฟก่อนใช้เป็น guideline") }

    let recognized = try observations.first?.recognizedPoints(.all) ?? [:]
    let namedJoints = jointNames.compactMap { jointName, stableName -> ReferencePoseJoint? in
      guard let point = recognized[jointName], point.confidence >= 0.25 else { return nil }
      return ReferencePoseJoint(
        name: stableName,
        x: Double(point.location.x),
        y: Double(point.location.y),
        confidence: Double(point.confidence)
      )
    }
    if namedJoints.filter({ $0.confidence >= 0.55 }).count < 8, !observations.isEmpty {
      flags.append("จุดร่างกายที่มั่นใจยังไม่พอ")
    }

    let points = Dictionary(uniqueKeysWithValues: namedJoints.map { ($0.name, $0) })
    let metrics = metrics(from: points)
    let recognizedText = recognizedText(from: textRequest.results ?? [])

    return ReferenceFrameObservation(
      id: "frame-\(sha256.prefix(20))-\(Int((timestampSeconds * 1_000).rounded()))",
      timestampSeconds: timestampSeconds,
      relativeImagePath: relativeImagePath,
      mimeType: mimeType,
      sha256: sha256,
      pixelWidth: image.width,
      pixelHeight: image.height,
      joints: namedJoints.sorted { $0.name < $1.name },
      metrics: metrics,
      recognizedText: recognizedText,
      linkedClaimIDs: linkedClaimIDs.sorted(),
      qualityFlags: flags,
      poseModelVersion: "Apple Vision body-pose revision \(request.revision)"
    )
  }

  private static func recognizedText(
    from observations: [VNRecognizedTextObservation]
  ) -> [String] {
    var values: [String] = []
    var seen: Set<String> = []
    var totalCharacters = 0

    for observation in observations.prefix(40) {
      guard let candidate = observation.topCandidates(1).first,
        candidate.confidence >= 0.45
      else { continue }
      let normalized = candidate.string
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      guard normalized.count >= 2, normalized.count <= 160 else { continue }
      let deduplicationKey = normalized.lowercased()
      guard !seen.contains(deduplicationKey), totalCharacters + normalized.count <= 800 else {
        continue
      }
      values.append(normalized)
      seen.insert(deduplicationKey)
      totalCharacters += normalized.count
      if values.count == 16 { break }
    }
    return values
  }

  private static func metrics(
    from joints: [String: ReferencePoseJoint]
  ) -> ReferencePoseMetrics {
    let hands = center(of: ["leftWrist", "rightWrist"], in: joints)
    let head = center(
      of: ["nose", "leftEye", "rightEye", "leftEar", "rightEar"],
      in: joints,
      minimumCount: 1
    )
    let pelvis = center(of: ["leftHip", "rightHip"], in: joints)
    let shoulders = center(of: ["leftShoulder", "rightShoulder"], in: joints)

    let torsoTilt: Double?
    if let shoulders, let pelvis {
      torsoTilt = atan2(shoulders.x - pelvis.x, shoulders.y - pelvis.y) * 180 / .pi
    } else {
      torsoTilt = nil
    }

    return ReferencePoseMetrics(
      handCenterX: hands?.x,
      handCenterY: hands?.y,
      headCenterX: head?.x,
      headCenterY: head?.y,
      pelvisCenterX: pelvis?.x,
      pelvisCenterY: pelvis?.y,
      torsoTilt2DDegrees: torsoTilt,
      shoulderSpan2D: distance("leftShoulder", "rightShoulder", in: joints),
      hipSpan2D: distance("leftHip", "rightHip", in: joints),
      leftElbowAngle2DDegrees: angle("leftShoulder", "leftElbow", "leftWrist", in: joints),
      rightElbowAngle2DDegrees: angle(
        "rightShoulder", "rightElbow", "rightWrist", in: joints),
      leftKneeAngle2DDegrees: angle("leftHip", "leftKnee", "leftAnkle", in: joints),
      rightKneeAngle2DDegrees: angle("rightHip", "rightKnee", "rightAnkle", in: joints)
    )
  }

  private static func center(
    of names: [String],
    in joints: [String: ReferencePoseJoint],
    minimumCount: Int = 2
  ) -> (x: Double, y: Double)? {
    let values = names.compactMap { name -> ReferencePoseJoint? in
      guard let joint = joints[name], joint.confidence >= 0.55 else { return nil }
      return joint
    }
    guard values.count >= minimumCount else { return nil }
    return (
      values.map(\.x).reduce(0, +) / Double(values.count),
      values.map(\.y).reduce(0, +) / Double(values.count)
    )
  }

  private static func distance(
    _ first: String,
    _ second: String,
    in joints: [String: ReferencePoseJoint]
  ) -> Double? {
    guard let a = usable(first, in: joints), let b = usable(second, in: joints) else { return nil }
    return hypot(a.x - b.x, a.y - b.y)
  }

  private static func angle(
    _ first: String,
    _ vertex: String,
    _ third: String,
    in joints: [String: ReferencePoseJoint]
  ) -> Double? {
    guard let a = usable(first, in: joints),
      let b = usable(vertex, in: joints),
      let c = usable(third, in: joints)
    else { return nil }

    let firstVector = (x: a.x - b.x, y: a.y - b.y)
    let secondVector = (x: c.x - b.x, y: c.y - b.y)
    let denominator = hypot(firstVector.x, firstVector.y) * hypot(secondVector.x, secondVector.y)
    guard denominator > 0.000_001 else { return nil }
    let cosine = max(
      -1,
      min(1, (firstVector.x * secondVector.x + firstVector.y * secondVector.y) / denominator)
    )
    return acos(cosine) * 180 / .pi
  }

  private static func usable(
    _ name: String,
    in joints: [String: ReferencePoseJoint]
  ) -> ReferencePoseJoint? {
    guard let joint = joints[name], joint.confidence >= 0.55 else { return nil }
    return joint
  }

  private static let jointNames: [(VNHumanBodyPoseObservation.JointName, String)] = [
    (.nose, "nose"),
    (.leftEye, "leftEye"),
    (.rightEye, "rightEye"),
    (.leftEar, "leftEar"),
    (.rightEar, "rightEar"),
    (.neck, "neck"),
    (.leftShoulder, "leftShoulder"),
    (.rightShoulder, "rightShoulder"),
    (.leftElbow, "leftElbow"),
    (.rightElbow, "rightElbow"),
    (.leftWrist, "leftWrist"),
    (.rightWrist, "rightWrist"),
    (.root, "root"),
    (.leftHip, "leftHip"),
    (.rightHip, "rightHip"),
    (.leftKnee, "leftKnee"),
    (.rightKnee, "rightKnee"),
    (.leftAnkle, "leftAnkle"),
    (.rightAnkle, "rightAnkle"),
  ]
}
