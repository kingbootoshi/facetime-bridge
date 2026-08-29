import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
let temporary = "";
let executable = "";
let compileExitCode = -1;
let compileStderr = "";

beforeAll(async () => {
  temporary = await mkdtemp(join(tmpdir(), "facetime-bridge-native-tests-"));
  executable = join(temporary, "authorization-tests");
  const compile = Bun.spawnSync(
    [
      "/usr/bin/xcrun",
      "swiftc",
      join(root, "native", "Sources", "FaceTimeBridge", "Types.swift"),
      join(root, "native", "Sources", "FaceTimeBridge", "Log.swift"),
      join(root, "native", "Sources", "FaceTimeBridge", "AXTraversal.swift"),
      join(root, "native", "Sources", "FaceTimeBridge", "StateClassifier.swift"),
      join(root, "native", "Sources", "FaceTimeBridge", "Actions.swift"),
      join(root, "native-tests", "AuthorizationTests.swift"),
      "-framework",
      "AppKit",
      "-framework",
      "ApplicationServices",
      "-o",
      executable,
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  compileExitCode = compile.exitCode;
  compileStderr = compile.stderr.toString();
});

afterAll(async () => {
  if (temporary) await rm(temporary, { recursive: true, force: true });
});

describe("native caller authorization", () => {
  test("compiles the native authorization fixture", () => {
    expect(compileExitCode, compileStderr).toBe(0);
  });

  test("fails closed for ambiguous or mismatched E.164 identities and actions", () => {
    expect(compileExitCode, compileStderr).toBe(0);
    const result = Bun.spawnSync([executable], { stdout: "pipe", stderr: "pipe" });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    expect(result.stdout.toString()).toContain("native authorization regressions passed");
  });
});
