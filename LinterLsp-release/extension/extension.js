'use strict';
const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { LanguageClient, TransportKind, State } = require('vscode-languageclient/node');
const { chooseRoot, bridgeArgs, engineSettings, sourcemapCommand } = require('./config');

let client;
let output;
let statusItem;
let sourcemaps = []; // running sourcemap generators (only ever started when linter.sourcemap.mode is "project")
let currentRoot = null;
let extensionVersion = '0.0.0';

function settings() {
	const config = vscode.workspace.getConfiguration('linter');
	const out = {};
	for (const key of Object.keys(config)) {
		if (typeof config[key] !== 'function') out[key] = config.get(key);
	}
	return out;
}

// ----- status bar -----

const STATES = {
	starting: { text: '$(sync~spin) Linter', tip: 'Linter is starting' },
	ok: { text: '$(check) Linter', tip: 'Linter is running' },
	warn: { text: '$(warning) Linter', tip: 'Linter is running, but something is missing' },
	error: { text: '$(error) Linter', tip: 'Linter has a problem' },
	off: { text: '$(circle-slash) Linter', tip: 'Linter is switched off (linter.enabled)' },
};

function showState(state, detail) {
	if (!statusItem) return;
	const s = STATES[state];
	statusItem.text = s.text;
	statusItem.tooltip = `${s.tip}${detail ? `\n${detail}` : ''}\nVersion ${extensionVersion}. Click to run Linter: Doctor.`;
	statusItem.show();
}

// ----- sourcemap: opt-in only -----

/**
 * Keeps sourcemap.json fresh for luau-lsp, but ONLY when linter.sourcemap.mode is "project". That is the one thing Linter can do
 * that writes a file into a project (Rojo creates sourcemap.json there), so it is off by default. When it is off, a
 * sourcemap.json that already exists is simply read by luau-lsp.
 */
function startSourcemaps(root, mode) {
	if (mode !== 'project') return;
	const cfg = vscode.workspace.getConfiguration('luau-lsp.sourcemap');
	const { onPath, isFile } = require(path.join(root, 'bridge', 'locate'));
	const configuredRojo = cfg.get('rojoPath');
	const rojo = configuredRojo && isFile(configuredRojo) ? configuredRojo : onPath('rojo') || '';
	for (const folder of vscode.workspace.workspaceFolders || []) {
		const dir = folder.uri.fsPath;
		const projectFile = cfg.get('rojoProjectFile') || 'default.project.json';
		const plan = sourcemapCommand(
			{
				mode,
				enabled: cfg.get('enabled'),
				autogenerate: cfg.get('autogenerate'),
				generatorCommand: cfg.get('generatorCommand'),
				rojoProjectFile: projectFile,
				sourcemapFile: cfg.get('sourcemapFile'),
				includeNonScripts: cfg.get('includeNonScripts'),
			},
			fs.existsSync(path.join(dir, projectFile)),
			rojo
		);
		if (!plan) {
			if (fs.existsSync(path.join(dir, projectFile)) && !rojo) {
				output.appendLine(`sourcemap: Rojo not found (set "luau-lsp.sourcemap.rojoPath" or put rojo on PATH); luau-lsp will have no DataModel types for ${dir}`);
			}
			continue;
		}
		try {
			const child = spawn(plan.command, plan.args, { cwd: dir, shell: plan.shell, windowsHide: true });
			child.stdout.on('data', (d) => output.append(`[sourcemap] ${d}`));
			child.stderr.on('data', (d) => output.append(`[sourcemap] ${d}`));
			child.on('error', (error) => output.appendLine(`sourcemap: ${error.message}`));
			sourcemaps.push(child);
			output.appendLine(`sourcemap (linter.sourcemap.mode = project): ${plan.command} ${plan.args.join(' ')} (in ${dir})`);
		} catch (error) {
			output.appendLine(`sourcemap: could not start (${error.message})`);
		}
	}
}

function stopSourcemaps() {
	for (const child of sourcemaps) {
		try {
			child.kill();
		} catch {
			// already gone
		}
	}
	sourcemaps = [];
}

// ----- doctor -----

async function runDoctor(current, root) {
	const { diagnose } = require(path.join(root, 'bridge', 'doctor'));
	return diagnose({
		root,
		settings: current,
		workspaceFolders: (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath),
		expectVersion: extensionVersion,
	});
}

async function doctorCommand() {
	const current = settings();
	const { root, notes } = chooseRoot(vscodeExtensionPath, current.root, extensionVersion);
	output.show(true);
	output.appendLine(`\n--- Linter: Doctor (version ${extensionVersion}) ---`);
	for (const note of notes) output.appendLine(`note: ${note}`);
	if (!root) {
		output.appendLine('ERROR Linter runtime: not found. Reinstall the extension.');
		showState('error', 'runtime not found');
		return vscode.window.showErrorMessage('Linter: the runtime files were not found. Reinstall the extension.');
	}
	const result = await runDoctor(current, root);
	for (const line of result.lines) output.appendLine(line);
	showState(client ? result.level : 'error', result.level === 'ok' ? '' : 'see the Linter output panel');
	const summary = { ok: 'Everything Linter needs was found.', warn: 'Linter works, with warnings (see the Linter output panel).', error: 'Linter has a problem (see the Linter output panel).' }[result.level];
	if (result.level === 'ok') vscode.window.showInformationMessage(`Linter: ${summary}`);
	else if (result.level === 'warn') vscode.window.showWarningMessage(`Linter: ${summary}`);
	else vscode.window.showErrorMessage(`Linter: ${summary}`);
}

let vscodeExtensionPath = '';

// ----- one-time notices -----

function announceUpdate(context) {
	const last = context.globalState.get('linter.lastVersion');
	if (last && last !== extensionVersion) {
		vscode.window.showInformationMessage(`Linter was updated to ${extensionVersion} (from ${last}).`, "What's new").then((choice) => {
			if (choice) vscode.commands.executeCommand('vscode.open', vscode.Uri.file(path.join(context.extensionPath, 'CHANGELOG.md')));
		});
	}
	context.globalState.update('linter.lastVersion', extensionVersion);
}

/** Two luau-lsp clients answer every request twice. This only tells the user; it never disables anything. */
function warnAboutOtherExtension(context) {
	const other = vscode.extensions.getExtension('JohnnyMorganz.luau-lsp');
	if (!other || !other.isActive) return;
	if (context.globalState.get('linter.otherExtensionWarned') === extensionVersion) return;
	context.globalState.update('linter.otherExtensionWarned', extensionVersion);
	vscode.window
		.showWarningMessage(
			'The "Luau Language Server" extension (JohnnyMorganz.luau-lsp) is also enabled, so you will see every suggestion twice. Linter includes the Luau language support and runs luau-lsp itself. Disable that extension (for this workspace) to avoid duplicates. Linter will not change your extensions.',
			'Show that extension'
		)
		.then((choice) => {
			if (choice) vscode.commands.executeCommand('workbench.extensions.search', '@id:JohnnyMorganz.luau-lsp');
		});
}

// ----- lifecycle -----

async function start(context) {
	const current = settings();
	if (current.enabled === false) {
		showState('off');
		return;
	}
	showState('starting');
	const { root, notes } = chooseRoot(context.extensionPath, current.root, extensionVersion);
	for (const note of notes) output.appendLine(`note: ${note}`);
	if (!root) {
		showState('error', 'runtime files not found');
		vscode.window.showErrorMessage('Linter: runtime files not found (bridge/, server/, core/). Reinstall the extension, or fix "linter.root".');
		return;
	}
	currentRoot = root;
	const mode = (current.sourcemap && current.sourcemap.mode) || 'off';
	startSourcemaps(root, mode);
	const args = bridgeArgs(root, Object.assign({}, current, { expectVersion: extensionVersion }));
	const bridge = path.join(root, 'bridge', 'bridge.js');
	const serverOptions = {
		run: { module: bridge, transport: TransportKind.stdio, args },
		debug: { module: bridge, transport: TransportKind.stdio, args },
	};
	const clientOptions = {
		documentSelector: [
			{ scheme: 'file', language: 'luau' },
			{ scheme: 'untitled', language: 'luau' },
		],
		synchronize: {
			configurationSection: ['linter', 'luau-lsp'],
			fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{lua,luau,json}'),
		},
		initializationOptions: { linter: engineSettings(current) },
		outputChannel: output,
	};
	client = new LanguageClient('linter', 'Linter (Luau)', serverOptions, clientOptions);
	client.onDidChangeState((event) => {
		if (event.newState === State.Stopped && client) showState('error', 'the language server stopped; run "Linter: Restart"');
	});
	context.subscriptions.push(client);
	try {
		await client.start();
	} catch (error) {
		showState('error', error.message);
		return;
	}
	// what the user should know (a missing tool, no project file) is checked in the background and shown in the status bar
	runDoctor(current, root)
		.then((result) => {
			showState(result.level, result.level === 'ok' ? '' : result.lines.filter((l) => /^(WARN|ERROR)/.test(l)).join('\n'));
			if (result.level !== 'ok') for (const line of result.lines) output.appendLine(line);
		})
		.catch((error) => output.appendLine(`doctor failed: ${error.message}`));
}

async function stop() {
	stopSourcemaps();
	if (client) {
		const running = client;
		client = undefined;
		try {
			await running.stop();
		} catch {
			// already stopped
		}
	}
}

async function activate(context) {
	extensionVersion = (context.extension && context.extension.packageJSON && context.extension.packageJSON.version) || extensionVersion;
	vscodeExtensionPath = context.extensionPath;
	output = vscode.window.createOutputChannel('Linter');
	statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 0);
	statusItem.command = 'linter.doctor';
	context.subscriptions.push(output, statusItem);
	context.subscriptions.push(
		vscode.commands.registerCommand('linter.restart', async () => {
			await stop();
			await start(context);
		}),
		vscode.commands.registerCommand('linter.doctor', doctorCommand),
		vscode.commands.registerCommand('linter.report', async () => {
			if (!client) return vscode.window.showInformationMessage('Linter is not running.');
			try {
				const result = await client.sendRequest('linter/report');
				output.clear();
				for (const line of (result && result.lines) || []) output.appendLine(line);
				output.show(true);
			} catch (error) {
				vscode.window.showWarningMessage(`Linter report failed: ${error.message}`);
			}
		}),
		vscode.workspace.onDidChangeConfiguration(async (event) => {
			if (!client) return;
			if (['luauLspPath', 'luauLspArgs', 'lunePath', 'timeoutMs', 'root', 'enabled', 'sourcemap'].some((k) => event.affectsConfiguration(`linter.${k}`)) || event.affectsConfiguration('luau-lsp.sourcemap')) {
				await stop();
				await start(context);
			} else if (event.affectsConfiguration('linter')) {
				client.sendNotification('workspace/didChangeConfiguration', { settings: { linter: engineSettings(settings()) } });
			}
		})
	);
	announceUpdate(context);
	warnAboutOtherExtension(context);
	await start(context);
}

async function deactivate() {
	await stop();
}

module.exports = { activate, deactivate };
