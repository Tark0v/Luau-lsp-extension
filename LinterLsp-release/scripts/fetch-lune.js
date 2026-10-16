#!/usr/bin/env node
'use strict';
// Makes the pinned Lune available in tools/ (reusing the per-user cache, downloading only when needed).
//   node scripts/fetch-lune.js
const { TOOLS, ensureTool, installToRepo, download, unzip, REPO_TOOLS } = require('./tools');

const VERSION = TOOLS.lune.version;

/** Release asset name for a platform/arch (pure, tested). */
function assetFor(platform, arch) {
	const names = { win32: 'windows', windows: 'windows', linux: 'linux', darwin: 'macos', macos: 'macos' };
	const arches = { x64: 'x86_64', x86_64: 'x86_64', arm64: 'aarch64', aarch64: 'aarch64' };
	if (!names[platform] || !arches[arch]) throw new Error(`no Lune release for ${platform}/${arch}`);
	return `lune-${VERSION}-${names[platform]}-${arches[arch]}.zip`;
}

async function main() {
	const result = await ensureTool('lune', { repoToolsDir: REPO_TOOLS, log: console.log });
	const placed = installToRepo(result.path, 'lune');
	console.log(`lune ${VERSION}: ${result.source}${placed.changed ? ', copied to tools/' : ', tools/ already current'}`);
}

if (require.main === module) {
	main().catch((error) => {
		console.error(error.message);
		process.exit(1);
	});
}

module.exports = { assetFor, VERSION, download, unzip };
