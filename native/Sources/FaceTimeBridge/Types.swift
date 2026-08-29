import AppKit
import ApplicationServices
import Foundation

enum ControlCommand: String, Codable {
    case probe
    case call
    case answer
    case hangup
}

enum CallState: String, Codable {
    case idle
    case prompt
    case dialing
    case ringing
    case connected
    case ended
    case unknown
}

enum ControlAction: String, Codable {
    case opened
    case confirmed
    case answered
    case hungUp = "hung-up"
}

struct ControlResult: Encodable {
    let version = 1
    let ok: Bool
    let command: ControlCommand
    let state: CallState
    let authorized: Bool
    let action: ControlAction?
    let message: String
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case version
        case ok
        case command
        case state
        case authorized
        case action
        case message
        case errorCode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(ok, forKey: .ok)
        try container.encode(command, forKey: .command)
        try container.encode(state, forKey: .state)
        try container.encode(authorized, forKey: .authorized)
        if let action {
            try container.encode(action, forKey: .action)
        } else {
            try container.encodeNil(forKey: .action)
        }
        try container.encode(message, forKey: .message)
        if let errorCode {
            try container.encode(errorCode, forKey: .errorCode)
        } else {
            try container.encodeNil(forKey: .errorCode)
        }
    }
}

enum CallerAuthority: String {
    case exactHandle = "exact-handle"
    case contactName = "contact-name"
}

struct TargetIdentity {
    let handle: String
    let name: String
    let digits: String?
    let nationalDigits: String?
    let authority: CallerAuthority

    init(handle: String, name: String, authority: CallerAuthority = .exactHandle) throws {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e164 = handle.range(of: #"^\+[1-9]\d{7,14}$"#, options: .regularExpression) != nil
        let email = handle.range(
            of: #"^[A-Za-z0-9.!#$%&'*+=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#,
            options: .regularExpression
        ) != nil
        let unsafeName = name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        guard handle == trimmedHandle, handle.count <= 512, e164 || email else {
            throw ArgumentError.invalidTarget
        }
        guard !name.isEmpty, name == trimmedName, name.count <= 512, !unsafeName else {
            throw ArgumentError.invalidTarget
        }
        // The name corroborates the handle; a name that is (or whose digits
        // normalize to) the handle would let one text value prove both.
        let normalized = String(handle.filter(\.isNumber))
        let nameDigits = String(name.filter(\.isNumber))
        guard name.caseInsensitiveCompare(handle) != .orderedSame else {
            throw ArgumentError.invalidTarget
        }
        if !normalized.isEmpty, !nameDigits.isEmpty,
           nameDigits == normalized || nameDigits == String(normalized.suffix(10)) {
            throw ArgumentError.invalidTarget
        }
        self.handle = handle
        self.name = name
        self.authority = authority
        digits = normalized.count >= 10 ? normalized : nil
        nationalDigits = normalized.count > 10 ? String(normalized.suffix(10)) : (normalized.count == 10 ? normalized : nil)
    }
}

enum ArgumentError: Error {
    case invalidArguments
    case invalidTarget
}

struct AXNode {
    let element: AXUIElement
    let role: String
    let identifier: String
    let title: String
    let description: String
    let value: String
    let help: String
    let enabled: Bool
    let actions: [String]
    let parentIndex: Int?

    init(
        element: AXUIElement,
        role: String,
        identifier: String,
        title: String,
        description: String,
        value: String,
        help: String,
        enabled: Bool,
        actions: [String],
        parentIndex: Int? = nil
    ) {
        self.element = element
        self.role = role
        self.identifier = identifier
        self.title = title
        self.description = description
        self.value = value
        self.help = help
        self.enabled = enabled
        self.actions = actions
        self.parentIndex = parentIndex
    }

    var texts: [String] {
        [title, description, value, help, identifier].filter { !$0.isEmpty }
    }
}

struct AXSurface {
    let pid: pid_t
    let process: String
    let bundleID: String
    let nodes: [AXNode]
}

struct AXSnapshot {
    let surfaces: [AXSurface]
}

struct StateEvidence {
    let state: CallState
    let duration: String?
    let surface: AXSurface?
    let authorized: Bool
}

struct ActionCandidate {
    let surface: AXSurface
    let node: AXNode
}
