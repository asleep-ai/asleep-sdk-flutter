import Foundation

enum InitializationPhase: String {
  case setup
  case configuration
}

protocol InitializationScheduledTask: AnyObject {
  func cancel()
}

protocol InitializationScheduling {
  func schedule(
    after delay: TimeInterval,
    _ action: @escaping () -> Void
  ) -> InitializationScheduledTask
}

private final class DispatchInitializationTask: InitializationScheduledTask {
  private let workItem: DispatchWorkItem

  init(workItem: DispatchWorkItem) {
    self.workItem = workItem
  }

  func cancel() {
    workItem.cancel()
  }
}

struct DispatchInitializationScheduler: InitializationScheduling {
  func schedule(
    after delay: TimeInterval,
    _ action: @escaping () -> Void
  ) -> InitializationScheduledTask {
    let workItem = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    return DispatchInitializationTask(workItem: workItem)
  }
}

func initializationTimeoutError(
  phase: InitializationPhase,
  timeout: TimeInterval
) -> PigeonError {
  PigeonError(
    code: "INITIALIZATION_TIMEOUT",
    message: "The native Asleep SDK did not complete "
      + "\(phase.rawValue) within \(Int(timeout)) seconds",
    details: [
      "phase": phase.rawValue,
      "timeoutSeconds": Int(timeout),
      "platform": "ios",
    ]
  )
}

final class InitializationAttemptCoordinator {
  typealias Completion = (UInt64, Result<Void, Error>) -> Void

  private final class Attempt {
    let identifier: UInt64
    var phase: InitializationPhase
    let completion: Completion
    var timeoutTask: InitializationScheduledTask?

    init(
      identifier: UInt64,
      phase: InitializationPhase,
      completion: @escaping Completion
    ) {
      self.identifier = identifier
      self.phase = phase
      self.completion = completion
    }
  }

  static let defaultTimeout: TimeInterval = 30

  private let scheduler: InitializationScheduling
  private let timeout: TimeInterval
  private var nextIdentifier: UInt64 = 0
  private var activeAttempt: Attempt?

  init(
    scheduler: InitializationScheduling = DispatchInitializationScheduler(),
    timeout: TimeInterval = InitializationAttemptCoordinator.defaultTimeout
  ) {
    precondition(timeout > 0)
    self.scheduler = scheduler
    self.timeout = timeout
  }

  var hasActiveAttempt: Bool {
    activeAttempt != nil
  }

  func begin(
    phase: InitializationPhase,
    completion: @escaping Completion
  ) -> UInt64? {
    guard activeAttempt == nil else { return nil }
    nextIdentifier &+= 1
    let attempt = Attempt(
      identifier: nextIdentifier,
      phase: phase,
      completion: completion
    )
    activeAttempt = attempt
    armTimeout(for: attempt)
    return attempt.identifier
  }

  func isCurrent(
    _ identifier: UInt64,
    phase: InitializationPhase? = nil
  ) -> Bool {
    guard let attempt = activeAttempt, attempt.identifier == identifier else {
      return false
    }
    return phase == nil || attempt.phase == phase
  }

  @discardableResult
  func advance(
    _ identifier: UInt64,
    to phase: InitializationPhase
  ) -> Bool {
    guard
      let attempt = activeAttempt,
      attempt.identifier == identifier
    else {
      return false
    }
    attempt.timeoutTask?.cancel()
    attempt.timeoutTask = nil
    attempt.phase = phase
    armTimeout(for: attempt)
    return true
  }

  @discardableResult
  func succeed(_ identifier: UInt64) -> Bool {
    finish(identifier, result: .success(()))
  }

  @discardableResult
  func fail(_ identifier: UInt64, error: Error) -> Bool {
    finish(identifier, result: .failure(error))
  }

  func detach(error: Error) {
    guard let attempt = activeAttempt else { return }
    _ = finish(attempt.identifier, result: .failure(error))
  }

  private func armTimeout(for attempt: Attempt) {
    let identifier = attempt.identifier
    let phase = attempt.phase
    let task = scheduler.schedule(after: timeout) { [weak self] in
      guard let self, self.isCurrent(identifier, phase: phase) else { return }
      _ = self.fail(
        identifier,
        error: initializationTimeoutError(phase: phase, timeout: self.timeout)
      )
    }
    if isCurrent(identifier, phase: phase) {
      attempt.timeoutTask = task
    } else {
      task.cancel()
    }
  }

  @discardableResult
  private func finish(
    _ identifier: UInt64,
    result: Result<Void, Error>
  ) -> Bool {
    guard
      let attempt = activeAttempt,
      attempt.identifier == identifier
    else {
      return false
    }
    activeAttempt = nil
    attempt.timeoutTask?.cancel()
    attempt.timeoutTask = nil
    attempt.completion(identifier, result)
    return true
  }
}
