# Linter for Luau: setup, updates and troubleshooting

Works on Windows, Linux and macOS. Needs Node.js 18+ and a network connection the first time only.

## The short version

```
node scripts/setup.js            # checks the machine, gets the tools, runs the tests, builds the extension (changes nothing in VS Code)
node scripts/setup.js --install  # the same, then installs the extension into VS Code
```

Restart VS Code, open a folder that contains `default.project.json`, open a `.luau` file. The status bar item **Linter** turns into a check mark when everything was found; click it (or run **Linter: Doctor**) for the details.

If the **Luau Language Server** extension (JohnnyMorganz.luau-lsp) is also enabled you will see every suggestion twice. Linter includes the Luau language support and runs luau-lsp itself, so disable that one for the workspace. Linter shows a one-time reminder and never changes your extensions itself.

## What setup does (and why it is safe to run again)

1. Checks the machine (OS, Node, npm).
2. **Lune** and **luau-lsp**: each is checked by *running* it (`--version`) and comparing with the pinned version in `version.json`. A tool that already works is never downloaded again. Tools live in a per-user cache (`%LOCALAPPDATA%\linter-luau\tools` on Windows, `~/.cache/linter-luau/tools` on Linux, `~/Library/Caches/linter-luau/tools` on macOS; override with `LINTER_CACHE`), so a second copy of this folder or a rebuild reuses them. Downloads retry, time out, are written as `.part` files and are only renamed into place when complete and verified, so a failure never leaves a broken tool behind.
3. Stages the runtime (`extension/runtime`) from the sources and stamps the version from `version.json` everywhere.
4. Builds `extension/linter-luau-<platform>-<version>.vsix`. Only `--install` runs `code --install-extension`.

## Linter never writes into your project

The engine, the bridge and the extension only read your files. The one thing that *can* write is generating `sourcemap.json` with Rojo, so it is **off** by default (`linter.sourcemap.mode = "off"`): a `sourcemap.json` that already exists is read, nothing is created. Linter's own engine builds its tree from `default.project.json` and does not need the sourcemap; luau-lsp uses it for game-tree types. Set `linter.sourcemap.mode` to `"project"` if you want Linter to ask Rojo to create and update it.

## Settings

Settings are under `linter.*` (File > Preferences > Settings, search "linter"); the existing `luau-lsp.*` settings still work. The ones that matter most: `linter.enabled`, `linter.sourcemap.mode`, `linter.luauLspPath`, `linter.lunePath`, `linter.timeoutMs`, `linter.debug`; anything else goes in `linter.advanced` as `{ "name": value }`.

Warnings (each has a code you can search for in the Problems panel):

| Setting | Default | Code | What it reports |
|---|---|---|---|
| `linter.checkArguments` | on | `Linter.ArgumentType` | an argument that cannot match the parameter's type |
| `linter.checkMembers` | on | `Linter.UnknownMember`, `Linter.UnknownChild`, `Linter.NotCallable` | a misspelled table member / child of an instance (only when a close name exists, with "Did you mean ...?"); calling a string, number or boolean |
| `linter.checkArgumentCount` | off | `Linter.ArgumentCount` | more arguments than the function takes |
| `linter.checkMissingChildren` | off | `Linter.MissingChild` | `WaitForChild("X")` when the project files contain no X |
| `linter.hideMovedErrors` | on | (none shown) | hides luau-lsp's false "not found" for instances a script moves into place at run time |

A warning is only shown when it holds every time that code is evaluated, so loops and branches do not produce guesses.

## Commands

- **Linter: Doctor (check setup)**: what was found (versions, paths, project file, sourcemap) and the exact fix for anything missing.
- **Linter: Restart**.
- **Linter: Show scripts only partly understood**.

## Updates

The version lives in `version.json` and is stamped into the extension, the runtime and its `manifest.json`. At start-up the extension, the bridge and the engine must be the same build; a `linter.root` that points at a different build is ignored with a note in the **Linter** output panel. After an update VS Code shows a one-time "Linter was updated" message with a link to `CHANGELOG.md`.

To update from source: pull the new files, run `node scripts/setup.js --install`, restart VS Code. Roll back by installing an older `.vsix` the same way (Extensions view > "..." > Install from VSIX).

To remove: `code --uninstall-extension linter.linter-luau`, then delete this folder (and the tool cache folder above if you want the space back).

## Troubleshooting

Open **Linter: Doctor** first; it prints the fix. Details are also in View > Output > "Linter".

| Symptom | Fix |
|---|---|
| Status bar shows a warning or error | Click it; follow the `fix:` line. |
| `Lune ... does not run` / `not found` | `node scripts/setup.js` (or set `linter.lunePath`). |
| `luau-lsp ... not found` | `node scripts/setup.js` (or set `linter.luauLspPath`). |
| Every suggestion twice | Disable the JohnnyMorganz.luau-lsp extension for this workspace. |
| No `game.Workspace...` types from luau-lsp | There is no `sourcemap.json`. Run Rojo yourself, or set `linter.sourcemap.mode` to `project`. |
| "runtime ... is version X but this extension is Y" | Clear `linter.root`, or reinstall. |
| The first completion right after opening a big project is slow or missing | Linter runs your project's start-up scripts once, in the background, about a second after the project loads; completions after that are served from memory. |
| `code` not found | VS Code: Ctrl+Shift+P > "Shell Command: Install 'code' command in PATH", or install the `.vsix` from the Extensions view. |

## Optional: the full Roblox class data

Out of the box Linter uses Lune's built-in class data (properties only); luau-lsp fills in methods and events. To capture Studio's complete data once (and after big Roblox updates): run `tools/lune run scripts/receive-dump`, then run `scripts/DumpReflection.luau` in Studio with HTTP requests on. It writes `data/reflection.json`; rebuild with `node scripts/setup.js`.

## Other editors

`node bridge/bridge.js --root <this folder>` serves Luau files over stdio (Neovim, Helix, Zed ...). Settings go in `initializationOptions.linter`.

## Where things are

`CHANGELOG.md` lists what changed in each version; `README.md` is the short version.
