import { chmod, mkdir, rename, unlink, writeFile } from "node:fs/promises";
import { createInterface } from "node:readline/promises";
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

async function findBrew(): Promise<string> {
  const result = await runProcess(["/usr/bin/which", "brew"], { timeoutMs: 3_000 });
  if (result.exitCode !== 0) {
    throw new Error("Homebrew is required. Install it manually from https://brew.sh and rerun setup.");
  }
  const path = decodeUtf8(result.stdout, "which output").trim();
  if (!path.startsWith("/") || path.includes("\n")) throw new Error("Homebrew executable path was invalid");
  return path;
}

async function missingPackages(brew: string): Promise<string[]> {
  const missing: string[] = [];
  for (const name of PACKAGES) {
    const result = await runProcess([brew, "list", "--cask", name], { timeoutMs: 10_000 });
    if (result.exitCode !== 0) missing.push(name);
  }
  return missing;
}

async function installPackages(brew: string): Promise<void> {
  const child = Bun.spawn([brew, "install", ...PACKAGES], {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  if (await child.exited !== 0) {
    throw new Error("Homebrew could not install the required BlackHole packages");
  }
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
    if (result.exitCode !== 0) throw new Error("swiftc could not compile the Accessibility helper");
    await chmod(temporary, 0o755);
    await rename(temporary, destination);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
}

async function installCliLauncher(): Promise<void> {
  const destination = join(homedir(), ".local", "bin", "facetime-control");
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

async function askRequired(reader: ReturnType<typeof createInterface>, label: string): Promise<string> {
  while (true) {
    const value = (await reader.question(label)).trim();
    if (value.length > 0) return value;
    stdout.write("A value is required.\n");
  }
}

async function askYesNo(reader: ReturnType<typeof createInterface>, label: string): Promise<boolean> {
  const value = (await reader.question(`${label} [y/N] `)).trim().toLowerCase();
  return value === "y" || value === "yes";
}

export async function runSetup(): Promise<void> {
  if (process.platform !== "darwin") throw new Error("setup is available only on macOS");
  const brew = await findBrew();
  const missing = await missingPackages(brew);
  const reader = createInterface({ input: stdin, output: stdout });
  try {
    if (missing.length > 0) {
      stdout.write(`Missing official Homebrew packages: ${missing.join(", ")}\n`);
      if (!(await askYesNo(reader, "Run: brew install blackhole-2ch blackhole-16ch?"))) {
        throw new Error("BlackHole installation was declined; setup made no package change");
      }
      await installPackages(brew);
    }

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

  stdout.write(`Setup complete. Configuration is stored at ${join(homedir(), ".config", "facetime-control", "config.json")} with mode 0600.\n`);
  stdout.write("Manual steps still required:\n");
  stdout.write("1. Sign in to FaceTime yourself. A dedicated iCloud account for this Mac is recommended.\n");
  stdout.write("2. Confirm that a normal FaceTime Audio call works before using automation.\n");
  stdout.write(`3. Grant Accessibility permission manually to ${helperPath()}.\n`);
  stdout.write("4. Grant microphone permission to the browser or audio consumer when macOS asks.\n");
  stdout.write("5. In FaceTime, select BlackHole 16ch for call output and BlackHole 2ch for the microphone.\n");
  stdout.write("6. Run facetime-control doctor, then facetime-control probe.\n");
}
