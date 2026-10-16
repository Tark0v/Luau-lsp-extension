#!/usr/bin/env node
'use strict';
// One command from a fresh copy of this folder to an installed VS Code extension:
//   node scripts/setup.js [--install]      (default: build only; --install also runs `code --install-extension`)
// Steps: machine check -> Lune -> luau-lsp -> extension dependencies -> tests -> package + install. Every step is skipped
// when already done, so it is safe to run again. Stops with the reason at the first problem.
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const exe = (name) => (process.platform === 'win32' ? `${name}.exe` : name);
const has = (file) => fs.existsSync(path.join(root, file));

function step(name, action) {
	process.stdout.write(`\n[${name}]\n`);
	try {
		action();
	} catch (error) {
		console.error(`\nsetup stopped at "${name}": ${error.message}`);
		process.exit(1);
	}
}

function needsShell(command) {
	return process.platform === 'win32' && /\.(cmd|bat)$/i.test(command);
}

function run(command, args, cwd = root) {
	const result = spawnSync(command, args, { cwd, stdio: 'inherit', shell: needsShell(command) });
	if (result.error) throw result.error;
	if (result.status !== 0) throw new Error(`${command} ${args.join(' ')} failed`);
}

function version(command, args) {
	const result = spawnSync(command, args, { encoding: 'utf8', shell: needsShell(command) });
	return result.status === 0 ? (result.stdout || '').trim() : null;
}

step('machine', () => {
	const major = Number(process.versions.node.split('.')[0]);
	if (major < 18) throw new Error(`Node 18+ is required (found ${process.versions.node})`);
	if (!['linux', 'win32', 'darwin'].includes(process.platform)) throw new Error(`unsupported platform ${process.platform}`);
	const npm = version(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['--version']);
	if (!npm) throw new Error('npm was not found (it comes with Node)');
	console.log(`${process.platform}/${process.arch}, node ${process.versions.node}, npm ${npm}`);
});

step('Lune', () => {
	// idempotent: runs the tool to check it, reuses the per-user cache, downloads only what is missing or wrong
	run(process.execPath, [path.join('scripts', 'fetch-lune.js')]);
});

step('luau-lsp', () => {
	// same check as Lune: a file merely existing does not count
	run(process.execPath, [path.join('scripts', 'fetch-luau-lsp.js')]);
});

step('Roblox data', () => {
	for (const file of ['data/luau-lsp/globalTypes.d.luau', 'data/luau-lsp/api-docs.json']) {
		if (!has(file)) throw new Error(`${file} is missing from this folder (it ships with the project)`);
	}
	console.log(has('data/reflection.json') ? 'class data present (Studio dump)' : 'no data/reflection.json: Lune\'s built-in class data is used (see Instructions.md to create the full dump)');
});

step('extension dependencies', () => {
	if (has('extension/node_modules/vscode-languageclient')) return console.log('already installed');
	run(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['install', '--no-audit', '--no-fund'], path.join(root, 'extension'));
});

step('stage runtime', () => {
	// version.json -> extension/package.json, extension/runtime and its manifest (generated, never edited by hand)
	run(process.execPath, [path.join('scripts', 'package-extension.js'), '--stage-only']);
});

step('tests', () => {
	if (!has('scripts/test.js') || !has('tests')) return console.log('skipped (no tests folder)');
	run(process.execPath, [path.join('scripts', 'test.js')]);
});

// Installing changes the user's VS Code, so it only happens when asked for (--install). The default builds the .vsix and stops.
if (!process.argv.includes('--install')) {
	step('package', () => run(process.execPath, [path.join('scripts', 'package-extension.js')]));
	console.log('\nBuilt, NOT installed: your VS Code was not touched. To install, run: node scripts/setup.js --install   (or Extensions view > "..." > Install from VSIX).');
} else {
	step('package and install', () => run(process.execPath, [path.join('scripts', 'package-extension.js'), '--install']));
	console.log('\nDone. Restart VS Code, open a Rojo project folder, open a .luau file.');
}
