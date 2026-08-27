import AppKit
import ApplicationServices
import Foundation

func emit(_ result: ControlResult) {
    do {
        let data = try JSONEncoder().encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        FileHandle.standardError.write(Data("native helper could not encode its result\n".utf8))
        exit(1)
    }
}

func parseArguments() throws -> (ControlCommand, TargetIdentity?) {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let commandText = arguments.first, let command = ControlCommand(rawValue: commandText) else {
        throw ArgumentError.invalidArguments
    }
    if arguments.count == 1, command == .probe { return (command, nil) }
    guard arguments.count == 5,
          arguments[1] == "--target-handle",
          arguments[3] == "--target-name" else {
        throw ArgumentError.invalidArguments
    }
    return (command, try TargetIdentity(handle: arguments[2], name: arguments[4]))
}

let parsed: (ControlCommand, TargetIdentity?)
do {
    parsed = try parseArguments()
} catch {
    emit(ControlResult(
        ok: false,
        command: .probe,
        state: .unknown,
        authorized: false,
        action: nil,
        message: "invalid native helper arguments",
        errorCode: "INVALID_ARGUMENTS"
    ))
    exit(1)
}

let (command, target) = parsed
guard AXIsProcessTrusted() else {
    emit(ControlResult(
        ok: false,
        command: command,
        state: .unknown,
        authorized: false,
        action: nil,
        message: "manual Accessibility approval is required for facetime-bridge-ax",
        errorCode: "ACCESSIBILITY_NOT_TRUSTED"
    ))
    exit(1)
}

let output: ControlResult
switch command {
case .probe:
    output = probeFaceTime(target: target)
case .call:
    guard let target else {
        emit(ControlResult(ok: false, command: command, state: .unknown, authorized: false, action: nil, message: "configured identity is required", errorCode: "TARGET_REQUIRED"))
        exit(1)
    }
    output = callTarget(target)
case .answer:
    guard let target else {
        emit(ControlResult(ok: false, command: command, state: .unknown, authorized: false, action: nil, message: "configured identity is required", errorCode: "TARGET_REQUIRED"))
        exit(1)
    }
    output = answerTarget(target)
case .hangup:
    guard let target else {
        emit(ControlResult(ok: false, command: command, state: .unknown, authorized: false, action: nil, message: "configured identity is required", errorCode: "TARGET_REQUIRED"))
        exit(1)
    }
    output = hangupTarget(target)
}
emit(output)
exit(output.ok ? 0 : 1)
