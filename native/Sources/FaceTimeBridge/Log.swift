import Foundation

private let flightDirectory = "/tmp/facetime-bridge-flight"

private let logStamp: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

func ftbLog(_ message: String) {
  FileHandle.standardError.write(Data("\(logStamp.string(from: Date())) \(message)\n".utf8))
}

/// Writes a sanitized AX snapshot to the flight directory so a failed
/// confirmation can be diagnosed after the call UI is gone.
func dumpFlightSnapshot(target: TargetIdentity, reason: String) {
  let rows = sanitizedAccessibilitySnapshot(target: target)
  guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) else {
    ftbLog("flight: snapshot serialization failed reason=\(reason)")
    return
  }
  let stamp = logStamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
  let path = "\(flightDirectory)/\(stamp)-\(reason).json"
  do {
    try FileManager.default.createDirectory(atPath: flightDirectory, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path))
    ftbLog("flight: wrote \(path) (\(rows.count) nodes)")
  } catch {
    ftbLog("flight: write failed reason=\(reason) error=\(error)")
  }
}
