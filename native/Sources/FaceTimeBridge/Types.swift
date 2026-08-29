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

struct TargetIdentity {
    let handle: String
    let digits: String

    init(handle: String) throws {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let e164 = handle.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil
        guard handle == trimmedHandle, e164 else {
            throw ArgumentError.invalidTarget
        }
        self.handle = handle
        digits = String(handle.dropFirst())
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
