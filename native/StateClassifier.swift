import AppKit
import ApplicationServices
import Foundation

private let outgoingLabels = ["Call", "FaceTime Audio", "communication audio"]
private let dialingLabels = ["Dialing", "Dialing…", "Calling", "Calling…", "Connecting", "Connecting…"]
private let connectedLabels = ["Connected"]
private let endedLabels = ["Ended", "Call Ended", "Disconnected"]
private let durationExpression = try! NSRegularExpression(pattern: #"\b\d{1,3}:[0-5]\d\b"#)

func normalizedSemanticText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\u{202F}", with: " ")
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

func semanticContains(_ text: String, _ expected: String) -> Bool {
    normalizedSemanticText(text).localizedCaseInsensitiveContains(normalizedSemanticText(expected))
}

private func normalizedDigits(_ text: String) -> String {
    String(text.filter(\.isNumber))
}

func identifiesTarget(_ text: String, target: TargetIdentity?) -> Bool {
    guard let target else { return false }
    if semanticContains(text, target.name) || semanticContains(text, target.handle) { return true }
    let digits = normalizedDigits(text)
    if let expected = target.digits, digits == expected { return true }
    if let expected = target.nationalDigits, digits == expected { return true }
    return false
}

private func equalsAny(_ text: String, _ expected: [String]) -> Bool {
    expected.contains {
        normalizedSemanticText(text).compare(
            normalizedSemanticText($0),
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
}

private func containsAny(_ text: String, _ expected: [String]) -> Bool {
    expected.contains { semanticContains(text, $0) }
}

private func timerValue(_ text: String) -> String? {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = durationExpression.firstMatch(in: text, range: range),
          let swiftRange = Range(match.range, in: text) else { return nil }
    return String(text[swiftRange])
}

func surfaceAuthorized(_ surface: AXSurface, target: TargetIdentity?) -> Bool {
    surface.nodes.contains { node in node.texts.contains { identifiesTarget($0, target: target) } }
}

func semanticAction(_ node: AXNode, labels: [String]) -> Bool {
    node.role == (kAXButtonRole as String)
        && node.enabled
        && node.actions.contains(kAXPressAction as String)
        && node.texts.contains { equalsAny($0, labels) }
}

func authorizedIncomingNode(on surface: AXSurface, target: TargetIdentity?) -> AXNode? {
    guard surface.bundleID == "com.apple.notificationcenterui",
          surfaceAuthorized(surface, target: target),
          let target else { return nil }
    return surface.nodes.first { node in
        node.role == "AXGenericElement"
            && node.enabled
            && node.actions.contains(kAXPressAction as String)
            && node.texts.contains { text in
                identifiesTarget(text, target: target)
                    && semanticContains(text, "FaceTime Audio")
                    && timerValue(text) == nil
                    && !semanticContains(text, "Click to Call")
                    && !semanticContains(text, "left")
                    && !semanticContains(text, "ended")
                    && !semanticContains(text, "missed")
            }
    }
}

func state(of surface: AXSurface, target: TargetIdentity?) -> StateEvidence {
    let texts = surface.nodes.flatMap(\.texts)
    let authorized = surfaceAuthorized(surface, target: target)
    let hasFaceTime = texts.contains { semanticContains($0, "FaceTime") }
    let hasFaceTimeAudio = texts.contains { semanticContains($0, "FaceTime Audio") }
    let duration = texts.compactMap(timerValue).first
    let authorizedLeft = surface.bundleID == "com.apple.notificationcenterui"
        && authorized
        && hasFaceTime
        && texts.contains { semanticContains($0, "left") }
    let ringing = authorizedIncomingNode(on: surface, target: target) != nil
    let prompt = surface.bundleID == "com.apple.notificationcenterui"
        && authorized
        && texts.contains { semanticContains($0, "Click to Call") }
        && surface.nodes.contains { semanticAction($0, labels: outgoingLabels) }
    if authorized && hasFaceTimeAudio && duration != nil {
        return StateEvidence(state: .connected, duration: duration, surface: surface, authorized: true)
    }
    if authorizedLeft { return StateEvidence(state: .ended, duration: nil, surface: surface, authorized: true) }
    if ringing { return StateEvidence(state: .ringing, duration: nil, surface: surface, authorized: true) }
    if prompt { return StateEvidence(state: .prompt, duration: nil, surface: surface, authorized: true) }
    if authorized && hasFaceTimeAudio && texts.contains(where: { containsAny($0, connectedLabels) }) {
        return StateEvidence(state: .connected, duration: duration, surface: surface, authorized: true)
    }
    if authorized && hasFaceTimeAudio && texts.contains(where: { containsAny($0, dialingLabels) }) {
        return StateEvidence(state: .dialing, duration: nil, surface: surface, authorized: true)
    }
    if authorized && texts.contains(where: { containsAny($0, endedLabels) }) {
        return StateEvidence(state: .ended, duration: duration, surface: surface, authorized: true)
    }
    return StateEvidence(state: .unknown, duration: nil, surface: nil, authorized: false)
}

func state(of snapshot: AXSnapshot, target: TargetIdentity?) -> StateEvidence {
    for priority in [CallState.connected, .dialing, .ringing, .prompt, .ended] {
        if let match = snapshot.surfaces.lazy.map({ state(of: $0, target: target) }).first(where: { $0.state == priority }) {
            return match
        }
    }
    return StateEvidence(
        state: snapshot.surfaces.isEmpty ? .unknown : .idle,
        duration: nil,
        surface: nil,
        authorized: false
    )
}

func outgoingCandidates(in snapshot: AXSnapshot, target: TargetIdentity) -> [ActionCandidate] {
    snapshot.surfaces.flatMap { surface -> [ActionCandidate] in
        guard surface.bundleID == "com.apple.notificationcenterui",
              state(of: surface, target: target).state == .prompt,
              surfaceAuthorized(surface, target: target) else { return [] }
        return surface.nodes
            .filter { semanticAction($0, labels: outgoingLabels) }
            .map { ActionCandidate(surface: surface, node: $0) }
    }
}
