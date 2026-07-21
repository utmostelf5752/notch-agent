# Eave — project guidance

See `AGENTS.md` for structure, build commands, and coding style. This file
covers workflow rules specific to shipping.

## After code changes

Rerun `./build.sh` (check for `error:` / `Built`), then `open build/Eave.app`
to confirm the change runs. The app excludes itself from screen capture when
`screenShareProtectionEnabled` is on, so `screencapture` of its windows fails —
to grab UI screenshots, temporarily `defaults write com.jagruth.eave
screenShareProtectionEnabled -bool false`, relaunch, capture, then restore it.

## Before pushing to main (a push is a release)

Every push to `main` triggers `.github/workflows/release.yml`, which rebuilds
and republishes the rolling "latest" release + `appcast.xml`. Installed apps
auto-update from it via Sparkle. So **every push to main ships to users** — treat
it as cutting a release. Only push when the user has asked; then, before pushing:

1. **Gather the user-facing changes** since the last changelog entry (`git log`,
   the working diff). Keep only what a user would notice — features, fixes, UX.
   Drop internal refactors, tests, and comment-only edits.

2. **Ask the user what version number to bump to.** The marketing version is
   derived in `build.sh` as `0.1.<git rev-list --count HEAD>`, so it advances by
   one per commit. The default target is that count computed for the *final
   commit that will land on main* — but confirm the number with the user, since
   they may want to squash or label it differently. The changelog entry's
   `version` must equal the marketing version that pushed `HEAD` produces.

3. **Write the changelog** in two places, newest entry on top, using today's
   date (absolute, e.g. `2026-07-21`):
   - `remote/changelog.json` — the source of truth; installed apps fetch it from
     `raw.githubusercontent.com/.../main/remote/changelog.json`, so it only takes
     effect once committed and pushed to `main`.
   - `Changelog.builtin` in `Sources/Eave/Changelog.swift` — the compiled-in
     offline fallback; keep it in sync with the remote file.
   Notes render as plain bullet text in Settings → About under "What's New"; the
   entry matching an available update gets an accent "UPDATE" badge.

4. **Build and sanity-check**: `./build.sh`, then confirm Settings → About shows
   the new entry (the `about` debug command opens that tab:
   `printf 'about\n' > /tmp/eave-cmd; kill -USR2 $(pgrep -x Eave)`).

5. **Commit and push.** Commit the changelog with the code so the version the
   entry names is the version that ships.
