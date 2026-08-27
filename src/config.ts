import { chmod, lstat, mkdir, open, readFile, rename, stat, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import type { LocalConfig } from "./types.ts";

const MAX_CONFIG_BYTES = 16 * 1024;
const REQUIRED_KEYS = new Set(["targetHandle", "targetName"]);
const OPTIONAL_KEYS = new Set(["blackHole2chLabel", "blackHole16chLabel"]);

export class ConfigError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ConfigError";
  }
}

export function configPath(home = homedir()): string {
  return join(home, ".config", "facetime-bridge", "config.json");
}

function requireText(value: unknown, key: string): string {
  if (
    typeof value !== "string"
    || value.length === 0
    || value.trim() !== value
    || value.length > 512
    || /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw new ConfigError("INVALID_CONFIG", `${key} must be a non-empty, trimmed text value`);
  }
  return value;
}

function requireTargetHandle(value: unknown): string {
  const handle = requireText(value, "targetHandle");
  const e164 = /^\+[1-9]\d{7,14}$/;
  const email = /^[A-Za-z0-9.!#$%&'*+=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;
  if (!e164.test(handle) && !email.test(handle)) {
    throw new ConfigError("INVALID_CONFIG", "targetHandle must be an E.164 phone number or email address");
  }
  return handle;
}

export function parseConfig(value: unknown): LocalConfig {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ConfigError("INVALID_CONFIG", "config must be a JSON object");
  }
  const record = value as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (!REQUIRED_KEYS.has(key) && !OPTIONAL_KEYS.has(key)) {
      throw new ConfigError("INVALID_CONFIG", `unknown config key: ${key}`);
    }
  }
  const parsed: LocalConfig = {
    targetHandle: requireTargetHandle(record.targetHandle),
    targetName: requireText(record.targetName, "targetName"),
  };
  if (record.blackHole2chLabel !== undefined) {
    parsed.blackHole2chLabel = requireText(record.blackHole2chLabel, "blackHole2chLabel");
  }
  if (record.blackHole16chLabel !== undefined) {
    parsed.blackHole16chLabel = requireText(record.blackHole16chLabel, "blackHole16chLabel");
  }
  return parsed;
}

export async function loadConfig(path = configPath()): Promise<LocalConfig> {
  let metadata;
  try {
    metadata = await lstat(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new ConfigError("CONFIG_MISSING", `config not found: ${path}`);
    }
    throw error;
  }
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new ConfigError("CONFIG_UNSAFE", "config must be a regular file, not a link");
  }
  if ((metadata.mode & 0o777) !== 0o600) {
    throw new ConfigError("CONFIG_UNSAFE", "config permissions must be exactly 0600");
  }
  const uid = typeof process.getuid === "function" ? process.getuid() : undefined;
  if (uid !== undefined && metadata.uid !== uid) {
    throw new ConfigError("CONFIG_UNSAFE", "config must be owned by the current user");
  }
  if (metadata.size > MAX_CONFIG_BYTES) {
    throw new ConfigError("CONFIG_TOO_LARGE", "config exceeds the 16 KiB limit");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    throw new ConfigError("INVALID_CONFIG", `config is not valid JSON: ${(error as Error).message}`);
  }
  return parseConfig(decoded);
}

export async function writeConfig(config: LocalConfig, path = configPath()): Promise<void> {
  const validated = parseConfig(config);
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
  const temporary = join(directory, `.config.${randomUUID()}.tmp`);
  const file = await open(temporary, "wx", 0o600);
  try {
    await file.writeFile(`${JSON.stringify(validated, null, 2)}\n`, "utf8");
    await file.sync();
    await file.close();
    await rename(temporary, path);
    await chmod(path, 0o600);
    const parent = await open(directory, "r");
    try {
      await parent.sync();
    } finally {
      await parent.close();
    }
  } catch (error) {
    await file.close().catch(() => undefined);
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
  const finalMetadata = await stat(path);
  if ((finalMetadata.mode & 0o777) !== 0o600) {
    throw new ConfigError("CONFIG_UNSAFE", "could not enforce config permissions 0600");
  }
}
