import ApplicationServices
import Foundation

struct ControlEvidence: Sendable {
  let ok: Bool
  let state: String
  let authorized: Bool
  let action: String?
  let errorCode: String?
  let message: String
}

enum ControlRunnerError: Error {
  case missingAuthorizedCallerE164
  case invalidAuthorizedCallerE164
}

struct ControlRunner: Sendable {
  static let authorizedCallerEnvironmentKey = "FACETIME_BRIDGE_AUTHORIZED_CALLER_E164"

  func run(_ command: ControlCommand) throws -> ControlEvidence {
    let target = try loadTarget()
    guard AXIsProcessTrusted() else {
      return ControlEvidence(
        ok: false,
        state: "unknown",
        authorized: false,
        action: nil,
        errorCode: "ACCESSIBILITY_NOT_TRUSTED",
        message: "manual Accessibility approval is required for facetime-bridge"
      )
    }
    let result: ControlResult
    switch command {
    case .probe: result = probeFaceTime(target: target)
    case .call: result = callTarget(target)
    case .answer: result = answerTarget(target)
    case .hangup: result = hangupTarget(target)
    }
    return ControlEvidence(
      ok: result.ok,
      state: result.state.rawValue,
      authorized: result.authorized,
      action: result.action?.rawValue,
      errorCode: result.errorCode,
      message: result.message
    )
  }

  func loadTarget(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TargetIdentity {
    guard let handle = environment[Self.authorizedCallerEnvironmentKey] else {
      throw ControlRunnerError.missingAuthorizedCallerE164
    }
    guard let target = try? TargetIdentity(handle: handle) else {
      throw ControlRunnerError.invalidAuthorizedCallerE164
    }
    return target
  }
}
