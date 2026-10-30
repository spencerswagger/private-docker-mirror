#!/bin/bash
# 清理 SWR 里不在 image.txt 白名单中的仓库。
# CLEANUP_MODE=dry-run（默认，只打印）| delete（真删）
set -u
REGION="${SWR_REGION:-cn-east-5}"
NS="${SWR_NAMESPACE:-spencerswagger}"
MODE="${CLEANUP_MODE:-dry-run}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SWR_IAM_USER:-}" || -z "${SWR_IAM_PASSWORD:-}" || -z "${SWR_IAM_DOMAIN:-}" ]]; then
  echo "跳过：缺少 SWR_IAM_* 凭据" >&2; exit 0
fi
TOKEN=$(curl -s -i -X POST "https://iam.${REGION}.myhuaweicloud.com/v3/auth/tokens" -H 'Content-Type: application/json' \
  -d "{\"auth\":{\"identity\":{\"methods\":[\"password\"],\"password\":{\"user\":{\"name\":\"${SWR_IAM_USER}\",\"password\":\"${SWR_IAM_PASSWORD}\",\"domain\":{\"name\":\"${SWR_IAM_DOMAIN}\"}}}},\"scope\":{\"project\":{\"name\":\"${REGION}\"}}}}" \
  | awk -F': ' 'tolower($1)=="x-subject-token"{print $2}' | tr -d '\r')
if [[ -z "$TOKEN" ]]; then echo "::error::取 IAM token 失败（凭据已提供），判为失败" >&2; exit 1; fi

KEEP=$(grep -v '^#' "${SCRIPT_DIR}/image.txt" | grep -v '^$' | grep -v '\*' | sed 's#^docker.io/##; s#:.*##; s#/#-#g' | sort -u)
REPOS=$(curl -s "https://swr.${REGION}.myhuaweicloud.com/v2/manage/repos?namespace=${NS}&limit=200&offset=0" \
  -H "X-Auth-Token: ${TOKEN}" | grep -oP '"name"\s*:\s*"\K[^"]+' | sort -u)
WILDCARD=$(grep -c '\*' "${SCRIPT_DIR}/image.txt" || true)
KEEP_N=$(echo "$KEEP" | grep -c . || true)
REPO_N=$(echo "$REPOS" | grep -c . || true)
# 下限保护：白名单里出现通配符、或白名单过小、或没有识别到现存仓库，一律拒绝删除
if [[ "${WILDCARD:-0}" -gt 0 ]]; then echo "::error::image.txt 仍含通配行，清理不安全，终止" >&2; exit 1; fi
if [[ "${KEEP_N:-0}" -lt 10 ]]; then echo "::error::白名单只有 ${KEEP_N} 个仓库（<10），清理不安全，终止" >&2; exit 1; fi
if [[ "${REPO_N:-0}" -eq 0 ]]; then echo "::error::没读到 SWR 现有仓库（可能 token/接口异常），终止" >&2; exit 1; fi
TO_DELETE=$(comm -23 <(echo "$REPOS") <(echo "$KEEP"))
DEL_N=$(echo "$TO_DELETE" | grep -c . || true)
MAX_DEL="${CLEANUP_MAX_DELETE:-100}"
echo "现有仓库 $(echo "$REPOS" | grep -c . ) 个；白名单 $(echo "$KEEP" | grep -c .) 个；待清理 ${DEL_N} 个（模式：${MODE}）"
if [[ "$MODE" == "delete" && "${DEL_N:-0}" -gt "$MAX_DEL" && "${CLEANUP_FORCE:-false}" != "true" ]]; then
  echo "::error::待删 ${DEL_N} 个 > 阈值 ${MAX_DEL}，需显式 CLEANUP_FORCE=true 才继续（已中止）" >&2; exit 1
fi
DEL_FAIL=0
for r in $TO_DELETE; do
  if [[ "$MODE" == "delete" ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "https://swr.${REGION}.myhuaweicloud.com/v2/manage/namespaces/${NS}/repos/${r}" -H "X-Auth-Token: ${TOKEN}")
    if [[ "$code" == "204" || "$code" == "200" ]]; then
      echo "  deleted ${r} (HTTP ${code})"
    else
      echo "::error::删除 ${r} 失败（HTTP ${code}）"
      DEL_FAIL=$((DEL_FAIL+1))
    fi
  else
    echo "  [dry-run] 会删除 ${r}"
  fi
done
if [[ "${DEL_FAIL:-0}" -gt 0 ]]; then echo "::error::有 ${DEL_FAIL} 个删除失败" >&2; exit 1; fi
