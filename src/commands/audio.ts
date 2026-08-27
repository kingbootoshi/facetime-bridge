import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runProcess } from "../process.ts";

const HOST = "127.0.0.1";
const PORT = 5612;

function response(body: Uint8Array, contentType: string): Response {
  return new Response(body, {
    headers: {
      "content-type": contentType,
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

export async function runAudioDemo(): Promise<void> {
  if (process.platform !== "darwin") throw new Error("the audio bridge is available only on macOS");
  const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
  const web = join(root, "web");
  const [html, module] = await Promise.all([
    readFile(join(web, "index.html")),
    readFile(join(web, "facetime-audio-bridge.js")),
  ]);
  const server = Bun.serve({
    hostname: HOST,
    port: PORT,
    fetch(request) {
      const url = new URL(request.url);
      if (request.method !== "GET") return new Response("Method not allowed", { status: 405 });
      if (url.pathname === "/") return response(html, "text/html; charset=utf-8");
      if (url.pathname === "/facetime-audio-bridge.js") return response(module, "text/javascript; charset=utf-8");
      return new Response("Not found", { status: 404 });
    },
  });
  const url = `http://${HOST}:${PORT}/`;
  try {
    const opened = await runProcess(["/usr/bin/open", url], { timeoutMs: 10_000 });
    if (opened.exitCode !== 0) throw new Error("the local audio workbench could not be opened");
    process.stdout.write(`Provider-neutral audio bridge: ${url}\nPress Control-C to stop it.\n`);
    await new Promise<void>((resolve) => process.once("SIGINT", resolve));
  } finally {
    server.stop(true);
  }
}
