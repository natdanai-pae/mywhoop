import CoreMedia
import Foundation
import Vision

/// ระดับความน่าเชื่อถือของค่าหนึ่งค่า ไม่ใช่คะแนนคุณภาพวงสวิงของผู้เล่น
enum SwingMetricQuality: String, Equatable {
  case good
  case limited
  case unavailable

  var displayName: String {
    switch self {
    case .good:
      return "ข้อมูลชัดเจน"
    case .limited:
      return "ข้อมูลพอใช้"
    case .unavailable:
      return "ข้อมูลไม่พอ"
    }
  }
}

/// ค่าที่วัดได้พร้อมหลักฐานว่าติดตามร่างกายได้ต่อเนื่องเพียงใด
///
/// `value == nil` หมายความว่าแอปตั้งใจไม่เดาค่าเมื่อหลักฐานไม่พอ
struct SwingMetricReading: Equatable {
  let value: Double?
  let quality: SwingMetricQuality
  let trackedFraction: Double
  let reason: String

  var isAvailable: Bool { value != nil }
}

/// ผลวิเคราะห์วงสวิงจากภาพสองมิติ ค่าระยะและความเร็วใช้ "ความยาวลำตัว"
/// เป็นหน่วย จึงไม่เปลี่ยนเพียงเพราะผู้เล่นยืนใกล้หรือไกลกล้องขึ้น
struct SwingAnalysisSummary: Equatable {
  let handPathBodyLengths: SwingMetricReading
  let peakHandSpeedBodyLengthsPerSecond: SwingMetricReading
  let addressTorsoTiltDegrees: SwingMetricReading
  let torsoTiltChangeDegrees: SwingMetricReading
  let shoulderSpanReductionPercent: SwingMetricReading
  let hipSpanReductionPercent: SwingMetricReading
  let backswingSeconds: SwingMetricReading
  let downswingSeconds: SwingMetricReading
  let handTempoRatio: SwingMetricReading

  let quality: SwingMetricQuality
  let trackedFraction: Double
  let reason: String
}

/// เก็บผลท่าทางย้อนหลังช่วงสั้น ๆ แล้วสรุปค่าที่วัดจากวงสวิงเมื่อ session จบ
///
/// ค่ามุมและ span เป็นภาพฉายสองมิติ (projected proxy) ไม่ใช่มุมหมุนสามมิติจริง
/// และเส้นทางมือยังเป็นกึ่งกลางข้อมือ ไม่ใช่หัวไม้
final class SwingMetricsAnalyzer {
  private struct FrameSample {
    let pose: PoseFrame?
    let handCenter: CGPoint?
    let normalizedHandSpeed: Double?
    let time: TimeInterval
  }

  private struct BodyMeasurement {
    let time: TimeInterval
    let torsoLength: Double
    let torsoTiltDegrees: Double
    let shoulderSpan: Double
    let hipSpan: Double
  }

  private struct TimedValue {
    let time: TimeInterval
    let value: Double
  }

  private struct TempoResult {
    let backswingSeconds: Double
    let downswingSeconds: Double
    let ratio: Double
    let trackedFraction: Double
    let sampleCount: Int
    let reason: String
  }

  let maximumHistoryDuration: TimeInterval
  let minimumJointConfidence: Float
  let minimumTrackedFraction: Double

  private let baselineDuration: TimeInterval
  private var samples: [FrameSample] = []
  private var sampleHeadIndex = 0

  private(set) var bufferedFrameCount = 0

  init(
    maximumHistoryDuration: TimeInterval = 6.0,
    minimumJointConfidence: Float = 0.55,
    minimumTrackedFraction: Double = 0.55,
    baselineDuration: TimeInterval = 0.60
  ) {
    self.maximumHistoryDuration = max(0.5, maximumHistoryDuration)
    // Metrics must never accept a joint below the agreed 55% confidence floor.
    self.minimumJointConfidence = min(1, max(0.55, minimumJointConfidence))
    self.minimumTrackedFraction = min(1, max(0.05, minimumTrackedFraction))
    self.baselineDuration = max(0.20, baselineDuration)
  }

  func reset() {
    samples.removeAll(keepingCapacity: true)
    sampleHeadIndex = 0
    bufferedFrameCount = 0
  }

  /// เพิ่ม pose และ motion ของเฟรมเดียวกันเข้า rolling window หกวินาที
  func consume(pose: PoseFrame?, motion: SwingMotionFrame) {
    guard let time = usableTime(pose?.timestamp ?? motion.timestamp) else { return }

    if let last = samples.last {
      if time < last.time { return }
      if time == last.time {
        samples[samples.count - 1] = FrameSample(
          pose: pose,
          handCenter: motion.handCenter,
          normalizedHandSpeed: motion.normalizedHandSpeed,
          time: time
        )
        bufferedFrameCount = samples.count - sampleHeadIndex
        return
      }
    }

    samples.append(
      FrameSample(
        pose: pose,
        handCenter: motion.handCenter,
        normalizedHandSpeed: motion.normalizedHandSpeed,
        time: time
      ))
    let cutoff = time - maximumHistoryDuration
    while sampleHeadIndex < samples.count, samples[sampleHeadIndex].time < cutoff {
      sampleHeadIndex += 1
    }
    if sampleHeadIndex == samples.count {
      samples.removeAll(keepingCapacity: true)
      sampleHeadIndex = 0
    } else if sampleHeadIndex >= 256, sampleHeadIndex * 2 >= samples.count {
      samples.removeFirst(sampleHeadIndex)
      sampleHeadIndex = 0
    }
    bufferedFrameCount = samples.count - sampleHeadIndex
  }

  /// API เดิมสำหรับหน้าจอและข้อมูลย้อนหลัง ส่วนเส้นทาง AI ใช้ `finalizeWithEvidence`
  /// เพื่อรับทั้งผลสรุปและข้อมูลรายเวลาที่ Mac สกัดแล้ว
  func finalize(session: SwingSessionSummary) -> SwingAnalysisSummary {
    buildSummary(session: session)
  }

  /// สร้างผลสรุปและ feature packet จาก rolling window ชุดเดียวกัน
  /// เพื่อให้เวลา จุดร่างกาย และตัวเลขที่ส่งให้ AI ตรงกับผลบนหน้าจอ
  func finalizeWithEvidence(
    session: SwingSessionSummary,
    captureFPS: Double?,
    poseAnalysisFPS: Double?,
    cameraView: String
  ) -> SwingAnalysisResult {
    let summary = buildSummary(session: session)
    return SwingAnalysisResult(
      summary: summary,
      evidencePacket: makeEvidencePacket(
        session: session,
        summary: summary,
        captureFPS: captureFPS,
        poseAnalysisFPS: poseAnalysisFPS,
        cameraView: cameraView
      )
    )
  }

  /// สร้างผลวิเคราะห์จาก session ที่เพิ่งจบ โดยคืน `nil` เฉพาะรายค่าที่หลักฐานไม่พอ
  private func buildSummary(session: SwingSessionSummary) -> SwingAnalysisSummary {
    guard
      let startTime = usableTime(session.startTimestamp),
      let endTime = usableTime(session.endTimestamp),
      endTime > startTime
    else {
      return whollyUnavailable(reason: "เวลาเริ่มหรือเวลาจบวงสวิงไม่ถูกต้อง")
    }

    let activeSamples = self.activeSamples
    let sessionSamples = activeSamples.filter { $0.time >= startTime && $0.time <= endTime }
    let baselineSamples = activeSamples.filter {
      $0.time >= startTime - baselineDuration && $0.time <= startTime
    }
    let contextSamples = activeSamples.filter {
      $0.time >= startTime - baselineDuration && $0.time <= endTime
    }

    guard sessionSamples.count >= 3 else {
      return whollyUnavailable(reason: "มีเฟรมในช่วงวงสวิงน้อยเกินไป")
    }

    let sessionBodies = bodyMeasurements(in: sessionSamples)
    let baselineBodies = bodyMeasurements(in: baselineSamples)
    let contextBodies = bodyMeasurements(in: contextSamples)
    let bodyTrackedFraction = fraction(sessionBodies.count, of: sessionSamples.count)
    let bodyScale = robustMedian(contextBodies.map(\.torsoLength).filter { $0 > 0.01 })

    let motionMetrics = normalizedMotionMetrics(
      session: session,
      sessionSamples: sessionSamples,
      bodyScale: bodyScale,
      bodyTrackedFraction: bodyTrackedFraction
    )
    let torsoMetrics = torsoMetrics(
      baselineBodies: baselineBodies,
      sessionBodies: sessionBodies,
      baselineFrameCount: baselineSamples.count,
      sessionFrameCount: sessionSamples.count
    )
    let shoulderReduction = spanReductionMetric(
      baselineSamples: baselineSamples,
      sessionSamples: sessionSamples,
      jointNames: (.leftShoulder, .rightShoulder),
      label: "แนวไหล่"
    )
    let hipReduction = spanReductionMetric(
      baselineSamples: baselineSamples,
      sessionSamples: sessionSamples,
      jointNames: (.leftHip, .rightHip),
      label: "แนวสะโพก"
    )
    let tempo = tempoMetrics(
      session: session,
      sessionSamples: sessionSamples,
      bodyScale: bodyScale,
      bodyTrackedFraction: bodyTrackedFraction
    )

    let tempoReadings:
      (
        backswing: SwingMetricReading,
        downswing: SwingMetricReading,
        ratio: SwingMetricReading
      )
    if let tempo {
      let quality = metricQuality(
        trackedFraction: tempo.trackedFraction,
        sampleCount: tempo.sampleCount
      )
      tempoReadings = (
        availableReading(
          tempo.backswingSeconds,
          quality: quality,
          trackedFraction: tempo.trackedFraction,
          reason: tempo.reason
        ),
        availableReading(
          tempo.downswingSeconds,
          quality: quality,
          trackedFraction: tempo.trackedFraction,
          reason: tempo.reason
        ),
        availableReading(
          tempo.ratio,
          quality: quality,
          trackedFraction: tempo.trackedFraction,
          reason: tempo.reason
        )
      )
    } else {
      let handFraction = trackedHandFraction(in: sessionSamples)
      let trackedFraction = min(bodyTrackedFraction, handFraction)
      let unavailable = unavailableReading(
        trackedFraction: trackedFraction,
        reason: "ไม่พบจุดเปลี่ยนจากแบ็กสวิงเป็นดาวน์สวิงที่ชัดเจน"
      )
      tempoReadings = (unavailable, unavailable, unavailable)
    }

    let overallQuality: SwingMetricQuality
    let overallReason: String
    if sessionBodies.count < 3 || bodyTrackedFraction < minimumTrackedFraction {
      overallQuality = .unavailable
      overallReason = "ข้อมูลข้อต่อที่มั่นใจอย่างน้อย 55% ไม่ต่อเนื่องพอ"
    } else if bodyTrackedFraction >= 0.80 && sessionBodies.count >= 8 {
      overallQuality = .good
      overallReason = "ติดตามไหล่และสะโพกได้ต่อเนื่อง"
    } else {
      overallQuality = .limited
      overallReason = "ติดตามไหล่และสะโพกได้บางช่วง จึงแสดงเฉพาะค่าที่มีหลักฐานพอ"
    }

    return SwingAnalysisSummary(
      handPathBodyLengths: motionMetrics.path,
      peakHandSpeedBodyLengthsPerSecond: motionMetrics.peakSpeed,
      addressTorsoTiltDegrees: torsoMetrics.addressTilt,
      torsoTiltChangeDegrees: torsoMetrics.tiltChange,
      shoulderSpanReductionPercent: shoulderReduction,
      hipSpanReductionPercent: hipReduction,
      backswingSeconds: tempoReadings.backswing,
      downswingSeconds: tempoReadings.downswing,
      handTempoRatio: tempoReadings.ratio,
      quality: overallQuality,
      trackedFraction: bodyTrackedFraction,
      reason: overallReason
    )
  }

  private func makeEvidencePacket(
    session: SwingSessionSummary,
    summary: SwingAnalysisSummary,
    captureFPS: Double?,
    poseAnalysisFPS: Double?,
    cameraView: String
  ) -> SwingEvidencePacket {
    let startTime = usableTime(session.startTimestamp) ?? 0
    let rawEndTime = usableTime(session.endTimestamp) ?? (startTime + max(0.001, session.duration))
    let endTime = max(startTime + 0.001, rawEndTime)
    let durationMs = max(1, milliseconds(endTime - startTime))
    let contextStartTime = startTime - baselineDuration
    let contextStartMs = min(0, milliseconds(contextStartTime - startTime))
    let activeSamples = self.activeSamples
    let sessionSamples = activeSamples.filter { $0.time >= startTime && $0.time <= endTime }
    let contextSamples = activeSamples.filter { $0.time >= contextStartTime && $0.time <= endTime }
    let selectedSamples = uniformlyDownsampled(
      contextSamples,
      maximumCount: SwingEvidencePacket.maximumTimelineFrames
    )
    let timeline = selectedSamples.map { evidenceFrame(from: $0, swingStartTime: startTime) }
    let poseTimes = sessionSamples.compactMap { $0.pose == nil ? nil : $0.time }
    let sessionPoseFPS: Double? = {
      guard let first = poseTimes.first, let last = poseTimes.last,
        poseTimes.count > 1, last > first
      else { return nil }
      return Double(poseTimes.count - 1) / (last - first)
    }()

    let metrics = [
      evidenceMetric(
        id: "hand_path_body_lengths",
        reading: summary.handPathBodyLengths,
        unit: "body_length",
        windowStartMs: 0,
        windowEndMs: durationMs
      ),
      evidenceMetric(
        id: "peak_hand_speed_body_lengths_per_second",
        reading: summary.peakHandSpeedBodyLengthsPerSecond,
        unit: "body_length_per_second",
        windowStartMs: 0,
        windowEndMs: durationMs
      ),
      evidenceMetric(
        id: "address_torso_tilt_2d_degrees",
        reading: summary.addressTorsoTiltDegrees,
        unit: "degree",
        windowStartMs: contextStartMs,
        windowEndMs: 0
      ),
      evidenceMetric(
        id: "torso_tilt_change_2d_degrees",
        reading: summary.torsoTiltChangeDegrees,
        unit: "degree",
        windowStartMs: 0,
        windowEndMs: durationMs
      ),
      evidenceMetric(
        id: "shoulder_projection_reduction_percent",
        reading: summary.shoulderSpanReductionPercent,
        unit: "percent",
        windowStartMs: contextStartMs,
        windowEndMs: durationMs
      ),
      evidenceMetric(
        id: "hip_projection_reduction_percent",
        reading: summary.hipSpanReductionPercent,
        unit: "percent",
        windowStartMs: contextStartMs,
        windowEndMs: durationMs
      ),
      evidenceMetric(
        id: "backswing_seconds",
        reading: summary.backswingSeconds,
        unit: "second",
        windowStartMs: 0,
        windowEndMs: durationMs
      ),
      evidenceMetric(
        id: "downswing_seconds",
        reading: summary.downswingSeconds,
        unit: "second",
        windowStartMs: 0,
        windowEndMs: durationMs
      ),
      evidenceMetric(
        id: "hand_tempo_ratio",
        reading: summary.handTempoRatio,
        unit: "ratio",
        windowStartMs: 0,
        windowEndMs: durationMs
      ),
    ]

    var phases = [
      SwingEvidencePhaseMarker(
        id: "address",
        tMs: 0,
        sourceType: .macVision2D,
        confidence: rounded(summary.trackedFraction, digits: 3),
        limitation: "เริ่ม session หลังตรวจว่าผู้เล่นอยู่นิ่ง ไม่ใช่ impact sensor"
      )
    ]
    if let backswingSeconds = summary.backswingSeconds.value {
      let topMs = min(durationMs, max(0, milliseconds(backswingSeconds)))
      phases.append(
        SwingEvidencePhaseMarker(
          id: "top_estimated_from_hand_reversal",
          tMs: topMs,
          sourceType: .macDerived2D,
          confidence: rounded(summary.backswingSeconds.trackedFraction, digits: 3),
          limitation: summary.backswingSeconds.reason
        ))
      if let downswingSeconds = summary.downswingSeconds.value {
        phases.append(
          SwingEvidencePhaseMarker(
            id: "impact_estimated_from_hand_return",
            tMs: min(durationMs, max(0, topMs + milliseconds(downswingSeconds))),
            sourceType: .macDerived2D,
            confidence: rounded(summary.downswingSeconds.trackedFraction, digits: 3),
            limitation: "เป็นเวลาโดยประมาณจากมือ ไม่ได้ยืนยันการกระทบลูกจากภาพหรือลูกกอล์ฟ"
          ))
      }
    }

    // A finish marker is evidence-backed only when the detector observed the
    // player return to stillness. A timeout merely closes the capture window;
    // treating it as Finish would fabricate a phase that may not have happened.
    if session.completionReason == .returnedToStillness {
      phases.append(
        SwingEvidencePhaseMarker(
          id: "finish_returned_to_stillness",
          tMs: durationMs,
          sourceType: .macDerived2D,
          confidence: rounded(summary.trackedFraction, digits: 3),
          limitation: "จุดจบที่ตรวจว่าผู้เล่นกลับมานิ่ง ไม่ได้ยืนยันตำแหน่ง follow-through ของไม้"
        ))
    }

    let auditPhaseCandidates = phases.filter {
      $0.id == "top_estimated_from_hand_reversal"
        || $0.id == "impact_estimated_from_hand_return"
    }
    let requestedAuditPhases: [SwingEvidencePhaseMarker]
    if auditPhaseCandidates.isEmpty {
      requestedAuditPhases = [
        phases[0],
        SwingEvidencePhaseMarker(
          id: "mid_swing_fallback",
          tMs: durationMs / 2,
          sourceType: .macDerived2D,
          confidence: rounded(summary.trackedFraction, digits: 3),
          limitation: "ใช้เฉพาะเมื่อตรวจ phase จากมือไม่สำเร็จ"
        ),
      ]
    } else if auditPhaseCandidates.count == 1 {
      requestedAuditPhases = [phases[0], auditPhaseCandidates[0]]
    } else {
      requestedAuditPhases = Array(auditPhaseCandidates.prefix(2))
    }
    let poseTimelineTimes = timeline.filter { !$0.joints.isEmpty }.map(\.tMs)
    let auditFrameRequests = requestedAuditPhases.prefix(
      SwingEvidencePacket.maximumAuditFrames
    ).map { marker in
      let nearest = poseTimelineTimes.min { abs($0 - marker.tMs) < abs($1 - marker.tMs) }
      return SwingAuditFrameRequest(
        role: marker.id,
        requestedTMs: marker.tMs,
        nearestPoseTMs: nearest,
        alignmentDeltaMs: nearest.map { abs($0 - marker.tMs) },
        imageContentID: nil
      )
    }

    let hasPose = sessionSamples.contains { $0.pose != nil }
    let hasHand = sessionSamples.contains { $0.handCenter != nil }
    let bodyAvailability: SwingEvidenceAvailability =
      hasPose
      ? (summary.trackedFraction >= minimumTrackedFraction ? .available : .limited)
      : .unavailable
    let handAvailability: SwingEvidenceAvailability = hasHand ? .available : .unavailable
    let capabilities = [
      SwingEvidenceCapability(
        id: "body_pose_2d",
        availability: bodyAvailability,
        sourceType: .macVision2D,
        limitation: "Apple Vision แบบภาพ 2 มิติ; ไม่ใช่โครงกระดูก 3 มิติ"
      ),
      SwingEvidenceCapability(
        id: "hand_center_path_2d",
        availability: handAvailability,
        sourceType: .macDerived2D,
        limitation: "กึ่งกลางข้อมือ ไม่ใช่ grip, shaft หรือหัวไม้"
      ),
      SwingEvidenceCapability(
        id: "club_head_path_2d",
        availability: .unavailable,
        sourceType: nil,
        limitation: "ยังไม่มีตัวตรวจหัวไม้บน Mac จึงไม่สร้างหรือเดาเส้นหัวไม้"
      ),
      SwingEvidenceCapability(
        id: "confirmed_ball_impact_from_camera",
        availability: .unavailable,
        sourceType: nil,
        limitation: "เวลาปะทะที่มีอยู่เป็นค่าประมาณจากการกลับมาของมือเท่านั้น"
      ),
    ]

    return SwingEvidencePacket(
      schema: SwingEvidencePacket.schemaVersion,
      coordinateSpace: "vision_normalized_xy_origin_lower_left",
      contextStartMs: contextStartMs,
      durationMs: durationMs,
      cameraView: cameraView,
      captureFPS: validRoundedFPS(captureFPS),
      poseAnalysisFPS: validRoundedFPS(sessionPoseFPS ?? poseAnalysisFPS),
      analyzedPoseFrameCount: poseTimes.count,
      sentTimelineFrameCount: timeline.count,
      timeline: timeline,
      metrics: metrics,
      phases: phases,
      auditFrameRequests: auditFrameRequests,
      capabilities: capabilities,
      limitations: [
        "ภาพความเร็วสูงถูกประมวลผลบน Mac; timeline มีเฉพาะเฟรมที่ Vision วิเคราะห์ทัน",
        "packet นี้ไม่มีวิดีโอดิบ และยังไม่มีพิกเซลของ audit keyframe จนกว่าตัวแยกภาพจะผูก imageContentID",
        "ค่าร่างกายและเส้นทางมือเป็นภาพ 2 มิติ; ห้ามสรุป depth, force, face angle หรือ club path",
      ]
    )
  }

  private func evidenceFrame(
    from sample: FrameSample,
    swingStartTime: TimeInterval
  ) -> SwingEvidenceTimelineFrame {
    var encodedJoints: [String: [Double]] = [:]
    if let pose = sample.pose {
      for (name, code) in evidenceJointNames {
        guard let value = pose.joints[name],
          value.confidence.isFinite,
          value.confidence >= minimumJointConfidence,
          value.location.x.isFinite,
          value.location.y.isFinite,
          (0...1).contains(Double(value.location.x)),
          (0...1).contains(Double(value.location.y))
        else { continue }
        encodedJoints[code] = [
          rounded(Double(value.location.x), digits: 4),
          rounded(Double(value.location.y), digits: 4),
          rounded(Double(value.confidence), digits: 3),
        ]
      }
    }

    let handCenter: [Double]? = sample.handCenter.flatMap { point in
      guard point.x.isFinite, point.y.isFinite,
        (0...1).contains(Double(point.x)),
        (0...1).contains(Double(point.y))
      else { return nil }
      return [rounded(Double(point.x), digits: 4), rounded(Double(point.y), digits: 4)]
    }
    var values: [String: Double] = [:]
    if let speed = sample.normalizedHandSpeed, speed.isFinite {
      values["hand_speed_image_per_s"] = rounded(speed, digits: 4)
    }
    if let body = bodyMeasurements(in: [sample]).first {
      values["torso_tilt_2d_deg"] = rounded(body.torsoTiltDegrees, digits: 3)
      values["shoulder_span_2d"] = rounded(body.shoulderSpan, digits: 4)
      values["hip_span_2d"] = rounded(body.hipSpan, digits: 4)
      values["torso_length_2d"] = rounded(body.torsoLength, digits: 4)
    }
    return SwingEvidenceTimelineFrame(
      tMs: milliseconds(sample.time - swingStartTime),
      joints: encodedJoints,
      handCenter: handCenter,
      values: values
    )
  }

  private var evidenceJointNames: [(VNHumanBodyPoseObservation.JointName, String)] {
    [
      (.nose, "nose"), (.neck, "neck"),
      (.leftShoulder, "ls"), (.rightShoulder, "rs"),
      (.leftElbow, "le"), (.rightElbow, "re"),
      (.leftWrist, "lw"), (.rightWrist, "rw"),
      (.leftHip, "lh"), (.rightHip, "rh"),
      (.leftKnee, "lk"), (.rightKnee, "rk"),
      (.leftAnkle, "la"), (.rightAnkle, "ra"),
    ]
  }

  private func evidenceMetric(
    id: String,
    reading: SwingMetricReading,
    unit: String,
    windowStartMs: Int,
    windowEndMs: Int
  ) -> SwingEvidenceMetric {
    SwingEvidenceMetric(
      id: id,
      value: reading.value.map { rounded($0, digits: 4) },
      unit: unit,
      sourceType: .macDerived2D,
      availability: evidenceAvailability(reading.quality),
      confidence: rounded(reading.trackedFraction, digits: 3),
      windowStartMs: windowStartMs,
      windowEndMs: windowEndMs,
      limitation: reading.reason
    )
  }

  private func evidenceAvailability(_ quality: SwingMetricQuality) -> SwingEvidenceAvailability {
    switch quality {
    case .good: return .available
    case .limited: return .limited
    case .unavailable: return .unavailable
    }
  }

  private func uniformlyDownsampled<T>(_ values: [T], maximumCount: Int) -> [T] {
    guard maximumCount > 1, values.count > maximumCount else { return values }
    let scale = Double(values.count - 1) / Double(maximumCount - 1)
    var result: [T] = []
    result.reserveCapacity(maximumCount)
    var previousIndex = -1
    for position in 0..<maximumCount {
      let index = min(values.count - 1, Int((Double(position) * scale).rounded()))
      guard index != previousIndex else { continue }
      result.append(values[index])
      previousIndex = index
    }
    return result
  }

  private func milliseconds(_ seconds: TimeInterval) -> Int {
    guard seconds.isFinite else { return 0 }
    return Int((seconds * 1_000).rounded())
  }

  private func rounded(_ value: Double, digits: Int) -> Double {
    guard value.isFinite else { return value }
    let scale = pow(10, Double(max(0, digits)))
    return (value * scale).rounded() / scale
  }

  private func validRoundedFPS(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0 else { return nil }
    return rounded(value, digits: 2)
  }

  private func normalizedMotionMetrics(
    session: SwingSessionSummary,
    sessionSamples: [FrameSample],
    bodyScale: Double?,
    bodyTrackedFraction: Double
  ) -> (path: SwingMetricReading, peakSpeed: SwingMetricReading) {
    let handFraction = trackedHandFraction(in: sessionSamples)
    let trackedFraction = min(bodyTrackedFraction, handFraction)
    let unavailableReason = "วัดระยะเป็นหน่วยลำตัวไม่ได้ เพราะเห็นมือหรือลำตัวไม่ต่อเนื่องพอ"

    guard
      trackedFraction >= minimumTrackedFraction,
      let bodyScale,
      bodyScale > 0.01
    else {
      let unavailable = unavailableReading(
        trackedFraction: trackedFraction,
        reason: unavailableReason
      )
      return (unavailable, unavailable)
    }

    let points = orderedUniquePoints(session.pointHistory)
    guard points.count >= 5 else {
      let unavailable = unavailableReading(
        trackedFraction: trackedFraction,
        reason: "จำนวนจุดกึ่งกลางมือไม่พอสำหรับวัดเส้นทาง"
      )
      return (unavailable, unavailable)
    }

    var lengths: [Double] = []
    var speeds: [Double] = []
    for pair in zip(points, points.dropFirst()) {
      guard
        let firstTime = usableTime(pair.0.timestamp),
        let secondTime = usableTime(pair.1.timestamp)
      else { continue }
      let elapsed = secondTime - firstTime
      guard elapsed > 0, elapsed <= 0.20 else { continue }

      let distance =
        euclideanDistance(
          pair.0.normalizedLocation,
          pair.1.normalizedLocation
        ) / bodyScale
      guard distance.isFinite else { continue }
      lengths.append(distance)
      speeds.append(distance / elapsed)
    }

    guard lengths.count >= 4, speeds.count >= 4 else {
      let unavailable = unavailableReading(
        trackedFraction: trackedFraction,
        reason: "จุดมือขาดช่วงจนคำนวณระยะและความเร็วอย่างปลอดภัยไม่ได้"
      )
      return (unavailable, unavailable)
    }

    // Winsorize only the top 5% so a single Vision jump cannot dominate either value.
    let segmentCap = percentile(lengths, 0.95) ?? 0
    let pathLength = lengths.reduce(0) { $0 + min($1, segmentCap) }
    guard let peakSpeed = percentile(speeds, 0.95) else {
      let unavailable = unavailableReading(
        trackedFraction: trackedFraction,
        reason: unavailableReason
      )
      return (unavailable, unavailable)
    }

    let quality = metricQuality(trackedFraction: trackedFraction, sampleCount: lengths.count)
    let reason = "คำนวณจากกึ่งกลางข้อมือและหารด้วยความยาวลำตัว ไม่ใช่ความเร็วหัวไม้"
    return (
      availableReading(
        pathLength,
        quality: quality,
        trackedFraction: trackedFraction,
        reason: reason
      ),
      availableReading(
        peakSpeed,
        quality: quality,
        trackedFraction: trackedFraction,
        reason: reason
      )
    )
  }

  private func torsoMetrics(
    baselineBodies: [BodyMeasurement],
    sessionBodies: [BodyMeasurement],
    baselineFrameCount: Int,
    sessionFrameCount: Int
  ) -> (addressTilt: SwingMetricReading, tiltChange: SwingMetricReading) {
    let baselineFraction = fraction(baselineBodies.count, of: baselineFrameCount)
    let swingFraction = fraction(sessionBodies.count, of: sessionFrameCount)
    let trackedFraction = min(baselineFraction, swingFraction)

    guard
      baselineBodies.count >= 3,
      sessionBodies.count >= 5,
      trackedFraction >= minimumTrackedFraction,
      let addressTilt = robustMedian(baselineBodies.map(\.torsoTiltDegrees))
    else {
      let unavailable = unavailableReading(
        trackedFraction: trackedFraction,
        reason: "เห็นไหล่และสะโพกช่วงยืนเตรียมหรือช่วงสวิงไม่พอสำหรับวัดมุมลำตัว"
      )
      return (unavailable, unavailable)
    }

    let changes = sessionBodies.map {
      abs(shortestAngleDifference($0.torsoTiltDegrees, addressTilt))
    }
    guard let tiltChange = percentile(changes, 0.90) else {
      let unavailable = unavailableReading(
        trackedFraction: trackedFraction,
        reason: "คำนวณการเปลี่ยนมุมลำตัวไม่ได้"
      )
      return (unavailable, unavailable)
    }

    let quality = metricQuality(
      trackedFraction: trackedFraction,
      sampleCount: sessionBodies.count
    )
    let reason = "มุมฉายบนภาพสองมิติเทียบกับแนวตั้ง ไม่ใช่มุมลำตัวสามมิติ"
    return (
      availableReading(
        addressTilt,
        quality: quality,
        trackedFraction: trackedFraction,
        reason: reason
      ),
      availableReading(
        tiltChange,
        quality: quality,
        trackedFraction: trackedFraction,
        reason: reason
      )
    )
  }

  private func spanReductionMetric(
    baselineSamples: [FrameSample],
    sessionSamples: [FrameSample],
    jointNames: (VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName),
    label: String
  ) -> SwingMetricReading {
    let baselineSpans = spans(in: baselineSamples, between: jointNames.0, and: jointNames.1)
    let sessionSpans = spans(in: sessionSamples, between: jointNames.0, and: jointNames.1)
    let trackedFraction = min(
      fraction(baselineSpans.count, of: baselineSamples.count),
      fraction(sessionSpans.count, of: sessionSamples.count)
    )

    guard
      baselineSpans.count >= 3,
      sessionSpans.count >= 5,
      trackedFraction >= minimumTrackedFraction,
      let baseline = robustMedian(baselineSpans),
      baseline > 0.01,
      let reducedSpan = percentile(sessionSpans, 0.10)
    else {
      return unavailableReading(
        trackedFraction: trackedFraction,
        reason: "เห็น\(label)ไม่ต่อเนื่องพอสำหรับวัดการหดของระยะฉาย"
      )
    }

    let reduction = min(100, max(0, (baseline - reducedSpan) / baseline * 100))
    let quality = metricQuality(
      trackedFraction: trackedFraction,
      sampleCount: sessionSpans.count
    )
    return availableReading(
      reduction,
      quality: quality,
      trackedFraction: trackedFraction,
      reason: "เป็นตัวแทนการหมุนจากระยะ\(label)ที่ฉายบนภาพสองมิติ ไม่ใช่องศาหมุนจริง"
    )
  }

  private func tempoMetrics(
    session: SwingSessionSummary,
    sessionSamples: [FrameSample],
    bodyScale: Double?,
    bodyTrackedFraction: Double
  ) -> TempoResult? {
    guard let bodyScale, bodyScale > 0.01 else { return nil }
    let points = orderedUniquePoints(session.pointHistory)
    guard points.count >= 9 else { return nil }

    let handFraction = trackedHandFraction(in: sessionSamples)
    let trackedFraction = min(bodyTrackedFraction, handFraction)
    guard trackedFraction >= minimumTrackedFraction else { return nil }

    let startWindow = Array(points.prefix(min(3, points.count)))
    let startPoint = CGPoint(
      x: CGFloat(
        robustMedian(startWindow.map { Double($0.normalizedLocation.x) })
          ?? Double(points[0].normalizedLocation.x)),
      y: CGFloat(
        robustMedian(startWindow.map { Double($0.normalizedLocation.y) })
          ?? Double(points[0].normalizedLocation.y))
    )
    let rawDistances = points.map {
      euclideanDistance(startPoint, $0.normalizedLocation) / bodyScale
    }
    let distances = medianSmoothed(rawDistances)
    guard
      let highDistance = percentile(distances, 0.95),
      highDistance >= 0.20
    else { return nil }

    let transitionCandidates = distances.indices.filter {
      distances[$0] >= highDistance && $0 >= 2 && $0 <= distances.count - 4
    }
    guard let transitionIndex = transitionCandidates.first else { return nil }

    let before = Array(distances[0...transitionIndex])
    let after = Array(distances[transitionIndex...])
    let risingFraction = directionalStepFraction(before, increasing: true)
    let fallingFraction = directionalStepFraction(after, increasing: false)
    guard risingFraction >= 0.60, fallingFraction >= 0.60 else { return nil }

    let returnThreshold = highDistance * 0.45
    let possibleImpactIndices = ((transitionIndex + 1)..<distances.count).filter {
      distances[$0] <= returnThreshold
    }
    guard let impactIndex = possibleImpactIndices.first else { return nil }

    guard
      let firstTime = usableTime(points[0].timestamp),
      let transitionTime = usableTime(points[transitionIndex].timestamp),
      let impactTime = usableTime(points[impactIndex].timestamp)
    else { return nil }

    let backswingSeconds: TimeInterval = transitionTime - firstTime
    let downswingSeconds: TimeInterval = impactTime - transitionTime
    guard
      backswingSeconds >= 0.10,
      downswingSeconds >= 0.06,
      backswingSeconds <= 3.0,
      downswingSeconds <= 1.5
    else { return nil }

    return TempoResult(
      backswingSeconds: backswingSeconds,
      downswingSeconds: downswingSeconds,
      ratio: backswingSeconds / downswingSeconds,
      trackedFraction: trackedFraction,
      sampleCount: points.count,
      reason: "ประมาณจากจุดกลับทิศที่ชัดเจนของกึ่งกลางมือ ไม่ใช่จังหวะกระทบลูกที่ยืนยันด้วยลูกกอล์ฟ"
    )
  }

  private func bodyMeasurements(in frameSamples: [FrameSample]) -> [BodyMeasurement] {
    frameSamples.compactMap { sample in
      guard
        let pose = sample.pose,
        let leftShoulder = joint(.leftShoulder, in: pose),
        let rightShoulder = joint(.rightShoulder, in: pose),
        let leftHip = joint(.leftHip, in: pose),
        let rightHip = joint(.rightHip, in: pose)
      else { return nil }

      let shoulderCenter = midpoint(leftShoulder, rightShoulder)
      let hipCenter = midpoint(leftHip, rightHip)
      let torsoLength = euclideanDistance(shoulderCenter, hipCenter)
      guard torsoLength > 0.01 else { return nil }

      let horizontal = Double(shoulderCenter.x - hipCenter.x)
      let vertical = Double(shoulderCenter.y - hipCenter.y)
      let angle = atan2(horizontal, vertical) * 180 / .pi
      return BodyMeasurement(
        time: sample.time,
        torsoLength: torsoLength,
        torsoTiltDegrees: angle,
        shoulderSpan: euclideanDistance(leftShoulder, rightShoulder),
        hipSpan: euclideanDistance(leftHip, rightHip)
      )
    }
  }

  private func spans(
    in frameSamples: [FrameSample],
    between firstName: VNHumanBodyPoseObservation.JointName,
    and secondName: VNHumanBodyPoseObservation.JointName
  ) -> [Double] {
    frameSamples.compactMap { sample in
      guard
        let pose = sample.pose,
        let first = joint(firstName, in: pose),
        let second = joint(secondName, in: pose)
      else { return nil }
      let value = euclideanDistance(first, second)
      return value > 0.005 ? value : nil
    }
  }

  private func joint(
    _ name: VNHumanBodyPoseObservation.JointName,
    in pose: PoseFrame
  ) -> CGPoint? {
    guard
      let joint = pose.joints[name],
      joint.confidence.isFinite,
      joint.confidence >= minimumJointConfidence,
      joint.location.x.isFinite,
      joint.location.y.isFinite
    else { return nil }
    return joint.location
  }

  private func trackedHandFraction(in frameSamples: [FrameSample]) -> Double {
    fraction(frameSamples.count { $0.handCenter != nil }, of: frameSamples.count)
  }

  private var activeSamples: ArraySlice<FrameSample> {
    samples[sampleHeadIndex...]
  }

  private func metricQuality(
    trackedFraction: Double,
    sampleCount: Int
  ) -> SwingMetricQuality {
    trackedFraction >= 0.80 && sampleCount >= 8 ? .good : .limited
  }

  private func availableReading(
    _ value: Double,
    quality: SwingMetricQuality,
    trackedFraction: Double,
    reason: String
  ) -> SwingMetricReading {
    guard value.isFinite else {
      return unavailableReading(
        trackedFraction: trackedFraction,
        reason: "ผลคำนวณไม่ใช่ตัวเลขที่ใช้งานได้"
      )
    }
    return SwingMetricReading(
      value: value,
      quality: quality,
      trackedFraction: clampedFraction(trackedFraction),
      reason: reason
    )
  }

  private func unavailableReading(
    trackedFraction: Double,
    reason: String
  ) -> SwingMetricReading {
    SwingMetricReading(
      value: nil,
      quality: .unavailable,
      trackedFraction: clampedFraction(trackedFraction),
      reason: reason
    )
  }

  private func whollyUnavailable(reason: String) -> SwingAnalysisSummary {
    let unavailable = unavailableReading(trackedFraction: 0, reason: reason)
    return SwingAnalysisSummary(
      handPathBodyLengths: unavailable,
      peakHandSpeedBodyLengthsPerSecond: unavailable,
      addressTorsoTiltDegrees: unavailable,
      torsoTiltChangeDegrees: unavailable,
      shoulderSpanReductionPercent: unavailable,
      hipSpanReductionPercent: unavailable,
      backswingSeconds: unavailable,
      downswingSeconds: unavailable,
      handTempoRatio: unavailable,
      quality: .unavailable,
      trackedFraction: 0,
      reason: reason
    )
  }

  private func orderedUniquePoints(_ points: [SwingMotionPoint]) -> [SwingMotionPoint] {
    let sorted = points.compactMap { point -> (SwingMotionPoint, TimeInterval)? in
      guard let time = usableTime(point.timestamp) else { return nil }
      return (point, time)
    }.sorted { $0.1 < $1.1 }

    var result: [SwingMotionPoint] = []
    var lastTime: TimeInterval?
    for item in sorted where item.1 != lastTime {
      result.append(item.0)
      lastTime = item.1
    }
    return result
  }

  private func medianSmoothed(_ values: [Double]) -> [Double] {
    guard values.count >= 3 else { return values }
    return values.indices.map { index in
      let lower = max(0, index - 1)
      let upper = min(values.count - 1, index + 1)
      return robustMedian(Array(values[lower...upper])) ?? values[index]
    }
  }

  private func directionalStepFraction(_ values: [Double], increasing: Bool) -> Double {
    guard values.count >= 2 else { return 0 }
    let differences = zip(values, values.dropFirst()).map { $1 - $0 }
    let tolerance = max(0.005, (values.max() ?? 0) * 0.015)
    let matching = differences.count { difference in
      increasing ? difference >= -tolerance : difference <= tolerance
    }
    return fraction(matching, of: differences.count)
  }

  private func robustMedian(_ values: [Double]) -> Double? {
    percentile(values, 0.50)
  }

  private func percentile(_ values: [Double], _ percentile: Double) -> Double? {
    let sorted = values.filter(\.isFinite).sorted()
    guard !sorted.isEmpty else { return nil }
    if sorted.count == 1 { return sorted[0] }

    let bounded = min(1, max(0, percentile))
    let position = bounded * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    if lower == upper { return sorted[lower] }
    let fraction = position - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
  }

  private func shortestAngleDifference(_ angle: Double, _ reference: Double) -> Double {
    var difference = angle - reference
    while difference > 180 { difference -= 360 }
    while difference < -180 { difference += 360 }
    return difference
  }

  private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
    CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
  }

  private func euclideanDistance(_ first: CGPoint, _ second: CGPoint) -> Double {
    let horizontal = Double(second.x - first.x)
    let vertical = Double(second.y - first.y)
    return (horizontal * horizontal + vertical * vertical).squareRoot()
  }

  private func fraction(_ numerator: Int, of denominator: Int) -> Double {
    guard denominator > 0 else { return 0 }
    return clampedFraction(Double(numerator) / Double(denominator))
  }

  private func clampedFraction(_ value: Double) -> Double {
    min(1, max(0, value.isFinite ? value : 0))
  }

  private func usableTime(_ timestamp: CMTime?) -> TimeInterval? {
    guard let timestamp, timestamp.isValid else { return nil }
    let value = CMTimeGetSeconds(timestamp)
    return value.isFinite ? value : nil
  }
}
