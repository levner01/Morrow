#!/usr/bin/env node
/* Morrow 单 HTML 打包脚本（P0-006，AD-02）。
 * 输入：index.html + assets/css/* + assets/js/* + assets/vendor/*（固定清单，见下）
 * 输出：dist/index.html（单文件，内联 CSS/JS/vendor，零远程依赖）
 *       dist/release-manifest.json（含 built_at_utc 明确时间字段——复现性校验排除该字段）
 * 复现性：dist/index.html 不含任何时间戳；同一源输入 → 同一 SHA256。
 * 用法：
 *   node scripts/package-html.mjs           构建
 *   node scripts/package-html.js --check    构建到临时目录并与已发布 dist 比对 SHA256
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.resolve(__dirname, '..');
const OUT_DIR = path.join(ROOT, 'dist');
const TASK_INDEX_PATH = path.join(ROOT, 'docs/planning/task-index.json');

// 固定打包清单（顺序即加载顺序，classic scripts 依 AD-02 固定次序）。
const CSS_FILES = ['assets/css/app.css'];
const JS_FILES = [
  'assets/vendor/supabase-js@2.116.0.umd.js',
  'assets/js/config.js',
  'assets/js/transport.js',
  'assets/js/drafts.js',
  'assets/js/store.js',
  'assets/js/ui.js',
  'assets/js/today.js',
  'assets/js/app.js',
];
const SDK_FILE = 'assets/vendor/supabase-js@2.116.0.umd.js';
const SDK_NAME = '@supabase/supabase-js';
const SDK_VERSION = '2.116.0';

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// 生成版本前缀（MVP-002 顺手修复 1：不再硬编码 'p0-006-'）
// 策略：优先从 task-index.json 读取 next_task，降级为 git 短 hash，最后兜底 'dev'
function generateReleasePrefix() {
  try {
    // 尝试读取 task-index.json
    const taskIndexRaw = fs.readFileSync(TASK_INDEX_PATH, 'utf8');
    const taskIndex = JSON.parse(taskIndexRaw);
    if (taskIndex && taskIndex.next_task) {
      // next_task 格式如 "MVP-003" → 转为 "mvp-003"
      return taskIndex.next_task.toLowerCase().replace(/_/g, '-');
    }
  } catch (_) {
    // task-index.json 不存在或解析失败，尝试 git
  }

  try {
    // 尝试获取 git 短 hash
    const { execSync } = require('node:child_process');
    const gitHash = execSync('git rev-parse --short HEAD', { cwd: ROOT, encoding: 'utf8' }).trim();
    if (gitHash) {
      return 'git-' + gitHash;
    }
  } catch (_) {
    // git 不可用
  }

  return 'dev';
}

function read(rel) {
  return fs.readFileSync(path.join(ROOT, rel));
}

// 内联进 HTML 必须转义闭合标签序列，防止提前截断脚本/样式。
function escapeForHtml(source, kind) {
  if (kind === 'js') return source.replace(/<\/script/gi, '<\\/script');
  if (kind === 'css') return source.replace(/<\/style/gi, '<\\/style');
  return source;
}

function bodyFromSource() {
  const html = read('index.html').toString('utf8');
  const m = html.match(/<body[^>]*>([\s\S]*)<\/body>/i);
  if (!m) throw new Error('index.html 缺少 <body>');
  // 去尾部经典脚本引用行：dist 为单文件内联，不再外链。
  return m[1].replace(/\s*<script src="[^"]+"><\/script>\s*/g, '\n');
}

function build(outDir) {
  const files = [];
  const cssParts = [];
  const jsParts = [];

  for (const rel of CSS_FILES) {
    const buf = read(rel);
    files.push({ path: rel, sha256: sha256(buf) });
    cssParts.push('/* ---- ' + rel + ' ---- */\n' + escapeForHtml(buf.toString('utf8'), 'css'));
  }
  for (const rel of JS_FILES) {
    const buf = read(rel);
    files.push({ path: rel, sha256: sha256(buf) });
    jsParts.push('/* ---- ' + rel + ' ---- */\n' + escapeForHtml(buf.toString('utf8'), 'js'));
  }

  const sourceSha = sha256(Buffer.from(files.map(function (f) { return f.sha256; }).join('\n'), 'utf8'));
  const releasePrefix = generateReleasePrefix();
  const releaseId = releasePrefix + '-' + sourceSha.slice(0, 12);
  const sdkBuf = read(SDK_FILE);
  const sdk = { name: SDK_NAME, version: SDK_VERSION, file: SDK_FILE, sha256: sha256(sdkBuf), license: 'MIT' };

  const releaseScript =
    'window.MORROW_RELEASE=' +
    JSON.stringify({ id: releaseId, source_sha256: sourceSha, sdk: { name: sdk.name, version: sdk.version } }) +
    ';\n';

  const body = bodyFromSource();
  const distHtml =
    '<!DOCTYPE html>\n' +
    '<html lang="zh-CN">\n<head>\n' +
    '<meta charset="utf-8">\n' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n' +
    '<meta name="referrer" content="no-referrer">\n' +
    '<meta name="color-scheme" content="light dark">\n' +
    '<title>Morrow · 登录</title>\n' +
    '<meta name="description" content="Morrow 单用户生活工作台 — Phase 0 登录壳（P0-006）">\n' +
    '<!-- Morrow 发行 ' + releaseId + ' · 源 SHA256 ' + sourceSha + ' · 由 scripts/package-html.mjs 生成，禁止手改 dist -->\n' +
    '<style>\n' + cssParts.join('\n') + '\n</style>\n' +
    '</head>\n' +
    '<body>\n' +
    body + '\n' +
    '<script>\n' + releaseScript + '</scr' + 'ipt>\n' +
    '<script>\n' + jsParts.join('\n;\n') + '\n</scr' + 'ipt>\n' +
    '</body>\n</html>\n';

  fs.mkdirSync(outDir, { recursive: true });
  const distPath = path.join(outDir, 'index.html');
  fs.writeFileSync(distPath, distHtml, 'utf8');

  const manifest = {
    release: {
      id: releaseId,
      built_at_utc: new Date().toISOString(),
      reproducibility_note: 'dist/index.html 不含时间戳；同一源输入两次构建 SHA256 必相同。复现校验请排除本字段 built_at_utc。',
    },
    source_files: files,
    source_sha256: sourceSha,
    sdk: sdk,
    entry_source: 'index.html',
    dist: { path: 'dist/index.html', sha256: sha256(Buffer.from(distHtml, 'utf8')) },
    // P0-008：GitHub Pages 发布链路标注（静态字段，不参与 dist 可复现性校验）
    pages: {
      url: 'https://levner01.github.io/Morrow/',
      html_path: 'dist/index.html',
      deploy: 'GitHub Actions（build_type=workflow），artifact path=dist',
      note: 'Pages 服务的 HTML 与 dist.sha256 指向同一构建产物；回退时按 manifest 中 sha256 追溯。',
    },
  };
  fs.writeFileSync(path.join(outDir, 'release-manifest.json'), JSON.stringify(manifest, null, 2) + '\n', 'utf8');
  return { releaseId: releaseId, distSha: manifest.dist.sha256, distPath: distPath };
}

function main() {
  const check = process.argv.includes('--check');
  if (!check) {
    const r = build(OUT_DIR);
    console.log('[package-html] release ' + r.releaseId);
    console.log('[package-html] dist/index.html sha256 ' + r.distSha);
    console.log('[package-html] manifest  -> dist/release-manifest.json');
    return;
  }
  // --check：独立临时目录重建，与已发布 dist 比对（证明可复现）
  const tmp = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'morrow-pkg-'));
  try {
    const rebuilt = build(tmp);
    const publishedSha = sha256(fs.readFileSync(path.join(OUT_DIR, 'index.html')));
    const rebuiltSha = sha256(fs.readFileSync(path.join(tmp, 'index.html')));
    const ok = publishedSha === rebuiltSha;
    console.log('[package-html --check] published ' + publishedSha);
    console.log('[package-html --check] rebuilt    ' + rebuiltSha);
    console.log(ok ? 'REPRODUCIBLE: PASS' : 'REPRODUCIBLE: FAIL');
    process.exitCode = ok ? 0 : 1;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

if (require.main === module) {
  main();
}
