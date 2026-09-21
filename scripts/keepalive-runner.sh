#!/bin/zsh
# P0-007｜宿主 Keepalive 执行器（每日 07:00 Asia/Shanghai 由 launchd 触发 + RunAtLoad 开机补跑）
#
# 纪律：
# - token 只从 keychain（service: MORROW_AGENT_TOKEN）读取；进程零密码明文（环境/argv 均无）
# - 总 deadline 30s（03-execution §8）；单次尝试 curl --max-time 取 min(25s, 剩余预算)
# - 失败有界退避 1s/3s/10s，预算耗尽即停；成功不刷屏（单行日志）
# - 日志不含 token / hash；只记时间戳、attempt、HTTP code、request_id、耗时
set -u

KEYCHAIN_SERVICE="MORROW_AGENT_TOKEN"
SUPABASE_URL="${MORROW_SUPABASE_URL:-https://umutubzcwwmmbxfjkyvj.supabase.co}"
LOG="${MORROW_KEEPALIVE_LOG:-$HOME/Library/Logs/morrow-keepalive.log}"
TOTAL_DEADLINE_S=30
PER_ATTEMPT_CAP_S=25

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

TOKEN="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"
if [ -z "$TOKEN" ]; then
  echo "$(ts) exit=78 reason=agent_token_missing_in_keychain" >> "$LOG"
  exit 78
fi

start_epoch=$(date +%s)
deadline_epoch=$((start_epoch + TOTAL_DEADLINE_S))
backoffs=(1 3 10)
attempt=0

while true; do
  now=$(date +%s)
  budget=$((deadline_epoch - now))
  if [ "$budget" -le 0 ]; then
    echo "$(ts) exit=75 reason=total_deadline_exceeded attempts=$attempt" >> "$LOG"
    exit 75
  fi
  max_time=$budget
  [ "$max_time" -gt "$PER_ATTEMPT_CAP_S" ] && max_time=$PER_ATTEMPT_CAP_S

  attempt=$((attempt + 1))
  attempt_start=$(date +%s)
  body_file="$(mktemp -t morrow-keepalive)"
  http_code="$(curl -sS -o "$body_file" -w '%{http_code}' --max-time "$max_time" \
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

  if [ "$attempt" -gt 3 ]; then
    echo "$(ts) exit=76 reason=attempts_exhausted attempts=$attempt" >> "$LOG"
    exit 76
  fi
  sleep_s="${backoffs[$attempt]:-10}"
  now=$(date +%s)
  if [ $((now + sleep_s)) -ge "$deadline_epoch" ]; then
    echo "$(ts) exit=75 reason=total_deadline_exceeded attempts=$attempt" >> "$LOG"
    exit 75
  fi
  sleep "$sleep_s"
done
