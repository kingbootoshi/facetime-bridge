import { runControl } from "../native.ts";
import type { ControlCommand } from "../types.ts";

export async function runControlCommand(command: ControlCommand): Promise<boolean> {
  const response = await runControl(command);
  process.stdout.write(`${JSON.stringify(response)}\n`);
  return response.ok;
}
