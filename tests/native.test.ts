import { describe, expect, test } from "bun:test";
import { parseNativeResponse } from "../src/native.ts";
import type { ProcessResult } from "../src/types.ts";

const encoder = new TextEncoder();

function result(value: unknown, exitCode = 0): ProcessResult {
  return {
    argv: ["facetime-bridge-ax", "probe"],
    exitCode,
    stdout: encoder.encode(`${JSON.stringify(value)}\n`),
    stderr: new Uint8Array(),
  };
}

describe("native result protocol", () => {
  test("accepts the exact success schema", () => {
    const value = {
      version: 1,
      ok: true,
      command: "probe",
      state: "idle",
      authorized: false,
      action: null,
      message: "FaceTime state inspected",
      errorCode: null,
    };
    expect(parseNativeResponse(result(value), "probe")).toEqual(value);
  });

  test("rejects extra fields", () => {
    const value = {
      version: 1,
      ok: true,
      command: "probe",
      state: "idle",
      authorized: false,
      action: null,
      message: "FaceTime state inspected",
      errorCode: null,
      token: "not allowed",
    };
    expect(() => parseNativeResponse(result(value), "probe")).toThrow("unexpected shape");
  });

  test("rejects disagreement with process status", () => {
    const value = {
      version: 1,
      ok: false,
      command: "call",
      state: "unknown",
      authorized: false,
      action: null,
      message: "failed",
      errorCode: "FAILED",
    };
    expect(() => parseNativeResponse(result(value, 0), "call")).toThrow("process exit status");
  });
});
