import ApplicationServices
import Darwin
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
  case invalidCommand
  case unsafeConfig
  case invalidConfig
}

struct ControlRunner: Sendable {
  private let configPath = "/Users/saint/.config/facetime-bridge/config.json"
  private let maximumConfigBytes = 16 * 1024

  func run(_ command: Facetimebridge_V1_ControlCommand) throws -> ControlEvidence {
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
    default: throw ControlRunnerError.invalidCommand
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

  func loadTarget() throws -> TargetIdentity {
    var metadata = stat()
    guard lstat(configPath, &metadata) == 0,
          metadata.st_uid == getuid(),
          metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_mode & 0o777 == 0o600,
          metadata.st_size <= maximumConfigBytes else {
      throw ControlRunnerError.unsafeConfig
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: configPath), options: .uncached)
    guard data.count <= maximumConfigBytes,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys).isSubset(of: ["targetHandle", "targetName", "callerAuthority", "blackHole2chLabel", "blackHole16chLabel"]),
          let handle = object["targetHandle"] as? String,
          let name = object["targetName"] as? String,
          let authority = CallerAuthority(rawValue: object["callerAuthority"] as? String ?? CallerAuthority.exactHandle.rawValue),
          let target = try? TargetIdentity(handle: handle, name: name, authority: authority) else {
      throw ControlRunnerError.invalidConfig
    }
    return target
  }
}
