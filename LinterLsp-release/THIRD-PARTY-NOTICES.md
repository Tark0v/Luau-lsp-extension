# Third-party software and data

Linter for Luau runs, and the packaged extension includes, the following programs and data. They are the work of their authors and are covered by their own licenses; this file only says where they come from. Please read the licenses at the sources before redistributing.

| What | Where it is used | Source | License |
|---|---|---|---|
| luau-lsp | the language server that provides types, hover and errors; a copy is placed in `tools/` and in the packaged extension | https://github.com/JohnnyMorganz/luau-lsp | MIT (see `extension/THIRD-PARTY-LICENSE-luau-lsp.txt`) |
| Lune | the Luau runtime that runs the Linter engine; a copy is placed in `tools/` and in the packaged extension | https://github.com/lune-org/lune | MPL-2.0 (source and license text at the link; the unmodified binary is redistributed) |
| Luau grammar and language configuration | `extension/syntaxes/`, `extension/language-configuration.json` | taken from the luau-lsp VS Code extension | MIT |
| Roblox type definitions and documentation for luau-lsp | `data/luau-lsp/globalTypes.d.luau`, `data/luau-lsp/api-docs.json` | distributed with luau-lsp (generated from Roblox's published API data and documentation) | see the luau-lsp repository for the license of these files |
| Roblox class data | `data/reflection.json` (optional) | a dump of Roblox Studio's public API (properties, methods, events) made with `scripts/DumpReflection.luau` | Roblox API data; refresh it yourself with the script if you prefer |
| vscode-languageclient and its dependencies | the VS Code extension (`extension/node_modules` after `npm install`) | https://github.com/microsoft/vscode-languageserver-node | MIT |

Nothing here is modified by Linter. If you redistribute a build, keep this file and the license texts that belong to the software you include.
