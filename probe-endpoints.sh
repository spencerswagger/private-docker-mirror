#!/bin/bash
# 临时探测：找到 SWR 更新仓库概要信息的正确路径/方法（用完即删）
set -u
R="${SWR_REGION:-cn-east-5}"; NS="${SWR_NAMESPACE:-spencerswagger}"; REPO="library-nginx"
B="https://swr.${R}.myhuaweicloud.com"
S="$(cd "$(dirname "$0")" && pwd)/hwc_sign.py"

req() { # method url [body]
  local m="$1" u="$2" b="${3:-}" f; f=$(mktemp)
  python3 "$S" --lines "$m" "$u" "$b" > "$f" 2>/dev/null || { echo "SIGN-FAIL $m $u"; rm -f "$f"; return; }
  { read -r A; read -r D; } < "$f"; rm -f "$f"
  local out code
  out=$(curl -s -w '\n%{http_code}' -X "$m" "$u" -H "Authorization: $A" -H "X-Sdk-Date: $D" -H 'Content-Type: application/json' ${b:+-d "$b"})
  code=$(echo "$out" | tail -1); body=$(echo "$out" | sed '$d' | head -c 160 | tr -d '\n')
  printf '%-6s %-88s → %s %s\n' "$m" "$u" "$code" "$body"
}

echo "=== 列表：找出真实仓库名 ==="
req GET "$B/v2/manage/repos?namespace=${NS}&limit=5&offset=0"
req GET "$B/v2/manage/namespaces/${NS}/repos?limit=5&offset=0"
req GET "$B/v2/manage/namespaces/${NS}/repositories?limit=5&offset=0"
echo "=== 更新：逐个方法/路径试 ==="
for m in PATCH PUT; do
  req $m "$B/v2/manage/namespaces/${NS}/repos/${REPO}" '{"is_public":true}'
  req $m "$B/v2/manage/namespaces/${NS}/repos/${REPO}/" '{"is_public":true}'
  req $m "$B/v2/manage/namespaces/${NS}/repositories/${REPO}" '{"is_public":true}'
done
