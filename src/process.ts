import type { ProcessResult } from "./types.ts";

const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_BYTE_CAP = 64 * 1024;

export interface ProcessOptions {
  timeoutMs?: number;
  stdoutByteCap?: number;
  stderrByteCap?: number;
  cwd?: string;
  env?: Record<string, string | undefined>;
}

export class ProcessError extends Error {
  constructor(
    public readonly code: "SPAWN_FAILED" | "TIMED_OUT" | "OUTPUT_LIMIT",
    message: string,
  ) {
    super(message);
    this.name = "ProcessError";
  }
}

async function readBounded(
  stream: ReadableStream<Uint8Array>,
  cap: number,
  onLimit: () => void,
): Promise<Uint8Array> {
  const chunks: Uint8Array[] = [];
  let length = 0;
  const reader = stream.getReader();
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      length += next.value.byteLength;
      if (length > cap) {
        onLimit();
        throw new ProcessError("OUTPUT_LIMIT", `child output exceeded ${cap} bytes`);
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

export async function runProcess(
  argv: readonly [string, ...string[]],
  options: ProcessOptions = {},
): Promise<ProcessResult> {
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const stdoutByteCap = options.stdoutByteCap ?? DEFAULT_BYTE_CAP;
  const stderrByteCap = options.stderrByteCap ?? DEFAULT_BYTE_CAP;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
    throw new TypeError("timeoutMs must be a positive safe integer");
  }
  if (!Number.isSafeInteger(stdoutByteCap) || stdoutByteCap <= 0) {
    throw new TypeError("stdoutByteCap must be a positive safe integer");
  }
  if (!Number.isSafeInteger(stderrByteCap) || stderrByteCap <= 0) {
    throw new TypeError("stderrByteCap must be a positive safe integer");
  }

  let processHandle: ReturnType<typeof Bun.spawn>;
  try {
    processHandle = Bun.spawn([...argv], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
      cwd: options.cwd,
      env: options.env,
    });
  } catch (error) {
    throw new ProcessError("SPAWN_FAILED", `could not start child process: ${(error as Error).message}`);
  }

  let timedOut = false;
  let outputLimited = false;
  const stopForLimit = (): void => {
    outputLimited = true;
    processHandle.kill("SIGKILL");
  };
  const timer = setTimeout(() => {
    timedOut = true;
    processHandle.kill("SIGKILL");
  }, timeoutMs);

  const stdoutPromise = readBounded(processHandle.stdout, stdoutByteCap, stopForLimit);
  const stderrPromise = readBounded(processHandle.stderr, stderrByteCap, stopForLimit);
  const [exitCode, stdoutSettled, stderrSettled] = await Promise.all([
    processHandle.exited,
    stdoutPromise.then(
      (value) => ({ ok: true as const, value }),
      (error: unknown) => ({ ok: false as const, error }),
    ),
    stderrPromise.then(
      (value) => ({ ok: true as const, value }),
      (error: unknown) => ({ ok: false as const, error }),
    ),
  ]);
  clearTimeout(timer);

  if (timedOut) {
    throw new ProcessError("TIMED_OUT", `child process exceeded ${timeoutMs} ms`);
  }
  if (outputLimited) {
    throw new ProcessError("OUTPUT_LIMIT", "child process exceeded its output byte limit");
  }
  if (!stdoutSettled.ok) throw stdoutSettled.error;
  if (!stderrSettled.ok) throw stderrSettled.error;
  return {
    argv: [...argv],
    exitCode,
    stdout: stdoutSettled.value,
    stderr: stderrSettled.value,
  };
}

export function decodeUtf8(bytes: Uint8Array, label: string): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new ProcessError("OUTPUT_LIMIT", `${label} was not valid UTF-8`);
  }
}
