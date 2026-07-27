import Combine
import Foundation

/// Keeps source-master export work alive long enough for macOS termination to
/// wait for it. The work itself stays camera-first: stopping admission prevents
/// a new take, but never cancels a bundle that is already being finalized.
@MainActor
final class SwingReplayBundleWorkTracker: ObservableObject {
  @Published private(set) var pendingWorkCount = 0

  var hasPendingWork: Bool { pendingWorkCount > 0 }

  private var acceptsNewWork = true
  private var tasks: [UUID: Task<Void, Never>] = [:]

  @discardableResult
  func start(
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Bool {
    guard acceptsNewWork else { return false }

    let id = UUID()
    pendingWorkCount += 1
    let task = Task { @MainActor [weak self] in
      await operation()
      self?.complete(id)
    }
    tasks[id] = task
    return true
  }

  func prepareForTermination() {
    acceptsNewWork = false
  }

  func flushPendingWork() async {
    while !tasks.isEmpty {
      let snapshot = Array(tasks.values)
      for task in snapshot {
        await task.value
      }
      await Task.yield()
    }
  }

  private func complete(_ id: UUID) {
    guard tasks.removeValue(forKey: id) != nil else { return }
    pendingWorkCount = max(0, pendingWorkCount - 1)
  }
}
