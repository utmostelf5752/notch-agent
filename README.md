# Eave

**Your coding agents, right above your work.** Eave keeps Claude, Codex,
Cursor, and ChatGPT in a Liquid Glass panel tucked into the macOS notch. Hover
the notch or press the global shortcut (Option+Space by default) to start a
conversation without switching apps.

## Download

[**Download Eave.dmg**](https://github.com/utmostelf5752/notch-agent/releases/latest/download/Eave.dmg)
— always the newest build from `main`, published automatically by CI.

The app is ad-hoc signed (no Apple Developer ID), so the first launch is
blocked by Gatekeeper. After dragging it to Applications, right-click the app
and choose **Open**, then confirm — or run `xattr -dr com.apple.quarantine
/Applications/Eave.app`.

UI: solid black, rounded bottom corners, no borders or shadows (ChatGPT-popup
feel). Top strip flanking the notch cutout holds settings (left) and
pin + new-chat (right); provider and folder are dropdown pills inside the
composer. Open/close is a reveal: content is laid out in place and a
top-anchored mask wipes down over it with a strong decelerating ease-out
(timingCurve 0.16, 1, 0.3, 1 / 0.4s), no bounce, no motion of the content
itself.

### ChatGPT provider (ChatGPTWeb.swift — embedded web view)

The app owns a persistent hidden `WKWebView` logged into chatgpt.com. Its
account state is checked automatically at launch and the last result/email is
cached for the provider menu. First use pops a real chatgpt.com sign-in window
(cookies persist in the app's WebKit store, so it's one-time; note Google-SSO
may refuse embedded web views — email/passkey login is safest). Afterwards the
user's exact text is inserted into the hidden page (`document.execCommand('insertText')`
into the first VISIBLE
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

For Xcode, open `Eave.xcodeproj` (not `Package.swift`) and run the shared
`Eave` scheme. It builds a native `Eave.app` with the same bundle
identifier, Info.plist, icon, menu-bar asset, and sources as the shell build.
Opening `Package.swift` makes Xcode generate a SwiftPM executable scheme, which
does not launch the app through the same bundle path.

`project.yml` is the source for the checked-in Xcode project. After changing
the project structure, regenerate it with `xcodegen generate`.

The standalone build remains available without Xcode:

```sh
./build.sh                     # swiftc build into build/Eave.app
open build/Eave.app            # launches with no dock icon
```

Local Xcode and shell builds use the Apple Development certificate for team
`WJZ957T3P9`, giving the app a stable signing requirement so macOS privacy
permissions survive rebuilds. `build.sh` falls back to ad-hoc signing on CI or
machines without that certificate; override its certificate selection with
`EAVE_SIGN_IDENTITY` when needed.

Quit with Cmd+Q while the panel is open, or `pkill Eave`.

### Console noise when running from Xcode

Two kinds of launch-time log spam were diagnosed (2026-07-14):

- "Cannot index window tabs due to missing main bundle identifier" — was
  real and is FIXED for supported launches: `NSWindow.allowsAutomaticWindowTabbing
  = false` in the app delegate, and both the native Xcode target and
  `build.sh` now produce a real app bundle with `Support/Info.plist`.
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
- Click the notch, or use the configured shortcut anywhere: open with keyboard focus
- Esc, Cmd+W, the configured shortcut, or click anywhere outside (global mouse monitor):
  close. The pin button (top right) disables outside-click closing so the
  panel stays up while you work in other apps.
- Return: send. Option+Return: newline. Cmd+A/C/V/X/Z work via a
  programmatic Edit main menu (accessory apps have no menu bar, but key
  equivalents still route through NSApp.mainMenu).
- Top strip: settings gear (left) — shortcut, panel behavior, and quit; pin + new-chat
  pencil (right).
- Composer pills: provider (Claude/Codex/ChatGPT) and working folder (hidden
  for ChatGPT, which never touches files). Each provider keeps its own
  conversation thread.
- Menu bar terminal-bucket icon: an open notch tray with `>_`; it takes on the
  system accent color while a turn is in flight.
- Debug: `kill -USR1 <pid>` toggles; `kill -USR2 <pid>` runs commands from
  /tmp/eave-cmd (provider:X / send:text / msgs / dump) — how the
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

The configurable global hotkey uses Carbon `RegisterEventHotKey`, which needs
no accessibility permission.

Notch geometry comes from `NSScreen.safeAreaInsets` +
`auxiliaryTopLeft/RightArea`; on displays without a notch a small black tab is
drawn at the top center instead.

Hover detection is a 0.1s mouse-position poll over the notch target
(`startNotchWatch`). Closing is handled by global + local mouseDown monitors
(`installOutsideClickMonitors`): a click that lands in none of the app's
visible windows collapses the panel unless it is pinned. Losing key-window
status alone never closes it.

App and website icons are generated by `swift Support/makeicon.swift` from the
selected design source in `Support/AppIcon-source.png`. The script renders the
transparent app PNG, complete `Support/AppIcon.icns`, website icons, and the
menu-bar template derived from `Support/MenuBarIcon-master.png`; `build.sh`
copies the app and menu-bar assets into the bundle. The menu bar status item
lives in AppDelegate and tints the `>_` bucket while the session is running.

## Toolchain quirks (this machine)

- `build.sh` uses raw `swiftc` so the app can still be built independently of
  Xcode's generated SwiftPM schemes.
- The native app project is generated from `project.yml` with XcodeGen and is
  checked in so opening it does not require regeneration.

## Chats, streaming, steps, attachments

- History is persistent: chats save to ~/Library/Application Support/Eave/chats.json
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
  macOS asks for Screen Recording permission once). Claude receives native
  image content blocks, Codex receives native local-image/file inputs, and
  ChatGPT gets real byte uploads injected into the site's file input (10
  MB/file cap); none receive an added screenshot instruction prompt. Cursor's
  CLI has no attachment input, so it receives only the local path. Screenshots
  are captured as JPEG, and other image formats are copied to JPEG without
  changing the original; oversized images are compressed below 4.5 MB. Sent
  attachments remain clickable in the transcript; screenshots are stored in
  `~/Library/Application Support/Eave/Screenshots/` and can also be
  revealed in Finder from the attachment's context menu.

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
