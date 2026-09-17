# 家机一键 runner（P0-002 家机探针）

- 用途：家机（另一台 Mac）不在场，由凯哥在家机执行本脚本并回传输出
- 安全约定：脚本**不含任何密钥与密码**；key 由你运行时手动注入环境变量，密码用隐藏式交互输入；输出不含 token（脚本已做脱敏截取）
- 预计耗时：约 3 分钟

## 使用步骤

```bash
# 1. 把本文件保存为 morrow-probe-runner.sh
# 2. 赋权并执行（Publishable key 请从 Dashboard → Settings → API Keys 复制）：
chmod +x morrow-probe-runner.sh
SUPABASE_PUBLISHABLE_KEY='在此粘贴 Publishable key' ./morrow-probe-runner.sh
# 3. 按脚本提示：浏览器打开生成的 /tmp/morrow-file-probe.html，人工确认并回填结论
# 4. 将全部输出 + 截图回传（截图不得含 token/session/密码）
```

## morrow-probe-runner.sh（完整脚本）

```bash
#!/usr/bin/env bash
# Morrow P0-002 家机探针 runner —— 无密钥、无密码落盘；输出脱敏
set -uo pipefail
BASE="https://umutubzcwwmmbxfjkyvj.supabase.co"
KEY="${SUPABASE_PUBLISHABLE_KEY:?请以 SUPABASE_PUBLISHABLE_KEY=... 注入 publishable key}"

echo "== 0. 家机环境快照 =="
sw_vers; uname -m
"/Applications/Safari.app/Contents/Info.plist" >/dev/null 2>&1 && /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Safari.app/Contents/Info.plist | sed 's/^/Safari /'
[ -f "/Applications/Google Chrome.app/Contents/Info.plist" ] && /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "/Applications/Google Chrome.app/Contents/Info.plist" | sed 's/^/Chrome /'
echo "user-agent(本脚本curl): $(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE/auth/v1/health" >/dev/null 2>&1; echo curl-ok)"

echo "== 1. 项目 URL 连通 =="
echo -n "auth health(带key): "; curl -s -m 15 -o /tmp/hm_h.json -w 'HTTP %{http_code} ' "$BASE/auth/v1/health" -H "apikey: $KEY"; head -c 120 /tmp/hm_h.json; echo

echo "== 2. Data API 三态 =="
echo -n "合法key(缺表→404 PGRST205 即有效): "; curl -s -m 15 -o /tmp/hm_1.json -w 'HTTP %{http_code} ' "$BASE/rest/v1/probe_missing_table_xyz" -H "apikey: $KEY"; head -c 140 /tmp/hm_1.json; echo
echo -n "无key: "; curl -s -m 15 -o /tmp/hm_2.json -w 'HTTP %{http_code} ' "$BASE/rest/v1/"; head -c 120 /tmp/hm_2.json; echo
echo -n "错key: "; curl -s -m 15 -o /tmp/hm_3.json -w 'HTTP %{http_code} ' "$BASE/rest/v1/" -H "apikey: sb_publishable_0000000000000000000000000000"; head -c 120 /tmp/hm_3.json; echo

echo "== 3. file:// CORS（Origin null，机器级）=="
echo -n "REST+Origin:null: "; curl -s -D - -o /dev/null -m 15 "$BASE/rest/v1/probe_missing_table_xyz" -H "apikey: $KEY" -H 'Origin: null' | grep -iE 'HTTP/|access-control-allow-origin' | tr '\n' ' '; echo
echo -n "auth+Origin:null: "; curl -s -D - -o /dev/null -m 15 -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $KEY" -H 'Content-Type: application/json' -H 'Origin: null' -d '{"email":"x@y.z","password":"x"}' | grep -iE 'HTTP/|access-control-allow-origin' | tr '\n' ' '; echo

echo "== 4. Human 密码登录（交互式输入，不回显、不落盘）=="
read -s -p "probe 用户密码（由公司机保管人提供）: " PROBE_PW; echo
LOGIN=$(jq -n --arg p "$PROBE_PW" '{email:"morrow-probe@probe.invalid",password:$p}')
curl -s -m 15 -o /tmp/hm_login.json -w "login: HTTP %{http_code}\n" "$BASE/auth/v1/token?grant_type=password" -H "apikey: $KEY" -H 'Content-Type: application/json' -d "$LOGIN"
TOK=$(jq -r '.access_token // empty' /tmp/hm_login.json 2>/dev/null)
if [ -n "$TOK" ]; then
  echo -n "JWT读probe_rls: "; curl -s -m 15 -o /tmp/hm_r.json -w 'HTTP %{http_code} ' "$BASE/rest/v1/probe_rls?select=id,note" -H "apikey: $KEY" -H "Authorization: Bearer $TOK"; head -c 200 /tmp/hm_r.json; echo
  echo -n "JWT读probe_int8: "; curl -s -m 15 -o /tmp/hm_i8.json -w 'HTTP %{http_code} ' "$BASE/rest/v1/probe_int8?select=v" -H "apikey: $KEY" -H "Authorization: Bearer $TOK"; head -c 120 /tmp/hm_i8.json; echo
else
  echo "login 未成功（body 摘要）: $(head -c 200 /tmp/hm_login.json)"
fi

echo "== 5. Edge 三态 =="
read -s -p "PROBE_TOKEN（由公司机保管人提供）: " PT; echo
FN="$BASE/functions/v1/probe-health"
echo -n "无token: "; curl -s -m 20 -o /tmp/hm_e1.json -w 'HTTP %{http_code} ' "$FN"; head -c 120 /tmp/hm_e1.json; echo
echo -n "错token: "; curl -s -m 20 -o /tmp/hm_e2.json -w 'HTTP %{http_code} ' "$FN" -H "Authorization: Bearer wrong-token"; head -c 120 /tmp/hm_e2.json; echo
echo -n "合法token: "; curl -s -m 20 -o /tmp/hm_e3.json -w 'HTTP %{http_code} ' "$FN" -H "Authorization: Bearer $PT"; head -c 200 /tmp/hm_e3.json; echo

echo "== 6. 生成 file:// 原型页（浏览器人工验证）=="
cat > /tmp/morrow-file-probe.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>Morrow file:// probe</title>
<script>
// file:// 原型：验证 null origin 下 Auth/Data API 可达性与本地存储可用性（非最终验收）
const BASE = "https://umutubzcwwmmbxfjkyvj.supabase.co";
function log(id, txt){ document.getElementById(id).textContent = txt; }
async function run(){
  const key = document.getElementById("k").value.trim();
  if(!key) { alert("先粘贴 publishable key"); return; }
  try {
    const h = await fetch(`${BASE}/auth/v1/health`, { headers:{ apikey:key } });
    log("r1", `auth health: ${h.status} ${(await h.text()).slice(0,80)}`);
  } catch(e){ log("r1", "auth health FAIL: " + e); }
  try {
    const r = await fetch(`${BASE}/rest/v1/probe_missing_table_xyz`, { headers:{ apikey:key } });
    log("r2", `REST(缺表): ${r.status} ${(await r.text()).slice(0,80)}`);
  } catch(e){ log("r2", "REST FAIL: " + e); }
  try { localStorage.setItem("morrow_probe", "1"); log("r3", "localStorage: OK(" + localStorage.getItem("morrow_probe") + ")"); }
  catch(e){ log("r3", "localStorage FAIL: " + e); }
  try { indexedDB.open("morrow_probe_db").onsuccess = function(){ log("r4","IndexedDB: OK"); }; indexedDB.open("morrow_probe_db").onerror = function(){ log("r4","IndexedDB: FAIL"); }; }
  catch(e){ log("r4", "IndexedDB FAIL: " + e); }
  log("r0", "location.origin = " + JSON.stringify(location.origin) + "  protocol = " + location.protocol);
}
</script>
<h3>Morrow file:// 探针（P0-002，非最终验收）</h3>
<p>publishable key: <input id="k" size="50" placeholder="运行时粘贴，不存储"></p>
<p><button onclick="run()">运行探针</button></p>
<pre id="r0"></pre><pre id="r1"></pre><pre id="r2"></pre><pre id="r3"></pre><pre id="r4"></pre>
HTML
echo "已生成 /tmp/morrow-file-probe.html —— 请用 Safari 与 Chrome 各打开一次（file://），点【运行探针】，"
echo "把 r0~r4 五行结果 + 是否有 console 报错 记录回传（可截图，页面不含密钥）"

echo "== 7. 清理临时文件 =="
rm -f /tmp/hm_*.json
echo "runner 完成。请回传：全部脚本输出 + r0~r4 结果/截图 + 浏览器版本 + 是否使用代理"
```

## 期望输出（判读基准，与公司机实测一致）

| 步骤 | 期望 |
|---|---|
| 1 auth health | `HTTP 200 {"version":"v2.197.0",...}` |
| 2 合法 key | `HTTP 404` + `PGRST205`（证明 key 有效） |
| 2 无 key / 错 key | `HTTP 401` no API key found / Invalid API key |
| 3 Origin null | REST/auth 均出现 `access-control-allow-origin: null`（或 `*`） |
| 4 login | `HTTP 200`；JWT 读 `probe_rls` → `200 []`（该用户零行）；`probe_int8` → `200 {"v":"9007199254740993"}` |
| 5 Edge | 无/错 token → `401 {"error":"unauthorized"}`；合法 → `200 {"status":"ok","db_status":200,"v":"9007199254740993"}` |
| 6 file:// | origin=`"null"`、protocol=`file:`；auth/REST 状态同上；localStorage/IndexedDB 结果如实记录（不同浏览器可能不同，失败不判死刑，P0-008 复验） |

> 注（2026-09-17 归档）：探针对象已清理（Edge 函数删除、probe 用户从未创建），上表第 4/5 节重跑将分别得到登录失败与 404——属预期，归档见 [result.md](result.md) §D.4/§F；第 4/5 步所需密码/token 已从公司机 keychain 删除。有效回传范围为第 0–3、6 节（公开端点 + file:// 页）。

## 附：公司机保管人待提供（不进本文件）

- probe 用户密码（公司机 keychain `MORROW_PROBE_PW`）与 PROBE_TOKEN（keychain `MORROW_PROBE_TOKEN`）——由凯哥自行转移到家机（当面/密码管理器），不要走聊天明文
- 若回传时探针对象已被清理，4/5 步会失败——以 result.md「探针清理」节的清理时间为准判断
