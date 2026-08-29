import { describe, expect, test } from "bun:test";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AUTHORIZED_CALLER_E164_ENV, AuthorizedCallerError } from "../src/config.ts";
import { parseNativeResponse, runControl } from "../src/native.ts";
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

  test("passes only the command argument and canonical caller environment to the helper", async () => {
    const directory = await mkdtemp(join(tmpdir(), "facetime-bridge-native-"));
    const helper = join(directory, "helper");
    await writeFile(
      helper,
      `#!/bin/sh
if [ "$#" -ne 1 ] || [ "$1" != "probe" ] || [ "$${AUTHORIZED_CALLER_E164_ENV}" != "+15550101001" ]; then
  exit 9
fi
printf '%s\\n' '{"version":1,"ok":true,"command":"probe","state":"idle","authorized":false,"action":null,"message":"FaceTime state inspected","errorCode":null}'
`,
    );
    await chmod(helper, 0o700);
    try {
      const response = await runControl("probe", {
        binary: helper,
        environment: { ...process.env, [AUTHORIZED_CALLER_E164_ENV]: "+15550101001" },
      });
      expect(response.command).toBe("probe");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  test("fails before helper execution when environment authority is missing", async () => {
    await expect(runControl("probe", { binary: "/not-used", environment: {} })).rejects.toBeInstanceOf(
      AuthorizedCallerError,
    );
  });
});
