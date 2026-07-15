#!/usr/bin/env node
// NotchAgent → ChatGPT web bridge.
// Drives the user's signed-in chatgpt.com tab in their real Chrome via
// codex-chatgpt-control, with Playwright-over-CDP standing in for the Codex
// browser bridge the SDK normally expects. Chrome must be running with
// --remote-debugging-port=9222 (see start-chrome-debug.sh).
//
// stdout: NDJSON events for the app —
//   {"type":"thread","id":"..."}       conversation id to resume with
//   {"type":"agent_message","text":""} assistant reply
//   {"type":"status","text":""}        progress note
//   {"type":"error","message":""}      failure
import { chromium } from "playwright-core";
import { createChatGPT } from "codex-chatgpt-control";

const emit = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");

const argv = process.argv.slice(2);
let thread;
const ti = argv.indexOf("--thread");
if (ti !== -1) {
  thread = argv[ti + 1];
  argv.splice(ti, 2);
}
const prompt = argv.join(" ").trim();
if (!prompt) {
  emit({ type: "error", message: "Empty prompt." });
  process.exit(1);
}

let cdp;
try {
  cdp = await chromium.connectOverCDP("http://127.0.0.1:9222", { timeout: 3000 });
} catch {
  emit({
    type: "error",
    message:
      "The NotchAgent Chrome window isn't running. Run Support/chatgpt-bridge/start-chrome-debug.sh (it opens a separate Chrome that can run alongside your normal one), sign in at chatgpt.com there once, then try again.",
  });
  process.exit(1);
}

try {
  const context = cdp.contexts()[0] ?? (await cdp.newContext());
  emit({ type: "status", text: "attached to Chrome" });
  const chatgpt = createChatGPT({ browser: context });

  const result = await chatgpt.ask({
    prompt,
    ...(thread ? { thread: { conversationId: thread } } : {}),
    preferExistingTab: true,
    wait: true,
    read: true,
  });

  const data = result?.data ?? {};
  const conversationId =
    data.conversationId ??
    data.thread?.conversationId ??
    data.session?.conversationId;
  if (typeof conversationId === "string") {
    emit({ type: "thread", id: conversationId });
  }

  const text =
    result?.output_text ??
    data.message?.text ??
    data.latest?.text ??
    (typeof data.text === "string" ? data.text : undefined);

  if (result?.ok && typeof text === "string" && text.length > 0) {
    emit({ type: "agent_message", text });
  } else if (result?.blocker) {
    emit({ type: "error", message: `${result.blocker.kind}: ${result.blocker.message}` });
  } else if (result?.error) {
    emit({ type: "error", message: result.error.message });
  } else if (!result?.ok) {
    emit({ type: "error", message: `ChatGPT run finished with status "${result?.status}" and no text.` });
    console.error("raw result:", JSON.stringify(result));
  } else {
    emit({ type: "error", message: "No reply text captured." });
    console.error("raw result:", JSON.stringify(result));
  }
} catch (error) {
  emit({ type: "error", message: error?.message ?? String(error) });
  process.exitCode = 1;
} finally {
  // Disconnect only — never close the user's real browser.
  await cdp.close().catch(() => {});
}
