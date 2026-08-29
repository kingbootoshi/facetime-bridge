import Foundation
import GRPCCore

func shouldAnswerIncoming(state: String, authorized: Bool) -> Bool {
  state == "ringing" && authorized
}

struct FaceTimeMediaService: Facetimebridge_V1_FaceTimeMedia.SimpleServiceProtocol {
  private let control = ControlRunner()

  func health(
    request: Facetimebridge_V1_HealthRequest,
    context: ServerContext
  ) async throws -> Facetimebridge_V1_HealthResponse {
    .with {
      $0.ready = true
      $0.inputDevice = AudioBridge.inputDeviceName
      $0.outputDevice = AudioBridge.outputDeviceName
    }
  }

  func control(
    request: Facetimebridge_V1_ControlRequest,
    context: ServerContext
  ) async throws -> Facetimebridge_V1_ControlResponse {
    let evidence = try control.run(request.command)
    return response(from: evidence)
  }

  func waitIncoming(
    request: Facetimebridge_V1_WaitIncomingRequest,
    response: RPCWriter<Facetimebridge_V1_CallEvent>,
    context: ServerContext
  ) async throws {
    while !context.cancellation.isCancelled {
      let observed = try control.run(.probe)
      if observed.errorCode != nil {
        try await response.write(event(from: observed))
        return
      }
      if shouldAnswerIncoming(state: observed.state, authorized: observed.authorized) {
        try await response.write(event(from: observed))
        let answered = try control.run(.answer)
        try await response.write(event(from: answered))
        if answered.ok && answered.state == "connected" { return }
      }
      try await Task.sleep(for: .milliseconds(250))
    }
  }

  func audio(
    request: RPCAsyncSequence<Facetimebridge_V1_AudioPacket, any Error>,
    response: RPCWriter<Facetimebridge_V1_AudioPacket>,
    context: ServerContext
  ) async throws {
    var iterator = request.makeAsyncIterator()
    guard let start = try await iterator.next(),
          start.kind == .start,
          !start.callID.isEmpty,
          start.sampleRate == 24_000,
          start.channels == 1 else {
      throw RPCError(code: .invalidArgument, message: "the first audio packet must start one 24 kHz mono call")
    }

    let bridge = AudioBridge()
    let captures = try bridge.start()
    let callID = start.callID
    try await response.write(.with {
      $0.callID = callID
      $0.kind = .event
      $0.sampleRate = 24_000
      $0.channels = 1
      $0.event = "ready"
    })
    let captureTask = Task {
      var sequence: UInt64 = 0
      for await data in captures {
        sequence &+= 1
        try await response.write(.with {
          $0.callID = callID
          $0.kind = .capture
          $0.pcm16 = data
          $0.sampleRate = 24_000
          $0.channels = 1
          $0.sequence = sequence
        })
      }
    }

    defer {
      captureTask.cancel()
      bridge.stop()
    }

    while let packet = try await iterator.next() {
      guard packet.callID == callID else {
        throw RPCError(code: .invalidArgument, message: "audio packet call ID changed")
      }
      switch packet.kind {
      case .playback:
        try bridge.enqueuePlayback(packet.pcm16)
      case .clear:
        bridge.clearPlayback()
      case .stop:
        bridge.stop()
        _ = try await captureTask.value
        return
      default:
        throw RPCError(code: .invalidArgument, message: "unsupported audio packet kind")
      }
    }
    bridge.stop()
    _ = try await captureTask.value
  }

  private func response(from evidence: ControlEvidence) -> Facetimebridge_V1_ControlResponse {
    .with {
      $0.ok = evidence.ok
      $0.state = evidence.state
      $0.authorized = evidence.authorized
      $0.action = evidence.action ?? ""
      $0.errorCode = evidence.errorCode ?? ""
      $0.message = evidence.message
    }
  }

  private func event(from evidence: ControlEvidence) -> Facetimebridge_V1_CallEvent {
    .with {
      $0.state = evidence.state
      $0.authorized = evidence.authorized
      $0.errorCode = evidence.errorCode ?? ""
      $0.observedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
    }
  }
}
