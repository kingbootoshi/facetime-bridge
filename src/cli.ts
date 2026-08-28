#!/usr/bin/env bun
import { CliArgumentError, parseCliArgs, USAGE } from "./cli-args.ts";
import { ConfigError } from "./config.ts";
import { NativeProtocolError } from "./native.ts";
import { ProcessError } from "./process.ts";
import { runControlCommand } from "./commands/control.ts";
import { runDoctor } from "./commands/doctor.ts";
import { runSetup, SetupError } from "./commands/setup.ts";
import { runAudioDemo } from "./commands/audio.ts";

async function main(): Promise<number> {
  let invocation;
  try {
    invocation = parseCliArgs(process.argv.slice(2));
  } catch (error) {
    if (error instanceof CliArgumentError) {
      process.stderr.write(`${error.message}\n${USAGE}`);
      return 2;
    }
    throw error;
  }
  if (invocation.kind === "help") {
    process.stdout.write(USAGE);
    return 0;
  }
  switch (invocation.command) {
    case "setup":
      await runSetup();
      return 0;
    case "doctor":
      return (await runDoctor()) ? 0 : 1;
    case "audio":
      await runAudioDemo();
      return 0;
    case "probe":
    case "call":
    case "answer":
    case "hangup":
      return (await runControlCommand(invocation.command)) ? 0 : 1;
  }
}

try {
  process.exitCode = await main();
} catch (error) {
  if (error instanceof ConfigError || error instanceof NativeProtocolError || error instanceof ProcessError || error instanceof SetupError) {
    process.stderr.write(`${error.name}: ${error.message}\n`);
  } else {
    process.stderr.write("facetime-bridge failed unexpectedly\n");
  }
  process.exitCode = 1;
}
