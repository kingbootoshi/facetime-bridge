import ApplicationServices
import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

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
        AudioBridge.inputDeviceName == "BlackHole 16ch",
        AudioBridge.outputDeviceName == "BlackHole 2ch",
        AudioBridge.transportSampleRate == 24_000 else {
    fputs("native FaceTime self-check failed\n", stderr)
    exit(1)
  }
  print("{\"nativeSelfCheck\":true}")
  exit(0)
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
