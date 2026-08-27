import AppKit
import ApplicationServices
import Foundation

private let pollInterval: TimeInterval = 0.25
private let discoveryDeadline: TimeInterval = 25
private let confirmationDeadline: TimeInterval = 12

private func result(
    command: ControlCommand,
    ok: Bool,
    evidence: StateEvidence,
    action: ControlAction? = nil,
    message: String,
    errorCode: String? = nil
) -> ControlResult {
    ControlResult(
        ok: ok,
        command: command,
        state: evidence.state,
        authorized: evidence.authorized,
        action: action,
        message: message,
        errorCode: errorCode
    )
}

private func failure(
    command: ControlCommand,
    code: String,
    message: String,
    evidence: StateEvidence? = nil
) -> ControlResult {
    result(
        command: command,
        ok: false,
        evidence: evidence ?? StateEvidence(state: .unknown, duration: nil, surface: nil, authorized: false),
        message: message,
        errorCode: code
    )
}

private func serviceMainRunLoop() {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
}

private func waitForState(_ accepted: Set<CallState>, target: TargetIdentity, deadline: Date) -> StateEvidence? {
    while Date() < deadline {
        serviceMainRunLoop()
        let evidence = state(of: scanAccessibility(), target: target)
        if accepted.contains(evidence.state) { return evidence }
    }
    return nil
}

private func press(_ candidate: ActionCandidate) -> AXError {
    AXUIElementPerformAction(candidate.node.element, kAXPressAction as CFString)
}

private func hasAnyOutgoingPrompt(_ snapshot: AXSnapshot) -> Bool {
    snapshot.surfaces.contains { surface in
        surface.bundleID == "com.apple.notificationcenterui"
            && surface.nodes.contains { node in
                node.texts.contains { semanticContains($0, "Click to Call") }
                    && semanticAction(node, labels: ["Call", "FaceTime Audio", "communication audio"])
            }
    }
}

private func hasUnverifiedIncomingCall(_ snapshot: AXSnapshot) -> Bool {
    snapshot.surfaces.contains { surface in
        guard surface.bundleID == "com.apple.notificationcenterui" else { return false }
        return surface.nodes.contains { node in
            node.role == "AXGenericElement"
                && node.enabled
                && node.actions.contains(kAXPressAction as String)
                && node.texts.contains {
                    semanticContains($0, "FaceTime Audio")
                        && !semanticContains($0, "Click to Call")
                        && !semanticContains($0, "left")
                        && !semanticContains($0, "ended")
                        && !semanticContains($0, "missed")
                }
        }
    }
}

func probeFaceTime(target: TargetIdentity?) -> ControlResult {
    let evidence = state(of: scanAccessibility(), target: target)
    return result(command: .probe, ok: true, evidence: evidence, message: "FaceTime state inspected")
}

func callTarget(_ target: TargetIdentity) -> ControlResult {
    let before = scanAccessibility()
    guard !hasAnyOutgoingPrompt(before) else {
        return failure(command: .call, code: "PREEXISTING_PROMPT", message: "a call prompt already exists")
    }
    guard let url = URL(string: "facetime-audio://\(target.handle)"), NSWorkspace.shared.open(url) else {
        return failure(command: .call, code: "OPEN_FAILED", message: "FaceTime Audio URL could not be opened")
    }
    let deadline = Date().addingTimeInterval(discoveryDeadline)
    while Date() < deadline {
        serviceMainRunLoop()
        let snapshot = scanAccessibility()
        let candidates = outgoingCandidates(in: snapshot, target: target)
        if candidates.count > 1 {
            return failure(command: .call, code: "AMBIGUOUS_ACTION", message: "more than one authorized call action matched")
        }
        guard let candidate = candidates.first else {
            if hasAnyOutgoingPrompt(snapshot) {
                return failure(command: .call, code: "TARGET_NOT_AUTHORIZED", message: "the call prompt did not match the configured identity")
            }
            continue
        }
        guard press(candidate) == .success else {
            return failure(command: .call, code: "PRESS_FAILED", message: "the authorized call action could not be pressed")
        }
        guard let confirmed = waitForState([.dialing, .connected], target: target, deadline: Date().addingTimeInterval(confirmationDeadline)) else {
            return failure(command: .call, code: "CONFIRMATION_TIMEOUT", message: "the call did not enter dialing or connected state")
        }
        return result(command: .call, ok: true, evidence: confirmed, action: .confirmed, message: "authorized call started")
    }
    return failure(command: .call, code: "PROMPT_TIMEOUT", message: "no authorized call prompt appeared")
}

func answerTarget(_ target: TargetIdentity) -> ControlResult {
    let deadline = Date().addingTimeInterval(discoveryDeadline)
    while Date() < deadline {
        serviceMainRunLoop()
        let snapshot = scanAccessibility()
        let matches = snapshot.surfaces.compactMap { surface -> ActionCandidate? in
            guard let node = authorizedIncomingNode(on: surface, target: target) else { return nil }
            return ActionCandidate(surface: surface, node: node)
        }
        if matches.count > 1 {
            return failure(command: .answer, code: "AMBIGUOUS_ACTION", message: "more than one authorized answer action matched")
        }
        if let candidate = matches.first {
            guard press(candidate) == .success else {
                return failure(command: .answer, code: "PRESS_FAILED", message: "the authorized answer action could not be pressed")
            }
            guard let confirmed = waitForState([.connected], target: target, deadline: Date().addingTimeInterval(confirmationDeadline)) else {
                return failure(command: .answer, code: "CONFIRMATION_TIMEOUT", message: "the call did not enter connected state")
            }
            return result(command: .answer, ok: true, evidence: confirmed, action: .answered, message: "authorized call answered")
        }
        if hasUnverifiedIncomingCall(snapshot) {
            return failure(command: .answer, code: "CALLER_NOT_AUTHORIZED", message: "the incoming caller did not match the configured identity")
        }
    }
    return failure(command: .answer, code: "RING_TIMEOUT", message: "no authorized incoming call appeared")
}

func hangupTarget(_ target: TargetIdentity) -> ControlResult {
    let snapshot = scanAccessibility()
    let current = state(of: snapshot, target: target)
    guard current.state == .connected, current.authorized else {
        return failure(command: .hangup, code: "NO_AUTHORIZED_CALL", message: "no authorized connected call is active", evidence: current)
    }
    let phoneSurfaces = snapshot.surfaces.filter {
        $0.bundleID == "com.apple.mobilephone"
            && surfaceAuthorized($0, target: target)
            && state(of: $0, target: target).state == .connected
    }
    guard phoneSurfaces.count == 1, let phone = phoneSurfaces.first else {
        return failure(command: .hangup, code: "AMBIGUOUS_PHONE_SURFACE", message: "the authorized call did not map to one Phone process", evidence: current)
    }
    guard let application = NSRunningApplication(processIdentifier: phone.pid),
          application.bundleIdentifier == "com.apple.mobilephone",
          application.terminate() else {
        return failure(command: .hangup, code: "TERMINATE_FAILED", message: "Phone refused graceful termination", evidence: current)
    }
    guard let confirmed = waitForState([.idle, .ended], target: target, deadline: Date().addingTimeInterval(confirmationDeadline)) else {
        return failure(command: .hangup, code: "CONFIRMATION_TIMEOUT", message: "the call did not enter ended state", evidence: current)
    }
    return result(command: .hangup, ok: true, evidence: confirmed, action: .hungUp, message: "authorized call ended")
}
