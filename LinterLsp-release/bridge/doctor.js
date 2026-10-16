'use strict';
// Looks at everything Linter needs and says what it found, in plain terms, with the fix for anything missing.
// Read-only: it runs `--version` on the tools and looks at files; it never writes anywhere.
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { findLune, findLuauLsp, findDefinitions, isFile } = require('./locate');

/**
 * Runs `binary args` and resolves { ok, text }. Never rejects and never hangs: a program that does not start, exits non-zero or
 * takes longer than timeoutMs is reported as not ok. A `.js` path is run with this Node (how the tests stand in for luau-lsp).
 */
function probe(binary, args, { cwd, timeoutMs = 8000 } = {}) {
	return new Promise((resolve) => {
		if (!binary) return resolve({ ok: false, text: 'not found' });
		const isScript = binary.endsWith('.js');
		let child;
		try {
			child = spawn(isScript ? process.execPath : binary, isScript ? [binary, ...args] : args, { cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
		} catch (error) {
			return resolve({ ok: false, text: error.message });
		}
		let text = '';
		let done = false;
		const finish = (result) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			resolve(result);
		};
		const timer = setTimeout(() => {
			try {
				child.kill();
			} catch {
				// already gone
			}
			finish({ ok: false, text: `did not answer within ${timeoutMs} ms` });
		}, timeoutMs);
		child.stdout.on('data', (d) => (text += d));
		child.stderr.on('data', (d) => (text += d));
		child.on('error', (error) => finish({ ok: false, text: error.message }));
		child.on('close', (code) => finish({ ok: code === 0, text: text.trim().split('\n')[0] || `exit ${code}` }));
	});
}

function readManifest(root) {
	try {
		return JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
	} catch {
		return null;
	}
}

const ok = (id, title, detail) => ({ id, level: 'ok', title, detail });
const warn = (id, title, detail, fix) => ({ id, level: 'warn', title, detail, fix });
const bad = (id, title, detail, fix) => ({ id, level: 'error', title, detail, fix });

/**
 * options: root, settings ({ luauLspPath, lunePath, sourcemap: { mode } }), workspaceFolders (paths), env, expectVersion
 * Returns { level: 'ok' | 'warn' | 'error', checks, lines } - `lines` is the text shown to the user.
 */
async function diagnose(options) {
	const root = options.root;
	const settings = options.settings || {};
	const env = options.env || process.env;
	const checks = [];

	// 1. the runtime itself
	const missing = ['bridge/bridge.js', 'server/main.luau', 'core'].filter((p) => !fs.existsSync(path.join(root, p)));
	if (missing.length) {
		checks.push(bad('runtime', 'Linter runtime', `missing ${missing.join(', ')} in ${root}`, 'Reinstall the extension (or fix the "linter.root" setting).'));
	} else {
		const manifest = readManifest(root);
		if (!manifest) checks.push(ok('runtime', 'Linter runtime', `${root} (running from source, no manifest)`));
		else if (options.expectVersion && manifest.version !== options.expectVersion) {
			checks.push(bad('runtime', 'Linter runtime', `version ${manifest.version} does not match the extension (${options.expectVersion})`, 'Clear the "linter.root" setting or reinstall the extension.'));
		} else {
			checks.push(ok('runtime', 'Linter runtime', `version ${manifest.version} in ${root}`));
		}
	}

	// 2. the two programs (checked at the same time)
	const lunePath = findLune(root, settings.lunePath, env);
	const luauPath = findLuauLsp(settings.luauLspPath, env, root);
	const [lune, luau] = await Promise.all([probe(lunePath, ['--version'], { cwd: root }), probe(luauPath, ['--version'], { cwd: root })]);
	if (lune.ok) checks.push(ok('lune', 'Lune (runs the Linter engine)', `${lune.text} at ${lunePath}`));
	else checks.push(bad('lune', 'Lune (runs the Linter engine)', lunePath ? `${lunePath}: ${lune.text}` : 'not found', 'Run: node scripts/setup.js   (or set "linter.lunePath").'));
	if (luau.ok) checks.push(ok('luau-lsp', 'luau-lsp (types, hover, errors)', `${luau.text} at ${luauPath}`));
	else checks.push(bad('luau-lsp', 'luau-lsp (types, hover, errors)', luauPath ? `${luauPath}: ${luau.text}` : 'not found', 'Run: node scripts/setup.js   (or set "linter.luauLspPath").'));

	// 3. Roblox definitions for luau-lsp
	const defs = findDefinitions(root);
	if (defs.types && defs.docs) checks.push(ok('definitions', 'Roblox type definitions', defs.types));
	else checks.push(warn('definitions', 'Roblox type definitions', 'data/luau-lsp files are missing, so luau-lsp has no Roblox types', 'Reinstall the extension.'));

	// 4. each workspace folder: project file and sourcemap (read-only)
	const mode = (settings.sourcemap && settings.sourcemap.mode) || 'off';
	for (const folder of options.workspaceFolders || []) {
		const hasProject = fs.existsSync(path.join(folder, 'default.project.json'));
		const hasMap = isFile(path.join(folder, 'sourcemap.json'));
		const name = path.basename(folder);
		if (hasProject) checks.push(ok(`project:${folder}`, `Project file (${name})`, 'default.project.json found; Linter builds its own tree from it'));
		else checks.push(warn(`project:${folder}`, `Project file (${name})`, 'no default.project.json; Linter uses sourcemap.json or the folder layout', 'Open the folder that contains default.project.json.'));
		if (hasMap) checks.push(ok(`sourcemap:${folder}`, `sourcemap.json (${name})`, 'found; read only, Linter never changes it'));
		else if (mode === 'project') checks.push(warn(`sourcemap:${folder}`, `sourcemap.json (${name})`, 'none yet; Linter will ask Rojo to create one in the project (linter.sourcemap.mode = project)', 'Install Rojo if nothing appears.'));
		else checks.push(warn(`sourcemap:${folder}`, `sourcemap.json (${name})`, 'none; luau-lsp will have no game-tree types. Linter itself does not need it and does not write one', 'Run Rojo yourself, or set "linter.sourcemap.mode" to "project" to let Linter create it (this writes a file into the project).'));
	}

	const level = checks.some((c) => c.level === 'error') ? 'error' : checks.some((c) => c.level === 'warn') ? 'warn' : 'ok';
	const mark = { ok: 'OK   ', warn: 'WARN ', error: 'ERROR' };
	const lines = [];
	for (const c of checks) {
		lines.push(`${mark[c.level]} ${c.title}: ${c.detail}`);
		if (c.fix && c.level !== 'ok') lines.push(`      fix: ${c.fix}`);
	}
	return { level, checks, lines };
}

module.exports = { diagnose, probe, readManifest };
