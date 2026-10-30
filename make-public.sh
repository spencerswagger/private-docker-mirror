#!/bin/bash
# 把 image.txt 里列出的镜像，在华为云 SWR 里设为「公开」（别人可匿名 pull）。
# 认证：AK/SK 签名（SDK-HMAC-SHA256，见 hwc_sign.py），只需要 SWR_AK / SWR_SK。
set -u
REGION="${SWR_REGION:-cn-east-5}"
NS="${SWR_NAMESPACE:-spencerswagger}"
BASE="https://${SWR_API_HOST:-swr-api.${REGION}.myhuaweicloud.com}"
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
  SIG=$(mktemp); if ! python3 "${SCRIPT_DIR}/hwc_sign.py" --lines PATCH "$url" "$body" > "$SIG" 2>/dev/null; then
    rm -f "$SIG"; fail=$((fail+1)); echo "  ! ${repo} → 签名失败"; continue
  fi
  { read -r AUTH; read -r DATE; } < "$SIG"; rm -f "$SIG"
  resp=$(curl -s -w '\n%{http_code}' -X PATCH "$url" \
    -H "Authorization: ${AUTH}" -H "X-Sdk-Date: ${DATE}" \
    -H 'Content-Type: application/json' -d "$body")
  code=$(echo "$resp" | tail -1)
  if [[ "$code" == "200" || "$code" == "201" || "$code" == "204" ]]; then ok=$((ok+1))
  else
    fail=$((fail+1)); echo "  ! ${repo} → HTTP ${code} $(echo "$resp" | sed '$d' | head -c 300 | tr -d '\n')"
    if [[ ${ok} -eq 0 && ${fail} -eq 1 ]]; then
      echo "  [诊断] 列仓库（三种候选路径）:"
      for lu in "${BASE}/v2/manage/repos?namespace=${NS}&limit=5&offset=0" \
                "${BASE}/v2/manage/namespaces/${NS}/repos?limit=5&offset=0" \
                "${BASE}/v2/manage/namespaces/${NS}/repositories?limit=5&offset=0"; do
        f=$(mktemp); python3 "${SCRIPT_DIR}/hwc_sign.py" --lines GET "$lu" > "$f" 2>/dev/null || { rm -f "$f"; continue; }
        { read -r A2; read -r D2; } < "$f"; rm -f "$f"
        r2=$(curl -s -w '\n%{http_code}' "$lu" -H "Authorization: ${A2}" -H "X-Sdk-Date: ${D2}")
        echo "    GET $lu → $(echo "$r2" | tail -1) $(echo "$r2" | sed '$d' | head -c 240 | tr -d '\n')"
      done
    fi
  fi
done < "${SCRIPT_DIR}/image.txt"
echo "置公开完成：成功 ${ok}，失败 ${fail}"
if [[ ${ok} -eq 0 ]]; then echo "::error::一条都没成功，判为失败" >&2; exit 1; fi
if [[ ${fail} -gt 0 ]]; then echo "::error::有 ${fail} 条失败" >&2; exit 1; fi

if [[ "${MAKE_PUBLIC_VERIFY:-false}" == "true" ]]; then
  first=$(grep -v '^#' "${SCRIPT_DIR}/image.txt" | grep -v '^$' | grep -v '\*' | head -1)
  r="${first#docker.io/}"; r="${r%%:*}"; r="${r/\//-}"
  for u in "${BASE}/v2/manage/namespaces/${NS}/repos/${r}" "${BASE}/v2/manage/namespaces/${NS}" "${BASE}/v2/manage/repos?namespace=${NS}&limit=3&offset=0"; do
    f=$(mktemp); python3 "${SCRIPT_DIR}/hwc_sign.py" --lines GET "$u" > "$f" 2>/dev/null || { rm -f "$f"; continue; }
    { read -r A3; read -r D3; } < "$f"; rm -f "$f"
    rr=$(curl -s -w '\n%{http_code}' "$u" -H "Authorization: ${A3}" -H "X-Sdk-Date: ${D3}")
    echo "  [verify] GET $u → $(echo "$rr" | tail -1) $(echo "$rr" | sed '$d' | head -c 400 | tr -d '\n')"
  done
fi
