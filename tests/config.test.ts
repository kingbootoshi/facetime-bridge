import { afterEach, describe, expect, test } from "bun:test";
import { lstat, mkdtemp, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConfigError, loadConfig, parseConfig, writeConfig } from "../src/config.ts";

const directories: string[] = [];

afterEach(async () => {
  for (const directory of directories.splice(0)) {
    await Bun.$`/usr/bin/trash ${directory}`.quiet();
  }
});

async function temporaryConfigPath(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "facetime-bridge-config-"));
  directories.push(directory);
  return join(directory, "nested", "config.json");
}

describe("configuration authority", () => {
  test("accepts a strict email identity", () => {
    expect(parseConfig({ targetHandle: "user@example.com", targetName: "Example User" })).toEqual({
      targetHandle: "user@example.com",
      targetName: "Example User",
    });
  });

  test("accepts a one-grapheme Unicode corroborating name", () => {
    expect(parseConfig({ targetHandle: "emoji@example.com", targetName: "😀" })).toEqual({
      targetHandle: "emoji@example.com",
      targetName: "😀",
    });
  });

  test("rejects unknown keys and unsafe handles", () => {
    expect(() => parseConfig({ targetHandle: "https://example.com", targetName: "Example User" })).toThrow(ConfigError);
    expect(() => parseConfig({ targetHandle: "user@example.com", targetName: "Example User", fallback: true })).toThrow(ConfigError);
  });

  test("rejects unsafe corroborating display names", () => {
    expect(() => parseConfig({ targetHandle: "user@example.com", targetName: "user@example.com" })).toThrow(ConfigError);
    expect(() => parseConfig({ targetHandle: "+15551234567", targetName: "Call +1 555 123 4567" })).toThrow(ConfigError);
  });

  test("writes and loads an owned 0600 file", async () => {
    const path = await temporaryConfigPath();
    await writeConfig({ targetHandle: "user@example.com", targetName: "Example User" }, path);
    expect((await lstat(path)).mode & 0o777).toBe(0o600);
    expect(await loadConfig(path)).toEqual({ targetHandle: "user@example.com", targetName: "Example User" });
  });

  test("rejects symbolic links", async () => {
    const path = await temporaryConfigPath();
    const target = `${path}.target`;
    await writeConfig({ targetHandle: "user@example.com", targetName: "Example User" }, target);
    await symlink(target, path);
    await expect(loadConfig(path)).rejects.toMatchObject({ code: "CONFIG_UNSAFE" });
  });
});
