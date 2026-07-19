# Repository Guidelines

## Project Structure & Module Organization

Eave is a Swift 5.9 macOS 13+ menu-bar application. Production code lives in `Sources/Eave/`: `AppState.swift` coordinates windows and UI state, `AgentSession.swift` handles CLI-backed conversations, `ChatGPTWeb.swift` owns WebKit automation, and `Views.swift` contains the primary SwiftUI surface. Bundle metadata, icons, and helper tooling live in `Support/`. The static landing page is under `docs/`; `.github/workflows/release.yml` builds the rolling release. `project.yml` is the source of truth for the checked-in Xcode project.

## Build, Test, and Development Commands

- `./build.sh` compiles, bundles, and signs `build/Eave.app` using `swiftc`.
- `open build/Eave.app` launches the shell-built app; use `pkill Eave` to stop it.
- Open `Eave.xcodeproj` and run the shared `Eave` scheme for normal debugging. Do not open `Package.swift` as the primary Xcode project.
- `xcodegen generate` regenerates the project after changing `project.yml` or the source layout.
- `./make-dmg.sh` packages an already-built app as `build/Eave.dmg`.

When adding a Swift file, include it in `project.yml`, regenerate the Xcode project, and add it to the explicit source list in `build.sh`.

## Coding Style & Naming Conventions

Follow the existing Swift style: four-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties and functions, and focused `// MARK:` sections in large files. Prefer small AppKit/SwiftUI changes that preserve panel focus, signing, and accessibility behavior. No SwiftLint or SwiftFormat configuration is checked in, so match nearby formatting and keep comments limited to non-obvious platform behavior.

## Testing Guidelines

There is currently no XCTest target or coverage threshold. At minimum, run `./build.sh` after code changes. Launch the app and manually exercise affected notch, shortcut, provider, attachment, or WebKit flows. For UI changes, verify both the standard panel and relevant compact/stealth states; include screenshots when visual behavior changes.

## Commit & Pull Request Guidelines

Recent commits use short, imperative, sentence-case subjects such as `Render ChatGPT responses as Markdown`. Keep each commit scoped and avoid committing `build/`, `.build/`, user-specific Xcode state, credentials, or local chat data. Pull requests should explain the user-visible effect, list verification performed, link related issues when applicable, and attach before/after screenshots for UI or `docs/` changes.
