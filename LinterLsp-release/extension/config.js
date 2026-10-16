'use strict';
// Pure helpers for the extension: turning VS Code settings into the bridge's command line and the server's settings.
// Kept free of the `vscode` module so they can be tested with plain Node.
const fs = require('fs');
const path = require('path');

// settings that are not Linter engine options
const NON_ENGINE = new Set(['enabled', 'root', 'luauLspPath', 'luauLspArgs', 'lunePath', 'timeoutMs', 'advanced', 'trace', 'sourcemap']);

function isRuntime(candidate) {
	return Boolean(candidate) && fs.existsSync(path.join(candidate, 'bridge', 'bridge.js')) && fs.existsSync(path.join(candidate, 'core'));
}

/** The manifest the build writes next to the runtime ({ version, tools, files }), or null when there is none (running from the repository). */
function readManifest(root) {
	try {
		return JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
	} catch {
		return null;
	}
}

/** Where the runtime (bridge/, server/, core/, data/) lives: the setting, the staged copy, or the repository around the extension. */
function resolveRoot(extensionPath, configuredRoot) {
	const candidates = [configuredRoot, path.join(extensionPath, 'runtime'), path.resolve(extensionPath, '..')];
	for (const candidate of candidates) {
		if (isRuntime(candidate)) return candidate;
	}
	return null;
}

/**
 * Like resolveRoot, but a runtime built for a different version than this extension is skipped (extension, bridge and engine
 * must be one build; a stale `linter.root` would mix old and new). Returns { root, notes } - notes are things to tell the user.
 */
function chooseRoot(extensionPath, configuredRoot, extensionVersion) {
	const notes = [];
	const candidates = [configuredRoot, path.join(extensionPath, 'runtime'), path.resolve(extensionPath, '..')];
	for (const candidate of candidates) {
		if (!isRuntime(candidate)) {
			if (candidate && candidate === configuredRoot) notes.push(`linter.root "${configuredRoot}" is not a Linter runtime folder; ignoring it`);
			continue;
		}
		const manifest = readManifest(candidate);
		if (manifest && extensionVersion && manifest.version !== extensionVersion) {
			notes.push(`the runtime in "${candidate}" is version ${manifest.version} but this extension is ${extensionVersion}; ignoring it`);
			continue;
		}
		return { root: candidate, notes };
	}
	return { root: null, notes };
}

/** Command-line arguments for bridge.js. */
function bridgeArgs(root, settings) {
	const args = ['--root', root];
	if (settings.luauLspPath) args.push('--luau-lsp', settings.luauLspPath);
	for (const arg of settings.luauLspArgs || []) args.push('--luau-arg', String(arg));
	if (settings.lunePath) args.push('--lune', settings.lunePath);
	if (Number.isFinite(settings.timeoutMs) && settings.timeoutMs > 0) args.push('--linter-timeout', String(settings.timeoutMs));
	if (settings.expectVersion) args.push('--expect-version', String(settings.expectVersion));
	return args;
}

/** The engine options (`linter.*` minus the process settings, plus the free-form `linter.advanced`). */
function engineSettings(settings) {
	const out = {};
	for (const [key, value] of Object.entries(settings.advanced || {})) out[key] = value;
	for (const [key, value] of Object.entries(settings)) {
		if (!NON_ENGINE.has(key) && key !== 'expectVersion' && value !== undefined && value !== null && typeof value !== 'function') out[key] = value;
	}
	return out;
}

/**
 * The command that keeps sourcemap.json fresh (luau-lsp uses it for the DataModel).
 *
 * Writing a file into someone's project is something Linter only does when asked: `cfg.mode` must be 'project'. Any other value
 * (the default, 'off') returns null, and Linter only READS a sourcemap.json that already exists. When it is on, the
 * `luau-lsp.sourcemap.*` settings of the luau-lsp extension are honoured, so existing configuration keeps working.
 * Returns null when it is off or there is no Rojo project file to generate from. `rojo` is the resolved executable ('' = none).
 */
function sourcemapCommand(cfg, projectExists, rojo) {
	if (cfg.mode !== 'project') return null;
	if (cfg.enabled === false || cfg.autogenerate === false) return null;
	if (typeof cfg.generatorCommand === 'string' && cfg.generatorCommand.trim()) {
		let command = cfg.generatorCommand.trim();
		if (rojo && /^rojo(\s|$)/.test(command)) command = `"${rojo}"` + command.slice(4);
		return { command, args: [], shell: true };
	}
	if (!projectExists || !rojo) return null;
	const project = cfg.rojoProjectFile || 'default.project.json';
	const args = ['sourcemap', '--watch', project, '--output', cfg.sourcemapFile || 'sourcemap.json'];
	if (cfg.includeNonScripts !== false) args.push('--include-non-scripts');
	return { command: rojo, args, shell: false };
}

module.exports = { resolveRoot, chooseRoot, readManifest, bridgeArgs, engineSettings, sourcemapCommand, NON_ENGINE };
