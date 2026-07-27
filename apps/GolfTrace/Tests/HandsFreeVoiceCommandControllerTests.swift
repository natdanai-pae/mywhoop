@preconcurrency import AVFoundation
import Foundation
import XCTest

@testable import GolfTrace

final class HandsFreeVoiceCommandParserTests: XCTestCase {
  func testAcceptsExactCommandsAfterSafeSpeechNormalization() {
    XCTAssertEqual(HandsFreeVoiceCommandParser.parse(" กอล์ฟ เทรซ เริ่ม วง! "), .startSwing)
    XCTAssertEqual(HandsFreeVoiceCommandParser.parse("กอล์ฟเทรซ ยกเลิก。"), .cancel)
  }

  func testRejectsCommandsEmbeddedInLongerPhrases() {
    XCTAssertNil(HandsFreeVoiceCommandParser.parse("เริ่มวง"))
    XCTAssertNil(HandsFreeVoiceCommandParser.parse("กอล์ฟเทรซเริ่มวงเดี๋ยวนี้"))
    XCTAssertNil(HandsFreeVoiceCommandParser.parse("กอล์ฟเทรซยกเลิกให้หน่อย"))
    XCTAssertNil(HandsFreeVoiceCommandParser.parse("เริ่ม"))
    XCTAssertNil(HandsFreeVoiceCommandParser.parse(""))
  }

  func testNormalizationPreservesThaiMarksButRemovesSpeechSpacingAndPunctuation() {
    XCTAssertEqual(
      HandsFreeVoiceCommandParser.normalize("\nกอล์ฟ เทรซ เริ่ม\u{200B} วง…"),
      "กอล์ฟเทรซเริ่มวง"
    )
    XCTAssertEqual(HandsFreeVoiceCommandParser.normalize(" กอล์ฟเทรซ ยก-เลิก "), "กอล์ฟเทรซยกเลิก")
  }
}

@MainActor
final class HandsFreeVoiceCommandControllerTests: XCTestCase {
  func testPublishesExactCommandSpeaksFeedbackAndResumesOnlyAfterSpeechFinishes() async {
    let listener = RecordingHandsFreeVoiceListener()
    let speaker = RecordingHandsFreeFeedbackSpeaker()
    let controller = HandsFreeVoiceCommandController(
      listener: listener,
      feedbackSpeaker: speaker,
      restartDelay: 0
    )
    var receivedCommands: [HandsFreeVoiceCommand] = []
    controller.onCommand = { receivedCommands.append($0) }

    controller.start()
    await waitUntil { listener.startCount == 1 }
    let listeningStartCount = listener.startCount

    listener.emit("กอล์ฟเทรซ เริ่มวง", isFinal: true)

    XCTAssertEqual(controller.latestCommand?.command, .startSwing)
    XCTAssertEqual(controller.latestCommand?.transcript, "กอล์ฟเทรซ เริ่มวง")
    XCTAssertEqual(receivedCommands, [.startSwing])
    XCTAssertTrue(speaker.spokenTexts.isEmpty)
    XCTAssertEqual(listener.startCount, listeningStartCount)

    controller.speakFeedback(HandsFreeVoiceCommand.startSwing.feedbackText)
    XCTAssertEqual(speaker.spokenTexts, [HandsFreeVoiceCommand.startSwing.feedbackText])
    XCTAssertEqual(controller.status, .speakingFeedback)

    // A late recognizer callback or audible TTS echo belongs to the invalidated
    // listener generation and must never become a second command.
    listener.emitEvenIfStopped("กอล์ฟเทรซ ยกเลิก", isFinal: true)
    XCTAssertEqual(receivedCommands, [.startSwing])

    speaker.finish()

    XCTAssertEqual(listener.startCount, listeningStartCount + 1)
    XCTAssertEqual(controller.status, .listening)
  }

  func testSuspendInvalidatesCallbacksAndResumeRestartsRememberedListener() async {
    let listener = RecordingHandsFreeVoiceListener()
    let speaker = RecordingHandsFreeFeedbackSpeaker()
    let controller = HandsFreeVoiceCommandController(
      listener: listener,
      feedbackSpeaker: speaker,
      restartDelay: 0
    )

    controller.start()
    await waitUntil { listener.startCount == 1 }
    let startCount = listener.startCount

    controller.suspend()
    listener.emitEvenIfStopped("กอล์ฟเทรซ เริ่มวง", isFinal: true)

    XCTAssertEqual(controller.status, .suspended)
    XCTAssertTrue(controller.isSuspended)
    XCTAssertNil(controller.latestCommand)

    controller.resume()

    XCTAssertFalse(controller.isSuspended)
    XCTAssertEqual(listener.startCount, startCount + 1)
    XCTAssertEqual(controller.status, .listening)
  }

  func testFeedbackRequestedWhileSuspendedWaitsUntilResumeBeforeRecognitionRestarts() async {
    let listener = RecordingHandsFreeVoiceListener()
    let speaker = RecordingHandsFreeFeedbackSpeaker()
    let controller = HandsFreeVoiceCommandController(
      listener: listener,
      feedbackSpeaker: speaker,
      restartDelay: 0
    )

    controller.start()
    await waitUntil { listener.startCount == 1 }
    let listeningStartCount = listener.startCount

    controller.suspend()
    controller.speakFeedback("รับคำสั่งแล้ว เตรียมตี")

    XCTAssertTrue(speaker.spokenTexts.isEmpty)
    XCTAssertEqual(controller.status, .suspended)
    XCTAssertEqual(listener.startCount, listeningStartCount)

    controller.resume()

    XCTAssertEqual(speaker.spokenTexts, ["รับคำสั่งแล้ว เตรียมตี"])
    XCTAssertEqual(controller.status, .speakingFeedback)
    XCTAssertEqual(listener.startCount, listeningStartCount)

    speaker.finish()

    XCTAssertEqual(listener.startCount, listeningStartCount + 1)
    XCTAssertEqual(controller.status, .listening)
  }

  func testSuspendedFeedbackKeepsOnlyLatestStateResponse() async {
    let listener = RecordingHandsFreeVoiceListener()
    let speaker = RecordingHandsFreeFeedbackSpeaker()
    let controller = HandsFreeVoiceCommandController(
      listener: listener,
      feedbackSpeaker: speaker,
      restartDelay: 0
    )
    var supersededCompletionCount = 0

    controller.start()
    await waitUntil { listener.startCount == 1 }
    controller.suspend()
    controller.speakFeedback("สาม") {
      supersededCompletionCount += 1
    }
    controller.speakFeedback("สอง")

    XCTAssertTrue(speaker.spokenTexts.isEmpty)
    XCTAssertEqual(supersededCompletionCount, 1)

    controller.resume()

    XCTAssertEqual(speaker.spokenTexts, ["สอง"])
    speaker.finish()
    XCTAssertEqual(controller.status, .listening)
  }

  func testSuspendCancelsActiveFeedbackAndReplaysItSafelyAfterResume() async {
    let listener = RecordingHandsFreeVoiceListener()
    let speaker = RecordingHandsFreeFeedbackSpeaker()
    let controller = HandsFreeVoiceCommandController(
      listener: listener,
      feedbackSpeaker: speaker,
      restartDelay: 0
    )
    var completionCount = 0

    controller.start()
    await waitUntil { listener.startCount == 1 }
    let listeningStartCount = listener.startCount
    controller.speakFeedback("รับคำสั่งแล้ว เตรียมตี") {
      completionCount += 1
    }
    let stopCountBeforeSuspension = speaker.stopCount

    controller.suspend()

    XCTAssertEqual(speaker.stopCount, stopCountBeforeSuspension + 1)
    XCTAssertEqual(controller.status, .suspended)
    XCTAssertEqual(completionCount, 0)

    // The completion retained by the canceled speaker must not leak through.
    speaker.finish()
    XCTAssertEqual(completionCount, 0)

    controller.resume()

    XCTAssertEqual(
      speaker.spokenTexts,
      ["รับคำสั่งแล้ว เตรียมตี", "รับคำสั่งแล้ว เตรียมตี"]
    )
    XCTAssertEqual(controller.status, .speakingFeedback)
    XCTAssertEqual(listener.startCount, listeningStartCount)

    speaker.finish()

    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(listener.startCount, listeningStartCount + 1)
    XCTAssertEqual(controller.status, .listening)
  }

  func testLongerFinalPhraseDoesNotTriggerEarlierExactPartial() async {
    let listener = RecordingHandsFreeVoiceListener()
    let speaker = RecordingHandsFreeFeedbackSpeaker()
    let controller = HandsFreeVoiceCommandController(
      listener: listener,
      feedbackSpeaker: speaker,
      partialResultQuietPeriod: 1,
      restartDelay: 0
    )

    controller.start()
    await waitUntil { listener.startCount == 1 }
    listener.emit("กอล์ฟเทรซ เริ่มวง", isFinal: false)
    listener.emit("กอล์ฟเทรซ เริ่มวงเดี๋ยวนี้", isFinal: true)

    XCTAssertNil(controller.latestCommand)
    XCTAssertTrue(speaker.spokenTexts.isEmpty)
    await waitUntil { listener.startCount == 2 }
    XCTAssertEqual(controller.status, .listening)
  }

  func testAcceptedCommandWithoutSynchronousFeedbackRestartsListening() async {
    let listener = RecordingHandsFreeVoiceListener()
    let controller = HandsFreeVoiceCommandController(
      listener: listener,
      feedbackSpeaker: RecordingHandsFreeFeedbackSpeaker(),
      restartDelay: 0
    )

    controller.start()
    await waitUntil { listener.startCount == 1 }
    listener.emit("กอล์ฟเทรซ เริ่มวง", isFinal: true)

    await waitUntil { listener.startCount == 2 }
    XCTAssertEqual(controller.latestCommand?.command, .startSwing)
    XCTAssertEqual(controller.status, .listening)
  }

  func testDeniedPermissionPublishesUnavailableStatusAndError() async {
    let listener = RecordingHandsFreeVoiceListener()
    listener.authorization = HandsFreeVoiceAuthorization(
      microphoneGranted: false,
      speechRecognitionGranted: true,
      recognizerAvailable: true
    )
    let controller = HandsFreeVoiceCommandController(
      listener: listener,
      feedbackSpeaker: RecordingHandsFreeFeedbackSpeaker()
    )

    controller.start()
    await waitUntil { controller.status == .unavailable }

    XCTAssertEqual(controller.errorMessage, "ยังไม่ได้รับอนุญาตให้ใช้ไมโครโฟนสำหรับคำสั่งเสียง")
    XCTAssertEqual(listener.startCount, 0)
  }

  func testAudioTapCallbackRunsOnRealtimeQueueWithoutMainActorIsolation() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)
    )
    let appended = expectation(description: "audio buffer appended off main actor")
    let appender = RecordingHandsFreeAudioBufferAppender(expectation: appended)
    let tap = HandsFreeVoiceAudioTapFactory.make(appender: appender)
    let invocation = SendableAudioTapInvocation(
      tap: tap,
      buffer: buffer,
      time: AVAudioTime(sampleTime: 0, atRate: format.sampleRate)
    )

    DispatchQueue(label: "GolfTraceTests.realtime-audio-tap").async {
      invocation.invoke()
    }

    wait(for: [appended], timeout: 1)
    XCTAssertEqual(appender.appendCount, 1)
    XCTAssertFalse(appender.appendedOnMainThread)
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
  }
}

private final class RecordingHandsFreeAudioBufferAppender: HandsFreeVoiceAudioBufferAppending,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let expectation: XCTestExpectation
  private var _appendCount = 0
  private var _appendedOnMainThread = false

  init(expectation: XCTestExpectation) {
    self.expectation = expectation
  }

  var appendCount: Int {
    lock.withLock { _appendCount }
  }

  var appendedOnMainThread: Bool {
    lock.withLock { _appendedOnMainThread }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.withLock {
      _appendCount += 1
      _appendedOnMainThread = Thread.isMainThread
    }
    expectation.fulfill()
  }
}

private final class SendableAudioTapInvocation: @unchecked Sendable {
  private let tap: AVAudioNodeTapBlock
  private let buffer: AVAudioPCMBuffer
  private let time: AVAudioTime

  init(tap: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer, time: AVAudioTime) {
    self.tap = tap
    self.buffer = buffer
    self.time = time
  }

  func invoke() {
    tap(buffer, time)
  }
}

@MainActor
private final class RecordingHandsFreeVoiceListener: HandsFreeVoiceListening {
  var authorization = HandsFreeVoiceAuthorization.authorized
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private var onTranscript: (@MainActor @Sendable (String, Bool) -> Void)?
  private var onTermination: (@MainActor @Sendable (HandsFreeVoiceListenerFailure?) -> Void)?

  func requestAuthorization() async -> HandsFreeVoiceAuthorization {
    authorization
  }

  func start(
    onTranscript: @escaping @MainActor @Sendable (String, Bool) -> Void,
    onTermination: @escaping @MainActor @Sendable (HandsFreeVoiceListenerFailure?) -> Void
  ) throws {
    startCount += 1
    self.onTranscript = onTranscript
    self.onTermination = onTermination
  }

  func stop() {
    stopCount += 1
  }

  func emit(_ transcript: String, isFinal: Bool) {
    onTranscript?(transcript, isFinal)
  }

  func emitEvenIfStopped(_ transcript: String, isFinal: Bool) {
    onTranscript?(transcript, isFinal)
  }

  func terminate(_ failure: HandsFreeVoiceListenerFailure? = nil) {
    onTermination?(failure)
  }
}

@MainActor
private final class RecordingHandsFreeFeedbackSpeaker: HandsFreeVoiceFeedbackSpeaking {
  private(set) var spokenTexts: [String] = []
  private(set) var stopCount = 0
  private var completion: (@MainActor @Sendable () -> Void)?

  func speak(
    _ text: String,
    completion: @escaping @MainActor @Sendable () -> Void
  ) {
    spokenTexts.append(text)
    self.completion = completion
  }

  func stop() {
    stopCount += 1
    completion = nil
  }

  func finish() {
    let completion = completion
    self.completion = nil
    completion?()
  }
}
