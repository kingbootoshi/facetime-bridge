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
    let name: String
    let digits: String?
    let nationalDigits: String?

    init(handle: String, name: String) throws {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e164 = handle.range(of: #"^\+[1-9]\d{7,14}$"#, options: .regularExpression) != nil
        let email = handle.range(
            of: #"^[A-Za-z0-9.!#$%&'*+=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#,
            options: .regularExpression
        ) != nil
        let unsafeName = name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        let normalizedHandleDigits = String(handle.filter(\.isNumber))
        let normalizedNameDigits = String(name.filter(\.isNumber))
        guard handle == trimmedHandle, handle.count <= 512, e164 || email else {
            throw ArgumentError.invalidTarget
        }
        guard !name.isEmpty,
              name == trimmedName,
              name.count <= 512,
              !unsafeName,
              name.lowercased() != handle.lowercased(),
              !(e164 && normalizedNameDigits == normalizedHandleDigits) else {
            throw ArgumentError.invalidTarget
        }
        self.handle = handle
        self.name = name
        digits = e164 ? normalizedHandleDigits : nil
        nationalDigits = e164 && normalizedHandleDigits.count > 10
            ? String(normalizedHandleDigits.suffix(10))
            : nil
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
