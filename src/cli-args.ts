import type { CliCommand } from "./types.ts";

const COMMANDS: Record<CliCommand, true> = {
  setup: true,
  doctor: true,
  audio: true,
  probe: true,
  call: true,
  answer: true,
  hangup: true,
};

export type CliInvocation =
  | { kind: "help" }
  | { kind: "command"; command: CliCommand };

export class CliArgumentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CliArgumentError";
  }
}

export function parseCliArgs(argv: readonly string[]): CliInvocation {
  if (argv.length === 0 || (argv.length === 1 && (argv[0] === "--help" || argv[0] === "-h"))) {
    return { kind: "help" };
  }
  if (argv.length !== 1) {
    throw new CliArgumentError("commands do not accept options or positional arguments");
  }
  const command = argv[0];
  if (!(command in COMMANDS)) {
    throw new CliArgumentError(`unknown command: ${command}`);
  }
  return { kind: "command", command: command as CliCommand };
}

export const USAGE = `Usage: facetime-bridge <command>

Commands:
  setup    Build and install the native Swift package and CLI launcher
  doctor   Report local prerequisites without changing state
  audio    Open the provider-neutral BlackHole MediaStream bridge
  probe    Read the current FaceTime call state
  call     Start an audio call to the authorized E.164 number
  answer   Answer only that authorized incoming number
  hangup   End only an authorized connected call
`;
