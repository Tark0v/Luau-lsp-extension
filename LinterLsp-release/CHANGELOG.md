# Changelog

The version lives in `version.json`; the build stamps it into the extension, the runtime manifest and the VS Code package.

## 0.1.5
- Faster start: the 10 MB class-data file is decoded in the background instead of in front of the first request (project load on a 400-script project: 537 ms -> 135 ms; idle memory 88 MB -> 16 MB), and the project's start-up (its entry scripts) is run right after the project loads, so the first completion after a pause is already warm (4 ms instead of ~620 ms).
- New warnings, each with its own code and a setting (`linter.checkMembers`, `linter.checkArgumentCount`, `linter.checkMissingChildren`, `linter.hideMovedErrors`):
  - `Linter.UnknownMember`: a misspelled member of a table whose fields are all known ("Did you mean ...?").
  - `Linter.UnknownChild`: a misspelled child of an instance, counting children scripts move there at run time.
  - `Linter.NotCallable`: calling a value that is certainly a string, number or boolean.
  - `Linter.ArgumentCount` (off by default): more arguments than a function takes.
  - `Linter.MissingChild` (off by default): `WaitForChild("X")` when the project files contain no X.
  - luau-lsp's false "not found" errors for instances a script moves into place at run time are hidden by the proxy.
- Findings are only reported when they hold every time the code is evaluated; a check that is switched off and on again no longer serves a stale empty list.
- The checker now runs the project's start-up first, so moves and `_G` entries made there are part of what scripts are checked against.
- Clean-up: unused names removed.

## 0.1.4
- Setup is idempotent: it records what is installed, checks each tool by running it, reuses tools from a per-user cache and never leaves a half-written file. `node scripts/setup.js` only builds; `--install` is the only thing that touches VS Code.
- Linter no longer writes anything into your project. Generating `sourcemap.json` is now opt-in (`linter.sourcemap.mode`: `off` | `project`); the default only reads a `sourcemap.json` that already exists.
- New command **Linter: Doctor** and a status-bar item show what was found (versions, paths, project file, sourcemap) and the exact fix for anything missing.
- Version check at start-up: the extension, bridge and engine must be the same build; a mismatched `linter.root` is ignored with a message.
- One-time notice after an update, and a one-time warning when the JohnnyMorganz luau-lsp extension is also enabled (it never changes your extensions by itself).
- The bridge starts luau-lsp and Lune checks in parallel.
- Engine: moves (`.Parent =`, `.Name =`, `:Clone()`) are followed; the project file may contain comments and trailing commas; standard services always exist in the in-memory model; `_G`/`shared` are per side (server / client); a failed `assert` on something the project files do not show no longer stops evaluation; modules that move things are run when the project boots; the one-time boot gets a larger time allowance.

## 0.1.3
- Maintenance release.

## 0.1.0 - 0.1.2
- First ports of the Studio plugin engine to VS Code (bridge + proxy + Lune server).
