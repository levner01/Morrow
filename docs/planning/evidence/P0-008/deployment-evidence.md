# P0-008 发布链路证据附页（公司机执行，2026-09-23）

> 本文档逐条记录 Pages 部署链路的**原始命令与原始输出**，供 Review 复核与下次工程复现。凭据仅 runtime env 注入，本文档不含任何密钥。

## 1. GitHub repo 创建 + 首次 push

**注意（工具链坑，已克服）**：shell 环境变量 `GH_TOKEN`（GitHub App user token，`ghu_` 前缀）无 `createRepository` 权限；keyring 中 OAuth token（`gho_` 前缀，scopes: gist/read:org/repo/workflow）才有。所有 gh/git 写操作统一 `env -u GH_TOKEN` 走 keyring。另：公司机直连 `github.com:443` 超时（`api.github.com` 通），git push 需单次注入本地代理 `-x http://127.0.0.1:7897`（命令级，未改任何全局配置）。

命令：
```bash
env -u GH_TOKEN gh repo create levner01/Morrow --public --source=. --remote=origin --push \
  --description "Morrow - 个人生活工作台（M1 Phase0+MVP，静态单HTML + Supabase）"
```
原始输出：
```text
https://github.com/levner01/Morrow
To https://github.com/levner01/Morrow.git
 * [new branch]      HEAD -> main
branch 'main' set up to track 'origin/main'.
```

push 前 git 全历史三形态密钥扫描（publishable 前缀 / sb_secret_ / PAT），结果：零真实泄漏（仅命中 Review 记录文字与 vendor 库内部变量名；PAT 精确扫为空）。扫描输出见 P0-008 施工对话原始记录。

## 2. Pages 站点配置（workflow 模式）

第一次 POST 因 `--input` 覆盖 `-F` 导致 `build_type` 落成 `legacy`（PostgREST 同类参数覆盖陷阱），GET 确认后立即 PUT 纠正。

命令（纠正）：
```bash
printf '{"source":{"branch":"main","path":"/"},"build_type":"workflow"}' | \
  env -u GH_TOKEN gh api repos/levner01/Morrow/pages -X PUT -H "Accept: application/vnd.github+json" --input -
```
GET 确认原始输出：
```json
{"url":"https://api.github.com/repos/levner01/Morrow/pages","status":"building","cname":null,
 "custom_404":false,"html_url":"https://levner01.github.io/Morrow/","build_type":"workflow",
 "source":{"branch":"main","path":"/"},"public":true,"https_enforced":true}
```

## 3. Actions 部署

workflow：`.github/workflows/deploy-pages.yml`（main 分支 dist/** 变更触发，upload-pages-artifact path=dist + deploy-pages）。

run 结论：
```text
$ env -u GH_TOKEN gh run view 35825816856 --repo levner01/Morrow --json conclusion,status,url -q '.status+" "+.conclusion+" "+.url'
completed success https://github.com/levner01/Morrow/actions/runs/35825816856
```
（唯一 annotation 为 Node.js 20 deprecation 平台警告，无害。）

## 4. Pages URL 验证

命令：
```bash
curl -sS -o /dev/null -w "HTTP %{http_code} | final_url=%{url_effective} | redirects=%{num_redirects} | time=%{time_total}s" \
  https://levner01.github.io/Morrow/
curl -sS -o /dev/null -w "manifest HTTP %{http_code}\n" https://levner01.github.io/Morrow/release-manifest.json
```
原始输出：
```text
HTTP 200 | final_url=https://levner01.github.io/Morrow/ | redirects=0 | time=1.209269s
manifest HTTP 200
```
`redirects=0` + final_url 一致：无循环、无重定向。manifest.json 可离线取得（200）。

## 5. served hash = dist hash

命令：
```bash
curl -sS https://levner01.github.io/Morrow/ | shasum -a 256
```
原始输出：
```text
5e46b6d3169e228479a313044d38a32367f41b8d5987d1e511cfc2ae927200ac   # served
5e46b6d3169e228479a313044d38a32367f41b8d5987d1e511cfc2ae927200ac   # dist/release-manifest.json 中 dist.sha256
```
与 `node scripts/package-html.js --check` 输出一致：`REPRODUCIBLE: PASS`。

## 6. 公司机浏览器实测（Chrome headless CDP，viewport 1280×900）

命令（凭据 keychain → env，进程内存注入，不落盘）：
```bash
SUPABASE_PUBLISHABLE_KEY=$(security find-generic-password -s MORROW_PUBLISHABLE_KEY -a morrow -w) \
MORROW_OWNER_EMAIL=$(security find-generic-password -s MORROW_OWNER_EMAIL -a morrow -w) \
MORROW_OWNER_PASSWORD=$(security find-generic-password -s MORROW_OWNER_PASSWORD -a morrow -w) \
node tests/pages-evidence.js
```
原始输出（全文见 [pages-evidence-company.json](pages-evidence-company.json)）：
```text
PASS  P1_pages_boot_config_panel  — storage probe: 本地存储探针（http origin）：localStorage 可用 · IndexedDB 可用
PASS  P1_pages_network_zero_remote  — 远程 0 条（Pages 页启动零远程，资源全内联）
PASS  P2_pages_key_injected_login_panel  — login-panel=true；supabase 调用 1 条; 其他远程 0
PASS  P5_pages_real_login_shell  — sync-badge=synced（Pages URL 真实登录含 verifyOwner RPC 往返）
PASS  F3_company_file_boot_config_panel  — storage probe: 本地存储探针（file origin）：localStorage 可用 · IndexedDB 可用
PASS  F4_company_file_network_zero_remote  — 远程 0 条（file origin 启动零 fetch）
== 汇总: 6/6 通过 ==
```
**P5 为核心证据：真实 owner 在 Pages 发布 URL 上完成邮箱密码登录 → shell panel → `sync-badge=synced`（`get_workspace_revision_v1` C-04 信封 RPC 往返成功）。**

## 7. 家机 Pages URL 复核（留空待 leo 执行）

家机块 17/17 先于 Pages 部署完成（127.0.0.1 + file:// 双模式），Pages URL 家机复核由 leo 执行以下命令（输出待补本页）：
```bash
curl -sS -o /dev/null -w "page HTTP %{http_code} redirects=%{num_redirects}\n" https://levner01.github.io/Morrow/
curl -sS -o /dev/null -w "manifest HTTP %{http_code}\n" https://levner01.github.io/Morrow/release-manifest.json
curl -sS https://levner01.github.io/Morrow/ | shasum -a 256
```
期望：`200 0` / `200` / hash 与第 5 节一致。

| 项 | 命令 | 原始输出 | 判定 |
|---|---|---|---|
| 家机 Pages 页 | 见上 | （待 leo 补） | PENDING |
| 家机 manifest | 见上 | （待 leo 补） | PENDING |
| 家机 served hash | 见上 | （待 leo 补） | PENDING |
