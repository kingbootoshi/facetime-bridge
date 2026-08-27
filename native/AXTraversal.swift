import AppKit
import ApplicationServices
import Foundation

let knownBundleIDs: Set<String> = [
    "com.apple.mobilephone",
    "com.apple.FaceTime",
    "com.apple.CoreServicesUIAgent",
    "com.apple.UIKitSystem",
    "com.apple.notificationcenterui",
]

let knownProcessNames: Set<String> = [
    "Phone",
    "FaceTime",
    "CoreServicesUIAgent",
    "UIKitSystem",
    "FaceTimeNotificationViewBridge",
    "FaceTimeNotificationExtension",
    "NotificationCenter",
    "Notification Center",
]

private let maximumNodesPerProcess = 180
private let maximumDepth = 8
private let messagingTimeout: Float = 0.35

private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
}

private func textAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
    guard let value = copyAttribute(element, attribute) else { return "" }
    if let string = value as? String { return String(string.prefix(240)) }
    if let number = value as? NSNumber { return String(number.stringValue.prefix(240)) }
    return ""
}

private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
    (copyAttribute(element, attribute) as? NSNumber)?.boolValue ?? false
}

private func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

private func children(_ element: AXUIElement) -> [AXUIElement] {
    copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

private func readNode(_ element: AXUIElement) -> AXNode {
    AXNode(
        element: element,
        role: textAttribute(element, kAXRoleAttribute as CFString),
        identifier: textAttribute(element, kAXIdentifierAttribute as CFString),
        title: textAttribute(element, kAXTitleAttribute as CFString),
        description: textAttribute(element, kAXDescriptionAttribute as CFString),
        value: textAttribute(element, kAXValueAttribute as CFString),
        help: textAttribute(element, kAXHelpAttribute as CFString),
        enabled: boolAttribute(element, kAXEnabledAttribute as CFString),
        actions: actionNames(element)
    )
}

private func discoverApplications() -> [NSRunningApplication] {
    var seen = Set<pid_t>()
    return NSWorkspace.shared.runningApplications.filter { application in
        let bundleID = application.bundleIdentifier ?? ""
        let name = application.localizedName ?? ""
        let known = knownBundleIDs.contains(bundleID) || knownProcessNames.contains(name)
        return known && seen.insert(application.processIdentifier).inserted
    }
}

func scanAccessibility() -> AXSnapshot {
    let surfaces = discoverApplications().map { application -> AXSurface in
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, messagingTimeout)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var nodes: [AXNode] = []
        while cursor < queue.count && nodes.count < maximumNodesPerProcess {
            let (element, depth) = queue[cursor]
            cursor += 1
            nodes.append(readNode(element))
            if depth >= maximumDepth { continue }
            for child in children(element) where queue.count < maximumNodesPerProcess {
                queue.append((child, depth + 1))
            }
        }
        return AXSurface(
            pid: application.processIdentifier,
            process: application.localizedName ?? "unknown",
            bundleID: application.bundleIdentifier ?? "",
            nodes: nodes
        )
    }
    return AXSnapshot(surfaces: surfaces)
}
