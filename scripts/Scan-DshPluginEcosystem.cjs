#!/usr/bin/env node
/*
 * Read a real DSH profile and emit a reproducible, token-free plugin inventory.
 *
 * This file deliberately does not carry a plugin catalogue.  The profile's
 * package.json, installed packages, patch layers and package metadata are the
 * source of truth.  It is kept as plain Node.js so the same scanner works from
 * Windows PowerShell 5.1 and PowerShell 7.
 */
'use strict';

const childProcess = require('child_process');
const fs = require('fs');
const https = require('https');
const path = require('path');

const TARGET_DEFAULT = '0.1.5-rc.2';
const MAX_SOURCE_FILE_BYTES = 4 * 1024 * 1024;
const MAX_SOURCE_TOTAL_BYTES = 20 * 1024 * 1024;

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (!item.startsWith('--')) continue;
    const key = item.slice(2);
    if (key === 'offline' || key === 'run-plugin-list') {
      result[key] = true;
      continue;
    }
    result[key] = argv[index + 1] || '';
    index += 1;
  }
  return result;
}

const args = parseArguments(process.argv.slice(2));
const dshHome = path.resolve(args['dsh-home'] || process.env.DSH_HOME || path.join(process.env.USERPROFILE || process.env.HOME || '.', '.dsh'));
const profileName = args.profile || 'web';
const profileDirectory = path.join(dshHome, 'profiles', profileName);
const targetDshVersion = args['target-version'] || TARGET_DEFAULT;
const offline = Boolean(args.offline);

function stableUnique(values) {
  const seen = new Set();
  const output = [];
  for (const value of values || []) {
    const text = String(value || '').trim();
    if (!text || seen.has(text)) continue;
    seen.add(text);
    output.push(text);
  }
  return output;
}

function compareText(a, b) {
  return String(a || '').localeCompare(String(b || ''), 'en', { sensitivity: 'base' });
}

function safeReadText(filePath) {
  try { return fs.readFileSync(filePath, 'utf8'); } catch (_) { return ''; }
}

function safeReadJson(filePath) {
  try { return JSON.parse(fs.readFileSync(filePath, 'utf8')); } catch (_) { return null; }
}

function toStringArray(value) {
  if (Array.isArray(value)) return stableUnique(value.map(String));
  if (typeof value === 'string') return stableUnique([value]);
  return [];
}

function quoteMarkdown(value) {
  return String(value || '').replace(/\|/g, '\\|').replace(/[\r\n]+/g, '<br>');
}

function normalizeRepository(value, homepage) {
  let raw = '';
  if (typeof value === 'string') raw = value;
  else if (value && typeof value.url === 'string') raw = value.url;
  if (!raw && typeof homepage === 'string') raw = homepage;
  raw = raw.replace(/^git\+/, '').replace(/^github:/, 'https://github.com/').replace(/\.git(?:#.*)?$/, '');
  const match = raw.match(/github\.com[/:]([^/\s]+)\/([^/#\s]+)/i);
  if (!match) return { url: raw || null, github: null };
  const owner = match[1];
  const repository = match[2];
  return {
    url: 'https://github.com/' + owner + '/' + repository,
    github: { owner, repository, slug: owner + '/' + repository }
  };
}

function findPackageJson(packageName) {
  const candidate = path.join(profileDirectory, 'node_modules', ...packageName.split('/'), 'package.json');
  return fs.existsSync(candidate) ? candidate : null;
}

function findYamlModule() {
  const candidates = [
    path.join(profileDirectory, 'node_modules', 'js-yaml'),
    'js-yaml'
  ];
  for (const candidate of candidates) {
    try { return require(candidate); } catch (_) { /* fall through */ }
  }
  return null;
}

const yaml = findYamlModule();

function parseQuotedValues(text) {
  const values = [];
  const expression = /['\"`]([^'\"`]+)['\"`]/g;
  let match;
  while ((match = expression.exec(text || '')) !== null) values.push(match[1]);
  return stableUnique(values);
}

function addPatchObjectFacts(value, result) {
  if (Array.isArray(value)) {
    for (const item of value) addPatchObjectFacts(item, result);
    return;
  }
  if (!value || typeof value !== 'object') return;
  if (typeof value.id === 'string') result.pluginIds.push(value.id);
  if (Object.prototype.hasOwnProperty.call(value, 'inject')) {
    result.inject.push(...toStringArray(value.inject));
  }
  for (const child of Object.values(value)) addPatchObjectFacts(child, result);
}

function parsePatchFallback(text) {
  const result = { pluginIds: [], inject: [], parser: 'fallback' };
  let match;
  const idExpression = /^\s*-\s*id\s*:\s*['\"]?([^\s#'\"]+)/gm;
  while ((match = idExpression.exec(text)) !== null) result.pluginIds.push(match[1]);
  const inlineInject = /\binject\s*:\s*(\[[^\]]*\])/g;
  while ((match = inlineInject.exec(text)) !== null) result.inject.push(...parseQuotedValues(match[1]));
  return result;
}

function parsePatch(filePath) {
  const empty = { path: filePath || null, available: false, pluginIds: [], inject: [], parser: 'none', parseError: null };
  if (!filePath || !fs.existsSync(filePath)) return empty;
  const text = safeReadText(filePath);
  const result = { path: filePath, available: true, pluginIds: [], inject: [], parser: 'yaml', parseError: null };
  if (yaml) {
    try {
      addPatchObjectFacts(yaml.load(text), result);
    } catch (error) {
      result.parseError = String(error && error.message || error);
      const fallback = parsePatchFallback(text);
      result.pluginIds.push(...fallback.pluginIds);
      result.inject.push(...fallback.inject);
      result.parser = fallback.parser;
    }
  } else {
    const fallback = parsePatchFallback(text);
    result.pluginIds.push(...fallback.pluginIds);
    result.inject.push(...fallback.inject);
    result.parser = fallback.parser;
  }
  result.pluginIds = stableUnique(result.pluginIds).sort(compareText);
  result.inject = stableUnique(result.inject).sort(compareText);
  return result;
}

function readPinnedGitHeadsFromPnpmLock() {
  const lockPath = path.join(profileDirectory, 'pnpm-lock.yaml');
  const result = new Map();
  if (!fs.existsSync(lockPath)) return result;
  const record = (packageName, resolved) => {
    const match = String(resolved || '').match(/(?:codeload\.github\.com\/[^/]+\/[^/]+\/tar\.gz\/|github\.com\/[^/]+\/[^/]+\.git#)([0-9a-f]{7,40})/i);
    if (packageName && match) result.set(packageName, match[1]);
  };
  const lockText = safeReadText(lockPath);
  try {
    const document = yaml ? yaml.load(lockText) : null;
    const dependencies = document && document.importers && document.importers['.'] && document.importers['.'].dependencies;
    for (const [packageName, entry] of Object.entries(dependencies || {})) {
      const resolved = entry && typeof entry === 'object' ? String(entry.version || '') : '';
      record(packageName, resolved);
    }
  } catch (_) {
    // Fall through to a narrowly scoped parser for pnpm importer dependencies.
  }
  if (result.size === 0) {
    let inRootDependencies = false;
    let packageName = '';
    for (const line of lockText.split(/\r?\n/)) {
      if (/^\s{4}dependencies:\s*$/.test(line)) { inRootDependencies = true; packageName = ''; continue; }
      if (/^\S|^\s{0,3}\S/.test(line)) { inRootDependencies = false; packageName = ''; continue; }
      if (!inRootDependencies) continue;
      const key = line.match(/^\s{6}(?:'([^']+)'|"([^"]+)"|([^:\s]+)):\s*$/);
      if (key) { packageName = key[1] || key[2] || key[3] || ''; continue; }
      const version = line.match(/^\s{8}version:\s*(\S+)\s*$/);
      if (version && packageName) record(packageName, version[1]);
    }
  }
  return result;
}

function patchPathsForPackage(packageDirectory, dsh) {
  const candidates = [path.join(packageDirectory, 'cordis.patch.yml')];
  const bundle = dsh && dsh.bundle;
  if (typeof bundle === 'string') candidates.push(path.resolve(packageDirectory, bundle));
  if (bundle && typeof bundle === 'object') {
    for (const key of ['patch', 'cordisPatch']) {
      if (typeof bundle[key] === 'string') candidates.push(path.resolve(packageDirectory, bundle[key]));
    }
  }
  return stableUnique(candidates);
}

function collectJavaScriptFiles(root) {
  const files = [];
  const queue = [root];
  let totalBytes = 0;
  while (queue.length > 0 && totalBytes < MAX_SOURCE_TOTAL_BYTES) {
    const current = queue.shift();
    let entries = [];
    try { entries = fs.readdirSync(current, { withFileTypes: true }); } catch (_) { continue; }
    for (const entry of entries) {
      if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue;
      const itemPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        queue.push(itemPath);
        continue;
      }
      if (!entry.isFile() || !/\.(?:c?js|mjs|ts|tsx)$/i.test(entry.name)) continue;
      let size = 0;
      try { size = fs.statSync(itemPath).size; } catch (_) { continue; }
      if (size > MAX_SOURCE_FILE_BYTES || totalBytes + size > MAX_SOURCE_TOTAL_BYTES) continue;
      totalBytes += size;
      files.push(itemPath);
    }
  }
  return files;
}

function collectSourceFacts(packageDirectory) {
  const declaredInject = [];
  const observedInject = [];
  const provides = [];
  const files = collectJavaScriptFiles(packageDirectory);
  for (const filePath of files) {
    const source = safeReadText(filePath);
    const declaredPatterns = [
      /\b(?:export\s+)?(?:const|let|var)\s+inject\s*=\s*(\[[^\]]{0,2000}\])/g,
      /\b(?:module\.exports|exports)\.inject\s*=\s*(\[[^\]]{0,2000}\])/g,
      /\bmodule\.exports\s*=\s*\{[\s\S]{0,4000}?\binject\s*:\s*(\[[^\]]{0,2000}\])/g
    ];
    for (const pattern of declaredPatterns) {
      let match;
      while ((match = pattern.exec(source)) !== null) declaredInject.push(...parseQuotedValues(match[1]));
    }
    const runtimePattern = /\b(?:[A-Za-z_$][\w$]*\.)?inject\s*\(\s*(\[[^\]]{0,2000}\])/g;
    let runtimeMatch;
    while ((runtimeMatch = runtimePattern.exec(source)) !== null) observedInject.push(...parseQuotedValues(runtimeMatch[1]));
    const providePattern = /\b[A-Za-z_$][\w$]*(?:\.reflect)?\.provide\s*\(\s*['\"]([^'\"]+)['\"]/g;
    let provideMatch;
    while ((provideMatch = providePattern.exec(source)) !== null) provides.push(provideMatch[1]);
  }
  return {
    filesScanned: files.length,
    declaredInject: stableUnique(declaredInject).sort(compareText),
    observedInject: stableUnique(observedInject).sort(compareText),
    provides: stableUnique(provides).sort(compareText)
  };
}

function loadSemver() {
  try { return require(require.resolve('semver', { paths: [profileDirectory] })); } catch (_) { return null; }
}

const semver = loadSemver();

function satisfiesHostRange(range) {
  if (!range || typeof range !== 'string' || range.trim() === '*' || !semver) return null;
  try { return semver.satisfies(targetDshVersion, range, { includePrerelease: true, loose: true }); } catch (_) { return null; }
}

function dshPeerRanges(peerDependencies) {
  return Object.entries(peerDependencies || {})
    .filter(([name]) => name === '@deepseek-ai/dsh' || name.startsWith('@deepseek-ai/dsh-'))
    .map(([name, range]) => ({ package: name, range: String(range) }));
}

function compatibilityFacts(dsh, peerDependencies) {
  const compatibility = dsh && dsh.compatibility && typeof dsh.compatibility === 'object' ? dsh.compatibility : {};
  const result = { hostRange: [], explicitRelease: null, supports: [], blockers: [] };
  if (typeof compatibility.dsh === 'string') result.hostRange.push({ source: 'dsh.compatibility.dsh', range: compatibility.dsh });
  for (const peer of dshPeerRanges(peerDependencies)) result.hostRange.push({ source: 'peerDependencies.' + peer.package, range: peer.range });
  if (compatibility.dshReleases && Object.prototype.hasOwnProperty.call(compatibility.dshReleases, targetDshVersion)) {
    result.explicitRelease = String(compatibility.dshReleases[targetDshVersion]);
    const status = result.explicitRelease.toLowerCase();
    if (status === 'compatible' || status === 'supported' || status === 'pass') result.supports.push('dsh.compatibility.dshReleases 明确标注 ' + targetDshVersion + ' 为 ' + result.explicitRelease);
    if (status === 'incompatible' || status === 'blocked' || status === 'unsupported') result.blockers.push('dsh.compatibility.dshReleases 明确标注 ' + targetDshVersion + ' 为 ' + result.explicitRelease);
  }
  for (const range of result.hostRange) {
    const supported = satisfiesHostRange(range.range);
    if (supported === true) result.supports.push(range.source + ' 满足 ' + range.range);
    if (supported === false) result.blockers.push(range.source + ' 不满足 ' + range.range);
  }
  return result;
}

function npmCommand() {
  return process.platform === 'win32' ? 'npm.cmd' : 'npm';
}

function spawnCli(command, commandArgs, options) {
  if (process.platform !== 'win32') return childProcess.spawnSync(command, commandArgs, options);
  const comspec = process.env.ComSpec || process.env.COMSPEC || 'cmd.exe';
  const values = [command].concat(commandArgs || []).map(String);
  // 这些调用的参数来自 package 名、固定 DSH 版本和经过校验的 profile 名；
  // 不接受 shell metacharacter，避免把 profile 数据交给 cmd.exe 解释。
  if (values.some((value) => !/^[A-Za-z0-9@._:/\\-]+$/.test(value))) {
    throw new Error('Refusing unsafe Windows CLI argument.');
  }
  return childProcess.spawnSync(comspec, ['/d', '/s', '/c', values.join(' ')], options);
}

function queryNpmLatest(packageName) {
  if (offline) return { status: 'SKIPPED', version: null, peerDependencies: {}, repository: null, homepage: null, dsh: null };
  try {
    const result = spawnCli(npmCommand(), ['view', packageName + '@latest', 'version', 'peerDependencies', 'repository', 'homepage', 'dsh', '--json'], {
      encoding: 'utf8', timeout: 20000, windowsHide: true
    });
    if (result.status !== 0) return { status: 'ERROR', error: String(result.stderr || result.stdout || 'npm view failed').trim() };
    const parsed = JSON.parse(result.stdout || '{}');
    return {
      status: 'OK',
      version: parsed.version || null,
      peerDependencies: parsed.peerDependencies || {},
      repository: parsed.repository || null,
      homepage: parsed.homepage || null,
      dsh: parsed.dsh || null
    };
  } catch (error) {
    return { status: 'ERROR', error: String(error && error.message || error) };
  }
}

function httpJson(url) {
  return new Promise((resolve) => {
    const request = https.get(url, {
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'DeepSeekHarness-DesktopShell-plugin-scanner'
      }, timeout: 15000
    }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; });
      response.on('end', () => {
        try { resolve({ statusCode: response.statusCode || 0, body: JSON.parse(body || '{}') }); }
        catch (_) { resolve({ statusCode: response.statusCode || 0, body: null }); }
      });
    });
    request.on('timeout', () => request.destroy(new Error('timeout')));
    request.on('error', (error) => resolve({ statusCode: 0, error: String(error && error.message || error), body: null }));
  });
}

async function queryGithubLatest(repository) {
  if (!repository || !repository.github) return { status: 'SKIPPED', value: null };
  if (offline) return { status: 'SKIPPED', value: null };
  const slug = repository.github.slug;
  const release = await httpJson('https://api.github.com/repos/' + slug + '/releases/latest');
  if (release.statusCode === 200 && release.body && release.body.tag_name) {
    return { status: 'OK', value: release.body.tag_name, kind: 'release', url: release.body.html_url || repository.url };
  }
  const repositoryInfo = await httpJson('https://api.github.com/repos/' + slug);
  if (repositoryInfo.statusCode === 200 && repositoryInfo.body) {
    const branch = repositoryInfo.body.default_branch || 'main';
    const commit = await httpJson('https://api.github.com/repos/' + slug + '/commits/' + encodeURIComponent(branch));
    if (commit.statusCode === 200 && commit.body && commit.body.sha) {
      return { status: 'OK', value: branch + '@' + String(commit.body.sha).slice(0, 12), kind: 'default-branch', url: repository.url };
    }
    return { status: 'OK', value: branch, kind: 'default-branch', url: repository.url };
  }
  return { status: 'ERROR', value: null, error: release.error || ('GitHub HTTP ' + (repositoryInfo.statusCode || release.statusCode || 0)) };
}

function runPluginList() {
  if (!args['run-plugin-list']) return { executed: false, exitCode: null, packages: [], error: null };
  try {
    const executable = process.platform === 'win32' ? 'npx.cmd' : 'npx';
    const result = spawnCli(executable, ['--yes', '@deepseek-ai/dsh@' + targetDshVersion, 'plugin', '--profile', profileName, 'list'], {
      encoding: 'utf8', timeout: 60000, windowsHide: true,
      env: Object.assign({}, process.env, { DSH_HOME: dshHome })
    });
    const text = String(result.stdout || '') + '\n' + String(result.stderr || '');
    const packages = [];
    const pattern = /(?:├──|└──)\s+((?:@[^\s@]+\/)?[^\s@]+)@([^\s]+)/g;
    let match;
    while ((match = pattern.exec(text)) !== null) packages.push({ name: match[1], version: match[2] });
    return {
      executed: true,
      exitCode: typeof result.status === 'number' ? result.status : -1,
      packages: packages.sort((a, b) => compareText(a.name, b.name)),
      error: result.status === 0 ? null : String(result.stderr || result.error || 'plugin list failed').trim()
    };
  } catch (error) {
    return { executed: true, exitCode: -1, packages: [], error: String(error && error.message || error) };
  }
}

function isHostProvidedService(name) {
  const known = new Set([
    'agentDefaultModel', 'agents', 'connection', 'credentials', 'desktopPnpm', 'invariants', 'inputTriggers',
    'loader', 'locale', 'remote', 'sessionPersistence', 'sessionProjections', 'sessions',
    'settings', 'settingsScope', 'skills', 'slots', 'theme', 'tools', 'web', 'webRuntime', 'webServer',
    'workspaceRegistry'
  ]);
  if (known.has(name)) return true;
  return /^remote\.|^ui[A-Z]|^web[A-Z]|^client[A-Z]/.test(name);
}

function readPreflightResults(filePath) {
  const empty = { targetDshVersion: null, results: [], fullCombination: null };
  if (!filePath) return empty;
  const document = safeReadJson(filePath);
  if (!document) return empty;
  const results = Array.isArray(document) ? document : document.results;
  if (!Array.isArray(results)) return empty;
  return {
    targetDshVersion: Array.isArray(document) ? null : document.targetDshVersion || null,
    results: results.filter((item) => item && item.targetDshVersion === targetDshVersion),
    fullCombination: Array.isArray(document) ? null : document.fullCombination || null
  };
}

function preflightEvidenceFor(row, preflight) {
  const exact = (preflight.results || []).find((item) => item.package === row.package && (!item.version || item.version === row.version));
  if (!exact) return null;
  const checks = exact.checks || {};
  const required = ['bootReady', 'pluginTree', 'http', 'webView2', 'refresh', 'settings', 'restart'];
  const specMatches = Boolean(exact.installSpec) && exact.installSpec === row.installSpec;
  const complete = specMatches && exact.status === 'PASS' && required.every((key) => checks[key] === true);
  return { result: exact, complete, specMatches };
}

function fullPreflightComplete(preflight) {
  const full = preflight && preflight.fullCombination;
  const checks = full && full.checks || {};
  const required = ['bootReady', 'pluginTree', 'http', 'webView2', 'refresh', 'settings', 'restart'];
  return preflight && preflight.targetDshVersion === targetDshVersion && full && full.status === 'PASS' && required.every((key) => checks[key] === true);
}

function calculateInstallOrder(rows) {
  const byPackage = new Map(rows.map((row) => [row.package, row]));
  const remaining = new Map(rows.map((row) => [row.package, new Set(row.dependsOn.filter((name) => byPackage.has(name)))]));
  const order = [];
  while (remaining.size > 0) {
    const ready = Array.from(remaining.entries())
      .filter(([, dependencies]) => dependencies.size === 0)
      .map(([name]) => name)
      .sort(compareText);
    if (ready.length === 0) {
      order.push(...Array.from(remaining.keys()).sort(compareText));
      break;
    }
    for (const name of ready) {
      order.push(name);
      remaining.delete(name);
      for (const dependencies of remaining.values()) dependencies.delete(name);
    }
  }
  return stableUnique(order);
}

function buildInstallSpec(row) {
  if (!row.package || !row.version) return null;
  if (row.requested && /^(?:github:|git\+|https?:\/\/github\.com)/i.test(row.requested)) {
    const gitHead = row.gitHead || '';
    if (row.repository.github && gitHead) return 'github:' + row.repository.github.slug + '#' + gitHead;
    return row.requested;
  }
  return row.package + '@' + row.version;
}

function renderMarkdown(document) {
  const pluginList = document.profile.pluginList || {};
  const pluginListState = pluginList.executed
    ? ('已执行（exit ' + String(pluginList.exitCode) + '）')
    : '未执行（离线/显式跳过）';
  const lines = [
    '# DSH 0.1.5-rc.2 插件兼容矩阵',
    '',
    '> 本文件由 `scripts/Scan-DshPluginEcosystem.ps1` 从真实 profile 生成。它不是静态推荐表；`PASS` 仅来自同一精确 DSH 版本、同一插件版本且包含 BootReady、plugin tree、HTTP、WebView2、刷新、设置页和重启检查的 preflight 证据。',
    '',
    '目标 DSH：`' + document.targetDshVersion + '`  \\',
    'Profile：`' + document.profile.name + '`  \\',
    'Profile 状态：**' + document.profile.status + '**  \\',
    '`plugin list`：' + pluginListState + '  \\',
    '生成时间：`' + document.generatedAt + '`',
    '',
    '| 插件 | 已装版本 | 上游最新 | 依赖服务 | 依赖插件 | 0.1.5-rc.2 证据 | 状态 |',
    '| --- | --- | --- | --- | --- | --- | --- |'
  ];
  for (const row of document.plugins) {
    const upstream = [row.upstream.npm && row.upstream.npm.version, row.upstream.github && row.upstream.github.value].filter(Boolean).join('<br>') || '未获取';
    const services = row.requiresService.length ? row.requiresService.join(', ') : '—';
    const dependencies = row.dependsOn.length ? row.dependsOn.join(', ') : '—';
    const evidence = row.evidence.length ? row.evidence.join('<br>') : '无明确支持或 preflight 证据';
    lines.push('| `' + quoteMarkdown(row.package) + '` | `' + quoteMarkdown(row.version) + '` | ' + quoteMarkdown(upstream) + ' | ' + quoteMarkdown(services) + ' | ' + quoteMarkdown(dependencies) + ' | ' + quoteMarkdown(evidence) + ' | **' + row.status + '** |');
  }
  lines.push('', '## 安装顺序与反向依赖', '');
  for (const packageName of document.installOrder) {
    const row = document.plugins.find((item) => item.package === packageName);
    if (!row) continue;
    const downstream = row.dependents.length ? row.dependents.join(', ') : '无';
    lines.push('- `' + row.package + '` → 下游：' + downstream);
  }
  if (document.profile.patchOrphans.length) {
    lines.push('', '## 孤立 Profile 补丁', '', '以下 `cordis.patch.yml` 项没有任何已安装插件声明对应 id；它们会阻断完整组合 preflight：');
    for (const id of document.profile.patchOrphans) lines.push('- `' + id + '`');
  }
  if (document.profile.listError) {
    lines.push('', '## plugin list 失败', '', quoteMarkdown(document.profile.listError));
  }
  lines.push('', '状态含义：`PASS` = 完整精确 preflight；`WARN` = 元数据支持但未完成完整 preflight；`BLOCKED` = 明确 HostRange/服务/补丁阻断；`UNKNOWN` = 不能据现有证据判断，绝不自动当作兼容。', '');
  return lines.join('\n');
}

async function main() {
  const profilePackagePath = path.join(profileDirectory, 'package.json');
  const profilePackage = safeReadJson(profilePackagePath);
  if (!profilePackage) throw new Error('无法读取 DSH Profile package.json: ' + profilePackagePath);
  const rawProfileDependencies = Object.assign({}, profilePackage.dependencies || {}, profilePackage.optionalDependencies || {});
  // dsh-web-app / dsh-base 是 Profile 的官方核心 bundle，而不是用户插件。某些
  // plugin add 路径会把它们显式写入 package.json；无论写法如何，都不能让它们
  // 污染插件矩阵、依赖图或“当前实际保留插件”的数量。
  const coreBundlePackages = new Set(['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']);
  const directDependencies = Object.fromEntries(
    Object.entries(rawProfileDependencies).filter(([packageName]) => !coreBundlePackages.has(packageName))
  );
  const profilePatch = parsePatch(path.join(profileDirectory, 'cordis.patch.yml'));
  const preflightResults = readPreflightResults(args['preflight-results']);
  const pluginList = runPluginList();
  const packageNames = Object.keys(directDependencies).sort(compareText);
  const pinnedGitHeads = readPinnedGitHeadsFromPnpmLock();
  const rows = [];

  for (const packageName of packageNames) {
    const packageJsonPath = findPackageJson(packageName);
    const packageDirectory = packageJsonPath ? path.dirname(packageJsonPath) : null;
    const packageJson = packageJsonPath ? safeReadJson(packageJsonPath) : null;
    const dsh = packageJson && packageJson.dsh && typeof packageJson.dsh === 'object' ? packageJson.dsh : {};
    const patch = packageDirectory ? patchPathsForPackage(packageDirectory, dsh).map(parsePatch).find((item) => item.available) || parsePatch(null) : parsePatch(null);
    const source = packageDirectory ? collectSourceFacts(packageDirectory) : { filesScanned: 0, declaredInject: [], observedInject: [], provides: [] };
    const requested = String(directDependencies[packageName] || '');
    const repository = normalizeRepository(packageJson && packageJson.repository || requested, packageJson && packageJson.homepage);
    const peerDependencies = packageJson && packageJson.peerDependencies || {};
    const dshClientInject = toStringArray(dsh && dsh.client && dsh.client.inject);
    const facts = compatibilityFacts(dsh, peerDependencies);
    const dependencies = packageJson && packageJson.dependencies || {};
    rows.push({
      package: packageName,
      requested,
      version: packageJson && packageJson.version || null,
      gitHead: packageJson && packageJson.gitHead || pinnedGitHeads.get(packageName) || null,
      gitHeadSource: packageJson && packageJson.gitHead ? 'package.json.gitHead' : (pinnedGitHeads.has(packageName) ? 'pnpm-lock.yaml' : null),
      packagePath: packageDirectory,
      repository,
      peerDependencies,
      packageDependencies: Object.keys(dependencies),
      dshClientInject,
      patch,
      source,
      hostRange: facts.hostRange,
      compatibility: facts,
      installSpec: null,
      requiresService: [],
      observedServiceInject: [],
      providesService: [],
      dependsOn: [],
      dependents: [],
      unresolvedService: [],
      evidence: [],
      status: 'UNKNOWN',
      upstream: { npm: null, github: null }
    });
  }

  const upstreamRows = await Promise.all(rows.map(async (row) => {
    row.upstream.npm = queryNpmLatest(row.package);
    row.upstream.github = await queryGithubLatest(row.repository);
    row.upstream.latestHostRange = compatibilityFacts(row.upstream.npm.dsh, row.upstream.npm.peerDependencies);
    return row;
  }));

  const byPackage = new Map(upstreamRows.map((row) => [row.package, row]));
  const providers = new Map();
  for (const row of upstreamRows) {
    row.providesService = stableUnique(row.source.provides).sort(compareText);
    for (const service of row.providesService) {
      if (!providers.has(service)) providers.set(service, []);
      providers.get(service).push(row.package);
    }
  }
  for (const serviceProviders of providers.values()) serviceProviders.sort(compareText);

  for (const row of upstreamRows) {
    const hardServices = stableUnique([].concat(row.source.declaredInject, row.patch.inject));
    row.requiresService = hardServices.sort(compareText);
    row.observedServiceInject = stableUnique([].concat(row.source.observedInject, row.dshClientInject)).sort(compareText);
    const packageEdges = row.packageDependencies.filter((name) => byPackage.has(name));
    const serviceEdges = [];
    for (const service of row.requiresService) {
      const serviceProviders = providers.get(service) || [];
      if (serviceProviders.length) serviceEdges.push(...serviceProviders.filter((name) => name !== row.package));
      else if (!isHostProvidedService(service)) row.unresolvedService.push(service);
    }
    row.unresolvedService = stableUnique(row.unresolvedService).sort(compareText);
    row.dependsOn = stableUnique([].concat(packageEdges, serviceEdges)).filter((name) => name !== row.package).sort(compareText);
    row.installSpec = buildInstallSpec(row);
  }
  for (const row of upstreamRows) {
    for (const dependency of row.dependsOn) {
      const parent = byPackage.get(dependency);
      if (parent) parent.dependents.push(row.package);
    }
  }
  for (const row of upstreamRows) row.dependents = stableUnique(row.dependents).sort(compareText);

  const claimedPatchIds = new Set(upstreamRows.flatMap((row) => row.patch.pluginIds));
  const patchOrphans = profilePatch.pluginIds.filter((id) => !claimedPatchIds.has(id)).sort(compareText);
  for (const row of upstreamRows) {
    const evidence = [];
    const blockers = [].concat(row.compatibility.blockers || []);
    const isGitSource = row.requested && /^(?:github:|git\+|https?:\/\/github\.com)/i.test(row.requested);
    if (isGitSource && !row.gitHead) blockers.push('Git 来源没有由 package 元数据或 pnpm-lock.yaml 锁定的 commit，不能把浮动 ref 当作精确兼容版本');
    if (row.compatibility.supports.length) evidence.push(...row.compatibility.supports);
    if (isGitSource && row.gitHead) evidence.push((row.gitHeadSource || 'package metadata') + ' 锁定 Git commit ' + row.gitHead);
    if (row.unresolvedService.length) blockers.push('没有已安装 provider 的 Cordis 服务：' + row.unresolvedService.join(', '));
    const proof = preflightEvidenceFor(row, preflightResults);
    if (proof && proof.complete) evidence.push('完整精确 preflight 通过');
    else if (proof && !proof.specMatches) evidence.push('preflight 安装 spec 与当前精确锁定 spec 不一致或缺失，不能标为 PASS');
    else if (proof) evidence.push('存在不完整的 preflight 记录，不能标为 PASS');
    if (blockers.length) {
      row.status = 'BLOCKED';
      evidence.push(...blockers);
    } else if (proof && proof.complete) {
      row.status = 'PASS';
    } else if (row.compatibility.supports.length) {
      row.status = 'WARN';
    } else {
      row.status = 'UNKNOWN';
    }
    row.evidence = stableUnique(evidence);
  }

  const installOrder = calculateInstallOrder(upstreamRows);
  const allPluginsPassed = upstreamRows.length > 0 && upstreamRows.every((row) => row.status === 'PASS');
  const profileListFailed = pluginList.executed && pluginList.exitCode !== 0;
  const profileStatus = patchOrphans.length || profileListFailed ? 'BLOCKED' :
    (allPluginsPassed && fullPreflightComplete(preflightResults) ? 'PASS' : 'UNKNOWN');
  const document = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    targetDshVersion,
    profile: {
      name: profileName,
      directory: profileDirectory,
      packageJson: profilePackagePath,
      pluginList,
      patch: profilePatch,
      patchOrphans,
      status: profileStatus,
      listError: profileListFailed ? pluginList.error || 'plugin list failed' : null
    },
    installOrder,
    plugins: installOrder.map((packageName) => byPackage.get(packageName)).filter(Boolean)
  };
  const serialized = JSON.stringify(document, null, 2) + '\n';
  if (args['output-json']) fs.writeFileSync(path.resolve(args['output-json']), serialized, 'utf8');
  if (args['output-markdown']) fs.writeFileSync(path.resolve(args['output-markdown']), renderMarkdown(document), 'utf8');
  if (!args['output-json'] && !args['output-markdown']) process.stdout.write(serialized);
  else process.stdout.write(JSON.stringify({ targetDshVersion, pluginCount: document.plugins.length, profileStatus: document.profile.status }) + '\n');
}

main().catch((error) => {
  process.stderr.write('DSH plugin ecosystem scan failed: ' + String(error && error.stack || error) + '\n');
  process.exitCode = 1;
});
