// run-tests.mjs — unit + contract tests for dsh-plugin-pretoolhook
//
//   node dsh-plugin/test/run-tests.mjs
//
// Part A: pure-function unit tests (buildHookPayload, parseHookOutput) — no
//         child processes, runs anywhere.
// Part B: end-to-end spawn contract against the real src/Hook.ps1 — pipes a
//         DSH payload through the exact code path the plugin uses and asserts
//         the decision the hook returns. Requires pwsh 7+ on PATH.

import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildHookPayload,
  parseHookOutput,
  runHook,
} from "../index.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const hookPath = path.resolve(here, "..", "..", "src", "Hook.ps1");

let passed = 0;
let failed = 0;
const failures = [];

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  PASS: ${name}`);
  } catch (error) {
    failed++;
    failures.push({ name, error });
    console.log(`  FAIL: ${name}`);
    console.log(`        ${error.message}`);
  }
}

function fakeExec(name, args, extra = {}) {
  return {
    name,
    arguments: args,
    callId: extra.callId ?? "call_test001",
    rootCallId: extra.rootCallId ?? "call_test001",
    agent: extra.agent ?? { id: "agent-1", session: { id: "session-1" } },
    parent: extra.parent,
    signal: extra.signal ?? undefined,
  };
}

// =============================================================================
// Part A: unit tests
// =============================================================================
console.log("=== Part A: buildHookPayload ===");

test("bash maps to Bash with tool_input.command", () => {
  const payload = buildHookPayload(fakeExec("bash", { command: "ls -la" }));
  assert.equal(payload.hook_event_name, "PreToolUse");
  assert.equal(payload.tool_name, "Bash");
  assert.deepEqual(payload.tool_input, { command: "ls -la" });
});

test("pwsh maps to PowerShell with tool_input.command", () => {
  const payload = buildHookPayload(fakeExec("pwsh", { command: "Get-Process" }));
  assert.equal(payload.tool_name, "PowerShell");
  assert.deepEqual(payload.tool_input, { command: "Get-Process" });
});

test("write maps to Write with tool_input.file_path", () => {
  const payload = buildHookPayload(fakeExec("write", { file_path: "C:/temp/a.txt", content: "x" }));
  assert.equal(payload.tool_name, "Write");
  assert.deepEqual(payload.tool_input, { file_path: "C:/temp/a.txt" });
});

test("edit maps to Edit with tool_input.file_path", () => {
  const payload = buildHookPayload(fakeExec("edit", { file_path: "C:/temp/a.txt" }));
  assert.equal(payload.tool_name, "Edit");
  assert.deepEqual(payload.tool_input, { file_path: "C:/temp/a.txt" });
});

test("unmapped tool returns null", () => {
  assert.equal(buildHookPayload(fakeExec("read", { file_path: "a.txt" })), null);
  assert.equal(buildHookPayload(fakeExec("glob", { pattern: "*" })), null);
  assert.equal(buildHookPayload(fakeExec("todo_write", {})), null);
});

test("payload carries the DSH signature + call ids + session id", () => {
  const payload = buildHookPayload(fakeExec("bash", { command: "ls" }, { callId: "call_abc", rootCallId: "call_root" }));
  assert.equal(payload.dsh.harness, "DeepSeek Harness");
  assert.equal(payload.dsh.call_id, "call_abc");
  assert.equal(payload.dsh.root_call_id, "call_root");
  assert.equal(payload.tool_use_id, "call_abc");
  assert.equal(payload.session_id, "session-1");
  assert.match(payload.timestamp, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
});

test("transcript_path is omitted when unavailable, included when given", () => {
  // The harness that runs this test may inject DSH_SESSION_JSONL into the
  // environment; hide it to test the omitted branch deterministically.
  const saved = process.env.DSH_SESSION_JSONL;
  delete process.env.DSH_SESSION_JSONL;
  try {
    const without = buildHookPayload(fakeExec("bash", { command: "ls" }));
    assert.equal("transcript_path" in without, false);
  } finally {
    if (saved !== undefined) process.env.DSH_SESSION_JSONL = saved;
  }
  const withPath = buildHookPayload(fakeExec("bash", { command: "ls" }), {
    transcriptPath: "C:/Users/x/.dsh/sessions/s/session.jsonl",
  });
  assert.equal(withPath.transcript_path, "C:/Users/x/.dsh/sessions/s/session.jsonl");
});

test("missing arguments produce an empty tool_input (hook will fail closed)", () => {
  const payload = buildHookPayload(fakeExec("bash", undefined));
  assert.deepEqual(payload.tool_input, {});
});

console.log("=== Part A: parseHookOutput ===");

test("parses allow", () => {
  const out = parseHookOutput(JSON.stringify({ hookSpecificOutput: { permissionDecision: "allow", permissionDecisionReason: "read-only" } }), 0, "");
  assert.deepEqual(out, { kind: "allow", reason: "read-only" });
});

test("parses ask", () => {
  const out = parseHookOutput(JSON.stringify({ hookSpecificOutput: { permissionDecision: "ask", permissionDecisionReason: "rm -rf (high)" } }), 0, "");
  assert.deepEqual(out, { kind: "ask", reason: "rm -rf (high)" });
});

test("parses deny", () => {
  const out = parseHookOutput(JSON.stringify({ hookSpecificOutput: { permissionDecision: "deny", permissionDecisionReason: "no" } }), 0, "");
  assert.deepEqual(out, { kind: "deny", reason: "no" });
});

test("tolerates stray preamble lines before the JSON line", () => {
  const out = parseHookOutput("some noise\n" + JSON.stringify({ hookSpecificOutput: { permissionDecision: "allow", permissionDecisionReason: "ok" } }) + "\n", 0, "");
  assert.equal(out.kind, "allow");
});

test("fail-closed: exit 2 with stderr", () => {
  const out = parseHookOutput("", 2, "Hook: Missing required field: tool_name");
  assert.equal(out.kind, "deny");
  assert.match(out.reason, /exit 2/);
  assert.match(out.reason, /Missing required field/);
});

test("fail-closed: exit 0 but unparseable output", () => {
  const out = parseHookOutput("not json at all", 0, "");
  assert.equal(out.kind, "deny");
});

test("fail-closed: unexpected decision value", () => {
  const out = parseHookOutput(JSON.stringify({ hookSpecificOutput: { permissionDecision: "maybe", permissionDecisionReason: "?" } }), 0, "");
  assert.equal(out.kind, "deny");
});

// =============================================================================
// Part B: end-to-end spawn contract against the real Hook.ps1
// =============================================================================
console.log("=== Part B: spawn contract (real Hook.ps1) ===");

test("bash read-only command -> allow", async () => {
  const payload = buildHookPayload(fakeExec("bash", { command: "ls -la /tmp" }, { callId: "call_e2e_ro" }));
  const { code, stdout } = await runHook({ hookPath, timeoutMs: 30000 }, payload);
  assert.equal(code, 0);
  assert.equal(parseHookOutput(stdout, code, "").kind, "allow");
});

test("bash modifying command -> ask", async () => {
  const payload = buildHookPayload(fakeExec("bash", { command: "rm -rf /tmp/build" }, { callId: "call_e2e_mod" }));
  const { code, stdout } = await runHook({ hookPath, timeoutMs: 30000 }, payload);
  assert.equal(code, 0);
  const decision = parseHookOutput(stdout, code, "");
  assert.equal(decision.kind, "ask");
  assert.match(decision.reason, /rm/);
});

test("write to system path -> ask; editable path -> allow", async () => {
  const sysPayload = buildHookPayload(fakeExec("write", { file_path: "C:\\Windows\\evil.dll" }, { callId: "call_e2e_sys" }));
  const { code: c1, stdout: s1 } = await runHook({ hookPath, timeoutMs: 30000 }, sysPayload);
  assert.equal(parseHookOutput(s1, c1, "").kind, "ask");

  const okPayload = buildHookPayload(fakeExec("write", { file_path: "C:\\temp\\notes.txt" }, { callId: "call_e2e_ok" }));
  const { code: c2, stdout: s2 } = await runHook({ hookPath, timeoutMs: 30000 }, okPayload);
  assert.equal(parseHookOutput(s2, c2, "").kind, "allow");
});

test("hook spawn failure fails closed (bad pwsh path)", async () => {
  let rejected = null;
  try {
    await runHook({ hookPath, pwshPath: "definitely-not-pwsh-xyz", timeoutMs: 5000 }, {});
  } catch (error) {
    rejected = error;
  }
  assert.ok(rejected, "expected the bad pwsh path to reject");
});

// =============================================================================
// Summary
// =============================================================================
console.log("");
console.log("========================================");
console.log("dsh-plugin-pretoolhook tests complete");
console.log("========================================");
console.log(`Total:    ${passed + failed}`);
console.log(`Passed:   ${passed}`);
console.log(`Failed:   ${failed}`);
console.log("");

if (failed > 0) {
  for (const f of failures) {
    console.log(`  FAILED: ${f.name}`);
  }
  process.exit(1);
}
console.log("All plugin tests passed.");
process.exit(0);
