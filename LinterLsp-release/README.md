# Linter for Luau (VS Code)

Autocomplete luau-lsp cannot give: dynamic module lists, custom `require`, `_G`/`shared`, tables other modules fill, things scripts move at run time, parameters frameworks pass, plus wrong-argument warnings. The Roblox Studio plugin's engine, running beside luau-lsp.

## Requirements
Node 18+. Lune and luau-lsp (pinned in `version.json`) are fetched for you into a per-user cache and reused.

## Set up
    node scripts/setup.js            # builds the extension; changes nothing in VS Code
    node scripts/setup.js --install  # also installs it into VS Code

Safe to run again: it checks every tool by running it and only downloads what is missing or wrong. Details and troubleshooting: `Instructions.md`.

## Guarantees
- Linter only reads your project. Generating `sourcemap.json` is opt-in (`linter.sourcemap.mode`).
- The extension, bridge and engine are one version (`version.json`); a mismatched runtime is ignored with a message.
- Use **Linter: Doctor** (or click the status-bar item) to see what was found and how to fix what is missing.

## Reflection data (optional, once per Roblox update)
Start `tools/lune run scripts/receive-dump`, then run `scripts/DumpReflection.luau` in Studio (HTTP requests on). This writes `data/reflection.json`.
