#!/bin/bash

# 并行执行控制
MAX_PARALLEL="${MAX_PARALLEL:-3}"  # 默认最多 3 个并行任务

# 标签过滤控制
SYNC_ONLY_POPULAR_TAGS="${SYNC_ONLY_POPULAR_TAGS:-false}"  # 是否只同步热门标签

# 热门标签白名单（匹配标签名）
# 支持正则表达式
POPULAR_TAG_PATTERNS=(
    "^latest$"
    "^[0-9]+\.[0-9]+"         # 主版本号，如 1.2, 3.4
    "^[0-9]+$"                 # 纯数字版本，如 8, 11, 17
    "^[0-9]+\.[0-9]+\.[0-9]+$" # 完整版本号，如 1.2.3
)

# 不想要的标签模式
UNWANTED_TAG_PATTERNS=(
    ".*-rc.*"                  # 候选版本
    ".*-beta.*"                # 测试版本
    ".*-alpha.*"               # 预览版本
    ".*-dev.*"                 # 开发版本
    ".*-nightly.*"             # 每夜构建
    ".*-snapshot.*"            # 快照版本
    "sha256:.*"                # SHA256 哈希
    ".*-slim.*"                # slim 版本（可选，根据需要保留）
)

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "脚本目录：${SCRIPT_DIR}" >&2
echo "当前目录：$(pwd)" >&2
echo "只同步热门标签：${SYNC_ONLY_POPULAR_TAGS}" >&2

# 标准化镜像名称函数（如果需要则添加 docker.io/ 前缀）
normalize_image() {
    local image="$1"
    local tag=""
    
    # 提取 tag（如果有）
    if [[ "$image" == *":"* ]]; then
        tag="${image##*:}"
        image="${image%:*}"
    fi
    
    # 判断镜像名格式并添加适当的前缀
    local slash_count=$(echo "$image" | tr -cd '/' | wc -c)
    
    if [[ $slash_count -eq 0 ]]; then
        # 没有 '/'，是简单镜像名（如 "nginx" 或 "redis"）
        # 添加 docker.io/library/ 前缀
        image="docker.io/library/${image}"
    elif [[ $slash_count -eq 1 ]]; then
        # 只有一个 '/'，是 namespace/image 格式（如 "openlistteam/openlist"）
        # 添加 docker.io/ 前缀
        image="docker.io/${image}"
    fi
    # 如果有两个或更多 '/'，说明已经是完整格式，保持不变
    
    # 重新添加 tag（如果有）
    if [[ -n "$tag" ]]; then
        echo "${image}:${tag}"
    else
        echo "$image"
    fi
}

# 通配符扩展函数
# 支持分页获取所有镜像
expand_wildcard() {
    local pattern="$1"
    
    # 检查是否包含通配符
    if [[ "$pattern" == *"*"* ]]; then
        echo "正在扩展通配符：${pattern}" >&2
        
        # 提取通配符前的前缀（去掉末尾的 *）
        local prefix="${pattern%\*}"
        local namespace=""
        local search_term=""
        
        # 解析镜像名格式，去掉 docker.io 前缀
        # 格式 1: docker.io/library/alpine* -> namespace=library, search_term=alpine
        # 格式 2: docker.io/arm64v8/* -> namespace=arm64v8, search_term=*
        # 格式 3: library/alpine* -> namespace=library, search_term=alpine
        # 格式 4: arm64v8/* -> namespace=arm64v8, search_term=*
        
        if [[ "$prefix" =~ ^docker\.io/([^/]+)/(.*)$ ]]; then
            # docker.io/xxx/yyy* 格式
            namespace="${BASH_REMATCH[1]}"
            search_term="${BASH_REMATCH[2]}"
        elif [[ "$prefix" =~ ^([^/]+)/(.*)$ ]]; then
            # xxx/yyy* 格式（没有 docker.io 前缀）
            namespace="${BASH_REMATCH[1]}"
            search_term="${BASH_REMATCH[2]}"
        else
            # 其他格式，整个作为 search_term
            search_term="$prefix"
        fi
        
        echo "解析结果：namespace=${namespace}, search_term=${search_term}" >&2
        
        # 使用 Docker Hub API 搜索匹配的镜像（支持分页）
        local all_results=""
        local page=1
        local page_size=100  # Docker Hub API 最大支持 100
        
        echo "开始分页获取镜像..." >&2
        
        while true; do
            local search_url=""
            if [[ -n "$namespace" ]]; then
                search_url="https://hub.docker.com/v2/repositories/${namespace}/?page_size=${page_size}&page=${page}"
            else
                search_url="https://hub.docker.com/v2/repositories/library/?page_size=${page_size}&page=${page}"
            fi
            
            echo "获取第 ${page} 页：${search_url}" >&2
            
            # 获取并过滤匹配的镜像
            local response=""
            if command -v curl &> /dev/null; then
                response=$(curl -s --connect-timeout 10 --max-time 60 "$search_url")
            else
                echo "错误：未找到 curl 命令" >&2
                return
            fi
            
            if [[ -z "$response" ]]; then
                echo "警告：Docker Hub API 返回空响应，停止分页" >&2
                break
            fi
            
            local page_results=""
            if command -v jq &> /dev/null; then
                page_results=$(echo "$response" | jq -r '.results[].name // empty' 2>/dev/null)
                local next_page=$(echo "$response" | jq -r '.next // empty' 2>/dev/null)
            else
                echo "警告：未找到 jq 命令，使用 grep 解析" >&2
                page_results=$(echo "$response" | grep -oP '"name"\s*:\s*"\K[^"]+' 2>/dev/null || :)
                local next_page=""
            fi
            
            if [[ -z "$page_results" ]]; then
                echo "第 ${page} 页无结果，停止分页" >&2
                break
            fi
            
            all_results="${all_results}${page_results}"$'\n'
            local page_count=$(echo "$page_results" | grep -c .)
            echo "第 ${page} 页获取到 ${page_count} 个镜像" >&2
            
            # 检查是否还有下一页
            if [[ -z "$next_page" || "$next_page" == "null" ]]; then
                echo "没有更多页面，停止分页" >&2
                break
            fi
            
            page=$((page + 1))
        done
        
        if [[ -z "$all_results" ]]; then
            echo "警告：未找到匹配的镜像" >&2
            return
        fi
        
        # 如果 search_term 为空或为 *，则返回所有获取到的镜像
        if [[ -z "$search_term" || "$search_term" == "*" ]]; then
            echo "全量通配符，返回所有镜像" >&2
            local count=0
            while IFS= read -r name; do
                [[ -z "$name" ]] && continue
                if [[ -n "$namespace" ]]; then
                    if [[ "$namespace" == "library" ]]; then
                        echo "docker.io/library/${name}"
                    else
                        echo "${namespace}/${name}"
                    fi
                else
                    echo "docker.io/library/${name}"
                fi
                ((count++))
            done <<< "$all_results"
            echo "全量通配符扩展完成，共 ${count} 个镜像" >&2
            return
        fi
        
        # 过滤匹配模式的镜像名
        local regex_pattern="^${search_term//\*/.*}$"
        echo "匹配模式：${regex_pattern}" >&2
        local count=0
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if [[ "$name" =~ $regex_pattern ]]; then
                if [[ -n "$namespace" ]]; then
                    if [[ "$namespace" == "library" ]]; then
                        echo "docker.io/library/${name}"
                    else
                        echo "${namespace}/${name}"
                    fi
                else
                    echo "docker.io/library/${name}"
                fi
                ((count++))
            fi
        done <<< "$all_results"
        echo "通配符扩展完成，找到 ${count} 个镜像" >&2
    else
        # 无通配符，原样输出
        echo "$pattern"
    fi
}

# 构建标签过滤正则表达式
build_tag_filter() {
    local focus_pattern=""
    local skip_pattern=""
    
    if [[ "${SYNC_ONLY_POPULAR_TAGS}" == "true" ]]; then
        # 构建白名单正则（OR 连接）
        focus_pattern="($(IFS='|'; echo "${POPULAR_TAG_PATTERNS[*]}"))"
        
        # 构建黑名单正则（OR 连接）
        skip_pattern="($(IFS='|'; echo "${UNWANTED_TAG_PATTERNS[*]}"))"
        
        echo "热门标签过滤已启用" >&2
        echo "  白名单模式：${focus_pattern}" >&2
        echo "  黑名单模式：${skip_pattern}" >&2
    else
        echo "热门标签过滤已禁用，同步所有 tag" >&2
    fi
    
    # 返回时用特殊标记区分空值
    echo "FOCUS:${focus_pattern}:SKIP:${skip_pattern}"
}

# 同步单个镜像的函数
sync_image() {
    local image="$1"
    local filter_string="$2"
    
    echo "Start sync image $image" >&2
    
    # 解析过滤字符串
    local focus_filter=""
    local skip_filter=""
    
    if [[ -n "$filter_string" ]]; then
        # 从 "FOCUS:xxx:SKIP:yyy" 格式中提取
        focus_filter=$(echo "$filter_string" | sed 's/FOCUS:\(.*\):SKIP:.*/\1/')
        skip_filter=$(echo "$filter_string" | sed 's/FOCUS:.*:SKIP://')
    fi
    
    # 使用正则表达式提取两部分内容
    if [[ $image =~ (.*)/(.*)/(.*) ]]; then
        part1=${BASH_REMATCH[2]}
        part2=${BASH_REMATCH[3]}
        # 转换为目标镜像名称
        target_image="registry.cn-hangzhou.aliyuncs.com/spencerswagger/${part1}-${part2}"
        # 执行命令，传递标签过滤参数
        # 使用 export 确保环境变量被正确传递
        (
            if [[ -n "$focus_filter" ]]; then
                export FOCUS="$focus_filter"
                echo "设置 FOCUS=${focus_filter}" >&2
            fi
            if [[ -n "$skip_filter" ]]; then
                export SKIP="$skip_filter"
                echo "设置 SKIP=${skip_filter}" >&2
            fi
            INCREMENTAL=true QUICKLY=true SYNC=true ./diff-image.sh "$image" "$target_image"
        )
    else
        echo "无效的镜像名称：$image" >&2
        return 1
    fi
}

# 等待后台任务完成
wait_for_jobs() {
    local max_jobs="$1"
    while [[ $(jobs -r -p | wc -l) -ge $max_jobs ]]; do
        sleep 1
    done
}

# 收集所有需要处理的镜像
all_images=()

echo "开始读取 image.txt..." >&2

# 检查 image.txt 是否存在
if [[ ! -f "${SCRIPT_DIR}/image.txt" ]]; then
    echo "错误：找不到 ${SCRIPT_DIR}/image.txt 文件" >&2
    exit 1
fi

while read -r line; do
    # 跳过空行和注释
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    echo "处理配置行：${line}" >&2
    
    # 标准化镜像名称（如果需要则添加 docker.io/library/ 前缀）
    normalized_line=$(normalize_image "$line")
    echo "标准化后：${normalized_line}" >&2
    
    # 扩展通配符模式
    expanded_images=$(expand_wildcard "$normalized_line")
    echo "扩展结果：${expanded_images}" >&2
    
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        echo "添加镜像：${image}" >&2
        all_images+=("$image")
    done <<< "$expanded_images"
done < "${SCRIPT_DIR}/image.txt"

total_images=${#all_images[@]}
echo "总共需要处理 ${total_images} 个镜像，最大并行数：${MAX_PARALLEL}" >&2

# 构建标签过滤规则
tag_filter=$(build_tag_filter)

# 并行执行镜像同步
failed_count=0
success_count=0

for image in "${all_images[@]}"; do
    # 等待有空闲位置
    wait_for_jobs "$MAX_PARALLEL"
    
    # 在后台启动同步任务，传递完整的过滤字符串
    sync_image "$image" "$tag_filter" &
done

# 等待所有后台任务完成
wait

echo "任务完成" >&2