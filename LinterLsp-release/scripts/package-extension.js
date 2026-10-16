#!/usr/bin/env node
'use strict';
// Builds the installable VS Code extension (.vsix) for THIS machine's platform: stages the runtime (bridge, server, core,
// data, the Lune and luau-lsp binaries) into extension/runtime and runs vsce.
//   node scripts/package-extension.js [--stage-only] [--install]
//   --stage-only  only refresh extension/runtime from core/, server/, bridge/, data/ (no .vsix, no network, nothing installed)
//   --install     also runs `code --install-extension` (changes the user's VS Code; never used by tests)
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const pins = require('../version.json');
const extension = path.join(root, 'extension');
const runtime = path.join(extension, 'runtime');
const exe = (name) => (process.platform === 'win32' ? `${name}.exe` : name);
function needsShell(command) {
	return process.platform === 'win32' && /\.(cmd|bat)$/i.test(command);
}
const TARGETS = { 'linux-x64': 'linux-x64', 'linux-arm64': 'linux-arm64', 'win32-x64': 'win32-x64', 'win32-arm64': 'win32-arm64', 'darwin-x64': 'darwin-x64', 'darwin-arm64': 'darwin-arm64' };

function copy(from, to, filter) {
	fs.cpSync(path.join(root, from), path.join(runtime, to || from), { recursive: true, filter });
}

function main() {
	const target = TARGETS[`${process.platform}-${process.arch}`];
	if (!target) throw new Error(`no VS Code target for ${process.platform}/${process.arch}`);
	for (const binary of ['lune', 'luau-lsp']) {
		if (!fs.existsSync(path.join(root, 'tools', exe(binary)))) {
			throw new Error(`tools/${exe(binary)} is missing (node scripts/fetch-lune.js; put luau-lsp in tools/)`);
		}
	}
	// the programs that go into the package must run and be the pinned versions (a file merely existing is not enough)
	const { runVersion } = require('./tools');
	for (const binary of ['lune', 'luau-lsp']) {
		const said = runVersion(path.join(root, 'tools', exe(binary)));
		if (said === null || !said.includes(pins.tools[binary])) {
			throw new Error(`tools/${exe(binary)} does not run or is not version ${pins.tools[binary]} (run: node scripts/setup.js)`);
		}
	}
	fs.rmSync(runtime, { recursive: true, force: true });
	fs.mkdirSync(runtime, { recursive: true });
	copy('bridge', 'bridge', (src) => !src.includes(`${path.sep}test`));
	copy('server');
	copy('core');
	copy('data');
	fs.mkdirSync(path.join(runtime, 'tools'));
	for (const binary of ['lune', 'luau-lsp']) fs.copyFileSync(path.join(root, 'tools', exe(binary)), path.join(runtime, 'tools', exe(binary)));

	// one version for everything: version.json -> the extension's package.json, the runtime manifest and the changelog shipped with it
	const packagePath = path.join(extension, 'package.json');
	const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
	if (packageJson.version !== pins.version) {
		packageJson.version = pins.version;
		fs.writeFileSync(packagePath, `${JSON.stringify(packageJson, null, 2)}\n`);
	}
	const hashes = {};
	const hashTree = (dir, base) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) hashTree(full, base);
			else if (/\.(js|luau|json|txt)$/.test(entry.name)) hashes[path.relative(base, full).split(path.sep).join('/')] = crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex');
		}
	};
	for (const dir of ['bridge', 'server', 'core']) hashTree(path.join(runtime, dir), runtime);
	fs.writeFileSync(path.join(runtime, 'manifest.json'), `${JSON.stringify({ version: pins.version, tools: pins.tools, files: hashes }, null, 1)}\n`);
	fs.copyFileSync(path.join(root, 'CHANGELOG.md'), path.join(extension, 'CHANGELOG.md'));
	fs.copyFileSync(path.join(root, 'THIRD-PARTY-NOTICES.md'), path.join(extension, 'THIRD-PARTY-NOTICES.md')); // the package contains Lune and luau-lsp
	if (process.argv.includes('--stage-only')) return console.log('staged extension/runtime (no .vsix built, nothing installed)');
	fs.writeFileSync(path.join(extension, '.vscodeignore'), ['test/**', '.vscode/**', '*.vsix', ''].join('\n'));
	const npx = process.platform === 'win32' ? 'npx.cmd' : 'npx';
	const vsce = spawnSync(npx, ['--yes', '@vscode/vsce', 'package', '--target', target, '--allow-missing-repository', '--skip-license'], { cwd: extension, stdio: 'inherit', shell: needsShell(npx) });
	if (vsce.status !== 0) throw new Error('vsce failed');
	const vsix = fs.readdirSync(extension).filter((f) => f.endsWith('.vsix')).sort().pop();
	console.log(`built ${path.join(extension, vsix)}`);
	if (process.argv.includes('--install')) {
		const codeCommand = process.platform === 'win32' ? 'code.cmd' : 'code'; // VS Code ships code.cmd on Windows
		const vsixPath = path.join(extension, vsix);
		const code = spawnSync(codeCommand, ['--install-extension', needsShell(codeCommand) ? `"${vsixPath}"` : vsixPath, '--force'], { stdio: 'inherit', shell: needsShell(codeCommand) });
		if (code.error) throw code.error;
		if (code.status !== 0) throw new Error('code --install-extension failed');
	}
}

try {
	main();
} catch (error) {
	console.error(error.message);
	process.exit(1);
}
