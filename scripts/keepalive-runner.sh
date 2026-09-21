#!/bin/zsh
# P0-007｜宿主 Keepalive 执行器（每日 07:00 Asia/Shanghai 由 launchd 触发 + RunAtLoad 开机补跑）
#
# 纪律：
# - token 只从 keychain（-a morrow -s MORROW_AGENT_TOKEN）读取；进程零密码明文（argv/env 均无）
# - 单次尝试 curl -m 25（Edge 内部 deadline 25s，宿主侧同上限）
# - 失败有界退避 1m/2m/4m，最多 3 次尝试；成功不刷屏（单行日志）
# - 日志只记时间戳/attempt/HTTP code/request_id/耗时，绝不含 token/hash
set -u

KEYCHAIN_SERVICE="MORROW_AGENT_TOKEN"
KEYCHAIN_ACCOUNT="morrow"
SUPABASE_URL="${MORROW_SUPABASE_URL:-https://umutubzcwwmmbxfjkyvj.supabase.co}"
LOG="${MORROW_KEEPALIVE_LOG:-/tmp/morrow-keepalive.log}"
MAX_ATTEMPTS=3

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

TOKEN="$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"
if [ -z "$TOKEN" ]; then
  echo "$(ts) exit=78 reason=agent_token_missing_in_keychain" >> "$LOG"
  exit 78
fi

backoffs=(60 120 240)
attempt=0
while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  attempt_start=$(date +%s)
  body_file="$(mktemp -t morrow-keepalive)"
  http_code="$(curl -sS -o "$body_file" -w '%{http_code}' -m 25 \
    -H "Authorization: Bearer $TOKEN" \
    "$SUPABASE_URL/functions/v1/health" 2>/dev/null)"
  curl_rc=$?
  elapsed=$(( $(date +%s) - attempt_start ))
  request_id="$(sed -n 's/.*"request_id":"\([0-9a-f-]*\)".*/\1/p' "$body_file" | head -1)"
  rm -f "$body_file"

  if [ "$curl_rc" -eq 0 ] && [ "$http_code" = "200" ]; then
    echo "$(ts) ok attempt=$attempt http=200 request_id=${request_id:-none} elapsed_s=$elapsed" >> "$LOG"
    exit 0
  fi

  echo "$(ts) fail attempt=$attempt http=${http_code:-none} curl_rc=$curl_rc request_id=${request_id:-none} elapsed_s=$elapsed" >> "$LOG"

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    sleep "${backoffs[$attempt]}"
  fi
done

echo "$(ts) exit=76 reason=attempts_exhausted attempts=$attempt" >> "$LOG"
exit 76
