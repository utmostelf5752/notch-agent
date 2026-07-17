# NotchAgent

Prototype of a coding agent living in the macOS notch (NotchNook-style). Hover
the notch or press Option+Space and a Liquid Glass chat panel bounces out of
the camera housing; messages go to the `claude` or `codex` CLI running
headlessly, or to your signed-in chatgpt.com session via browser automation.

## Download

[**Download NotchAgent.dmg**](https://github.com/utmostelf5752/notch-agent/releases/latest/download/NotchAgent.dmg)
— always the newest build from `main`, published automatically by CI.

The app is ad-hoc signed (no Apple Developer ID), so the first launch is
blocked by Gatekeeper. After dragging it to Applications, right-click the app
and choose **Open**, then confirm — or run `xattr -dr com.apple.quarantine
/Applications/NotchAgent.app`.

UI: solid black, rounded bottom corners, no borders or shadows (ChatGPT-popup
feel). Top strip flanking the notch cutout holds settings (left) and
pin + new-chat (right); provider and folder are dropdown pills inside the
composer. Open/close is a reveal: content is laid out in place and a
top-anchored mask wipes down over it with a strong decelerating ease-out
(timingCurve 0.16, 1, 0.3, 1 / 0.4s), no bounce, no motion of the content
itself.

### ChatGPT provider (ChatGPTWeb.swift — embedded web view)

The app owns a persistent hidden `WKWebView` logged into chatgpt.com. First
use pops a real chatgpt.com sign-in window (cookies persist in the app's
WebKit store, so it's one-time; note Google-SSO may refuse embedded web views
— email/passkey login is safest). Afterwards prompts are injected into the
hidden page (`document.execCommand('insertText')` into the first VISIBLE
composer candidate — chatgpt.com keeps a display:none fallback textarea that
poisons naive selectors, filter by `getClientRects().length`, then click
`button[data-testid='send-button']`) and the reply is scraped from
`[data-message-author-role='assistant']`, completion detected by two
consecutive stable-text polls with no Stop button. Conversation ids from
`/c/<id>` URLs give thread continuity. Selector set ported from
codex-chatgpt-control. Chat only — no local file access, so Auto-edit hides
for this provider. Inherently fragile to chatgpt.com UI changes.

`Support/chatgpt-bridge/` is the superseded first attempt (Node +
codex-chatgpt-control + Playwright-over-CDP into a separate debug-port
Chrome). Kept for reference; the app no longer calls it.

## Run

```sh
./build.sh                     # swiftc build into build/NotchAgent.app
open build/NotchAgent.app      # launches with no dock icon
```

Quit with Cmd+Q while the panel is open, or `pkill NotchAgent`.

### Console noise when running from Xcode

Two kinds of launch-time log spam were diagnosed (2026-07-14):

- "Cannot index window tabs due to missing main bundle identifier" — was
  real and is FIXED: `NSWindow.allowsAutomaticWindowTabbing = false` in the
  app delegate, plus an Info.plist embedded into the bare executable via
  `-sectcreate __TEXT __info_plist Support/EmbeddedInfo.plist` (wired into
  both Package.swift linkerSettings and build.sh) so `swift run` / Xcode SPM
  runs have a bundle identifier.
- "connection to service named com.apple.linkd.autoShortcut" Code=4097 /
  "Error registering app with intents framework" — NOT an app bug. On this
  macOS 27 beta the linkd service is broken system-wide: Apple's own
  processes (peopled, screencaptureui, Keychain, CoreLocationAgent, linkd
  itself) log the identical error, and even a properly bundled, codesigned
  .app launched via `open` gets it. Ignore it; nothing in the app can fix
  the OS daemon. Filter it out of the Xcode console with a filter on
  "linkd" if it bothers you.

## Controls

- Hover the notch (0.15s dwell): panel opens WITHOUT taking your keyboard.
  It stays open when the mouse leaves — closing is explicit.
- Click the notch, or Option+Space anywhere: open with keyboard focus
- Esc, Cmd+W, Option+Space, or click anywhere outside (global mouse monitor):
  close. The pin button (top right) disables outside-click closing so the
  panel stays up while you work in other apps.
- Return: send. Option+Return: newline. Cmd+A/C/V/X/Z work via a
  programmatic Edit main menu (accessory apps have no menu bar, but key
  equivalents still route through NSApp.mainMenu).
- Top strip: settings gear (left) — auto-edit, hotkey, quit; pin + new-chat
  pencil (right).
- Composer pills: provider (Claude/Codex/ChatGPT) and working folder (hidden
  for ChatGPT, which never touches files). Each provider keeps its own
  conversation thread.
- Menu bar sparkle icon: shows the app is running; "sparkles" while a turn
  is in flight.
- Debug: `kill -USR1 <pid>` toggles; `kill -USR2 <pid>` runs commands from
  /tmp/notchagent-cmd (provider:X / send:text / msgs / dump) — how the
  ChatGPT DOM automation gets debugged headlessly.

## Architecture

Two borderless windows at status-bar level, on all Spaces:

- **Target window** (`NotchTargetView`): notch-sized, always visible, pure
  black so it is invisible over the real notch. Never becomes key, so it can
  never steal keyboard focus. Click expands; hover shows a sparkle.
- **Chat panel** (`NotchPanel`, an `NSPanel` with `.nonactivatingPanel` +
  `canBecomeKey`): Spotlight-style — takes keyboard input without activating
  the app, so the frontmost app stays active. Ordered out on collapse, which
  hands keyboard focus back. `windowDidResignKey` auto-collapses on outside
  clicks.

Agent transport (`AgentSession`): both backends are spawn-per-turn CLIs
emitting JSONL on stdout, threaded by a session id:

- **Claude**: `claude -p <prompt> --output-format stream-json --verbose`,
  session id from the `result` event, continued with `--resume <id>`.
- **Codex**: `codex exec --json --skip-git-repo-check <prompt>`, thread id
  from the `thread.started` event, continued with
  `codex exec resume <thread-id> …`. `item.completed` items map to bubbles:
  `agent_message` → assistant text, `command_execution`/`file_change`/
  `web_search` → dim tool lines, `error`/`turn.failed` → red error lines.
  This JSONL interface is exactly what the Codex TypeScript SDK wraps, so
  shelling out loses nothing.

The global hotkey uses Carbon `RegisterEventHotKey`, which needs no
accessibility permission.

Notch geometry comes from `NSScreen.safeAreaInsets` +
`auxiliaryTopLeft/RightArea`; on displays without a notch a small black tab is
drawn at the top center instead.

Hover detection is a 0.1s mouse-position poll over the notch target
(`startNotchWatch`). Closing is handled by global + local mouseDown monitors
(`installOutsideClickMonitors`): a click that lands in none of the app's
visible windows collapses the panel unless it is pinned. Losing key-window
status alone never closes it.

App icon is generated by `swift Support/makeicon.swift` (renders
`Support/icon-1024.png`, then sips + iconutil produce `Support/AppIcon.icns`;
build.sh copies it into the bundle). The menu bar status item lives in
AppDelegate and swaps its SF Symbol with the session's isRunning.

## Toolchain quirks (this machine)

- No Xcode, CLT only. `swift build` fails (swift-package dyld error), hence
  `build.sh` with raw swiftc.
- The macOS SDK's SwiftUI `@State` is macro-backed and the CLT lacks the
  SwiftUIMacros plugin, so `@State` does not compile. All view state lives in
  `ObservableObject`s (`@Published` + `@ObservedObject`), which work fine.
  Avoid `@State`/`@StateObject` until Xcode is installed.

## Chats, streaming, steps, attachments

- History is persistent: chats save to ~/Library/Application Support/NotchAgent/chats.json
  (archived on new-chat, restore, and quit; cap 20). The clock button opens the
  list; restoring rehydrates the transcript, provider, and session ids so the
  conversation continues — ChatGPT threads resume via their /c/<id> URL when
  signed in (anonymous ChatGPT chats restore as transcript only).
- Streaming: Claude streams token deltas (--include-partial-messages;
  the final assistant event replaces the accumulated text so nothing
  double-prints). ChatGPT streams by polling the growing DOM text every 0.4s.
  Codex cannot stream — the spinner says "Waiting for response".
- Tool activity collapses: consecutive steps render live while the turn runs,
  then fold into an expandable "N steps" row when it finishes.
- Attachments: drag files onto the panel or the notch itself (drop on the
  notch also opens the panel), or use the paperclip menu — Choose Files…,
  Screenshot: Full Screen, or Screenshot: Active App Window (screencapture;
  macOS asks for Screen Recording permission once). Claude/Codex receive
  paths in the prompt and read them with their own tools; ChatGPT gets real
  byte uploads injected into the site's file input (10 MB/file cap).

## Known limitations / next steps

- No streaming within a turn: text appears per assistant message (per tool
  loop), not token by token. Add `--include-partial-messages` and parse
  `stream_event` deltas for typewriter output.
- Markdown in replies is rendered as plain text.
- Fixed panel size; no drag-to-resize.
- Screen/display changes (unplugging a monitor, resolution change) do not
  reposition the windows; restart the app.
- Interactive permission prompts are impossible in `-p` mode — the agent
  simply can't use un-allowed tools unless Auto-edit is on. A real product
  would use the Agent SDK and render permission requests in the panel.
- No login handling: assumes `claude` / `codex` are authenticated.
- Codex CLI was upgraded to 0.144.4 on 2026-07-14 because config.toml's
  default model (gpt-5.6-terra) required a newer CLI than 0.142.5. Codex
  usage limit on this account resets Jul 31, 2026 — until then Codex turns
  return the limit message as an error bubble.
