'use strict';
// The pinned helper programs (Lune, luau-lsp): where they live, whether an installed copy is good, and how to get one.
//
// Rules this file keeps:
//   * idempotent: a tool that already runs and reports the pinned version is never downloaded again;
//   * a tool is judged by RUNNING it (`--version`), not by a file existing, and by a hash recorded when it was installed;
//   * one per-user cache (not the project, not the editor) holds every version, so rebuilds and other copies reuse it;
//   * nothing half-written is ever visible: files are written next to their destination as `.part` and renamed into place;
//   * it only ever writes inside the cache folder and the repository's own tools/ folder.
const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const pins = require('../version.json');

const REPO_TOOLS = path.resolve(__dirname, '..', 'tools');

const TOOLS = {
	lune: {
		version: pins.tools.lune,
		exe: (platform) => (platform === 'win32' ? 'lune.exe' : 'lune'),
		asset(platform, arch) {
			const osName = { linux: 'linux', win32: 'windows', darwin: 'macos' }[platform];
			const archName = { x64: 'x86_64', arm64: 'aarch64' }[arch];
			if (!osName || !archName) throw new Error(`no Lune release for ${platform}/${arch}`);
			return `lune-${this.version}-${osName}-${archName}.zip`;
		},
		url(platform, arch) {
			return `https://github.com/lune-org/lune/releases/download/v${this.version}/${this.asset(platform, arch)}`;
		},
	},
	'luau-lsp': {
		version: pins.tools['luau-lsp'],
		exe: (platform) => (platform === 'win32' ? 'luau-lsp.exe' : 'luau-lsp'),
		asset(platform, arch) {
			if (platform === 'linux' && arch === 'x64') return 'luau-lsp-linux-x86_64.zip';
			if (platform === 'linux' && arch === 'arm64') return 'luau-lsp-linux-arm64.zip';
			if (platform === 'darwin') return 'luau-lsp-macos.zip';
			if (platform === 'win32' && arch === 'x64') return 'luau-lsp-win64.zip';
			throw new Error(`no luau-lsp release for ${platform}/${arch}`);
		},
		url(platform, arch) {
			return `https://github.com/JohnnyMorganz/luau-lsp/releases/download/${this.version}/${this.asset(platform, arch)}`;
		},
	},
};

/** The per-user folder tools are cached in (pure: everything it needs is passed in). */
function cacheRoot(env = process.env, platform = process.platform, home = os.homedir()) {
	if (env.LINTER_CACHE) return env.LINTER_CACHE;
	if (platform === 'win32') return path.join(env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'), 'linter-luau', 'tools');
	if (platform === 'darwin') return path.join(home, 'Library', 'Caches', 'linter-luau', 'tools');
	return path.join(env.XDG_CACHE_HOME || path.join(home, '.cache'), 'linter-luau', 'tools');
}

function sha256(file) {
	return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

/** What `exe --version` printed, or null when it does not run. */
function runVersion(exe) {
	const result = spawnSync(exe, ['--version'], { encoding: 'utf8', timeout: 15000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
	if (result.error || result.status !== 0) return null;
	return `${result.stdout || ''}${result.stderr || ''}`.trim();
}

function download(url, destination, { retries = 3, timeoutMs = 60000, redirects = 5 } = {}) {
	const once = (target, left) =>
		new Promise((resolve, reject) => {
			const request = https.get(target, { headers: { 'User-Agent': 'linter-lsp' } }, (response) => {
				if ([301, 302, 303, 307, 308].includes(response.statusCode) && left > 0) {
					response.resume();
					return resolve(once(response.headers.location, left - 1));
				}
				if (response.statusCode !== 200) {
					response.resume();
					return reject(new Error(`download failed: HTTP ${response.statusCode} (${target})`));
				}
				const part = `${destination}.part`;
				const file = fs.createWriteStream(part);
				response.pipe(file);
				file.on('finish', () =>
					file.close(() => {
						fs.renameSync(part, destination);
						resolve();
					})
				);
				file.on('error', reject);
			});
			request.setTimeout(timeoutMs, () => request.destroy(new Error(`download timed out (${target})`)));
			request.on('error', reject);
		});
	return (async () => {
		let last;
		for (let attempt = 1; attempt <= retries; attempt++) {
			try {
				return await once(url, redirects);
			} catch (error) {
				last = error;
				try {
					fs.rmSync(`${destination}.part`, { force: true });
				} catch {
					// nothing to clean
				}
				if (attempt < retries) await new Promise((r) => setTimeout(r, 500 * attempt));
			}
		}
		throw last;
	})();
}

/** Extracts a zip into `directory`. Paths are passed as data, never spliced into a command line. */
function unzip(zip, directory) {
	fs.mkdirSync(directory, { recursive: true });
	const result =
		process.platform === 'win32'
			? spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', 'Expand-Archive -Force -LiteralPath $env:LINTER_ZIP -DestinationPath $env:LINTER_DEST'], {
					stdio: 'inherit',
					env: Object.assign({}, process.env, { LINTER_ZIP: zip, LINTER_DEST: directory }),
			  })
			: spawnSync('unzip', ['-o', '-q', zip, '-d', directory], { stdio: 'inherit' });
	if (result.status !== 0) throw new Error('could not extract the archive (is `unzip` installed?)');
}

function findFile(directory, name) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		if (entry.isFile() && entry.name === name) return full;
		if (entry.isDirectory()) {
			const found = findFile(full, name);
			if (found) return found;
		}
	}
	return null;
}

/** Copies `from` to `to` so that `to` is either the complete new file or whatever was there before. */
function placeFile(from, to, platform) {
	fs.mkdirSync(path.dirname(to), { recursive: true });
	const part = `${to}.part`;
	fs.copyFileSync(from, part);
	if (platform !== 'win32') fs.chmodSync(part, 0o755);
	try {
		fs.rmSync(to, { force: true });
	} catch {
		// a running copy cannot be replaced on Windows; the rename below reports it
	}
	fs.renameSync(part, to);
}

const defaultDeps = { run: runVersion, download, unzip };

/**
 * Makes sure `name` is available in the cache and returns { path, source, version, sha256 } where source is
 * 'cache' (already good), 'repo' (an existing tools/ copy was good and is now cached) or 'downloaded'.
 * options: cacheDir, repoToolsDir, platform, arch, offline, log, deps ({ run, download, unzip } for tests)
 */
async function ensureTool(name, options = {}) {
	const tool = TOOLS[name];
	if (!tool) throw new Error(`unknown tool ${name}`);
	const platform = options.platform || process.platform;
	const arch = options.arch || process.arch;
	const log = options.log || (() => {});
	const deps = Object.assign({}, defaultDeps, options.deps);
	const dir = path.join(options.cacheDir || cacheRoot(), `${name}-${tool.version}`);
	const exe = path.join(dir, tool.exe(platform));
	const stateFile = path.join(dir, 'state.json');

	const good = (file) => {
		if (!fs.existsSync(file)) return false;
		const said = deps.run(file);
		return said !== null && said.includes(tool.version);
	};
	const remember = (file) => {
		const hash = sha256(file);
		fs.writeFileSync(stateFile, JSON.stringify({ name, version: tool.version, sha256: hash }));
		return hash;
	};

	// 1. the cached copy, if it runs, reports the pinned version, and is the file that was installed
	if (good(exe)) {
		let recorded = null;
		try {
			recorded = JSON.parse(fs.readFileSync(stateFile, 'utf8')).sha256;
		} catch {
			// no record yet: trust what runs and record it now
		}
		const hash = sha256(exe);
		if (recorded === null) remember(exe);
		if (recorded === null || recorded === hash) return { path: exe, source: 'cache', version: tool.version, sha256: hash };
		log(`${name}: the cached file changed since it was installed; replacing it`);
	} else if (fs.existsSync(exe)) {
		log(`${name}: the cached copy does not run or is the wrong version; replacing it`);
	}

	// 2. a copy already in the repository's tools/ folder
	const repoCopy = options.repoToolsDir ? path.join(options.repoToolsDir, tool.exe(platform)) : null;
	if (repoCopy && good(repoCopy)) {
		placeFile(repoCopy, exe, platform);
		const hash = remember(exe);
		log(`${name}: reused ${repoCopy}`);
		return { path: exe, source: 'repo', version: tool.version, sha256: hash };
	}

	// 3. download
	if (options.offline) throw new Error(`${name} ${tool.version} is not installed and downloads are switched off`);
	fs.mkdirSync(dir, { recursive: true });
	const work = path.join(dir, `.work-${process.pid}`);
	fs.rmSync(work, { recursive: true, force: true });
	fs.mkdirSync(work, { recursive: true });
	try {
		const url = tool.url(platform, arch);
		log(`${name}: downloading ${url}`);
		const zip = path.join(work, 'archive.zip');
		await deps.download(url, zip);
		deps.unzip(zip, path.join(work, 'out'));
		const found = findFile(path.join(work, 'out'), tool.exe(platform));
		if (!found) throw new Error(`${name}: ${tool.exe(platform)} was not in the archive`);
		if (platform !== 'win32') fs.chmodSync(found, 0o755);
		if (!good(found)) throw new Error(`${name}: the downloaded file does not run or is not version ${tool.version}`);
		placeFile(found, exe, platform);
		const hash = remember(exe);
		return { path: exe, source: 'downloaded', version: tool.version, sha256: hash };
	} finally {
		fs.rmSync(work, { recursive: true, force: true });
	}
}

/** Copies a cached tool into the repository's tools/ folder when that copy is missing or different. */
function installToRepo(cachedPath, name, options = {}) {
	const platform = options.platform || process.platform;
	const target = path.join(options.repoToolsDir || REPO_TOOLS, TOOLS[name].exe(platform));
	if (fs.existsSync(target) && sha256(target) === sha256(cachedPath)) return { path: target, changed: false };
	placeFile(cachedPath, target, platform);
	return { path: target, changed: true };
}

module.exports = { TOOLS, REPO_TOOLS, cacheRoot, ensureTool, installToRepo, runVersion, download, unzip, sha256 };
