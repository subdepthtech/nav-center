#!/usr/bin/env node
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createOpencodeClient } from "@opencode-ai/sdk/v2";

function parseArgs(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(`Usage: atsim_opencode_sdk.mjs --prompt <file> [options]

Options:
  --prompt <file>      Provider-bound guarded prompt file
  --directory <path>   Repository/project directory
  --model <model>      OpenCode provider/model, e.g. zai-coding-plan/glm-5.1
  --agent <name>       OpenCode agent name
  --timeout <seconds>  Timeout in seconds
`);
    process.exit(0);
  }
  const args = {
    agent: "plan",
    directory: process.cwd(),
    model: "zai-coding-plan/glm-5.1",
    timeout: 180,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) {
      throw new Error(`Unexpected positional argument: ${arg}`);
    }
    const key = arg.slice(2).replace(/-([a-z])/g, (_, char) => char.toUpperCase());
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${arg}`);
    }
    index += 1;
    args[key] = key === "timeout" ? Number(value) : value;
  }
  if (!args.prompt) {
    throw new Error("--prompt is required");
  }
  if (!Number.isFinite(args.timeout) || args.timeout <= 0) {
    throw new Error("--timeout must be a positive number of seconds");
  }
  return args;
}

function parseModel(model) {
  const split = model.indexOf("/");
  if (split <= 0 || split === model.length - 1) {
    throw new Error(`Model must be in provider/model form: ${model}`);
  }
  return {
    providerID: model.slice(0, split),
    modelID: model.slice(split + 1),
  };
}

function assertOk(result, label) {
  if (result.error) {
    const detail = typeof result.error === "string" ? result.error : JSON.stringify(result.error);
    throw new Error(`${label} failed: ${detail}`);
  }
  if (!result.data) {
    throw new Error(`${label} returned no data`);
  }
  return result.data;
}

async function startServer(config, timeoutMs) {
  const proc = spawn("opencode", ["serve", "--hostname=127.0.0.1", "--port=0"], {
    cwd: process.cwd(),
    detached: true,
    env: {
      ...process.env,
      OPENCODE_CONFIG_CONTENT: JSON.stringify(config),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  return await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      stopServer(proc).finally(() => {
        reject(new Error(`Timeout waiting for OpenCode server after ${timeoutMs}ms`));
      });
    }, timeoutMs);
    let output = "";
    let settled = false;

    function finish(error, value) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(value);
    }

    function read(chunk) {
      output += chunk.toString();
      for (const line of output.split("\n")) {
        if (!line.startsWith("opencode server listening")) continue;
        const match = line.match(/on\s+(https?:\/\/[^\s]+)/);
        if (!match) {
          finish(new Error(`Failed to parse server URL from output: ${line}`));
          return;
        }
        finish(null, { proc, url: match[1] });
        return;
      }
    }

    proc.stdout.on("data", read);
    proc.stderr.on("data", read);
    proc.on("error", (error) => finish(error));
    proc.on("exit", (code) => {
      finish(new Error(`OpenCode server exited with code ${code}${output.trim() ? `: ${output}` : ""}`));
    });
  });
}

async function stopServer(proc) {
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return;
  const pid = proc.pid;
  if (!pid) return;
  const exited = new Promise((resolve) => proc.once("exit", resolve));
  try {
    process.kill(-pid, "SIGTERM");
  } catch {
    try {
      proc.kill("SIGTERM");
    } catch {
      return;
    }
  }
  const timeout = new Promise((resolve) => setTimeout(resolve, 1500, "timeout"));
  if ((await Promise.race([exited, timeout])) === "timeout") {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      try {
        proc.kill("SIGKILL");
      } catch {
        // Already gone.
      }
    }
  }
}

const DIFF_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["diffs"],
  properties: {
    diffs: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: [
          "suggestion_id",
          "path_hint",
          "original",
          "replacement",
          "reason",
          "master_evidence",
        ],
        properties: {
          suggestion_id: { type: "string" },
          path_hint: { type: "string" },
          original: { type: "string" },
          replacement: { type: "string" },
          reason: { type: "string" },
          master_evidence: {
            type: "array",
            items: { type: "string" },
          },
        },
      },
    },
  },
};

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const prompt = await readFile(args.prompt, "utf8");
  const model = parseModel(args.model);
  const controller = new AbortController();
  const timeout = setTimeout(() => {
    controller.abort(new Error(`OpenCode SDK draft timed out after ${args.timeout} seconds`));
  }, args.timeout * 1000);

  let server;
  try {
    server = await startServer({ model: args.model }, Math.min(10000, args.timeout * 1000));
    const client = createOpencodeClient({
      baseUrl: server.url,
      directory: args.directory,
      fetch: async (request) => {
        if (controller.signal.aborted) throw controller.signal.reason;
        return fetch(request, { signal: controller.signal });
      },
    });

    const session = assertOk(
      await client.session.create({
        directory: args.directory,
        title: "atsim draft-diffs",
        permission: [
          { permission: "edit", pattern: "*", action: "deny" },
          { permission: "bash", pattern: "*", action: "deny" },
          { permission: "external_directory", pattern: "*", action: "deny" },
        ],
      }),
      "session.create",
    );

    const response = assertOk(
      await client.session.prompt({
        sessionID: session.id,
        directory: args.directory,
        agent: args.agent,
        model,
        format: {
          type: "json_schema",
          schema: DIFF_SCHEMA,
          retryCount: 2,
        },
        parts: [
          {
            type: "text",
            text: prompt,
          },
        ],
      }),
      "session.prompt",
    );

    if (response.info?.error) {
      throw new Error(`OpenCode model error: ${JSON.stringify(response.info.error)}`);
    }
    if (!response.info || response.info.structured === undefined) {
      throw new Error("OpenCode SDK response did not include structured output");
    }

    process.stdout.write(`${JSON.stringify(response.info.structured, null, 2)}\n`);
  } finally {
    clearTimeout(timeout);
    if (server) {
      const client = createOpencodeClient({ baseUrl: server.url, directory: args.directory });
      try {
        await client.instance.dispose({ directory: args.directory });
      } catch {
        // Best-effort cleanup; stopServer() below still terminates the process group.
      }
      await stopServer(server.proc);
    }
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
