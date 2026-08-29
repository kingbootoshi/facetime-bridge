import ApplicationServices
import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

private func emitControlResult(_ result: ControlResult) -> Never {
  do {
    let data = try JSONEncoder().encode(result)
    print(String(decoding: data, as: UTF8.self))
    exit(result.ok ? 0 : 1)
  } catch {
    fputs("native control response encoding failed\n", stderr)
    exit(1)
  }
}

private func failedControlResult(
  command: ControlCommand,
  code: String,
  message: String
) -> ControlResult {
  ControlResult(
    ok: false,
    command: command,
    state: .unknown,
    authorized: false,
    action: nil,
    message: message,
    errorCode: code
  )
}

private func runDirectControl(_ command: ControlCommand) -> Never {
  do {
    let evidence = try ControlRunner().run(command)
    let result = ControlResult(
      ok: evidence.ok,
      command: command,
      state: CallState(rawValue: evidence.state) ?? .unknown,
      authorized: evidence.authorized,
      action: evidence.action.flatMap(ControlAction.init(rawValue:)),
      message: evidence.message,
      errorCode: evidence.errorCode
    )
    emitControlResult(result)
  } catch ControlRunnerError.missingAuthorizedCallerE164 {
    emitControlResult(failedControlResult(
      command: command,
      code: "AUTHORIZED_CALLER_MISSING",
      message: "\(ControlRunner.authorizedCallerEnvironmentKey) must be set to one E.164 phone number"
    ))
  } catch ControlRunnerError.invalidAuthorizedCallerE164 {
    emitControlResult(failedControlResult(
      command: command,
      code: "AUTHORIZED_CALLER_INVALID",
      message: "\(ControlRunner.authorizedCallerEnvironmentKey) must be one exact E.164 phone number"
    ))
  } catch {
    emitControlResult(failedControlResult(
      command: command,
      code: "NATIVE_CONTROL_FAILED",
      message: "native FaceTime control failed unexpectedly"
    ))
  }
}

if CommandLine.arguments.dropFirst().elementsEqual(["--ax-snapshot"]) {
  guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is required\n", stderr)
    exit(1)
  }
  let target = try ControlRunner().loadTarget()
  let data = try JSONSerialization.data(withJSONObject: sanitizedAccessibilitySnapshot(target: target), options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
  exit(0)
}

if CommandLine.arguments.dropFirst().elementsEqual(["--self-check"]) {
  guard shouldAnswerIncoming(state: "ringing", authorized: true),
        !shouldAnswerIncoming(state: "ringing", authorized: false),
        !shouldAnswerIncoming(state: "ambiguous", authorized: true),
        faceTimeIncomingFixturePasses(),
        identityDigitFixturePasses(),
        authorityLifecyclePasses(),
        CallWaveRecorder.selfCheck(),
        AudioBridge.inputDeviceName == "BlackHole 16ch",
        AudioBridge.outputDeviceName == "BlackHole 2ch",
        AudioBridge.transportSampleRate == 24_000 else {
    fputs("native FaceTime self-check failed\n", stderr)
    exit(1)
  }
  print("{\"nativeSelfCheck\":true}")
  exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 1, let command = ControlCommand(rawValue: arguments[0]) {
  runDirectControl(command)
}
if !arguments.isEmpty {
  fputs("Usage: facetime-bridge [probe|call|answer|hangup|--self-check|--ax-snapshot]\n", stderr)
  exit(2)
}

do {
  _ = try ControlRunner().loadTarget()
} catch ControlRunnerError.missingAuthorizedCallerE164 {
  fputs("FACETIME_BRIDGE_AUTHORIZED_CALLER_E164 must be set to one E.164 phone number\n", stderr)
  exit(1)
} catch ControlRunnerError.invalidAuthorizedCallerE164 {
  fputs("FACETIME_BRIDGE_AUTHORIZED_CALLER_E164 must be one exact E.164 phone number\n", stderr)
  exit(1)
} catch {
  fputs("native caller authority loading failed\n", stderr)
  exit(1)
}

let socketDefault = NSString(string: "~/.facetime-bridge/bridge.sock").expandingTildeInPath
let socketPath = ProcessInfo.processInfo.environment["FACETIME_BRIDGE_SOCKET"] ?? socketDefault
try? FileManager.default.createDirectory(
  atPath: (socketPath as NSString).deletingLastPathComponent,
  withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: socketPath) {
  try FileManager.default.removeItem(atPath: socketPath)
}

let server = GRPCServer(
  transport: .http2NIOPosix(
    address: .unixDomainSocket(path: socketPath),
    transportSecurity: .plaintext
  ),
  services: [FaceTimeMediaService()]
)

try await withThrowingDiscardingTaskGroup { group in
  group.addTask { try await server.serve() }
  if let address = try await server.listeningAddress {
    guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
      throw POSIXError(.EACCES)
    }
    print("facetime-media ready at \(address)")
  }
}
