import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { AUTHORIZED_CALLER_E164_ENV, AuthorizedCallerError, loadAuthorizedCallerE164 } from "../config.ts";
import { helperPath, runControl } from "../native.ts";
import { decodeUtf8, runProcess } from "../process.ts";

export interface DoctorFact {
  name: string;
  status: "available" | "unavailable";
  detail: string;
}

export interface DoctorReport {
  ok: boolean;
  facts: DoctorFact[];
}

async function commandFact(name: string, argv: [string, ...string[]]): Promise<DoctorFact> {
  try {
    const result = await runProcess(argv, { timeoutMs: 5_000, stdoutByteCap: 16 * 1024, stderrByteCap: 16 * 1024 });
    return result.exitCode === 0
      ? { name, status: "available", detail: "command found" }
      : { name, status: "unavailable", detail: "command not found" };
  } catch {
    return { name, status: "unavailable", detail: "command check failed" };
  }
}

function findNamedAudioDevice(value: unknown, expected: string): Record<string, unknown> | null {
  if (Array.isArray(value)) {
    for (const item of value) {
      const match = findNamedAudioDevice(item, expected);
      if (match) return match;
    }
    return null;
  }
  if (value === null || typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  if (record._name === expected) return record;
  for (const item of Object.values(record)) {
    const match = findNamedAudioDevice(item, expected);
    if (match) return match;
  }
  return null;
}

async function audioFacts(labels: readonly [string, string]): Promise<DoctorFact[]> {
  try {
    const result = await runProcess(["/usr/sbin/system_profiler", "SPAudioDataType", "-json"], {
      timeoutMs: 30_000,
      stdoutByteCap: 2 * 1024 * 1024,
      stderrByteCap: 64 * 1024,
    });
    if (result.exitCode !== 0) throw new Error("system profiler failed");
    const inventory: unknown = JSON.parse(decodeUtf8(result.stdout, "audio inventory"));
    return labels.map((label, index): DoctorFact => {
      const expectedChannels = index === 0 ? 2 : 16;
      const device = findNamedAudioDevice(inventory, label);
      const valid = device?.coreaudio_device_srate === 48_000
        && device.coreaudio_device_input === expectedChannels
        && device.coreaudio_device_output === expectedChannels
        && device.coreaudio_device_transport === "coreaudio_device_type_virtual";
      return {
        name: index === 0 ? "blackhole-2ch" : "blackhole-16ch",
        status: valid ? "available" : "unavailable",
        detail: valid
          ? `exact ${expectedChannels}-channel virtual device found at 48000 Hz`
          : `exact ${expectedChannels}-channel virtual device at 48000 Hz not found`,
      };
    });
  } catch {
    return [
      { name: "blackhole-2ch", status: "unavailable", detail: "audio inventory unavailable" },
      { name: "blackhole-16ch", status: "unavailable", detail: "audio inventory unavailable" },
    ];
  }
}

export async function collectDoctorReport(): Promise<DoctorReport> {
  const facts: DoctorFact[] = [];
  facts.push({
    name: "macos",
    status: process.platform === "darwin" ? "available" : "unavailable",
    detail: process.platform === "darwin" ? "running on macOS" : "macOS is required",
  });
  facts.push(await commandFact("homebrew", ["/usr/bin/which", "brew"]));
  facts.push(await commandFact("swift", ["/usr/bin/xcrun", "--find", "swift"]));

  const labels: readonly [string, string] = ["BlackHole 2ch", "BlackHole 16ch"];
  try {
    loadAuthorizedCallerE164();
    facts.push({
      name: "authorized-caller",
      status: "available",
      detail: `${AUTHORIZED_CALLER_E164_ENV} contains a valid E.164 phone number`,
    });
  } catch (error) {
    const detail = error instanceof AuthorizedCallerError ? error.code : "AUTHORIZED_CALLER_READ_FAILED";
    facts.push({ name: "authorized-caller", status: "unavailable", detail });
  }

  let helperAvailable = true;
  try {
    await access(helperPath(), constants.X_OK);
    facts.push({ name: "native-helper", status: "available", detail: "executable helper found" });
  } catch {
    helperAvailable = false;
    facts.push({ name: "native-helper", status: "unavailable", detail: "run setup to compile the helper" });
  }

  if (helperAvailable) {
    try {
      const probe = await runControl("probe");
      facts.push({
        name: "accessibility",
        status: probe.errorCode === "ACCESSIBILITY_NOT_TRUSTED" ? "unavailable" : "available",
        detail: probe.errorCode === "ACCESSIBILITY_NOT_TRUSTED" ? "manual Accessibility approval required" : "Accessibility trust available",
      });
    } catch {
      facts.push({ name: "accessibility", status: "unavailable", detail: "helper probe unavailable" });
    }
  } else {
    facts.push({ name: "accessibility", status: "unavailable", detail: "native helper unavailable" });
  }

  facts.push(...(await audioFacts(labels)));
  return { ok: facts.every((fact) => fact.status === "available"), facts };
}

export async function runDoctor(): Promise<boolean> {
  const report = await collectDoctorReport();
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  return report.ok;
}
