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
    actions: [String] = [],
    parentIndex: Int? = nil
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
        actions: actions,
        parentIndex: parentIndex
    )
}

private func surface(_ nodes: [AXNode]) -> AXSurface {
    AXSurface(pid: 1, process: "NotificationCenter", bundleID: "com.apple.notificationcenterui", nodes: nodes)
}

@main
struct AuthorizationTests {
    static func main() throws {
        let target = try TargetIdentity(handle: "+15550101001")
        let other = try TargetIdentity(handle: "+15550101002")
        let minimum = try TargetIdentity(handle: "+12345678")

        require(identifiesTarget(target.handle, target: target), "exact E.164 identity must authorize")
        require(identifiesTarget("+1 (555) 010-1001", target: target), "full digit-normalized identity must authorize")
        require(!identifiesTarget("(555) 010-1001", target: target), "national suffix must not authorize")
        require(!identifiesTarget("Untrusted Display Label", target: target), "display text must not authorize")
        require(!identifiesTarget(other.handle, target: target), "different E.164 identity must not authorize")
        require(
            !identifiesTarget("attacker+15550101001@example.invalid", target: target),
            "an email containing the authorized digits must not authorize"
        )
        require(identifiesTarget(minimum.handle, target: minimum), "minimum-length valid E.164 identity must authorize")

        for invalid in ["", " +15550101001", "+15550101001\n", "+١٥٥٥٠١٠١٠٠١", "+05550101001", "+1234567", "+1234567890123456", "not-a-phone"] {
            do {
                _ = try TargetIdentity(handle: invalid)
                require(false, "invalid E.164 identity must be rejected")
            } catch ArgumentError.invalidTarget {
            }
        }

        let exactCall = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            value: target.handle,
            help: "Untrusted Display Label",
            actions: [kAXPressAction as String]
        )
        let cardIdentity = node(value: "+1 (555) 010-1001", parentIndex: 0)
        let cardCall = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            actions: [kAXPressAction as String],
            parentIndex: 0
        )
        let unrelatedCall = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            actions: [kAXPressAction as String],
            parentIndex: 1
        )
        let wrongHandleCall = node(
            role: kAXButtonRole as String,
            title: "Call",
            description: "Click to Call",
            value: other.handle,
            help: "Untrusted Display Label",
            actions: [kAXPressAction as String]
        )

        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([exactCall])]), target: target).count == 1,
            "exact E.164 identity on the action must authorize"
        )
        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([cardIdentity, cardCall])]), target: target).count == 1,
            "exact identity and action on one card must authorize"
        )
        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([cardIdentity, unrelatedCall])]), target: target).isEmpty,
            "identity on one card must not authorize another card's action"
        )
        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([wrongHandleCall])]), target: target).isEmpty,
            "display text with a different E.164 identity must not authorize"
        )
        require(
            outgoingCandidates(in: AXSnapshot(surfaces: [surface([exactCall, exactCall])]), target: target).count == 2,
            "ambiguous exact actions must remain visible to the caller and fail closed"
        )

        let connected = node(
            title: "FaceTime Audio",
            description: target.handle,
            value: "Untrusted Display Label",
            help: "Connected"
        )
        let wrongConnected = node(
            title: "FaceTime Audio",
            description: other.handle,
            value: "Untrusted Display Label",
            help: "Connected"
        )
        require(state(of: surface([connected]), target: target).state == .connected, "exact E.164 identity must authorize connected state")
        require(state(of: surface([wrongConnected]), target: target).state == .unknown, "display text must not authorize state")
        let disconnected = node(title: "FaceTime Audio", description: target.handle, help: "Disconnected")
        require(state(of: surface([disconnected]), target: target).state == .ended, "Disconnected must not match Connected")
        let timedConnected = node(title: "FaceTime Audio", description: target.handle, help: "0:12")
        require(state(of: surface([timedConnected]), target: target).state == .connected, "a live timer must classify connected")
        let timedEnded = node(title: "FaceTime Audio", description: target.handle, help: "Call Ended 0:12")
        require(state(of: surface([timedEnded]), target: target).state == .ended, "a timed ended summary must not classify connected")

        require(identityDigitFixturePasses(), "identity digit fixtures must pass")
        require(faceTimeIncomingFixturePasses(), "incoming banner containment fixtures must pass")
        require(authorityLifecyclePasses(), "call authority lifecycle fixtures must pass")

        let hangup = hangupTarget(target)
        require(!hangup.ok && hangup.errorCode == "NO_AUTHORIZED_CALL", "hangup without live call authority must refuse")

        print("native authorization regressions passed")
    }
}
