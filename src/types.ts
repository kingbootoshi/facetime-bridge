export const CALL_STATES = [
  "idle",
  "prompt",
  "dialing",
  "ringing",
  "connected",
  "ended",
  "unknown",
] as const;

export type CallState = (typeof CALL_STATES)[number];
export type ControlCommand = "probe" | "call" | "answer" | "hangup";
export type CliCommand = "setup" | "doctor" | "audio" | ControlCommand;
export type NativeAction = "opened" | "confirmed" | "answered" | "hung-up";

export interface LocalConfig {
  targetHandle: string;
  targetName: string;
  blackHole2chLabel?: string;
  blackHole16chLabel?: string;
}

export interface NativeResponse {
  version: 1;
  ok: boolean;
  command: ControlCommand;
  state: CallState;
  authorized: boolean;
  action: NativeAction | null;
  message: string;
  errorCode: string | null;
}

export interface ProcessResult {
  argv: readonly string[];
  exitCode: number;
  stdout: Uint8Array;
  stderr: Uint8Array;
}
