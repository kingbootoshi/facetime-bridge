import AppKit
import ApplicationServices
import Foundation

private let outgoingLabels = ["Call", "FaceTime Audio", "communication audio"]
private let incomingAudioLabels = ["Accept Audio Call"]
let answerLabels = ["Answer"]
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

// Digits are compared after removing duration tokens: a live call card appends a
// running timer ("0:09", flight capture 2026-08-29T19-03-44) whose digits would
// contaminate the sequence. Comparison stays whole-string equality - a longer
// number that merely contains the handle must not authorize. Digits embedded in
// an identifier ("attacker+15551234567@example.com") prove an email identity,
// not a phone identity: any "@" or a digit adjacent to a letter disqualifies
// the text from phone-digit matching entirely.
private func strippedCallDigits(_ text: String) -> String? {
    guard !text.contains("@") else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    let cleaned = durationExpression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    let characters = Array(cleaned)
    for (index, character) in characters.enumerated() where character.isNumber {
        if index > 0 && characters[index - 1].isLetter { return nil }
        if index + 1 < characters.count && characters[index + 1].isLetter { return nil }
    }
    return normalizedDigits(cleaned)
}

// Case folding is ASCII-only so confusables (KELVIN SIGN, long s, diacritics)
// never fold into a configured ASCII handle.
private func asciiLowercased(_ text: String) -> [Character] {
    text.map { $0.isASCII && $0.isUppercase ? Character($0.lowercased()) : $0 }
}

private func identifierExtending(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || ".-_+@".contains(character)
}

// The handle must appear as a whole token: an adjacent character that could
// extend an email or handle means the text names a different identity that
// merely embeds the configured one ("prefix-ann@example.com").
private func containsHandleToken(_ text: String, _ handle: String) -> Bool {
    let haystack = asciiLowercased(normalizedSemanticText(text))
    let needle = asciiLowercased(normalizedSemanticText(handle))
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for start in 0...(haystack.count - needle.count) {
        guard Array(haystack[start..<(start + needle.count)]) == needle else { continue }
        let beforeOk = start == 0 || !identifierExtending(haystack[start - 1])
        let end = start + needle.count
        let afterOk = end == haystack.count || !identifierExtending(haystack[end])
        if beforeOk && afterOk { return true }
    }
    return false
}

func identifiesTarget(_ text: String, target: TargetIdentity?) -> Bool {
    guard let target else { return false }
    if target.authority == .contactName && semanticContains(text, target.name) { return true }
    if containsHandleToken(text, target.handle) { return true }
    guard let digits = strippedCallDigits(text), !digits.isEmpty else { return false }
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

func isIncomingAudioAction(_ node: AXNode) -> Bool {
    semanticAction(node, labels: incomingAudioLabels)
}

func authorizedIncomingNodes(on surface: AXSurface, target: TargetIdentity?) -> [AXNode] {
    guard surfaceAuthorized(surface, target: target), let target else { return [] }
    if surface.bundleID == "com.apple.FaceTime" {
        return surface.nodes.filter(isIncomingAudioAction)
    }
    guard surface.bundleID == "com.apple.notificationcenterui" else { return [] }
    let identityCards = surface.nodes.filter { node in
        node.texts.contains { text in
            identifiesTarget(text, target: target)
                && semanticContains(text, "FaceTime Audio")
                && timerValue(text) == nil
                && !semanticContains(text, "Click to Call")
                && !semanticContains(text, "left")
                && !semanticContains(text, "ended")
                && !semanticContains(text, "missed")
        }
    }
    guard identityCards.count == 1,
          let cardParent = identityCards.first?.parentIndex else { return [] }
    return surface.nodes.filter { semanticAction($0, labels: answerLabels) && $0.parentIndex == cardParent }
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
    let ringing = !authorizedIncomingNodes(on: surface, target: target).isEmpty
    let prompt = surface.bundleID == "com.apple.notificationcenterui"
        && authorized
        && texts.contains { semanticContains($0, "Click to Call") }
        && surface.nodes.contains { semanticAction($0, labels: outgoingLabels) }
    // A visible ended label wins over a timer: "Call Ended 0:12" summarizes a
    // finished call, and misreading it as connected re-grants dead-call authority.
    let hasEndedLabel = texts.contains { containsAny($0, endedLabels) }
    if authorized && hasFaceTimeAudio && duration != nil && !hasEndedLabel {
        return StateEvidence(state: .connected, duration: duration, surface: surface, authorized: true)
    }
    if authorizedLeft { return StateEvidence(state: .ended, duration: nil, surface: surface, authorized: true) }
    if ringing { return StateEvidence(state: .ringing, duration: nil, surface: surface, authorized: true) }
    if prompt { return StateEvidence(state: .prompt, duration: nil, surface: surface, authorized: true) }
    // Observed live 2026-08-29 18:04 (flight-correlated): the banner card vanishes
    // within 67ms of the authorized Answer press. The persistent in-call evidence is
    // the com.apple.mobilephone process surface, which exists only while a call is
    // active and exposes a "communication audio" AXButton. This surface carries no
    // caller identity, so it is reported unauthorized; Actions.swift upgrades it
    // only while the pid-bound in-process call-authority token from an
    // identity-verified press is live.
    if surface.bundleID == "com.apple.mobilephone"
        && surface.nodes.contains(where: { node in
            node.role == "AXButton" && node.texts.contains { semanticContains($0, "communication audio") }
        }) {
        return StateEvidence(state: .connected, duration: duration, surface: surface, authorized: false)
    }
    // "Disconnected" semantically contains "Connected": any ended label on the
    // surface wins over the connected substring rule.
    if authorized && hasFaceTimeAudio && !hasEndedLabel && texts.contains(where: { containsAny($0, connectedLabels) }) {
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
              state(of: surface, target: target).state == .prompt else { return [] }
        // ADR-0015 prohibits surface-wide authorization: the pressed action must
        // itself carry the configured identity, or share its card container
        // (parentIndex) with a node that does.
        let cardParents = Set(surface.nodes.compactMap { node -> Int? in
            guard node.texts.contains(where: { identifiesTarget($0, target: target) }) else { return nil }
            return node.parentIndex
        })
        return surface.nodes
            .filter { node in
                semanticAction(node, labels: outgoingLabels)
                    && (node.texts.contains { identifiesTarget($0, target: target) }
                        || node.parentIndex.map(cardParents.contains) == true)
            }
            .map { ActionCandidate(surface: surface, node: $0) }
    }
}
func identityDigitFixturePasses() -> Bool {
    let target = try! TargetIdentity(handle: "+15551234567", name: "Fixture Caller")
    // Live call card: bidi isolates, formatted number, appended duration timer
    // (shape from flight capture 2026-08-29T19-03-44).
    guard identifiesTarget("\u{202A}+1 (555) 123-4567\u{202C}, FaceTime Audio - , 0:09", target: target),
          identifiesTarget("+1 (555) 123-4567, FaceTime Audio", target: target),
          identifiesTarget("(555) 123-4567", target: target) else { return false }
    // A longer number merely containing the handle must not authorize,
    // nor may timer digits complete a partial number.
    guard !identifiesTarget("+91 555 123 45671, FaceTime Audio", target: target),
          !identifiesTarget("+1 (555) 123-456, FaceTime Audio - , 7:00", target: target),
          !identifiesTarget("Fixture Caller, FaceTime Audio - , 0:09", target: target) else { return false }
    return true
}


func faceTimeIncomingFixturePasses() -> Bool {
    let element = AXUIElementCreateApplication(0)
    let action = AXNode(
        element: element,
        role: kAXButtonRole as String,
        identifier: "accept-audio",
        title: "Accept Audio Call",
        description: "",
        value: "",
        help: "",
        enabled: true,
        actions: [kAXPressAction as String]
    )
    let caller = AXNode(
        element: element,
        role: kAXStaticTextRole as String,
        identifier: "caller",
        title: "Fixture Caller",
        description: "FaceTime Audio",
        value: "fixture@example.com",
        help: "",
        enabled: true,
        actions: []
    )
    let surface = AXSurface(pid: 0, process: "FaceTime", bundleID: "com.apple.FaceTime", nodes: [action, caller])
    let phoneSurface = AXSurface(pid: 0, process: "Phone", bundleID: "com.apple.mobilephone", nodes: [action, caller])
    let target = try! TargetIdentity(handle: "fixture@example.com", name: "Fixture Caller")
    let other = try! TargetIdentity(handle: "other@example.com", name: "Other Caller")
    let bannerCard = AXNode(
        element: element,
        role: "AXGenericElement",
        identifier: "",
        title: "",
        description: "\u{2066}Fixture Caller\u{2069}, FaceTime Audio",
        value: "",
        help: "",
        enabled: true,
        actions: [kAXPressAction as String],
        parentIndex: 0
    )
    let answerButton = AXNode(
        element: element,
        role: kAXButtonRole as String,
        identifier: "",
        title: "",
        description: "Answer",
        value: "",
        help: "",
        enabled: true,
        actions: [kAXPressAction as String],
        parentIndex: 0
    )
    let strayAnswerButton = AXNode(
        element: element,
        role: kAXButtonRole as String,
        identifier: "",
        title: "",
        description: "Answer",
        value: "",
        help: "",
        enabled: true,
        actions: [kAXPressAction as String],
        parentIndex: 1
    )
    let nameTarget = try! TargetIdentity(handle: "fixture@example.com", name: "Fixture Caller", authority: .contactName)
    let banner = AXSurface(
        pid: 0,
        process: "Notification Center",
        bundleID: "com.apple.notificationcenterui",
        nodes: [bannerCard, answerButton]
    )
    let ambiguousBanner = AXSurface(
        pid: 0,
        process: "Notification Center",
        bundleID: "com.apple.notificationcenterui",
        nodes: [bannerCard, bannerCard, answerButton]
    )
    let splitBanner = AXSurface(
        pid: 0,
        process: "Notification Center",
        bundleID: "com.apple.notificationcenterui",
        nodes: [bannerCard, strayAnswerButton]
    )
    return authorizedIncomingNodes(on: surface, target: target).count == 1
        && state(of: surface, target: target).state == .ringing
        && authorizedIncomingNodes(on: phoneSurface, target: target).isEmpty
        && authorizedIncomingNodes(on: surface, target: other).isEmpty
        && authorizedIncomingNodes(on: banner, target: nameTarget).count == 1
        && authorizedIncomingNodes(on: banner, target: nameTarget).first?.texts.contains("Answer") == true
        && state(of: banner, target: nameTarget).state == .ringing
        && authorizedIncomingNodes(on: banner, target: target).isEmpty
        && authorizedIncomingNodes(on: ambiguousBanner, target: nameTarget).isEmpty
        && authorizedIncomingNodes(on: splitBanner, target: nameTarget).isEmpty
}
