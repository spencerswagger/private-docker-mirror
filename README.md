# Docker 镜像同步（国内可直拉）

把 Docker Hub 的常用镜像同步到 **华为云 SWR**，国内网络直接 `docker pull`，不用翻墙。
仓库共 **104 个 tag / 17 个镜像**，全部为白名单显式指定（不扫全量 tag）。

## 一、怎么用（拉镜像）

源镜像 → SWR 地址的换算规则：

```
docker.io/<namespace>/<repo>:<tag>
        ↓
swr.cn-east-5.myhuaweicloud.com/spencerswagger/<namespace>-<repo>:<tag>
```

- 去掉 `docker.io/`，把 `<namespace>/<repo>` 里的 `/` 换成 `-`，`tag` 原样保留
- 官方镜像（无 namespace）按 `namespace = library` 处理

示例：

```bash
# Docker Hub: docker.io/library/node:22-alpine
docker pull swr.cn-east-5.myhuaweicloud.com/spencerswagger/library-node:22-alpine

# Docker Hub: docker.io/library/postgres:17-alpine
docker pull swr.cn-east-5.myhuaweicloud.com/spencerswagger/library-postgres:17-alpine
```

在 docker-compose / k8s manifest 里，把 `image:` 直接换成上面的 SWR 地址即可，环境变量、端口、数据卷都不用改。

## 二、目前同步了哪些

| 镜像 | 版本 | tag 数 |
|---|---|---|
| node | 14 → 24（含 17/19/21/23 非 LTS 线） | 28 |
| golang | 1.16 → 1.27 | 21 |
| python | 3.6 → 3.14 | 18 |
| eclipse-temurin / maven | JDK 8（jdk / jre）+ maven 3.9 | 3 |
| postgres | 13 → 18（alpine） | 6 |
| redis | 6.2 → 8（alpine） | 5 |
| nginx | 1.24 / 1.26 / 1.27 / stable（alpine） | 5 |
| mysql | 5.7 / 8.0 / 8.4 | 3 |
| meilisearch | latest / v1.55.0 / v1.12.0 | 3 |
| alpine / debian / ubuntu / busybox | 基础系统 | 9 |
| rabbitmq / curl / registry | 工具 | 3 |

**完整清单**：见 [`image.txt`](image.txt)，一行一个 `docker.io/<ns>/<repo>:<tag>`，支持 `#` 注释。

## 三、同步机制

| 方式 | 触发 | 说明 |
|---|---|---|
| 定时批量 | 每天 `12:00` / `18:00` UTC（北京 20:00 / 次日 02:00） | 按 `image.txt` 同步（`.github/workflows/sync.yml`） |
| 手动单个 | Actions → **Sync Manually** → Run workflow | 必填 `image`，如 `docker.io/library/nginx:latest`（`.github/workflows/sync-manual.yml`） |
| 手动批量 | Actions → **Sync** → Run workflow | 可选 `max_parallel` / `sync_only_popular_tags` / `sync_multi_arch` |

- 同步引擎：`skopeo`（先 `skopeo copy` 到 SWR，再按平台/架构处理）
- 默认**只同步当前平台**（amd64）；要 arm64 需显式 `sync_multi_arch=true`
- 多架构镜像走 `arm64v8/*` 之类的独立 namespace

## 四、我想加新镜像怎么办

1. 提 **Issue** 说明镜像名 + tag（推荐，维护者统一评估）
2. 或直接改 `image.txt`（一行一个）提 **PR**
3. 临时用一次，可以自己跑 `Sync Manually`

## 五、维护者说明

仓库 secrets：

| Secret | 用途 | 必需 |
|---|---|---|
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | 拉 Docker Hub（避免匿名限流） | 建议 |
| `SWR_USERNAME` / `SWR_PASSWORD` | `skopeo login` 推送 SWR（本质是一对 AK/SK 的登录串） | **必需** |
| `SWR_IAM_USER` / `SWR_IAM_PASSWORD` / `SWR_IAM_DOMAIN` | 调 SWR 管理 API（把仓库置为「公开」、清理清单外仓库） | 置公开需要 |

- SWR 新建仓库默认**私有**，别人拉不到；`Make public` 步骤会把本次同步的仓库 `is_public` 置 true。
- 清理（`Cleanup`）默认 **dry-run 只打印**，要真删除需手动传 `cleanup_mode=delete`。
