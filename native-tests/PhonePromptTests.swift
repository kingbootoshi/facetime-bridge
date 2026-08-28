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
    enabled: Bool = true,
    actions: [String] = []
) -> AXNode {
    AXNode(
        element: AXUIElementCreateSystemWide(),
        role: role,
        identifier: "",
        title: title,
        description: description,
        value: "",
        help: "",
        enabled: enabled,
        actions: actions
    )
}

private func surface(bundleID: String = "com.apple.mobilephone", nodes: [AXNode]) -> AXSurface {
    AXSurface(pid: 1, process: "Phone", bundleID: bundleID, nodes: nodes)
}

private let call = node(
    role: kAXButtonRole as String,
    description: "communication audio",
    actions: [kAXPressAction as String]
)
private let cancel = node(
    role: kAXButtonRole as String,
    title: "Cancel",
    actions: [kAXPressAction as String]
)

@main
struct PhonePromptTests {
    static func main() {
        require(
            isUnverifiablePhoneCallPrompt(surface(nodes: [call, cancel])),
            "the exact macOS 26 Phone proxy surface must be detected"
        )
        require(
            !isUnverifiablePhoneCallPrompt(surface(bundleID: "com.example.Phone", nodes: [call, cancel])),
            "a lookalike bundle must not be detected"
        )
        require(
            !isUnverifiablePhoneCallPrompt(surface(nodes: [call])),
            "a partial surface must fail closed"
        )
        require(
            !isUnverifiablePhoneCallPrompt(surface(nodes: [call, cancel, cancel])),
            "an ambiguous surface must not be accepted as the exact prompt"
        )
        let disabledCall = node(
            role: kAXButtonRole as String,
            description: "communication audio",
            enabled: false,
            actions: [kAXPressAction as String]
        )
        require(
            !isUnverifiablePhoneCallPrompt(surface(nodes: [disabledCall, cancel])),
            "a disabled action must not be detected"
        )
        require(
            unverifiablePhoneCallPrompts(
                in: AXSnapshot(surfaces: [surface(nodes: [call, cancel]), surface(nodes: [call, cancel])])
            ).count == 2,
            "multiple exact surfaces must remain visible to the caller"
        )
        print("native Phone prompt regressions passed")
    }
}
