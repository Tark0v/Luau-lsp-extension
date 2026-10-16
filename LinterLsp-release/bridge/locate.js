'use strict';
// Finding the programs the proxy runs, on Windows and Linux (and macOS).
const fs = require('fs');
const path = require('path');
const os = require('os');

function isFile(p) {
	try {
		return fs.statSync(p).isFile();
	} catch {
		return false;
	}
}

function onPath(name, env = process.env) {
	const exts = process.platform === 'win32' ? (env.PATHEXT || '.EXE;.CMD').split(';').concat(['']) : [''];
	for (const dir of (env.PATH || env.Path || '').split(path.delimiter)) {
		if (!dir) continue;
		for (const ext of exts) {
			const candidate = path.join(dir, name + ext.toLowerCase());
			if (isFile(candidate)) return candidate;
		}
	}
	return null;
}

/** The Lune runtime: explicit setting, LINTER_LUNE, <root>/tools/lune[.exe], then PATH. */
function findLune(root, explicit, env = process.env) {
	const exe = process.platform === 'win32' ? 'lune.exe' : 'lune';
	const candidates = [explicit, env.LINTER_LUNE, path.join(root, 'tools', exe)];
	for (const candidate of candidates) {
		if (candidate && isFile(candidate)) return candidate;
	}
	return onPath('lune', env);
}

/** luau-lsp: explicit setting, LUAU_LSP, <root>/tools, PATH, then the binary a VS Code-family extension installed. */
function findLuauLsp(explicit, env = process.env, root) {
	const exe = process.platform === 'win32' ? 'luau-lsp.exe' : 'luau-lsp';
	const candidates = [explicit, env.LUAU_LSP];
	if (root) candidates.push(path.join(root, 'tools', exe));
	for (const candidate of candidates) {
		if (candidate && isFile(candidate)) return candidate;
	}
	const found = onPath('luau-lsp', env);
	if (found) return found;
	// the JohnnyMorganz.luau-lsp extension keeps its server in bin/ (named `server` in 1.x), in any VS Code flavour
	const serverNames = process.platform === 'win32' ? ['luau-lsp.exe', 'server.exe'] : ['luau-lsp', 'server'];
	for (const flavour of ['.vscode', '.vscode-oss', '.vscode-insiders', '.cursor', '.vscodium']) {
		const extensions = path.join(os.homedir(), flavour, 'extensions');
		let entries = [];
		try {
			entries = fs.readdirSync(extensions).filter((entry) => /^johnnymorganz\.luau-lsp/i.test(entry)).sort().reverse();
		} catch {
			continue;
		}
		for (const entry of entries) {
			for (const name of serverNames) {
				const candidate = path.join(extensions, entry, 'bin', name);
				if (isFile(candidate)) return candidate;
			}
		}
	}
	return null;
}

/** Definitions and documentation luau-lsp needs for Roblox types, when shipped under <root>/data/luau-lsp. */
function findDefinitions(root) {
	const types = path.join(root, 'data', 'luau-lsp', 'globalTypes.d.luau');
	const docs = path.join(root, 'data', 'luau-lsp', 'api-docs.json');
	return { types: isFile(types) ? types : null, docs: isFile(docs) ? docs : null };
}

module.exports = { findLune, findLuauLsp, findDefinitions, onPath, isFile };
