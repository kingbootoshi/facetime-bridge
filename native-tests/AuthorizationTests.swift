import AppKit
import ApplicationServices
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func node(
    role: String = "AXGenericElement",
    title: String = "",
    description: String = "",
    value: String = "",
    help: String = "",
    identifier: String = "",
    enabled: Bool = true,
    actions: [String] = []
) -> AXNode {
    AXNode(
        element: AXUIElementCreateSystemWide(),
        role: role,
        identifier: identifier,
        title: title,
        description: description,
        value: value,
        help: help,
        enabled: enabled,
        actions: actions
    )
}

private func surface(_ nodes: [AXNode]) -> AXSurface {
    AXSurface(pid: 1, process: "NotificationCenter", bundleID: "com.apple.notificationcenterui", nodes: nodes)
}

@main
struct AuthorizationTests {
    static func main() throws {
        let target = try TargetIdentity(handle: "ann@example.com", name: "Ann")
        let sameNameDifferentHandle = try TargetIdentity(handle: "other@example.com", name: "Ann")
        let kelvinTarget = try TargetIdentity(handle: "kate@example.com", name: "Kate")
        let longSTarget = try TargetIdentity(handle: "sam@example.com", name: "Sam")
        let phoneTarget = try TargetIdentity(handle: "+15551234567", name: "Alice")
        let minimumPhoneTarget = try TargetIdentity(handle: "+12345678", name: "Bob")
        _ = try TargetIdentity(handle: "emoji@example.com", name: "😀")

        require(identifiesTarget("ann@example.com", target: target), "exact configured handle must authorize")
        require(!identifiesTarget("Joanne", target: target), "display-name substring must not authorize")
        require(!identifiesTarget("Ann", target: target), "display name alone must not authorize")
        require(!identifiesTarget("other@example.com", target: target), "different handle must not authorize")
        require(!identifiesTarget("prefix-ann@example.com", target: target), "embedded email must not authorize")
        require(!identifiesTarget("ánn@example.com", target: target), "diacritic-different email must not authorize")
        require(!identifiesTarget("Kate@example.com", target: kelvinTarget), "Unicode Kelvin sign must not fold into an ASCII handle")
        require(
            !identifiesTarget("attacker+15551234567@example.com", target: phoneTarget),
            "an email containing the configured phone digits must not authorize"
        )
        require(!identifiesTarget("ſam@example.com", target: longSTarget), "Unicode long s must not fold into an ASCII handle")
        require(identifiesTarget("+12345678", target: minimumPhoneTarget), "minimum-length valid E.164 handle must authorize")

        do {
            _ = try TargetIdentity(handle: "empty@example.com", name: "")
            require(false, "empty display name must be rejected")
        } catch ArgumentError.invalidTarget {
            // Expected.
        }

        do {
            _ = try TargetIdentity(handle: "ann@example.com", name: "ann@example.com")
            require(false, "display name must differ from the configured handle")
        } catch ArgumentError.invalidTarget {
            // Expected.
        }

        do {
            _ = try TargetIdentity(handle: "+15551234567", name: "Call +1 555 123 4567")
            require(false, "display name must not normalize to the configured phone handle")
        } catch ArgumentError.invalidTarget {
            // Expected.
        }

        let exactCall = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            value: target.handle,
            help: target.name,
            actions: [kAXPressAction as String]
        )
        let separateIdentity = node(title: target.name, value: target.handle)
        let unrelatedCall = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            actions: [kAXPressAction as String]
        )
        let wrongHandleCall = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            value: sameNameDifferentHandle.handle,
            help: target.name,
            actions: [kAXPressAction as String]
        )

        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([exactCall])]), target: target).count == 1,
            "exact handle and action on one node must authorize"
        )
        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([separateIdentity, unrelatedCall])]), target: target).isEmpty,
            "identity on one node must not authorize another node's Call action"
        )
        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([wrongHandleCall])]), target: target).isEmpty,
            "same display name with a different handle must not authorize"
        )
        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([exactCall, exactCall])]), target: target).count == 2,
            "ambiguous exact actions must remain visible to the caller and fail closed"
        )


        let connected = node(title: "FaceTime Audio", description: target.handle, value: target.name, help: "Connected")
        let wrongConnected = node(title: "FaceTime Audio", description: sameNameDifferentHandle.handle, value: target.name, help: "Connected")
        require(state(of: surface([connected]), target: target).state == .connected, "exact handle must authorize connected state")
        require(state(of: surface([wrongConnected]), target: target).state == .unknown, "same name with a different handle must not authorize state")
        let disconnected = node(title: "FaceTime Audio", description: target.handle, value: target.name, help: "Disconnected")
        require(state(of: surface([disconnected]), target: target).state == .ended, "Disconnected must not match Connected")

        // Incoming-banner containment, digit identity, and the authority token
        // lifecycle are owned by the in-binary fixtures that `--self-check` runs
        // on every build; execute the same canonical proofs here.
        require(identityDigitFixturePasses(), "identity digit fixtures must pass")
        require(faceTimeIncomingFixturePasses(), "incoming banner containment fixtures must pass")
        require(authorityLifecyclePasses(), "call authority lifecycle fixtures must pass")

        // Hangup is authority-gated: with no live pid-bound call authority
        // (granted only by an identity-verified answer/call press), it must
        // refuse before selecting any process to terminate.
        let hangup = hangupTarget(target)
        require(!hangup.ok && hangup.errorCode == "NO_AUTHORIZED_CALL", "hangup without live call authority must refuse")

        print("native authorization regressions passed")
    }
}
