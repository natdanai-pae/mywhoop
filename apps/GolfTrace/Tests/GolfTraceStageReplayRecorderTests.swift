import Foundation
import XCTest

@testable import GolfTrace

final class GolfTraceStageReplayRecorderTests: XCTestCase {
  @MainActor
  func testCancelDuringPipelinePreparationNeverStartsOrFinalizesCapture() async {
    let pipeline = FakeStageCapturePipeline()
    let factoryGate = StageCaptureTestGate()
    var factoryStarted = false
    let recorder = GolfTraceStageReplayRecorder(
      windowNumberProvider: { 42 },
      pipelineFactory: { _ in
        factoryStarted = true
        await factoryGate.wait()
        return pipeline
      }
    )

    recorder.startIfNeeded()
    await waitUntil { factoryStarted }

    recorder.cancelRecording()
    await factoryGate.open()
    await waitUntil { !recorder.hasPendingWork }

    XCTAssertEqual(pipeline.snapshot.startCalls, 0)
    XCTAssertEqual(pipeline.snapshot.stopCalls, 0)
    XCTAssertEqual(pipeline.snapshot.finalizeCalls, 0)
    XCTAssertEqual(pipeline.snapshot.abortCalls, 1)
    XCTAssertFalse(recorder.isPreparing)
    XCTAssertFalse(recorder.isRecording)
  }

  @MainActor
  func testCancelActiveCaptureUsesAbortInsteadOfStopAndFinalize() async {
    let pipeline = FakeStageCapturePipeline()
    let recorder = makeRecorder(pipeline: pipeline)

    recorder.startIfNeeded()
    await waitUntil { recorder.isRecording }

    recorder.cancelRecording()
    await waitUntil { !recorder.hasPendingWork }

    XCTAssertEqual(pipeline.snapshot.startCalls, 1)
    XCTAssertEqual(pipeline.snapshot.completedStarts, 1)
    XCTAssertEqual(pipeline.snapshot.stopCalls, 0)
    XCTAssertEqual(pipeline.snapshot.finalizeCalls, 0)
    XCTAssertEqual(pipeline.snapshot.abortCalls, 1)
  }

  @MainActor
  func testCancelWhileStartIsSuspendedAbortsWithoutFinalizing() async {
    let startGate = StageCaptureTestGate()
    let pipeline = FakeStageCapturePipeline(startGate: startGate)
    let recorder = makeRecorder(pipeline: pipeline)

    recorder.startIfNeeded()
    await waitUntil { pipeline.snapshot.startCalls == 1 }

    recorder.cancelRecording()
    await startGate.open()
    await waitUntil { !recorder.hasPendingWork }

    XCTAssertEqual(pipeline.snapshot.completedStarts, 0)
    XCTAssertEqual(pipeline.snapshot.stopCalls, 0)
    XCTAssertEqual(pipeline.snapshot.finalizeCalls, 0)
    XCTAssertEqual(pipeline.snapshot.abortCalls, 1)
  }

  @MainActor
  func testCancelWhileNormalStopIsSuspendedConvertsTeardownToDiscard() async {
    let stopGate = StageCaptureTestGate()
    let pipeline = FakeStageCapturePipeline(stopGate: stopGate)
    let recorder = makeRecorder(pipeline: pipeline)

    recorder.startIfNeeded()
    await waitUntil { recorder.isRecording }
    XCTAssertTrue(
      recorder.finishRecording { _ in
        XCTFail("A cancelled stop must not deliver its original completion")
      })
    await waitUntil { pipeline.snapshot.stopCalls == 1 }

    recorder.cancelRecording()
    await stopGate.open()
    await waitUntil { !recorder.hasPendingWork }

    XCTAssertTrue(pipeline.snapshot.discardRequested)
    XCTAssertEqual(pipeline.snapshot.finalizeCalls, 0)
    XCTAssertEqual(pipeline.snapshot.abortCalls, 1)
  }

  @MainActor
  func testSuccessfulFinishStillStopsAndReturnsMovie() async {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-stage-recorder-test-(UUID().uuidString)")
      .appendingPathExtension("mov")
    let expectedCounters = GolfTraceStageCaptureFrameCounters(
      received: 240,
      appended: 238,
      backpressureDrops: 2
    )
    let pipeline = FakeStageCapturePipeline(
      outputURL: outputURL,
      frameCounters: expectedCounters
    )
    let recorder = makeRecorder(pipeline: pipeline)
    var completionResult: Result<URL, Error>?

    recorder.startIfNeeded()
    await waitUntil { recorder.isRecording }
    XCTAssertTrue(
      recorder.finishRecording { result in
        completionResult = result
      }
    )
    await waitUntil { completionResult != nil && !recorder.hasPendingWork }

    guard case .success(let completedURL) = completionResult else {
      XCTFail("Expected a successful stage replay")
      return
    }
    XCTAssertEqual(completedURL, outputURL)
    XCTAssertEqual(pipeline.snapshot.stopCalls, 1)
    XCTAssertEqual(pipeline.snapshot.finalizeCalls, 1)
    XCTAssertEqual(pipeline.snapshot.abortCalls, 0)
    XCTAssertFalse(pipeline.snapshot.discardRequested)
    XCTAssertEqual(recorder.frameCounters, expectedCounters)
  }

  @MainActor
  func testPaneLayoutChangeDuringCaptureDisablesStalePIPCoordinates() async {
    let pipeline = FakeStageCapturePipeline()
    let recorder = makeRecorder(pipeline: pipeline)
    let initialLayout = makePaneLayout(split: 0.62)
    recorder.updatePaneLayout(initialLayout)

    recorder.startIfNeeded()
    await waitUntil { recorder.isRecording }
    recorder.updatePaneLayout(makePaneLayout(split: 0.54))

    var completionResult: Result<URL, Error>?
    XCTAssertTrue(recorder.finishRecording { completionResult = $0 })
    await waitUntil { completionResult != nil && !recorder.hasPendingWork }

    XCTAssertNil(recorder.lastCompletedPaneLayout)
  }

  @MainActor
  private func makeRecorder(
    pipeline: FakeStageCapturePipeline
  ) -> GolfTraceStageReplayRecorder {
    GolfTraceStageReplayRecorder(
      windowNumberProvider: { 42 },
      pipelineFactory: { _ in pipeline }
    )
  }

  private func makePaneLayout(split: Double) -> GolfTraceStagePaneLayout {
    GolfTraceStagePaneLayout(
      rapsodo: GolfTraceNormalizedRect(
        x: 0.02,
        y: 0.08,
        width: split - 0.03,
        height: 0.86
      ),
      swingCamera: GolfTraceNormalizedRect(
        x: split,
        y: 0.08,
        width: 0.98 - split,
        height: 0.86
      )
    )
  }

  @MainActor
  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for recorder state", file: file, line: line)
  }
}

private actor StageCaptureTestGate {
  private var isOpen = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = continuations
    continuations.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

private final class FakeStageCapturePipeline: GolfTraceStageCapturePipeline,
  @unchecked Sendable
{
  struct Snapshot {
    var startCalls = 0
    var completedStarts = 0
    var stopCalls = 0
    var finalizeCalls = 0
    var abortCalls = 0
    var discardOutputCalls = 0
    var discardRequested = false
  }

  private let lock = NSLock()
  private let startGate: StageCaptureTestGate?
  private let stopGate: StageCaptureTestGate?
  private let outputURL: URL
  let frameCounters: GolfTraceStageCaptureFrameCounters
  private var state = Snapshot()
  private var failureCallback: (@Sendable (Error) -> Void)?

  init(
    startGate: StageCaptureTestGate? = nil,
    stopGate: StageCaptureTestGate? = nil,
    outputURL: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-fake-stage.mov"),
    frameCounters: GolfTraceStageCaptureFrameCounters = GolfTraceStageCaptureFrameCounters()
  ) {
    self.startGate = startGate
    self.stopGate = stopGate
    self.outputURL = outputURL
    self.frameCounters = frameCounters
  }

  var onUnexpectedFailure: (@Sendable (Error) -> Void)? {
    get { lock.withLock { failureCallback } }
    set { lock.withLock { failureCallback = newValue } }
  }

  var snapshot: Snapshot {
    lock.withLock { state }
  }

  func start() async throws {
    mutate { $0.startCalls += 1 }
    if let startGate {
      await startGate.wait()
    }
    try Task.checkCancellation()
    guard !snapshot.discardRequested else { throw CancellationError() }
    mutate { $0.completedStarts += 1 }
  }

  func stop() async throws -> URL {
    mutate { $0.stopCalls += 1 }
    if let stopGate {
      await stopGate.wait()
    }
    guard !snapshot.discardRequested else { throw CancellationError() }
    mutate { $0.finalizeCalls += 1 }
    return outputURL
  }

  func requestDiscard() {
    mutate { $0.discardRequested = true }
  }

  func abortAndDiscard() async {
    mutate {
      $0.discardRequested = true
      $0.abortCalls += 1
    }
  }

  func discardOutput() {
    mutate { $0.discardOutputCalls += 1 }
  }

  private func mutate(_ update: (inout Snapshot) -> Void) {
    lock.withLock {
      update(&state)
    }
  }
}
