#!/bin/bash
# 把 SWR 里「已存在但仍是私有」的仓库置为公开（别人可匿名 pull）。
# 为什么按「仓库列表」而不是 image.txt：同步是并行后台任务，刚同步完的仓库可能还没落库；
# 按列表发布 = 每次跑都把「现在已经存在的仓库」全刷一遍，天然幂等、不受时序影响。
# 认证：AK/SK 签名（见 hwc_sign.py）。PUBLISH_ONLY_WHITELIST=true 时只处理 image.txt 里的仓库。
set -u
REGION="${SWR_REGION:-cn-east-5}"
NS="${SWR_NAMESPACE:-spencerswagger}"
BASE="https://${SWR_API_HOST:-swr-api.${REGION}.myhuaweicloud.com}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SWR_AK:-}" || -z "${SWR_SK:-}" ]]; then echo "跳过：缺少 SWR_AK / SWR_SK" >&2; exit 0; fi
command -v python3 >/dev/null || { echo "::error::需要 python3" >&2; exit 1; }

req() { # method url [body] -> 设 CODE / BODY
  local m="$1" u="$2" b="${3:-}" f
  f=$(mktemp); if ! python3 "${SCRIPT_DIR}/hwc_sign.py" --lines "$m" "$u" "$b" > "$f" 2>/dev/null; then
    rm -f "$f"; CODE=000; BODY="签名失败"; return 1
  fi
  { read -r AUTH; read -r DATE; } < "$f"; rm -f "$f"
  local out; out=$(curl -s -w '\n%{http_code}' -X "$m" "$u" \
    -H "Authorization: ${AUTH}" -H "X-Sdk-Date: ${DATE}" -H 'Content-Type: application/json' ${b:+-d "$b"})
  CODE=$(echo "$out" | tail -1); BODY=$(echo "$out" | sed '$d')
}

# 1) 拉全量仓库名（分页）
repos=""; offset=0
while :; do
  req GET "${BASE}/v2/manage/repos?namespace=${NS}&limit=100&offset=${offset}" || break
  [[ "$CODE" != "200" ]] && { echo "::error::列仓库失败（HTTP ${CODE}）$(echo "$BODY" | head -c 200)" >&2; exit 1; }
  page=$(echo "$BODY" | grep -oP '"name"\s*:\s*"\K[^"]+' | sort -u)
  [[ -z "$page" ]] && break
  repos="${repos}${page}"$'\n'
  cnt=$(echo "$page" | grep -c .)
  [[ "$cnt" -lt 100 ]] && break
  offset=$((offset + cnt))
done
REPO_N=$(echo "$repos" | grep -c . || true)
echo "SWR 现有仓库：${REPO_N} 个"

# 2) 可选：只发白名单
if [[ "${PUBLISH_ONLY_WHITELIST:-false}" == "true" ]]; then
  keep=$(grep -v '^#' "${SCRIPT_DIR}/image.txt" | grep -v '^$' | grep -v '\*' | sed 's#^docker.io/##; s#:.*##; s#/#-#g' | sort -u)
  repos=$(comm -12 <(echo "$repos" | grep . | sort -u) <(echo "$keep"))
  echo "只发白名单：$(echo "$repos" | grep -c . || echo 0) 个"
fi

# 3) 逐个置公开（已是公开的跳过）
ok=0; skip=0; fail=0
while read -r r; do
  [[ -z "$r" ]] && continue
  req GET "${BASE}/v2/manage/namespaces/${NS}/repos/${r}" || { fail=$((fail+1)); continue; }
  if [[ "$CODE" != "200" ]]; then fail=$((fail+1)); echo "  ! 读 ${r} 详情失败 HTTP ${CODE}"; continue; fi
  if echo "$BODY" | grep -q '"is_public":true'; then skip=$((skip+1)); continue; fi
  req PATCH "${BASE}/v2/manage/namespaces/${NS}/repos/${r}" '{"is_public": true}' || { fail=$((fail+1)); continue; }
  if [[ "$CODE" == "200" || "$CODE" == "201" || "$CODE" == "204" ]]; then ok=$((ok+1)); echo "  ✓ ${r} → public"
  else fail=$((fail+1)); echo "  ! ${r} → HTTP ${CODE} $(echo "$BODY" | head -c 200)"; fi
done <<< "$repos"

echo "置公开：新发 ${ok}，本来就是公开 ${skip}，失败 ${fail}"
[[ ${fail} -gt 0 ]] && { echo "::error::有 ${fail} 个失败" >&2; exit 1; }
exit 0
