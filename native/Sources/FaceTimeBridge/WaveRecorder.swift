import Foundation

private final class PCM16WAVFile: @unchecked Sendable {
  private let handle: FileHandle
  private let lock = NSLock()
  private var dataBytes: UInt32 = 0
  private var closed = false

  init(url: URL, sampleRate: UInt32 = 24_000) throws {
    let header = Self.header(sampleRate: sampleRate, dataBytes: 0)
    guard FileManager.default.createFile(
      atPath: url.path,
      contents: header,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw CocoaError(.fileWriteUnknown)
    }
    handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
  }

  func append(_ pcm16: Data) throws {
    guard !pcm16.isEmpty else { return }
    try lock.withLock {
      guard !closed else { throw CocoaError(.fileWriteUnknown) }
      guard pcm16.count <= Int(UInt32.max - dataBytes) else { throw CocoaError(.fileWriteOutOfSpace) }
      try handle.write(contentsOf: pcm16)
      dataBytes += UInt32(pcm16.count)
    }
  }

  func close() throws {
    try lock.withLock {
      guard !closed else { return }
      closed = true
      try handle.seek(toOffset: 0)
      try handle.write(contentsOf: Self.header(sampleRate: 24_000, dataBytes: dataBytes))
      try handle.synchronize()
      try handle.close()
    }
  }

  private static func header(sampleRate: UInt32, dataBytes: UInt32) -> Data {
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func u16(_ value: UInt16) {
      var littleEndian = value.littleEndian
      data.append(Data(bytes: &littleEndian, count: MemoryLayout.size(ofValue: littleEndian)))
    }
    func u32(_ value: UInt32) {
      var littleEndian = value.littleEndian
      data.append(Data(bytes: &littleEndian, count: MemoryLayout.size(ofValue: littleEndian)))
    }

    text("RIFF")
    u32(36 + dataBytes)
    text("WAVEfmt ")
    u32(16)
    u16(1)
    u16(1)
    u32(sampleRate)
    u32(sampleRate * 2)
    u16(2)
    u16(16)
    text("data")
    u32(dataBytes)
    return data
  }
}

final class CallWaveRecorder: @unchecked Sendable {
  private let caller: PCM16WAVFile
  private let agent: PCM16WAVFile
  private let directory: URL
  private let stateLock = NSLock()
  private var disabled = false

  static func fromEnvironment() throws -> CallWaveRecorder? {
    guard let root = ProcessInfo.processInfo.environment["FACETIME_BRIDGE_RECORDINGS_DIR"] else { return nil }
    guard root.hasPrefix("/") else { throw CocoaError(.fileWriteInvalidFileName) }
    return try create(in: URL(fileURLWithPath: root, isDirectory: true))
  }

  private static func create(in root: URL) throws -> CallWaveRecorder {
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let folder = Date().formatted(.iso8601)
      .replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.lowercased()
    let call = root.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(
      at: call,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return try CallWaveRecorder(
      caller: PCM16WAVFile(url: call.appendingPathComponent("caller.wav")),
      agent: PCM16WAVFile(url: call.appendingPathComponent("agent.wav")),
      directory: call
    )
  }

  private init(caller: PCM16WAVFile, agent: PCM16WAVFile, directory: URL) {
    self.caller = caller
    self.agent = agent
    self.directory = directory
  }

  func appendCaller(_ data: Data) { append(data, to: caller) }
  func appendAgent(_ data: Data) { append(data, to: agent) }

  func close() {
    stateLock.withLock { disabled = true }
    try? caller.close()
    try? agent.close()
  }

  private func append(_ data: Data, to file: PCM16WAVFile) {
    guard stateLock.withLock({ !disabled }) else { return }
    do {
      try file.append(data)
    } catch {
      let shouldReport = stateLock.withLock {
        guard !disabled else { return false }
        disabled = true
        return true
      }
      if shouldReport {
        fputs("facetime-bridge: WAV recording disabled after a write failure: \(error)\n", stderr)
        try? caller.close()
        try? agent.close()
      }
    }
  }

  static func selfCheck() -> Bool {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("facetime-bridge-wave-self-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    guard let recorder = try? create(in: root) else {
      fputs("WAV self-check: could not create recorder\n", stderr)
      return false
    }
    recorder.appendCaller(Data([1, 2]))
    recorder.appendAgent(Data([3, 4, 5, 6]))
    recorder.close()
    guard let callerData = try? Data(contentsOf: recorder.directory.appendingPathComponent("caller.wav")),
          let agentData = try? Data(contentsOf: recorder.directory.appendingPathComponent("agent.wav")) else {
      fputs("WAV self-check: could not read valid recording fixture\n", stderr)
      return false
    }
    guard callerData.prefix(4) == Data("RIFF".utf8),
          callerData.count == 46,
          callerData[40..<44] == Data([2, 0, 0, 0]),
          agentData.count == 48,
          agentData[40..<44] == Data([4, 0, 0, 0]) else {
      fputs("WAV self-check: caller=\(callerData.count) \(Array(callerData[40..<min(44, callerData.count)])) agent=\(agentData.count) \(Array(agentData[40..<min(44, agentData.count)]))\n", stderr)
      fputs("WAV self-check: valid PCM did not produce valid headers\n", stderr)
      return false
    }

    let failureDirectory = root.appendingPathComponent("failure", isDirectory: true)
    guard (try? FileManager.default.createDirectory(
      at: failureDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )) != nil,
      let closedCaller = try? PCM16WAVFile(url: failureDirectory.appendingPathComponent("caller.wav")),
      let untouchedAgent = try? PCM16WAVFile(url: failureDirectory.appendingPathComponent("agent.wav")),
      (try? closedCaller.close()) != nil else {
      fputs("WAV self-check: could not create failure fixture\n", stderr)
      return false
    }
    let failing = CallWaveRecorder(caller: closedCaller, agent: untouchedAgent, directory: failureDirectory)
    failing.appendCaller(Data([1, 2]))
    guard failing.stateLock.withLock({ failing.disabled }) else {
      fputs("WAV self-check: write failure did not disable recorder\n", stderr)
      return false
    }
    failing.appendAgent(Data([3, 4]))
    failing.close()
    guard let untouched = try? Data(contentsOf: failureDirectory.appendingPathComponent("agent.wav")) else {
      fputs("WAV self-check: could not read failure fixture\n", stderr)
      return false
    }
    return untouched.count == 44 && untouched[40..<44] == Data([0, 0, 0, 0])
  }
}
