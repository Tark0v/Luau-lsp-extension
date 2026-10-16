#!/usr/bin/env node
'use strict';
// Makes the pinned luau-lsp available in tools/ (reusing the per-user cache, downloading only when needed).
//   node scripts/fetch-luau-lsp.js
const { TOOLS, ensureTool, installToRepo, REPO_TOOLS } = require('./tools');

const VERSION = TOOLS['luau-lsp'].version;

/** Release asset for a platform/arch (pure, tested). */
function assetFor(platform, arch) {
	return TOOLS['luau-lsp'].asset(platform, arch);
}

async function main() {
	const result = await ensureTool('luau-lsp', { repoToolsDir: REPO_TOOLS, log: console.log });
	const placed = installToRepo(result.path, 'luau-lsp');
	console.log(`luau-lsp ${VERSION}: ${result.source}${placed.changed ? ', copied to tools/' : ', tools/ already current'}`);
}

if (require.main === module) {
	main().catch((error) => {
		console.error(error.message);
		process.exit(1);
	});
}

module.exports = { assetFor, VERSION };
