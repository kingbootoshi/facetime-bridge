import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { AUTHORIZED_CALLER_E164_ENV, loadAuthorizedCallerE164 } from "./config.ts";
import { decodeUtf8, runProcess } from "./process.ts";
import {
  CALL_STATES,
  type ControlCommand,
  type NativeAction,
  type NativeResponse,
  type ProcessResult,
} from "./types.ts";

const RESPONSE_KEYS: Record<keyof NativeResponse, true> = {
  version: true,
  ok: true,
  command: true,
  state: true,
  authorized: true,
  action: true,
  message: true,
  errorCode: true,
};
const ACTIONS: Record<NativeAction, true> = {
  opened: true,
  confirmed: true,
  answered: true,
  "hung-up": true,
};
const COMMANDS: Record<ControlCommand, true> = {
  probe: true,
  call: true,
  answer: true,
  hangup: true,
};

export class NativeProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "NativeProtocolError";
  }
}

export function helperPath(home = homedir()): string {
  return join(home, ".local", "bin", "facetime-bridge-ax");
}

function isNativeAction(value: unknown): value is NativeAction {
  return typeof value === "string" && value in ACTIONS;
}

export function parseNativeResponse(result: ProcessResult, expected: ControlCommand): NativeResponse {
  const stdout = decodeUtf8(result.stdout, "native stdout");
  if (stdout.length === 0 || stdout.length > 64 * 1024) {
    throw new NativeProtocolError("native helper returned an empty or oversized response");
  }
  let value: unknown;
  try {
    value = JSON.parse(stdout);
  } catch {
    throw new NativeProtocolError("native helper did not return one JSON object");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new NativeProtocolError("native response must be an object");
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record);
  if (keys.length !== Object.keys(RESPONSE_KEYS).length || keys.some((key) => !(key in RESPONSE_KEYS))) {
    throw new NativeProtocolError("native response has an unexpected shape");
  }
  if (record.version !== 1 || typeof record.ok !== "boolean" || record.command !== expected) {
    throw new NativeProtocolError("native response header is invalid");
  }
  if (typeof record.state !== "string" || !CALL_STATES.includes(record.state as never)) {
    throw new NativeProtocolError("native response state is invalid");
  }
  if (typeof record.authorized !== "boolean") {
    throw new NativeProtocolError("native response authorization is invalid");
  }
  if (record.action !== null && !isNativeAction(record.action)) {
    throw new NativeProtocolError("native response action is invalid");
  }
  if (typeof record.message !== "string" || record.message.length === 0 || record.message.length > 1024) {
    throw new NativeProtocolError("native response message is invalid");
  }
  if (record.errorCode !== null && (typeof record.errorCode !== "string" || record.errorCode.length === 0)) {
    throw new NativeProtocolError("native response errorCode is invalid");
  }
  if (record.ok !== (result.exitCode === 0) || record.ok !== (record.errorCode === null)) {
    throw new NativeProtocolError("native response disagrees with process exit status");
  }
  if (record.command === "probe" && record.action !== null) {
    throw new NativeProtocolError("probe cannot report an action");
  }
  return record as unknown as NativeResponse;
}

export async function runControl(
  command: ControlCommand,
  options: {
    binary?: string;
    environment?: Readonly<Record<string, string | undefined>>;
    timeoutMs?: number;
  } = {},
): Promise<NativeResponse> {
  if (!(command in COMMANDS)) throw new NativeProtocolError("unsupported control command");
  const authorizedCallerE164 = loadAuthorizedCallerE164(options.environment);
  const environment = {
    ...(options.environment ?? process.env),
    [AUTHORIZED_CALLER_E164_ENV]: authorizedCallerE164,
  };
  const binary = options.binary ?? helperPath();
  await access(binary, constants.X_OK).catch(() => {
    throw new NativeProtocolError("native helper is unavailable; run setup");
  });
  const result = await runProcess([binary, command], {
    env: environment,
    timeoutMs: options.timeoutMs ?? (command === "probe" ? 8_000 : 45_000),
    stdoutByteCap: 64 * 1024,
    stderrByteCap: 16 * 1024,
  });
  return parseNativeResponse(result, command);
}
