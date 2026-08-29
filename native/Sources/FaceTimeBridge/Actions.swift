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

// Call authority is established at action time - an identity-verified press of an
// Answer or Call control - and carried as this in-process token, because the live
// com.apple.mobilephone surface exposes no caller identity. Connected evidence
// counts as authorized, and hangup may terminate the Phone process, only while
// the token is live AND bound to the same Phone pid first observed connected
// under it. The token expires after authorityLifetime, clears on any observed
// idle/ended scan, and clears when a press fails to confirm. The daemon serves
// gRPC on the main run loop, so access is single-threaded (nonisolated(unsafe)).
// ponytail: pid binding plus expiry bounds the stale-token window; the remaining
// gap is a manual call raced inside one authorityLifetime with no intervening
// scan AND Phone reusing the same pid - practically nil. Upgrade path is
// correlating a CallServices call UUID.
private let authorityLifetime: TimeInterval = 4 * 3600

private struct CallAuthority {
    let granted: Date
    var phonePid: pid_t?
}

nonisolated(unsafe) private var activeCallAuthority: CallAuthority?

private func clearAuthority(_ reason: String) {
    if activeCallAuthority != nil {
        ftbLog("authority: cleared (\(reason))")
        activeCallAuthority = nil
    }
}

private func withAuthority(_ evidence: StateEvidence) -> StateEvidence {
    if let authority = activeCallAuthority, Date() > authority.granted.addingTimeInterval(authorityLifetime) {
        clearAuthority("expired")
    }
    switch evidence.state {
    case .ended:
        clearAuthority("observed ended")
        return evidence
    case .idle:
        // Observed live 2026-08-29 19:24: the banner vanishes ~70ms after the
        // authorized answer press, before the Phone process surface exists, so a
        // pre-bind idle scan is the normal establishment gap. Idle only proves the
        // call is over once the token has bound to a Phone pid; an unbound token
        // is still cleared by confirmation timeouts and expiry.
        if activeCallAuthority?.phonePid != nil {
            clearAuthority("observed idle after bound call")
        }
        return evidence
    case .connected where !evidence.authorized:
        guard let authority = activeCallAuthority, let pid = evidence.surface?.pid else { return evidence }
        if authority.phonePid == nil {
            activeCallAuthority?.phonePid = pid
            ftbLog("authority: bound to Phone pid \(pid)")
        } else if authority.phonePid != pid {
            return evidence
        }
        return StateEvidence(state: .connected, duration: evidence.duration, surface: evidence.surface, authorized: true)
    default:
        return evidence
    }
}

private func waitForState(_ accepted: Set<CallState>, target: TargetIdentity, deadline: Date) -> StateEvidence? {
    var lastLogged: CallState?
    while Date() < deadline {
        serviceMainRunLoop()
        let evidence = withAuthority(state(of: scanAccessibility(), target: target))
        if evidence.state != lastLogged {
            ftbLog("waitForState: state=\(evidence.state) authorized=\(evidence.authorized) accepted=\(accepted)")
            lastLogged = evidence.state
        }
        if accepted.contains(evidence.state) { return evidence }
    }
    ftbLog("waitForState: TIMEOUT accepted=\(accepted) lastState=\(String(describing: lastLogged))")
    dumpFlightSnapshot(target: target, reason: "confirm-timeout")
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
        if surface.bundleID == "com.apple.FaceTime" {
            return surface.nodes.contains(where: isIncomingAudioAction)
        }
        guard surface.bundleID == "com.apple.notificationcenterui" else { return false }
        return surface.nodes.contains { semanticAction($0, labels: answerLabels) }
            || surface.nodes.contains { node in
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
    let evidence = withAuthority(state(of: scanAccessibility(), target: target))
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
                return failure(command: .call, code: "TARGET_NOT_AUTHORIZED", message: "the call prompt did not match the authorized E.164 number")
            }
            continue
        }
        guard press(candidate) == .success else {
            return failure(command: .call, code: "PRESS_FAILED", message: "the authorized call action could not be pressed")
        }
        activeCallAuthority = CallAuthority(granted: Date(), phonePid: nil)
        ftbLog("authority: granted by authorized call press")
        guard let confirmed = waitForState([.dialing, .connected], target: target, deadline: Date().addingTimeInterval(confirmationDeadline)) else {
            clearAuthority("call confirmation timeout")
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
        let matches = snapshot.surfaces.flatMap { surface in
            authorizedIncomingNodes(on: surface, target: target).map {
                ActionCandidate(surface: surface, node: $0)
            }
        }
        if matches.count > 1 {
            return failure(command: .answer, code: "AMBIGUOUS_ACTION", message: "more than one authorized answer action matched")
        }
        if let candidate = matches.first {
            ftbLog("answer: authorized ring matched, pressing")
            let pressResult = press(candidate)
            ftbLog("answer: press result=\(pressResult.rawValue)")
            guard pressResult == .success else {
                return failure(command: .answer, code: "PRESS_FAILED", message: "the authorized answer action could not be pressed")
            }
            activeCallAuthority = CallAuthority(granted: Date(), phonePid: nil)
            ftbLog("authority: granted by authorized answer press")
            guard let confirmed = waitForState([.connected], target: target, deadline: Date().addingTimeInterval(confirmationDeadline)) else {
                clearAuthority("answer confirmation timeout")
                return failure(command: .answer, code: "CONFIRMATION_TIMEOUT", message: "the call did not enter connected state")
            }
            return result(command: .answer, ok: true, evidence: confirmed, action: .answered, message: "authorized call answered")
        }
        if hasUnverifiedIncomingCall(snapshot) {
            return failure(command: .answer, code: "CALLER_NOT_AUTHORIZED", message: "the incoming caller did not match the authorized E.164 number")
        }
    }
    return failure(command: .answer, code: "RING_TIMEOUT", message: "no authorized incoming call appeared")
}

func hangupTarget(_ target: TargetIdentity) -> ControlResult {
    let snapshot = scanAccessibility()
    let current = withAuthority(state(of: snapshot, target: target))
    guard current.state == .connected, current.authorized, let authority = activeCallAuthority, let boundPid = authority.phonePid else {
        return failure(command: .hangup, code: "NO_AUTHORIZED_CALL", message: "no authorized connected call is active", evidence: current)
    }
    let phoneSurfaces = snapshot.surfaces.filter {
        $0.bundleID == "com.apple.mobilephone"
            && $0.pid == boundPid
            && state(of: $0, target: target).state == .connected
    }
    guard phoneSurfaces.count == 1, let phone = phoneSurfaces.first else {
        return failure(command: .hangup, code: "AMBIGUOUS_PHONE_SURFACE", message: "the authority-bound Phone process is not in a connected call", evidence: current)
    }
    guard let application = NSRunningApplication(processIdentifier: phone.pid),
          application.bundleIdentifier == "com.apple.mobilephone",
          application.terminate() else {
        return failure(command: .hangup, code: "TERMINATE_FAILED", message: "Phone refused graceful termination", evidence: current)
    }
    guard let confirmed = waitForState([.idle, .ended], target: target, deadline: Date().addingTimeInterval(confirmationDeadline)) else {
        // Termination was already requested; the token must not outlive this
        // command whether or not macOS confirmed the ended state in time.
        clearAuthority("hangup confirmation timeout")
        return failure(command: .hangup, code: "CONFIRMATION_TIMEOUT", message: "the call did not enter ended state", evidence: current)
    }
    return result(command: .hangup, ok: true, evidence: confirmed, action: .hungUp, message: "authorized call ended")
}

func authorityLifecyclePasses() -> Bool {
    func phoneEvidence(pid: pid_t) -> StateEvidence {
        StateEvidence(
            state: .connected,
            duration: nil,
            surface: AXSurface(pid: pid, process: "Phone", bundleID: "com.apple.mobilephone", nodes: []),
            authorized: false
        )
    }
    defer { activeCallAuthority = nil }

    // A manual call with no token must stay unauthorized.
    activeCallAuthority = nil
    guard !withAuthority(phoneEvidence(pid: 100)).authorized else { return false }

    // A live token binds to the first connected Phone pid and upgrades it.
    activeCallAuthority = CallAuthority(granted: Date(), phonePid: nil)
    guard withAuthority(phoneEvidence(pid: 100)).authorized,
          activeCallAuthority?.phonePid == 100 else { return false }

    // A different Phone pid under the same token must not upgrade.
    guard !withAuthority(phoneEvidence(pid: 200)).authorized else { return false }

    // The bound pid still upgrades.
    guard withAuthority(phoneEvidence(pid: 100)).authorized else { return false }

    // An observed ended state clears the token.
    _ = withAuthority(StateEvidence(state: .ended, duration: nil, surface: nil, authorized: false))
    guard activeCallAuthority == nil,
          !withAuthority(phoneEvidence(pid: 100)).authorized else { return false }

    // Idle before the token binds is the establishment gap: it must not clear.
    activeCallAuthority = CallAuthority(granted: Date(), phonePid: nil)
    _ = withAuthority(StateEvidence(state: .idle, duration: nil, surface: nil, authorized: false))
    guard activeCallAuthority != nil else { return false }

    // An observed idle state after pid binding clears the token.
    activeCallAuthority = CallAuthority(granted: Date(), phonePid: 100)
    _ = withAuthority(StateEvidence(state: .idle, duration: nil, surface: nil, authorized: false))
    guard activeCallAuthority == nil else { return false }

    // An expired token never upgrades.
    activeCallAuthority = CallAuthority(granted: Date(timeIntervalSinceNow: -authorityLifetime - 1), phonePid: 100)
    guard !withAuthority(phoneEvidence(pid: 100)).authorized, activeCallAuthority == nil else { return false }

    // clearAuthority is what confirm timeouts call.
    activeCallAuthority = CallAuthority(granted: Date(), phonePid: nil)
    clearAuthority("self-check")
    return activeCallAuthority == nil
}
