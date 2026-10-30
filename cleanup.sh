#!/bin/bash
# 清理 SWR 里不在 image.txt 白名单中的仓库。CLEANUP_MODE=dry-run（默认）| delete
set -u
REGION="${SWR_REGION:-cn-east-5}"
NS="${SWR_NAMESPACE:-spencerswagger}"
MODE="${CLEANUP_MODE:-dry-run}"
BASE="https://swr.${REGION}.myhuaweicloud.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SWR_AK:-}" || -z "${SWR_SK:-}" ]]; then echo "跳过：缺少 SWR_AK / SWR_SK" >&2; exit 0; fi
command -v python3 >/dev/null || { echo "::error::需要 python3" >&2; exit 1; }

sign_headers() {  # $1=method $2=url [$3=body] -> 设 AUTH / DATE
  local out
  mapfile -t H < <(python3 "${SCRIPT_DIR}/hwc_sign.py" --lines "$1" "$2" "${3:-}") || return 1
  AUTH="${H[0]}"; DATE="${H[1]}"
}

LIST_URL="${BASE}/v2/manage/repos?namespace=${NS}&limit=200&offset=0"
sign_headers GET "$LIST_URL" || { echo "::error::签名失败" >&2; exit 1; }
RESP=$(curl -s "$LIST_URL" -H "Authorization: ${AUTH}" -H "X-Sdk-Date: ${DATE}")
REPOS=$(echo "$RESP" | grep -oP '"name"\s*:\s*"\K[^"]+' | sort -u)
KEEP=$(grep -v '^#' "${SCRIPT_DIR}/image.txt" | grep -v '^$' | grep -v '\*' | sed 's#^docker.io/##; s#:.*##; s#/#-#g' | sort -u)

WILDCARD=$(grep -c '\*' "${SCRIPT_DIR}/image.txt" || true)
KEEP_N=$(echo "$KEEP" | grep -c . || true)
REPO_N=$(echo "$REPOS" | grep -c . || true)
if [[ "${WILDCARD:-0}" -gt 0 ]]; then echo "::error::image.txt 仍含通配行，清理不安全，终止" >&2; exit 1; fi
if [[ "${KEEP_N:-0}" -lt 10 ]]; then echo "::error::白名单只有 ${KEEP_N} 个（<10），清理不安全，终止" >&2; exit 1; fi
if [[ "${REPO_N:-0}" -eq 0 ]]; then echo "::error::没读到 SWR 现有仓库（token/接口异常），终止" >&2; exit 1; fi

TO_DELETE=$(comm -23 <(echo "$REPOS") <(echo "$KEEP"))
DEL_N=$(echo "$TO_DELETE" | grep -c . || true)
MAX_DEL="${CLEANUP_MAX_DELETE:-100}"
echo "现有 ${REPO_N} 个；白名单 ${KEEP_N} 个；待清理 ${DEL_N} 个（模式：${MODE}）"
if [[ "$MODE" == "delete" && "${DEL_N:-0}" -gt "$MAX_DEL" && "${CLEANUP_FORCE:-false}" != "true" ]]; then
  echo "::error::待删 ${DEL_N} > 阈值 ${MAX_DEL}，需 CLEANUP_FORCE=true（已中止）" >&2; exit 1
fi

DEL_FAIL=0
for r in $TO_DELETE; do
  if [[ "$MODE" != "delete" ]]; then echo "  [dry-run] 会删除 ${r}"; continue; fi
  url="${BASE}/v2/manage/namespaces/${NS}/repos/${r}"
  sign_headers DELETE "$url" || { DEL_FAIL=$((DEL_FAIL+1)); continue; }
  code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$url" -H "Authorization: ${AUTH}" -H "X-Sdk-Date: ${DATE}")
  if [[ "$code" == "204" || "$code" == "200" ]]; then echo "  deleted ${r}"; else echo "::error::删除 ${r} 失败（HTTP ${code}）"; DEL_FAIL=$((DEL_FAIL+1)); fi
done
if [[ "${DEL_FAIL:-0}" -gt 0 ]]; then echo "::error::有 ${DEL_FAIL} 个删除失败" >&2; exit 1; fi
