'use strict';
// The proxy core: one client (the editor), luau-lsp, and the Linter server. Pure message routing over injected endpoints,
// so it is testable without processes.
//
// An endpoint is { send(message), alive() }. Incoming messages are fed through fromClient / fromLuau / fromLinter.
//   * everything goes to luau-lsp; notifications (document sync, config, file events) also go to Linter
//   * completion requests go to both; the answers are merged (see merge.js) once luau-lsp has answered and Linter has
//     answered or is out of time
//   * diagnostics from both are published to the editor as one list per file
//   * Linter being absent, slow or dying never costs luau-lsp's answers

const { mergeCompletion, mergeFileDiagnostics, mergeCapabilities } = require('./merge');

function lineStarts(text) {
	const starts = [0];
	for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) starts.push(i + 1);
	return starts;
}

/** Applies LSP content changes (JS strings are UTF-16, like LSP columns). */
function applyChanges(text, changes) {
	for (const change of changes || []) {
		if (change && change.range) {
			const starts = lineStarts(text);
			const at = (position) => {
				const start = starts[position.line];
				if (start === undefined) return text.length;
				const end = starts[position.line + 1] === undefined ? text.length : starts[position.line + 1] - 1;
				return Math.min(start + position.character, end);
			};
			text = text.slice(0, at(change.range.start)) + change.text + text.slice(at(change.range.end));
		} else if (change) {
			text = change.text;
		}
	}
	return text;
}

class Proxy {
	/**
	 * options: client, luau|null, linter|null (endpoints), linterTimeoutMs, restartLinter() -> endpoint|null, log(text),
	 * setTimeout/clearTimeout (injectable for tests), maxRestarts
	 */
	constructor(options) {
		this.client = options.client;
		this.luau = options.luau || null;
		this.linter = options.linter || null;
		this.linterTimeoutMs = options.linterTimeoutMs ?? 800;
		this.restartLinter = options.restartLinter || (() => null);
		this.log = options.log || (() => {});
		this.setTimer = options.setTimeout || setTimeout;
		this.clearTimer = options.clearTimeout || clearTimeout;
		this.maxRestarts = options.maxRestarts ?? 5;
		this.pendingInit = null;
		this.pendingCompletions = new Map();
		this.linterRequests = new Set(); // client request ids answered by Linter alone
		this.docs = new Map(); // uri -> text
		this.initParams = null;
		this.diagnostics = { luau: new Map(), linter: new Map() };
		this.restarts = [];
		this.internalId = 0;
		this.warned = false;
	}

	// ----- from the editor -----

	fromClient(message) {
		if (!message || typeof message !== 'object') return;
		const { method, id } = message;
		if (method === undefined) {
			// the editor answering something luau-lsp asked (workspace/configuration ...)
			if (this.luau) this.luau.send(message);
			return;
		}
		if (method === 'initialize' && id !== undefined) return this.initialize(message);
		if (method === 'textDocument/completion' && id !== undefined) return this.completion(message);
		if (id !== undefined) {
			if (method.startsWith('linter/')) {
				if (this.linter && this.linter.alive()) {
					this.linterRequests.add(id);
					this.linter.send(message);
				} else {
					this.client.send({ jsonrpc: '2.0', id, error: { code: -32601, message: 'Linter is not running' } });
				}
				return;
			}
			if (this.luau) this.luau.send(message);
			else this.client.send({ jsonrpc: '2.0', id, result: method === 'shutdown' ? null : null });
			if (method === 'shutdown' && this.linter) this.linter.send(message);
			return;
		}
		this.notification(message);
	}

	notification(message) {
		const { method, params } = message;
		if (method === 'textDocument/didOpen') {
			this.docs.set(params.textDocument.uri, params.textDocument.text);
		} else if (method === 'textDocument/didChange') {
			const uri = params.textDocument.uri;
			if (this.docs.has(uri)) this.docs.set(uri, applyChanges(this.docs.get(uri), params.contentChanges));
		} else if (method === 'textDocument/didClose') {
			this.docs.delete(params.textDocument.uri);
			this.diagnostics.linter.delete(params.textDocument.uri);
		}
		if (this.luau) this.luau.send(message);
		if (this.linter && this.linter.alive()) this.linter.send(message);
	}

	initialize(message) {
		this.initParams = message.params;
		this.pendingInit = { id: message.id, luau: null, linter: null, luauDone: !this.luau, linterDone: !this.linter, failed: false };
		if (this.luau) this.luau.send(message);
		if (this.linter) this.linter.send(message);
		this.finishInit();
	}

	finishInit() {
		const init = this.pendingInit;
		if (!init || !init.luauDone || !init.linterDone) return;
		this.pendingInit = null;
		if (!init.luau && !init.linter) {
			this.client.send({ jsonrpc: '2.0', id: init.id, error: { code: -32603, message: 'neither luau-lsp nor Linter could start' } });
			return;
		}
		const luauCaps = init.luau && init.luau.capabilities;
		const linterCaps = init.linter && init.linter.capabilities;
		this.client.send({
			jsonrpc: '2.0',
			id: init.id,
			result: {
				capabilities: mergeCapabilities(luauCaps, linterCaps),
				serverInfo: { name: 'linter-lsp proxy', version: '0.1.0' },
			},
		});
		if (!this.linter && !this.warned) {
			this.warned = true;
			this.client.send({ jsonrpc: '2.0', method: 'window/showMessage', params: { type: 2, message: 'Linter could not start (no working Lune runtime); only luau-lsp is active. Run `node scripts/setup.js` in the Linter folder.' } });
		}
		if (!this.luau && !this.warned) {
			this.warned = true;
			this.client.send({ jsonrpc: '2.0', method: 'window/showMessage', params: { type: 2, message: 'luau-lsp was not found or does not run; only Linter completions are available. Run `node scripts/setup.js` in the Linter folder.' } });
		}
	}

	completion(message) {
		const entry = {
			id: message.id,
			luauDone: !this.luau,
			linterDone: !this.linter || !this.linter.alive(),
			luau: null,
			linter: null,
			timedOut: false,
			timer: null,
		};
		this.pendingCompletions.set(message.id, entry);
		if (this.luau) this.luau.send(message);
		if (!entry.linterDone) {
			this.linter.send(message);
			entry.timer = this.setTimer(() => {
				entry.timedOut = true;
				this.finishCompletion(entry);
			}, this.linterTimeoutMs);
		}
		this.finishCompletion(entry);
	}

	finishCompletion(entry) {
		if (!this.pendingCompletions.has(entry.id)) return;
		if (!entry.luauDone) return;
		if (!entry.linterDone && !entry.timedOut) return;
		this.pendingCompletions.delete(entry.id);
		if (entry.timer) this.clearTimer(entry.timer);
		this.client.send({ jsonrpc: '2.0', id: entry.id, result: mergeCompletion(entry.luau, entry.linter) });
	}

	// ----- from luau-lsp -----

	fromLuau(message) {
		if (!message || typeof message !== 'object') return;
		if (message.method === undefined && message.id !== undefined) {
			const init = this.pendingInit;
			if (init && init.id === message.id && !init.luauDone) {
				init.luauDone = true;
				if (message.error) init.failed = true;
				else init.luau = message.result;
				return this.finishInit();
			}
			const entry = this.pendingCompletions.get(message.id);
			if (entry && !entry.luauDone) {
				entry.luauDone = true;
				entry.luau = message.error ? null : message.result;
				return this.finishCompletion(entry);
			}
			return this.client.send(message);
		}
		if (message.method === 'textDocument/publishDiagnostics') {
			this.diagnostics.luau.set(message.params.uri, message.params.diagnostics || []);
			return this.publish(message.params.uri, message.params);
		}
		this.client.send(message);
	}

	// ----- from Linter -----

	fromLinter(message) {
		if (!message || typeof message !== 'object') return;
		if (message.method === undefined && message.id !== undefined) {
			const init = this.pendingInit;
			if (init && init.id === message.id && !init.linterDone) {
				init.linterDone = true;
				if (message.error) init.failed = true;
				else init.linter = message.result;
				return this.finishInit();
			}
			const entry = this.pendingCompletions.get(message.id);
			if (entry && !entry.linterDone) {
				entry.linterDone = true;
				entry.linter = message.error ? null : message.result;
				return this.finishCompletion(entry);
			}
			if (this.linterRequests.delete(message.id)) return this.client.send(message);
			return; // an internal answer (restart handshake)
		}
		if (message.method === 'textDocument/publishDiagnostics') {
			this.diagnostics.linter.set(message.params.uri, message.params.diagnostics || []);
			return this.publish(message.params.uri, message.params);
		}
		// Linter has nothing else to say to the editor
	}

	publish(uri, params) {
		const merged = mergeFileDiagnostics(this.diagnostics.luau.get(uri), this.diagnostics.linter.get(uri));
		const out = { uri, diagnostics: merged };
		if (params && params.version !== undefined) out.version = params.version;
		this.client.send({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics', params: out });
	}

	// ----- failure handling -----

	/** The Linter process ended. Pending completions go on without it; it is restarted a few times, then left off. */
	linterExited() {
		for (const entry of this.pendingCompletions.values()) {
			if (!entry.linterDone) {
				entry.linterDone = true;
				this.finishCompletion(entry);
			}
		}
		if (this.pendingInit && !this.pendingInit.linterDone) {
			this.pendingInit.linterDone = true;
			this.finishInit();
		}
		this.diagnostics.linter.clear();
		const now = Date.now();
		this.restarts = this.restarts.filter((t) => now - t < 60000);
		if (this.restarts.length >= this.maxRestarts) {
			this.log('Linter crashed too often; leaving it off (luau-lsp keeps working)');
			this.linter = null;
			return;
		}
		this.restarts.push(now);
		const endpoint = this.restartLinter();
		if (!endpoint) {
			this.linter = null;
			return;
		}
		this.linter = endpoint;
		this.replay();
	}

	/** Brings a fresh Linter process up to date: handshake, then every open document. */
	replay() {
		if (!this.initParams || !this.linter) return;
		const id = `linter-restart-${++this.internalId}`;
		this.linter.send({ jsonrpc: '2.0', id, method: 'initialize', params: this.initParams });
		this.linter.send({ jsonrpc: '2.0', method: 'initialized', params: {} });
		for (const [uri, text] of this.docs) {
			this.linter.send({ jsonrpc: '2.0', method: 'textDocument/didOpen', params: { textDocument: { uri, languageId: 'luau', version: 1, text } } });
		}
	}

	luauExited() {
		this.luau = null;
		for (const entry of this.pendingCompletions.values()) {
			entry.luauDone = true;
			this.finishCompletion(entry);
		}
		if (this.pendingInit && !this.pendingInit.luauDone) {
			this.pendingInit.luauDone = true;
			this.finishInit();
		}
	}
}

module.exports = { Proxy, applyChanges };
