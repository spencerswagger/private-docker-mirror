#!/bin/bash
# 把 image.txt 里列出的镜像，在华为云 SWR 里设为「公开」（别人可匿名 pull）。
# 认证：AK/SK 签名（SDK-HMAC-SHA256，见 hwc_sign.py），只需要 SWR_AK / SWR_SK。
set -u
REGION="${SWR_REGION:-cn-east-5}"
NS="${SWR_NAMESPACE:-spencerswagger}"
BASE="https://swr.${REGION}.myhuaweicloud.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SWR_AK:-}" || -z "${SWR_SK:-}" ]]; then
  echo "跳过：缺少 SWR_AK / SWR_SK" >&2
  exit 0
fi
command -v python3 >/dev/null || { echo "::error::需要 python3" >&2; exit 1; }

ok=0; fail=0
while read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  [[ "$line" == *"*"* ]] && continue
  src="${line#docker.io/}"; src="${src%%:*}"
  repo="${src/\//-}"
  url="${BASE}/v2/manage/namespaces/${NS}/repos/${repo}"
  body='{"is_public": true}'
  hdrs=$(SWR_REGION="$REGION" python3 "${SCRIPT_DIR}/hwc_sign.py" --json PATCH "$url" "$body") || { fail=$((fail+1)); continue; }
  AUTH=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["Authorization"])' <<<"$hdrs")
  DATE=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["X-Sdk-Date"])' <<<"$hdrs")
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "$url" \
    -H "Authorization: ${AUTH}" -H "X-Sdk-Date: ${DATE}" \
    -H 'Content-Type: application/json' -d "$body")
  if [[ "$code" == "200" || "$code" == "201" || "$code" == "204" ]]; then ok=$((ok+1))
  else fail=$((fail+1)); echo "  ! ${repo} → HTTP ${code}"; fi
done < "${SCRIPT_DIR}/image.txt"
echo "置公开完成：成功 ${ok}，失败 ${fail}"
if [[ ${ok} -eq 0 ]]; then echo "::error::一条都没成功，判为失败" >&2; exit 1; fi
if [[ ${fail} -gt 0 ]]; then echo "::error::有 ${fail} 条失败" >&2; exit 1; fi
