#!/bin/zsh
# Starts the dedicated Eave Chrome instance with CDP enabled.
# Chrome 136+ ignores --remote-debugging-port on the default profile, so this
# uses its own profile dir and runs ALONGSIDE your normal Chrome.
# First run: sign in at chatgpt.com in the window that opens — the login
# persists in the profile, so it's one-time.
PROFILE="${EAVE_CHROME_PROFILE:-$HOME/.eave-chrome}"
LEGACY_PROFILE="$HOME/.notchagent-chrome"
if [ ! -e "$PROFILE" ] && [ -d "$LEGACY_PROFILE" ]; then
  mv "$LEGACY_PROFILE" "$PROFILE"
  echo "Moved the existing NotchAgent Chrome profile to Eave."
fi
if curl -s -m 2 http://127.0.0.1:9222/json/version >/dev/null; then
  echo "Debug Chrome already running on port 9222."
  exit 0
fi
open -na "Google Chrome" --args \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port=9222 \
  --no-first-run \
  --no-default-browser-check \
  https://chatgpt.com
echo "Eave Chrome started (profile: $PROFILE, port 9222)."
echo "Sign in at chatgpt.com in that window if you haven't — then the ChatGPT provider works."
