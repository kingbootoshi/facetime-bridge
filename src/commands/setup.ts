import { access, chmod, mkdir, rename, unlink, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { createInterface, type Interface } from "node:readline/promises";
import { stdin, stdout } from "node:process";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import { parseConfig, writeConfig } from "../config.ts";
import { helperPath } from "../native.ts";
import { decodeUtf8, runProcess } from "../process.ts";
import type { LocalConfig } from "../types.ts";

const PACKAGES = ["blackhole-2ch", "blackhole-16ch"] as const;
const NATIVE_FILES = ["Types.swift", "AXTraversal.swift", "StateClassifier.swift", "Actions.swift", "main.swift"];
const PROJECT_ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))));

export class SetupError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SetupError";
  }
}

export function brewExecutableFor(arch: string): string {
  if (arch === "arm64") return "/opt/homebrew/bin/brew";
  if (arch === "x64") return "/usr/local/bin/brew";
  throw new SetupError(`unsupported macOS architecture: ${arch}`);
}

const homebrewEnv = { ...process.env, HOMEBREW_NO_AUTO_UPDATE: "1" };

async function findBrew(): Promise<string> {
  const brew = brewExecutableFor(process.arch);
  try {
    await access(brew, constants.X_OK);
  } catch {
    throw new SetupError(`Homebrew is required at ${brew}. Install it manually from https://brew.sh and rerun setup.`);
  }
  return brew;
}

async function missingPackages(brew: string): Promise<string[]> {
  const missing: string[] = [];
  for (const name of PACKAGES) {
    const result = await runProcess([brew, "list", "--cask", name], { timeoutMs: 10_000, env: homebrewEnv });
    if (result.exitCode !== 0) missing.push(name);
  }
  return missing;
}

export function missingPackageError(brew: string, missing: readonly string[]): Error {
  const noun = missing.length === 1 ? "package" : "packages";
  return new SetupError(`Missing official Homebrew ${noun}: ${missing.join(", ")}. Run explicitly: ${brew} install --cask ${missing.join(" ")}`);
}

export function validateBlackHoleCasks(value: unknown): void {
  if (value === null || typeof value !== "object" || !("casks" in value) || !Array.isArray(value.casks)) {
    throw new SetupError("untrusted BlackHole cask metadata");
  }
  const casks: unknown[] = value.casks;
  if (casks.length !== PACKAGES.length) throw new SetupError("untrusted BlackHole cask metadata");
  for (const token of PACKAGES) {
    const cask = casks.find(
      (candidate) =>
        candidate !== null && typeof candidate === "object" && "token" in candidate && candidate.token === token,
    );
    if (!cask || typeof cask !== "object" || !("tap" in cask) || cask.tap !== "homebrew/cask") {
      throw new SetupError("untrusted BlackHole cask metadata");
    }
  }
}

async function verifyPackages(brew: string): Promise<void> {
  const result = await runProcess([brew, "info", "--cask", "--json=v2", ...PACKAGES], {
    timeoutMs: 30_000,
    stdoutByteCap: 256 * 1024,
    stderrByteCap: 64 * 1024,
    env: homebrewEnv,
  });
  if (result.exitCode !== 0) throw new SetupError("Homebrew could not inspect the required BlackHole packages");
  let metadata: unknown;
  try {
    metadata = JSON.parse(decodeUtf8(result.stdout, "Homebrew cask metadata"));
  } catch {
    throw new SetupError("Homebrew returned invalid BlackHole cask metadata");
  }
  validateBlackHoleCasks(metadata);
}

async function compileHelper(): Promise<void> {
  const nativeDirectory = join(PROJECT_ROOT, "native");
  const destination = helperPath();
  await mkdir(dirname(destination), { recursive: true, mode: 0o755 });
  const temporary = `${destination}.${randomUUID()}.tmp`;
  const sources = NATIVE_FILES.map((name) => join(nativeDirectory, name));
  try {
    const result = await runProcess(
      ["/usr/bin/xcrun", "swiftc", ...sources, "-framework", "AppKit", "-framework", "ApplicationServices", "-o", temporary],
      { timeoutMs: 90_000, stdoutByteCap: 256 * 1024, stderrByteCap: 256 * 1024 },
    );
    if (result.exitCode !== 0) throw new SetupError("swiftc could not compile the Accessibility helper");
    await chmod(temporary, 0o755);
    await rename(temporary, destination);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
}

async function installCliLauncher(): Promise<void> {
  const destination = join(homedir(), ".local", "bin", "facetime-bridge");
  const temporary = `${destination}.${randomUUID()}.tmp`;
  const entrypoint = pathToFileURL(join(PROJECT_ROOT, "src", "cli.ts")).href;
  await mkdir(dirname(destination), { recursive: true, mode: 0o755 });
  try {
    await writeFile(temporary, `#!/usr/bin/env bun\nimport ${JSON.stringify(entrypoint)};\n`, {
      mode: 0o755,
      flag: "wx",
    });
    await chmod(temporary, 0o755);
    await rename(temporary, destination);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
}

async function askRequired(reader: Interface, label: string): Promise<string> {
  while (true) {
    const value = (await reader.question(label)).trim();
    if (value.length > 0) return value;
    stdout.write("A value is required.\n");
  }
}

export async function runSetup(): Promise<void> {
  if (process.platform !== "darwin") throw new SetupError("setup is available only on macOS");
  const brew = await findBrew();
  const missing = await missingPackages(brew);
  if (missing.length > 0) throw missingPackageError(brew, missing);
  await verifyPackages(brew);
  const reader = createInterface({ input: stdin, output: stdout });
  try {
    const targetHandle = await askRequired(reader, "Authorized FaceTime handle (example: user@example.com): ");
    const targetName = await askRequired(reader, "Exact FaceTime display name (example: Example User): ");
    const blackHole2chLabel = (await reader.question("Exact BlackHole 2ch label override (blank for BlackHole 2ch): ")).trim();
    const blackHole16chLabel = (await reader.question("Exact BlackHole 16ch label override (blank for BlackHole 16ch): ")).trim();
    const candidate: LocalConfig = { targetHandle, targetName };
    if (blackHole2chLabel) candidate.blackHole2chLabel = blackHole2chLabel;
    if (blackHole16chLabel) candidate.blackHole16chLabel = blackHole16chLabel;
    const config = parseConfig(candidate);

    await compileHelper();
    await installCliLauncher();
    await writeConfig(config);
  } finally {
    reader.close();
  }

  stdout.write(`Setup complete. Configuration is stored at ${join(homedir(), ".config", "facetime-bridge", "config.json")} with mode 0600.\n`);
  stdout.write("Manual steps still required:\n");
  stdout.write("1. Sign in to FaceTime yourself. A dedicated iCloud account for this Mac is recommended.\n");
  stdout.write("2. Confirm that a normal FaceTime Audio call works before using automation.\n");
  stdout.write(`3. Grant Accessibility permission manually to ${helperPath()}.\n`);
  stdout.write("4. Grant microphone permission to the browser or audio consumer when macOS asks.\n");
  stdout.write("5. In FaceTime, select BlackHole 16ch for call output and BlackHole 2ch for the microphone.\n");
  stdout.write("6. Run facetime-bridge doctor, then facetime-bridge probe.\n");
}
