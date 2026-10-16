#!/usr/bin/env node
'use strict';
// The Linter language server as an editor sees it: a stdio LSP server that runs luau-lsp and the Linter server (Lune) and
// merges their answers. Usage:
//   node bridge.js [--root <dir>] [--luau-lsp <path>] [--luau-arg <arg>]... [--lune <path>] [--linter-timeout <ms>]
//                  [--expect-version <x.y.z>] [--no-linter] [--no-luau]
// Everything it logs goes to stderr (stdout is the protocol). This process only reads: it never writes into the project.

const { spawn } = require('child_process');
const path = require('path');
const { FrameParser, LineParser, encodeFrame, encodeLine } = require('./framing');
const { Proxy } = require('./proxy');
const { findLune, findLuauLsp, findDefinitions } = require('./locate');
const { probe, readManifest } = require('./doctor');

function parseArgs(argv) {
	const options = { luauArgs: [], linter: true, luau: true, timeout: 800 };
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === '--root') options.root = argv[++i];
		else if (arg === '--luau-lsp') options.luauLsp = argv[++i];
		else if (arg === '--luau-arg') options.luauArgs.push(argv[++i]);
		else if (arg === '--lune') options.lune = argv[++i];
		else if (arg === '--linter-timeout') options.timeout = Number(argv[++i]) || 800;
		else if (arg === '--expect-version') options.expectVersion = argv[++i];
		else if (arg === '--no-linter') options.linter = false;
		else if (arg === '--no-luau') options.luau = false;
	}
	options.root = options.root || path.resolve(__dirname, '..');
	return options;
}

function log(text) {
	process.stderr.write(`[linter-bridge] ${text}\n`);
}

/** A child process speaking `format` ('frame' | 'line'); returns an endpoint. */
function spawnEndpoint(name, command, args, spawnOptions, format, onMessage, onExit) {
	let child;
	try {
		child = spawn(command, args, Object.assign({ stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true }, spawnOptions));
	} catch (error) {
		log(`${name}: could not start (${error.message})`);
		return null;
	}
	let alive = true;
	const parser = format === 'frame' ? new FrameParser((e) => log(`${name}: bad frame (${e.message})`)) : new LineParser((e) => log(`${name}: bad line (${e.message})`));
	child.stdout.on('data', (chunk) => {
		for (const message of parser.feed(chunk)) {
			try {
				onMessage(message);
			} catch (error) {
				log(`${name}: handler failed (${error.stack || error})`);
			}
		}
	});
	child.stderr.on('data', (chunk) => process.stderr.write(chunk));
	child.stdin.on('error', () => {}); // a dead child must not take the proxy down with EPIPE
	child.on('error', (error) => {
		log(`${name}: ${error.message}`);
	});
	child.on('exit', (code, signal) => {
		if (!alive) return;
		alive = false;
		log(`${name} exited (${signal || code})`);
		onExit();
	});
	return {
		child,
		alive: () => alive,
		send: (message) => {
			if (!alive) return;
			try {
				child.stdin.write(format === 'frame' ? encodeFrame(message) : encodeLine(message));
			} catch (error) {
				log(`${name}: write failed (${error.message})`);
			}
		},
		kill: () => {
			alive = false;
			try {
				child.kill();
			} catch {
				// already gone
			}
		},
	};
}

/** Does this program actually run? (A Rokit shim for a tool the project does not list fails here, not mid-session.) Resolves the binary or null. */
async function usable(name, binary, args, cwd) {
	if (!binary) return null;
	const result = await probe(binary, args, { cwd, timeoutMs: 8000 });
	if (!result.ok) {
		log(`${name} at ${binary} does not run (${result.text}); ignoring it. Run "node scripts/setup.js" to download a working copy into tools/.`);
		return null;
	}
	return binary;
}

async function main() {
	const options = parseArgs(process.argv.slice(2));
	const manifest = readManifest(options.root);
	if (manifest) {
		log(`Linter ${manifest.version}`);
		if (options.expectVersion && manifest.version !== options.expectVersion) {
			log(`WARNING: the runtime is version ${manifest.version} but the extension expects ${options.expectVersion}; parts of two builds are mixed`);
		}
	}
	// both programs are checked at the same time (each check is bounded), so start-up costs the slower one, not the sum
	const [luauBinary, luneBinary] = await Promise.all([
		options.luau ? usable('luau-lsp', findLuauLsp(options.luauLsp, process.env, options.root), ['--version'], options.root) : null,
		options.linter ? usable('lune', findLune(options.root, options.lune), ['--version'], options.root) : null,
	]);
	log(`luau-lsp: ${luauBinary || 'not found'}; lune: ${luneBinary || 'not found'}; root: ${options.root}`);

	const client = {
		alive: () => true,
		send: (message) => {
			try {
				process.stdout.write(encodeFrame(message));
			} catch (error) {
				log(`write to editor failed (${error.message})`);
			}
		},
	};

	let proxy;
	const startLinter = () =>
		luneBinary
			? spawnEndpoint(
					'linter',
					luneBinary,
					['run', 'server/main'],
					{ cwd: options.root, env: Object.assign({}, process.env, { LINTER_ROOT: options.root }) },
					'line',
					(message) => proxy.fromLinter(message),
					() => proxy.linterExited()
			  )
			: null;
	// Roblox types for luau-lsp, unless the caller already passed its own
	const defs = findDefinitions(options.root);
	const has = (flag) => options.luauArgs.some((arg) => arg.startsWith(flag));
	if (defs.types && !has('--definitions')) options.luauArgs.push(`--definitions:@roblox=${defs.types}`);
	if (defs.docs && !has('--docs') && !has('--documentation')) options.luauArgs.push(`--docs=${defs.docs}`);
	log(`luau-lsp args: ${options.luauArgs.join(' ') || '(none)'}`);

	// a `.js` path is run with this Node (how the tests stand in for luau-lsp on every OS)
	const luauIsScript = luauBinary && luauBinary.endsWith('.js');
	const luau = luauBinary
		? spawnEndpoint(
				'luau-lsp',
				luauIsScript ? process.execPath : luauBinary,
				luauIsScript ? [luauBinary, 'lsp', ...options.luauArgs] : ['lsp', ...options.luauArgs],
				{},
				'frame',
				(message) => proxy.fromLuau(message),
				() => proxy.luauExited()
		  )
		: null;

	proxy = new Proxy({
		client,
		luau,
		linter: null,
		linterTimeoutMs: options.timeout,
		restartLinter: startLinter,
		log,
	});
	proxy.linter = startLinter();

	const parser = new FrameParser((e) => log(`bad frame from the editor (${e.message})`));
	process.stdin.on('data', (chunk) => {
		for (const message of parser.feed(chunk)) {
			try {
				proxy.fromClient(message);
			} catch (error) {
				log(`routing failed (${error.stack || error})`);
			}
		}
	});
	const shutdown = () => {
		for (const endpoint of [proxy.luau, proxy.linter]) if (endpoint && endpoint.kill) endpoint.kill();
		process.exit(0);
	};
	process.stdin.on('end', shutdown);
	process.on('SIGTERM', shutdown);
	process.on('uncaughtException', (error) => log(`uncaught: ${error.stack || error}`));
	process.on('unhandledRejection', (error) => log(`unhandled: ${(error && error.stack) || error}`));
	// `exit` from the editor: give the children a moment to answer, then leave
	const originalFromClient = proxy.fromClient.bind(proxy);
	proxy.fromClient = (message) => {
		originalFromClient(message);
		if (message && message.method === 'exit') setTimeout(shutdown, 200);
	};
}

if (require.main === module) {
	// stdin is not read until the proxy exists; the editor's first messages wait in the pipe until then
	process.stdin.pause();
	main()
		.then(() => process.stdin.resume())
		.catch((error) => {
			log(`could not start: ${error.stack || error}`);
			process.exit(1);
		});
}

module.exports = { parseArgs };
