#!/bin/bash
# 建立 GitHub repo → push → 開 Pages → 等佢 build → 驗證
# 憑證由 ~/.github.env 讀，唔會出現喺指令、畫面或者 .git/config
set -o pipefail
ENVFILE="${ENVFILE:-/c/Users/backt/.github.env}"
DIR="$(cd "$(dirname "$0")" && pwd)"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/128.0 Safari/537.36"

[ -f "$ENVFILE" ] || { echo "✗ 搵唔到 $ENVFILE"; exit 1; }
set -a; . "$ENVFILE"; set +a
[ -n "$GITHUB_TOKEN" ] || { echo "✗ 憑證檔冇 GITHUB_TOKEN"; exit 1; }
[ -n "$GITHUB_USER" ]  || { echo "✗ 憑證檔冇 GITHUB_USER"; exit 1; }
[ -n "$GITHUB_REPO" ]  || { echo "✗ 憑證檔冇 GITHUB_REPO"; exit 1; }

API="https://api.github.com"
AUTH="Authorization: Bearer $GITHUB_TOKEN"
JSON="Accept: application/vnd.github+json"
FULL="$GITHUB_USER/$GITHUB_REPO"

echo "════════ $FULL ════════"

echo "→ 驗證 token…"
who=$(curl -s -H "$AUTH" -H "$JSON" "$API/user" | python -c "import json,sys; d=json.load(sys.stdin); print(d.get('login') or d.get('message'))")
echo "   登入身分：$who"
[ "$who" = "$GITHUB_USER" ] || echo "   ⚠ token 屬於 $who，但設定寫住 $GITHUB_USER"

echo "→ 檢查 repo 存唔存在…"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" -H "$JSON" "$API/repos/$FULL")
if [ "$code" = "404" ]; then
  echo "   唔存在，建立中…"
  r=$(curl -s -X POST -H "$AUTH" -H "$JSON" "$API/user/repos" \
      -d "{\"name\":\"$GITHUB_REPO\",\"private\":false,\"description\":\"CDN throughput test payloads\",\"auto_init\":false}")
  echo "$r" | python -c "
import json,sys
d=json.load(sys.stdin)
print('   ✓ 已建立：'+d['full_name']) if d.get('full_name') else print('   ✗ '+str(d.get('message'))+' '+str(d.get('errors','')))
"
else
  echo "   已存在（HTTP $code）"
fi

echo "→ Push…"
cd "$DIR"
git init -q 2>/dev/null
git add -A
git -c user.email="${GITHUB_USER}@users.noreply.github.com" -c user.name="$GITHUB_USER" \
    commit -q -m "CDN throughput test payloads" 2>/dev/null || echo "   （冇新改動）"
git branch -M main
git remote remove origin 2>/dev/null
git remote add origin "https://github.com/$FULL.git"
# token 只喺呢一句用，唔會寫入 .git/config
git -c "http.extraheader=Authorization: Bearer $GITHUB_TOKEN" \
    -c http.postBuffer=1048576000 -c http.version=HTTP/1.1 -c core.compression=0 \
    push -u origin main 2>&1 | tail -4

echo "→ 開啟 GitHub Pages…"
r=$(curl -s -X POST -H "$AUTH" -H "$JSON" "$API/repos/$FULL/pages" \
    -d '{"source":{"branch":"main","path":"/"}}')
echo "$r" | python -c "
import json,sys
d=json.load(sys.stdin)
print('   ✓ Pages 已開：'+d['html_url']) if d.get('html_url') else print('   '+str(d.get('message')))
"

echo "→ 等 Pages build（最多 3 分鐘）…"
BASE="https://$GITHUB_USER.github.io/$GITHUB_REPO"
for i in $(seq 1 18); do
  c=$(curl -s -o /dev/null -w '%{http_code}' -A "$UA" --max-time 20 "$BASE/files/test1_10mb.ai")
  if [ "$c" = "200" ]; then echo "   ✓ 上線咗（第 $((i*10)) 秒）"; break; fi
  printf "   等緊… %ds (HTTP %s)\r" $((i*10)) "$c"
  sleep 10
done
echo

echo "→ 驗證 7 個檔…"
ok=0; bad=0
for spec in "test1_10mb.ai:10000000" "test2_10mb.ai:10000000" "test3_10mb.ai:10000000" \
            "test4_10mb.ai:10000000" "calib_05mb.ai:5000000" "calib_20mb.ai:20000000" \
            "calib_25mb.ai:25000000"; do
  f="${spec%:*}"; want="${spec##*:}"
  h=$(curl -s -D- -o /dev/null -L -A "$UA" -H "Origin: https://t.local" \
      -H "Accept-Encoding: identity" --max-time 120 "$BASE/files/$f")
  st=$(echo "$h"|grep -iE "^HTTP"|tail -1|awk '{print $2}')
  acao=$(echo "$h"|grep -ci "access-control-allow-origin")
  cl=$(echo "$h"|grep -i "^content-length"|tail -1|cut -d: -f2-|tr -d '\r'|xargs)
  ce=$(echo "$h"|grep -ci "content-encoding")
  if [ "$st" = "200" ] && [ "$acao" -ge 1 ] && [ "$cl" = "$want" ] && [ "$ce" = "0" ]; then
    printf "   ✅ %-18s %10s B\n" "$f" "$cl"; ok=$((ok+1))
  else
    printf "   ❌ %-18s HTTP=%s CORS=%s len=%s enc=%s\n" "$f" "$st" "$acao" "${cl:-?}" "$ce"; bad=$((bad+1))
  fi
done

echo
echo "════════ 通過 $ok · 失敗 $bad ════════"
echo "基本網址：$BASE/files/"
if [ "$bad" = 0 ]; then
  : > "$DIR/pages-links.txt"
  for f in test1_10mb test2_10mb test3_10mb test4_10mb calib_05mb calib_20mb calib_25mb; do
    echo "$BASE/files/$f.ai" >> "$DIR/pages-links.txt"
  done
  echo "連結已寫入 $DIR/pages-links.txt"
fi
