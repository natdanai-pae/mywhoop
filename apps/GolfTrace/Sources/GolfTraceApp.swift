import AppKit
import Combine
import SwiftUI

@MainActor
final class GolfTraceAppDelegate: NSObject, NSApplicationDelegate {
  let historyController = SwingHistoryController()
  let replayController = SwingReplayController()
  let stageReplayRecorder = GolfTraceStageReplayRecorder()
  let rapsodoReplayRecorder = RapsodoSourceReplayRecorder()
  let replayBundleWorkTracker = SwingReplayBundleWorkTracker()
  let rapsodoCredentials = RapsodoCredentialSettings()
  let golfAISettings = GolfAISettings()
  lazy var golfKnowledgeController = GolfKnowledgeController(aiSettings: golfAISettings)
  lazy var aiGolfProController = AIGolfProController(settings: golfAISettings)
  lazy var launchMonitorController = LaunchMonitorController(
    tokenProvider: rapsodoCredentials.tokenProvider
  )

  private var terminationTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []
  private let singleInstanceGuard = GolfTraceSingleInstanceGuard()
  private var existingInstance: NSRunningApplication?
  private var shouldBlockLaunch = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    if let existing = anotherRunningGolfTrace() {
      existingInstance = existing
      shouldBlockLaunch = true
      return
    }

    switch singleInstanceGuard.acquire() {
    case .acquired:
      replayController.cleanStaleTemporaryReplaysAfterExclusiveLaunch()
    case .anotherInstanceRunning:
      shouldBlockLaunch = true
    case .unavailable:
      // หากยืนยันสิทธิ์ไม่ได้ ให้หยุดสำเนาใหม่นี้ไว้ก่อนเพื่อไม่ให้แย่ง Bluetooth
      shouldBlockLaunch = true
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !shouldBlockLaunch else {
      presentDuplicateLaunchAlert()
      return
    }

    let knowledgeController = golfKnowledgeController
    aiGolfProController.setKnowledgeProvider { [weak knowledgeController] question, settings in
      knowledgeController?.excerpts(
        for: "\(question) \(settings.guideline.rawValue) \(settings.coach.rawValue)",
        clubFamily: "\(settings.club.rawValue) \(settings.club.familyName)",
        cameraView: "\(settings.cameraView.rawValue) \(settings.cameraView.displayName)"
      ) ?? []
    }

    launchMonitorController.events
      .sink { [weak self] event in
        guard case .shot(let shot) = event else { return }
        self?.historyController.receiveLaunchMonitorShot(shot)
      }
      .store(in: &cancellables)

    launchMonitorController.start()

  }

  func applicationWillTerminate(_ notification: Notification) {
    singleInstanceGuard.release()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationTask != nil {
      return .terminateLater
    }
    launchMonitorController.stop()
    historyController.prepareForTermination()
    stageReplayRecorder.prepareForTermination()
    replayBundleWorkTracker.prepareForTermination()
    rapsodoReplayRecorder.prepareForTermination()
    guard
      stageReplayRecorder.hasPendingWork
        || rapsodoReplayRecorder.hasPendingWork
        || replayBundleWorkTracker.hasPendingWork
        || historyController.hasPendingPersistenceWork
        || replayController.hasPendingExportWork
        || launchMonitorController.hasPendingStopWork
    else {
      replayController.prepareForTermination()
      return .terminateNow
    }

    let stageReplayRecorder = stageReplayRecorder
    let historyController = historyController
    let replayController = replayController
    let launchMonitorController = launchMonitorController
    let rapsodoReplayRecorder = rapsodoReplayRecorder
    let replayBundleWorkTracker = replayBundleWorkTracker
    terminationTask = Task { @MainActor [weak self, weak sender] in
      await stageReplayRecorder.flushPendingWork()
      await replayBundleWorkTracker.flushPendingWork()
      await rapsodoReplayRecorder.flushPendingWork()
      replayController.prepareForTermination()
      await replayController.flushPendingExports()
      await historyController.flushPendingOperations()
      await launchMonitorController.flushPendingStop()
      self?.terminationTask = nil
      sender?.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  private func anotherRunningGolfTrace() -> NSRunningApplication? {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
    let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first { application in
        application.processIdentifier != currentProcessIdentifier && !application.isTerminated
      }
  }

  private func presentDuplicateLaunchAlert() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "GolfTrace เปิดอยู่แล้ว"
    alert.informativeText =
      existingInstance == nil
      ? "แอปที่เพิ่งเปิดจะไม่เชื่อมต่อ MLM2PRO เพื่อป้องกัน Bluetooth ถูกใช้งานซ้ำ กรุณาปิด GolfTrace เดิมก่อน แล้วจึงเปิดอีกครั้ง"
      : "แอปที่เพิ่งเปิดจะไม่เชื่อมต่อ MLM2PRO เพื่อป้องกัน Bluetooth ถูกใช้งานซ้ำ คุณสามารถกลับไปใช้ GolfTrace ที่กำลังเปิดอยู่ได้"

    if existingInstance != nil {
      alert.addButton(withTitle: "เปิด GolfTrace ที่กำลังใช้อยู่")
    }
    alert.addButton(withTitle: "ปิดสำเนานี้")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      existingInstance?.activate(options: [])
    }
    NSApp.terminate(nil)
  }
}

@main
struct GolfTraceApp: App {
  @NSApplicationDelegateAdaptor(GolfTraceAppDelegate.self) private var appDelegate

  var body: some Scene {
    Window("วิเคราะห์วงสวิง", id: "main") {
      ContentView(
        history: appDelegate.historyController,
        replay: appDelegate.replayController,
        stageReplayRecorder: appDelegate.stageReplayRecorder,
        rapsodoReplayRecorder: appDelegate.rapsodoReplayRecorder,
        replayBundleWorkTracker: appDelegate.replayBundleWorkTracker,
        launchMonitor: appDelegate.launchMonitorController,
        rapsodoCredentials: appDelegate.rapsodoCredentials,
        aiGolfPro: appDelegate.aiGolfProController,
        knowledge: appDelegate.golfKnowledgeController
      )
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1_420, height: 900)
  }
}
