# Docker 镜像同步说明

本仓库将 Docker Hub 上的镜像同步到华为云 SWR（`swr.cn-east-5.myhuaweicloud.com/spencerswagger/`）。

## 命名规则

给定 Docker Hub 源镜像：

```
docker.io/<namespace>/<repo>:<tag>
```

同步后的镜像地址为：

```
swr.cn-east-5.myhuaweicloud.com/spencerswagger/<namespace>-<repo>:<tag>
```

即：去掉 `docker.io/` 前缀，把剩余的 `<namespace>/<repo>` 中的 `/` 替换为 `-`，`tag` 保持不变。
官方镜像（无 namespace）按 `library` 处理。

## 对照示例

| Docker Hub 源镜像 | 同步后的镜像 |
| --- | --- |
| `docker.io/library/nginx:latest` | `swr.cn-east-5.myhuaweicloud.com/spencerswagger/library-nginx:latest` |
| `docker.io/library/redis:8.6.1-alpine3.23` | `swr.cn-east-5.myhuaweicloud.com/spencerswagger/library-redis:8.6.1-alpine3.23` |
| `docker.io/openlistteam/openlist:latest` | `swr.cn-east-5.myhuaweicloud.com/spencerswagger/openlistteam-openlist:latest` |

## 使用方式

直接用上述映射规则把源镜像替换为同步后的地址即可，无需改动 tag。例如：

```bash
docker pull swr.cn-east-5.myhuaweicloud.com/spencerswagger/library-nginx:latest
```

## 同步范围

镜像列表见 [image.txt](file:///workspace/image.txt)，支持通配符（如 `docker.io/library/*`）。同步逻辑与标签过滤规则见 [sync.sh](file:///workspace/sync.sh)。