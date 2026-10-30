#!/bin/bash
# 把本次 image.txt 里列出的镜像，在华为云 SWR 里设为「公开」（别人可匿名 pull）。
# 需要：SWR_IAM_USER / SWR_IAM_PASSWORD / SWR_IAM_DOMAIN（账号名）
#      可覆盖：SWR_REGION（默认 cn-east-5）、SWR_NAMESPACE（默认 spencerswagger）
set -u
REGION="${SWR_REGION:-cn-east-5}"
NS="${SWR_NAMESPACE:-spencerswagger}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${SWR_IAM_USER:-}" || -z "${SWR_IAM_PASSWORD:-}" || -z "${SWR_IAM_DOMAIN:-}" ]]; then
  echo "跳过：缺少 SWR_IAM_USER / SWR_IAM_PASSWORD / SWR_IAM_DOMAIN" >&2
  exit 0
fi

TOKEN=$(curl -s -i -X POST "https://iam.${REGION}.myhuaweicloud.com/v3/auth/tokens" \
  -H 'Content-Type: application/json' \
  -d "{\"auth\":{\"identity\":{\"methods\":[\"password\"],\"password\":{\"user\":{\"name\":\"${SWR_IAM_USER}\",\"password\":\"${SWR_IAM_PASSWORD}\",\"domain\":{\"name\":\"${SWR_IAM_DOMAIN}\"}}}},\"scope\":{\"project\":{\"name\":\"${REGION}\"}}}}" \
  | awk -F': ' 'tolower($1)=="x-subject-token"{print $2}' | tr -d '\r')
if [[ -z "$TOKEN" ]]; then echo "取 IAM token 失败，跳过" >&2; exit 0; fi

ok=0; fail=0
while read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  [[ "$line" == *"*"* ]] && continue          # 通配符行交给批量日志，这里只处理显式 tag
  src="${line#docker.io/}"; src="${src%%:*}"   # library/nginx
  repo="${src/\//-}"                           # library-nginx
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
    "https://swr.${REGION}.myhuaweicloud.com/v2/manage/namespaces/${NS}/repositories/${repo}" \
    -H "X-Auth-Token: ${TOKEN}" -H 'Content-Type: application/json' \
    -d '{"is_public": true}')
  if [[ "$code" == "200" || "$code" == "204" ]]; then ok=$((ok+1)); else fail=$((fail+1)); echo "  ! ${repo} → HTTP ${code}"; fi
done < "${SCRIPT_DIR}/image.txt"
echo "置公开完成：成功 ${ok}，失败 ${fail}"
