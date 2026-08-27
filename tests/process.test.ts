import { describe, expect, test } from "bun:test";
import { ProcessError, decodeUtf8, runProcess } from "../src/process.ts";

describe("bounded child processes", () => {
  test("captures an argv-only process", async () => {
    const result = await runProcess(["/usr/bin/printf", "%s", "hello"]);
    expect(result.exitCode).toBe(0);
    expect(decodeUtf8(result.stdout, "stdout")).toBe("hello");
  });

  test("kills a timed-out process", async () => {
    await expect(runProcess(["/bin/sleep", "1"], { timeoutMs: 20 })).rejects.toMatchObject<Partial<ProcessError>>({
      code: "TIMED_OUT",
    });
  });

  test("kills a process that exceeds the output cap", async () => {
    await expect(
      runProcess(["/usr/bin/yes", "x"], { stdoutByteCap: 32, stderrByteCap: 32 }),
    ).rejects.toMatchObject<Partial<ProcessError>>({ code: "OUTPUT_LIMIT" });
  });
});
