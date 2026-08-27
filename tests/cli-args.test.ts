import { describe, expect, test } from "bun:test";
import { CliArgumentError, parseCliArgs } from "../src/cli-args.ts";

describe("CLI arguments", () => {
  test("defaults to help", () => {
    expect(parseCliArgs([])).toEqual({ kind: "help" });
  });

  test("accepts each canonical command", () => {
    for (const command of ["setup", "doctor", "audio", "probe", "call", "answer", "hangup"] as const) {
      expect(parseCliArgs([command])).toEqual({ kind: "command", command });
    }
  });

  test("rejects extra arguments and unknown commands", () => {
    expect(() => parseCliArgs(["call", "user@example.com"])).toThrow(CliArgumentError);
    expect(() => parseCliArgs(["connect"])).toThrow(CliArgumentError);
  });
});
