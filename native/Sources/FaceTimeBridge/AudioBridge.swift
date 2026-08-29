@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

private enum AudioBridgeError: Error {
  case deviceMissing(String)
  case deviceSelectionFailed(OSStatus)
  case invalidCaptureFormat(Double, AVAudioChannelCount)
  case bufferAllocationFailed
}

private func audioDeviceID(named expectedName: String) throws -> AudioDeviceID {
  var devicesAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )
  var size: UInt32 = 0
  try statusError(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size))
  let count = Int(size) / MemoryLayout<AudioDeviceID>.size
  var devices = [AudioDeviceID](repeating: 0, count: count)
  try statusError(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, &devices))

  for device in devices {
    var nameAddress = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr,
          let name else { continue }
    if name.takeUnretainedValue() as String == expectedName { return device }
  }
  throw AudioBridgeError.deviceMissing(expectedName)
}

private func statusError(_ status: OSStatus) throws {
  guard status == noErr else { throw AudioBridgeError.deviceSelectionFailed(status) }
}

private func selectDevice(_ device: AudioDeviceID, for audioUnit: AudioUnit) throws {
  var selected = device
  try statusError(AudioUnitSetProperty(
    audioUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &selected,
    UInt32(MemoryLayout<AudioDeviceID>.size)
  ))
}

final class AudioBridge: @unchecked Sendable {
  static let inputDeviceName = "BlackHole 16ch"
  static let outputDeviceName = "BlackHole 2ch"
  static let transportSampleRate: Double = 24_000

  private let captureEngine = AVAudioEngine()
  private let playbackEngine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var captureContinuation: AsyncStream<Data>.Continuation?
  private var captureSequence: UInt64 = 0
  private let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: transportSampleRate,
    channels: 1,
    interleaved: false
  )!

  func start() throws -> AsyncStream<Data> {
    let inputDevice = try audioDeviceID(named: Self.inputDeviceName)
    let outputDevice = try audioDeviceID(named: Self.outputDeviceName)
    guard let captureUnit = captureEngine.inputNode.audioUnit,
          let playbackUnit = playbackEngine.outputNode.audioUnit else {
      throw AudioBridgeError.bufferAllocationFailed
    }
    try selectDevice(inputDevice, for: captureUnit)
    try selectDevice(outputDevice, for: playbackUnit)

    let input = captureEngine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate == 48_000, inputFormat.channelCount >= 2 else {
      throw AudioBridgeError.invalidCaptureFormat(inputFormat.sampleRate, inputFormat.channelCount)
    }

    let stream = AsyncStream<Data> { continuation in
      captureContinuation = continuation
    }
    input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
      self?.emitCapture(buffer)
    }

    playbackEngine.attach(player)
    playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: playbackFormat)
    try captureEngine.start()
    try playbackEngine.start()
    player.play()
    return stream
  }

  func enqueuePlayback(_ data: Data) throws {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
          let destination = buffer.floatChannelData?[0] else {
      throw AudioBridgeError.bufferAllocationFailed
    }
    buffer.frameLength = AVAudioFrameCount(sampleCount)
    data.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for index in 0..<sampleCount {
        destination[index] = Float(samples[index]) / Float(Int16.max)
      }
    }
    player.scheduleBuffer(buffer)
    if !player.isPlaying { player.play() }
  }

  func clearPlayback() {
    player.stop()
    player.play()
  }

  func stop() {
    captureEngine.inputNode.removeTap(onBus: 0)
    player.stop()
    captureEngine.stop()
    playbackEngine.stop()
    captureContinuation?.finish()
    captureContinuation = nil
  }

  private func emitCapture(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData else { return }
    let sourceFrames = Int(buffer.frameLength)
    let targetFrames = sourceFrames / 2
    var samples = [Int16](repeating: 0, count: targetFrames)
    for index in 0..<targetFrames {
      let sourceIndex = index * 2
      let first = (channels[0][sourceIndex] + channels[1][sourceIndex]) * 0.5
      let second = (channels[0][sourceIndex + 1] + channels[1][sourceIndex + 1]) * 0.5
      let clamped = max(-1, min(1, (first + second) * 0.5))
      samples[index] = Int16(clamped * Float(Int16.max))
    }
    captureSequence &+= 1
    captureContinuation?.yield(samples.withUnsafeBytes { Data($0) })
  }
}
