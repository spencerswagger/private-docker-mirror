#!/usr/bin/env python3
"""华为云 AK/SK 签名（SDK-HMAC-SHA256）—— 只用标准库。

用法（被 shell 调用）：
  python3 hwc_sign.py <METHOD> <URL> [BODY]      # 打印可直接用的 curl 头参数
  python3 hwc_sign.py --json <METHOD> <URL> [BODY]  # 打印 JSON: {"Authorization":..,"X-Sdk-Date":..,"Host":..}

环境变量：SWR_AK / SWR_SK；可选 SWR_REGION(默认 cn-east-5)、SWR_SERVICE(默认 swr)
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import sys
import datetime
from urllib.parse import urlsplit, quote


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def sign(method: str, url: str, body: str = "") -> dict[str, str]:
    ak = os.environ["SWR_AK"].strip()
    sk = os.environ["SWR_SK"].strip()
    region = os.environ.get("SWR_REGION", "cn-east-5")
    service = os.environ.get("SWR_SERVICE", "swr")

    u = urlsplit(url)
    host = u.hostname or ""
    # 华为云要求：路径与 query 都做 URI 编码（保留 '/' 与 '=' '&' 的分隔语义）
    raw_path = u.path if u.path else "/"
    if not raw_path.endswith("/"):
        raw_path += "/"           # 华为规范要求 CanonicalURI 以 '/' 结尾
    path = quote(raw_path, safe="/-_.~%")
    query = "&".join(
        sorted(
            "=".join(quote(p, safe="-_.~") for p in kv.split("=", 1))
            for kv in u.query.split("&") if kv
        )
    )
    now = datetime.datetime.now(datetime.timezone.utc)
    sdk_date = now.strftime("%Y%m%dT%H%M%SZ")
    short_date = now.strftime("%Y%m%d")

    payload_hash = hashlib.sha256(body.encode() if body else b"").hexdigest()
    canonical_headers = f"host:{host}\nx-sdk-date:{sdk_date}\n"
    signed_headers = "host;x-sdk-date"
    canonical_request = "\n".join([method.upper(), path, query, canonical_headers, signed_headers, payload_hash])
    scope = f"{short_date}/{region}/{service}/sdk_request"
    string_to_sign = "\n".join(["SDK-HMAC-SHA256", sdk_date, scope,
                                hashlib.sha256(canonical_request.encode()).hexdigest()])
    k_date = _hmac(("SDK" + sk).encode(), short_date)
    k_region = _hmac(k_date, region)
    k_service = _hmac(k_region, service)
    k_signing = _hmac(k_service, "sdk_request")
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()
    auth = (f"SDK-HMAC-SHA256 Access={ak}, SignedHeaders={signed_headers}, Signature={signature}")
    return {"Authorization": auth, "X-Sdk-Date": sdk_date, "Host": host}


def main() -> None:
    args = sys.argv[1:]
    as_json = False
    if args and args[0] == "--json":
        as_json = True; args = args[1:]
    if len(args) < 2:
        raise SystemExit("用法: hwc_sign.py [--json] <METHOD> <URL> [BODY]")
    method, url = args[0], args[1]
    body = args[2] if len(args) > 2 else ""
    h = sign(method, url, body)
    print(json.dumps(h) if as_json else "\n".join(f"{k}: {v}" for k, v in h.items()))


if __name__ == "__main__":
    main()
