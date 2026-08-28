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
    let normalized = normalizedSemanticText(text)
    if target.handle.hasPrefix("+") {
        let observedPhone = #"^\+?[0-9][0-9() .-]*$"#
        guard normalized.range(of: observedPhone, options: .regularExpression) != nil,
              let expected = target.digits else { return false }
        return normalizedDigits(normalized) == expected
    }
    let observedEmail = #"^[A-Za-z0-9.!#$%&'*+=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
    guard normalized.range(of: observedEmail, options: .regularExpression) != nil else { return false }
    return normalized.lowercased() == target.handle.lowercased()
}

func nodeAuthorizesTarget(_ node: AXNode, target: TargetIdentity?) -> Bool {
    guard let target else { return false }
    let texts = node.texts
    for (handleIndex, text) in texts.enumerated() where identifiesTarget(text, target: target) {
        let nameMatchesAnotherValue = texts.enumerated().contains { nameIndex, candidate in
            nameIndex != handleIndex
                && normalizedSemanticText(candidate).compare(
                    normalizedSemanticText(target.name),
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        }
        if nameMatchesAnotherValue { return true }
    }
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


private func timerValue(_ text: String) -> String? {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = durationExpression.firstMatch(in: text, range: range),
          let swiftRange = Range(match.range, in: text) else { return nil }
    return String(text[swiftRange])
}

func surfaceAuthorized(_ surface: AXSurface, target: TargetIdentity?) -> Bool {
    surface.nodes.contains { nodeAuthorizesTarget($0, target: target) }
}

func semanticAction(_ node: AXNode, labels: [String]) -> Bool {
    node.role == (kAXButtonRole as String)
        && node.enabled
        && node.actions.contains(kAXPressAction as String)
        && node.texts.contains { equalsAny($0, labels) }
}

func authorizedIncomingNodes(on surface: AXSurface, target: TargetIdentity?) -> [AXNode] {
    guard surface.bundleID == "com.apple.notificationcenterui",
          let target else { return [] }
    return surface.nodes.filter { node in
        let texts = node.texts
        let staleOrNonIncoming = texts.contains { text in
            timerValue(text) != nil
                || semanticContains(text, "Click to Call")
                || semanticContains(text, "left")
                || semanticContains(text, "ended")
                || semanticContains(text, "missed")
        }
        return node.role == "AXGenericElement"
            && node.enabled
            && node.actions.contains(kAXPressAction as String)
            && nodeAuthorizesTarget(node, target: target)
            && texts.contains { semanticContains($0, "FaceTime Audio") }
            && !staleOrNonIncoming
    }
}

func state(of surface: AXSurface, target: TargetIdentity?) -> StateEvidence {
    let authorizedNodes = surface.nodes.filter { nodeAuthorizesTarget($0, target: target) }
    let texts = authorizedNodes.flatMap(\.texts)
    let authorized = !authorizedNodes.isEmpty
    let hasFaceTime = texts.contains { semanticContains($0, "FaceTime") }
    let hasFaceTimeAudio = texts.contains { semanticContains($0, "FaceTime Audio") }
    let duration = texts.compactMap(timerValue).first
    let authorizedLeft = surface.bundleID == "com.apple.notificationcenterui"
        && authorized
        && hasFaceTime
        && texts.contains { semanticContains($0, "left") }
    let ringing = authorizedIncomingNodes(on: surface, target: target).count == 1
    let prompt = surface.bundleID == "com.apple.notificationcenterui"
        && authorizedNodes.contains { node in
            semanticAction(node, labels: outgoingLabels)
                && node.texts.contains { semanticContains($0, "Click to Call") }
        }
    let ended = authorized && texts.contains(where: { equalsAny($0, endedLabels) })
    if authorizedLeft || ended {
        return StateEvidence(state: .ended, duration: duration, surface: surface, authorized: true)
    }
    if ringing { return StateEvidence(state: .ringing, duration: nil, surface: surface, authorized: true) }
    if prompt { return StateEvidence(state: .prompt, duration: nil, surface: surface, authorized: true) }
    if authorized && hasFaceTimeAudio && duration != nil {
        return StateEvidence(state: .connected, duration: duration, surface: surface, authorized: true)
    }
    if authorized && hasFaceTimeAudio && texts.contains(where: { equalsAny($0, connectedLabels) }) {
        return StateEvidence(state: .connected, duration: duration, surface: surface, authorized: true)
    }
    if authorized && hasFaceTimeAudio && texts.contains(where: { equalsAny($0, dialingLabels) }) {
        return StateEvidence(state: .dialing, duration: nil, surface: surface, authorized: true)
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
        guard surface.bundleID == "com.apple.notificationcenterui" else { return [] }
        return surface.nodes
            .filter { node in
                nodeAuthorizesTarget(node, target: target)
                    && semanticAction(node, labels: outgoingLabels)
                    && node.texts.contains { semanticContains($0, "Click to Call") }
            }
            .map { ActionCandidate(surface: surface, node: $0) }
    }
}
