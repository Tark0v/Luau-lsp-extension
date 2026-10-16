'use strict';
// Merging Linter's answers into luau-lsp's. Same rules Linter used inside Studio (Completion/Items.merge + trimHidden):
// luau-lsp's entries win, Linter only fills missing detail / documentation and adds what is missing; names marked
// private/hidden are removed from luau-lsp's list unless Linter itself still offers them.

function itemsOf(result) {
	if (!result) return [];
	if (Array.isArray(result)) return result;
	return Array.isArray(result.items) ? result.items : [];
}

function mergeCompletion(luauResult, linterResult, maxItems = 2000) {
	const linterItems = itemsOf(linterResult);
	const hide = new Set((linterResult && linterResult.linter && linterResult.linter.hide) || []);
	const offered = new Set(linterItems.map((item) => item.label));

	const items = itemsOf(luauResult).filter((item) => !(hide.has(item.label) && !offered.has(item.label)));
	const existing = new Map();
	for (const item of items) {
		if (!existing.has(item.label)) existing.set(item.label, item);
	}
	let added = 0;
	for (const item of linterItems) {
		const current = existing.get(item.label);
		if (current) {
			if ((current.detail === undefined || current.detail === null || current.detail === 'any') && item.detail) {
				current.detail = item.detail;
			}
			if ((current.documentation === undefined || current.documentation === null) && item.documentation) {
				current.documentation = item.documentation;
			}
		} else if (added < maxItems) {
			items.push(item);
			existing.set(item.label, item);
			added++;
		}
	}
	const incomplete = Boolean((luauResult && luauResult.isIncomplete) || (linterResult && linterResult.isIncomplete));
	return { isIncomplete: incomplete, items };
}

/** Union of diagnostics from the servers, in a stable order (luau-lsp first). */
function mergeDiagnostics(...lists) {
	const out = [];
	for (const list of lists) {
		if (Array.isArray(list)) out.push(...list);
	}
	return out;
}

const MOVED_CODE = 'Linter.MovedAtRuntime';
const NOT_FOUND = /not found|not a valid member|unknown|does not exist|undefined/i;

function touchesLines(a, b) {
	if (!a || !b || !a.start || !a.end || !b.start || !b.end) return false;
	return a.start.line <= b.end.line && b.start.line <= a.end.line;
}

function mentions(message, name) {
	if (typeof message !== 'string' || typeof name !== 'string' || !name) return false;
	const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	return new RegExp(`(^|[^\\w])${escaped}([^\\w]|$)`).test(message);
}

/**
 * The diagnostics for one file: luau-lsp's, then Linter's. A Linter marker (code Linter.MovedAtRuntime, data.suppress = name) says
 * "a script moves `name` there at run time": luau-lsp's "not found" error about that name on the same line is false and is dropped.
 * The markers themselves are never shown. Errors that merely mention the name in another way (a wrong type, say) are kept.
 */
function mergeFileDiagnostics(luauList, linterList) {
	const luau = Array.isArray(luauList) ? luauList : [];
	const linter = Array.isArray(linterList) ? linterList : [];
	const marks = linter.filter((d) => d && d.data && typeof d.data.suppress === 'string');
	const kept = marks.length
		? luau.filter((d) => !(d && (d.severity === undefined || d.severity <= 2) && NOT_FOUND.test(d.message || '') && marks.some((m) => touchesLines(d.range, m.range) && mentions(d.message, m.data.suppress))))
		: luau;
	return mergeDiagnostics(kept, linter.filter((d) => !(d && d.code === MOVED_CODE)));
}

/** Capabilities of the merged server: luau-lsp's, plus completion triggers Linter needs. */
function mergeCapabilities(luauCaps, linterCaps) {
	const caps = Object.assign({}, linterCaps || {}, luauCaps || {});
	const triggers = new Set([
		...((luauCaps && luauCaps.completionProvider && luauCaps.completionProvider.triggerCharacters) || []),
		...((linterCaps && linterCaps.completionProvider && linterCaps.completionProvider.triggerCharacters) || []),
	]);
	caps.completionProvider = Object.assign({}, (luauCaps && luauCaps.completionProvider) || {}, {
		triggerCharacters: [...triggers],
	});
	if (!caps.textDocumentSync && linterCaps) caps.textDocumentSync = linterCaps.textDocumentSync;
	return caps;
}

module.exports = { mergeCompletion, mergeDiagnostics, mergeFileDiagnostics, mergeCapabilities, itemsOf };
