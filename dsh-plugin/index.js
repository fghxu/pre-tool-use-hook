// dsh-plugin-pretoolhook — DeepSeek Harness ↔ PreToolUse Hook bridge
//
// Registers a `tools/pre-execute` waterfall listener (the DSH tool scheduler's
// "allow / deny / ask before dispatch" seam). For every mapped tool call it
// builds a Claude Code PreToolUse-shaped payload — stamped with a `dsh` field
// so Hook.ps1's Detect-IDE identifies the caller as "DSH" — spawns
// src/Hook.ps1 with that JSON on stdin, and maps the hook's decision onto
// DSH's decision object:
//
//   hook "allow"  -> next()                    (continue the chain -> allow)
//   hook "ask"    -> { kind: "ask",    reason } (DSH approval seam prompts the user)
//   hook "deny"   -> { kind: "deny",   reason } (tool blocked with the reason)
//
// Fail-closed: an unparseable hook output, a non-zero exit, a spawn failure,
// or a timeout all map to `deny` with an explanatory reason. `exec.signal`
// aborts are observed: the child is killed and the call fails closed.
//
// Default tool map (DSH tool name -> hook tool_name + tool_input shape):
//   bash  -> Bash        (tool_input.command)
//   pwsh  -> PowerShell  (tool_input.command)
//   write -> Write       (tool_input.file_path)
//   edit  -> Edit        (tool_input.file_path)
// Everything else is left to DSH's own permission/sandbox stack (next()).

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

export const name = "dsh-plugin-pretoolhook";

/** Default DSH tool name -> hook tool mapping. Overridable via config.toolMap. */
export const DEFAULT_TOOL_MAP = {
  bash: { tool_name: "Bash", input: (args) => ({ command: args.command }) },
  pwsh: { tool_name: "PowerShell", input: (args) => ({ command: args.command }) },
  write: { tool_name: "Write", input: (args) => ({ file_path: args.file_path }) },
  edit: { tool_name: "Edit", input: (args) => ({ file_path: args.file_path }) },
};

const HARNESS_NAME = "DeepSeek Harness";

/**
 * Build the Claude Code PreToolUse payload for one DSH tool execution, or
 * return null when the tool is not mapped.
 * @param {object} exec - the ToolExecution passed to `tools/pre-execute`
 *   (name, arguments, callId, rootCallId, agent, signal, parent).
 * @param {object} [extra] - { toolMap, transcriptPath }.
 */
export function buildHookPayload(exec, extra = {}) {
  const toolMap = extra.toolMap ?? DEFAULT_TOOL_MAP;
  const mapping = toolMap[exec.name];
  if (!mapping) return null;
  const args = exec.arguments ?? {};
  // Drop undefined values so tool_input is deterministic JSON (JSON.stringify
  // would drop them anyway, but the payload should not depend on that).
  const rawInput = mapping.input(args) ?? {};
  const toolInput = Object.fromEntries(
    Object.entries(rawInput).filter(([, value]) => value !== undefined),
  );
  const payload = {
    hook_event_name: "PreToolUse",
    tool_name: mapping.tool_name,
    tool_input: toolInput,
    tool_use_id: exec.callId,
    timestamp: new Date().toISOString(),
  };
  const sessionId = exec.agent?.session?.id;
  if (sessionId) payload.session_id = sessionId;
  const transcriptPath =
    extra.transcriptPath ??
    (typeof process !== "undefined" ? process.env.DSH_SESSION_JSONL : undefined);
  if (transcriptPath) payload.transcript_path = transcriptPath;
  payload.dsh = {
    harness: HARNESS_NAME,
    ...(exec.callId ? { call_id: exec.callId } : {}),
    ...(exec.rootCallId ? { root_call_id: exec.rootCallId } : {}),
    ...(exec.agent?.id ? { agent_id: exec.agent.id } : {}),
  };
  return payload;
}

/**
 * Interpret the hook process result. Returns a decision object:
 *   { kind: "allow" } | { kind: "ask", reason } | { kind: "deny", reason }
 * Anything other than a well-formed allow/ask/deny in the hookSpecificOutput
 * wrapper fails closed to deny.
 */
export function parseHookOutput(stdout, exitCode, stderr) {
  const lines = String(stdout ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  let parsed = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      parsed = JSON.parse(lines[i]);
      break;
    } catch {
      // keep scanning backwards for the JSON line
    }
  }
  const decision = parsed?.hookSpecificOutput?.permissionDecision;
  const reason =
    parsed?.hookSpecificOutput?.permissionDecisionReason ??
    "pretoolhook: no reason given";
  if (decision === "allow" || decision === "ask" || decision === "deny") {
    return { kind: decision, reason: String(reason) };
  }
  const stderrSnippet = String(stderr ?? "").trim().slice(0, 200);
  return {
    kind: "deny",
    reason: `pretoolhook failed closed (exit ${exitCode}${stderrSnippet ? `: ${stderrSnippet}` : ", unparseable hook output"})`,
  };
}

/**
 * Spawn Hook.ps1 with the payload on stdin and resolve with
 * { code, stdout, stderr }. Rejects on spawn failure, timeout, or abort.
 */
export function runHook({ hookPath, pwshPath = "pwsh", timeoutMs = 45000 }, payload, signal) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(
        pwshPath,
        ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", hookPath],
        { stdio: ["pipe", "pipe", "pipe"], windowsHide: true },
      );
    } catch (error) {
      reject(new Error(`spawn failed: ${error.message}`));
      return;
    }
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });

    let settled = false;
    const settle = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      fn(value);
    };
    const timer = setTimeout(() => {
      try { child.kill(); } catch { /* already gone */ }
      settle(reject, new Error(`hook timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    const onAbort = () => {
      try { child.kill(); } catch { /* already gone */ }
      settle(reject, new Error("call aborted while the hook was running"));
    };
    if (signal) signal.addEventListener("abort", onAbort, { once: true });

    child.on("error", (error) => settle(reject, new Error(`hook process error: ${error.message}`)));
    child.on("close", (code) => settle(resolve, { code, stdout, stderr }));
    // Swallow EPIPE if the hook exits before consuming stdin.
    child.stdin.on("error", () => {});
    try {
      child.stdin.write(JSON.stringify(payload));
      child.stdin.end();
    } catch (error) {
      settle(reject, new Error(`failed to write hook stdin: ${error.message}`));
    }
  });
}

/** Resolve the hook script path: config → env → repo-relative fallback. */
export function resolveHookPath(config = {}) {
  if (config.hookPath) return config.hookPath;
  if (typeof process !== "undefined" && process.env.PRETOOLHOOK_HOOK_PATH) {
    return process.env.PRETOOLHOOK_HOOK_PATH;
  }
  // Fallback: ../src/Hook.ps1 relative to this plugin file (works when the
  // plugin is run straight from the pretoolhook repository checkout).
  const pluginDir = path.dirname(fileURLToPath(import.meta.url));
  const candidate = path.resolve(pluginDir, "..", "src", "Hook.ps1");
  return candidate;
}

/**
 * Cordis plugin entry. Config keys (all optional):
 *   enabled        (boolean, default true)       master switch
 *   hookPath       (string)  path to Hook.ps1    (default: PRETOOLHOOK_HOOK_PATH
 *                                                 or <repo>/src/Hook.ps1)
 *   pwshPath       (string, default "pwsh")      PowerShell 7+ executable
 *   timeoutMs      (number, default 45000)       hook process budget; covers the
 *                                                 hook's LLM second-opinion cap
 *                                                 (timeout_ms + 2000 headroom)
 *   toolMap        (object)  DSH tool name -> { tool_name, input(args) }
 *   skipNested     (boolean, default true)       skip transport sub-dispatches
 *                                                 (exec.parent set)
 */
export function apply(ctx, config = {}) {
  const enabled = config.enabled !== false;
  const hookPath = resolveHookPath(config);
  const pwshPath = config.pwshPath ?? "pwsh";
  const timeoutMs = config.timeoutMs ?? 45000;
  const toolMap =
    config.toolMap && typeof config.toolMap === "object" ? config.toolMap : DEFAULT_TOOL_MAP;
  const skipNested = config.skipNested !== false;

  // A hook path that can't be resolved to an existing file is a config error,
  // not a security event: warn once and let tools through rather than failing
  // closed on every mapped call. On a package install (plugin in node_modules)
  // the repo-relative fallback won't resolve — set PRETOOLHOOK_HOOK_PATH.
  const hookPathExists = hookPath ? existsSync(hookPath) : false;
  const active = enabled && hookPathExists;
  if (enabled && !hookPathExists) {
    ctx.logger?.warn?.(
      `pretoolhook: enabled but Hook.ps1 is missing at "${hookPath}" — no tools will be gated. ` +
        "Set PRETOOLHOOK_HOOK_PATH (or config.hookPath) to your copy of Hook.ps1 and restart.",
    );
  }

  ctx.on(
    "tools/pre-execute",
    (exec, next) => {
      if (!active) return next();
      if (exec.parent !== undefined && skipNested) return next();
      if (!toolMap[exec.name]) return next();

      const payload = buildHookPayload(exec, { toolMap });
      if (!payload) return next();

      return runHook({ hookPath, pwshPath, timeoutMs }, payload, exec.signal)
        .then(({ code, stdout, stderr }) => {
          const decision = parseHookOutput(stdout, code, stderr);
          if (decision.kind === "allow") return next();
          ctx.logger?.info?.(
            `pretoolhook: ${exec.name} (${exec.callId}) -> ${decision.kind}: ${decision.reason}`,
          );
          return { kind: decision.kind, reason: decision.reason };
        })
        .catch((error) => {
          ctx.logger?.warn?.(
            `pretoolhook: ${exec.name} (${exec.callId}) failed closed: ${error.message}`,
          );
          return { kind: "deny", reason: `pretoolhook failed closed: ${error.message}` };
        });
    },
    { prepend: true },
  );
}

export default { name, apply };
