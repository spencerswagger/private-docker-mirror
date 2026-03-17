#!/bin/bash

# 并行执行控制
MAX_PARALLEL="${MAX_PARALLEL:-3}"  # 默认最多 3 个并行任务

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "脚本目录：${SCRIPT_DIR}" >&2
echo "当前目录：$(pwd)" >&2

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
expand_wildcard() {
    local pattern="$1"
    
    # 检查是否包含通配符
    if [[ "$pattern" == *"*"* ]]; then
        echo "正在扩展通配符：${pattern}" >&2
        
        # 提取通配符前的前缀
        local prefix="${pattern%\*}"
        local namespace=""
        local search_term="$prefix"
        
        # 如果存在 namespace（例如 "docker.io/library/alpine*"）
        if [[ "$prefix" =~ ^([^/]+)/([^/]+)/(.*)$ ]]; then
            namespace="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
            search_term="${BASH_REMATCH[3]}"
        elif [[ "$prefix" =~ ^([^/]+)/(.*)$ ]]; then
            namespace="${BASH_REMATCH[1]}"
            search_term="${BASH_REMATCH[2]}"
        fi
        
        echo "解析结果：namespace=${namespace}, search_term=${search_term}" >&2
        
        # 对于全量通配符（如 */* 或 namespace/*），直接返回原始模式，避免请求过多数据
        if [[ "$search_term" == "" || "$search_term" == "*" ]]; then
            echo "检测到全量通配符，返回原始模式：${pattern}" >&2
            echo "$pattern"
            return
        fi
        
        # 使用 Docker Hub API 搜索匹配的镜像
        local search_url=""
        if [[ -n "$namespace" ]]; then
            search_url="https://hub.docker.com/v2/repositories/${namespace}/?page_size=100"
        else
            search_url="https://hub.docker.com/v2/repositories/library/?page_size=100"
        fi
        
        echo "请求 Docker Hub API: ${search_url}" >&2
        
        # 获取并过滤匹配的镜像
        local response=""
        if command -v curl &> /dev/null; then
            response=$(curl -s --connect-timeout 10 --max-time 30 "$search_url")
        else
            echo "错误：未找到 curl 命令" >&2
            echo "$pattern"
            return
        fi
        
        if [[ -z "$response" ]]; then
            echo "警告：Docker Hub API 返回空响应，使用原始模式" >&2
            echo "$pattern"
            return
        fi
        
        local results=""
        if command -v jq &> /dev/null; then
            results=$(echo "$response" | jq -r '.results[].name // empty' 2>/dev/null)
        else
            echo "警告：未找到 jq 命令，尝试使用 grep 解析" >&2
            results=$(echo "$response" | grep -oP '"name"\s*:\s*"\K[^"]+' 2>/dev/null || :)
        fi
        
        if [[ -z "$results" ]]; then
            echo "警告：未解析到镜像名称，使用原始模式" >&2
            echo "$pattern"
            return
        fi
        
        # 过滤匹配模式的镜像名
        local regex_pattern="^${search_term//\*/.*}$"
        echo "匹配模式：${regex_pattern}" >&2
        local count=0
        while IFS= read -r name; do
            if [[ -n "$name" && "$name" =~ $regex_pattern ]]; then
                if [[ -n "$namespace" ]]; then
                    echo "${namespace}/${name}"
                else
                    echo "docker.io/library/${name}"
                fi
                ((count++))
            fi
        done <<< "$results"
        echo "通配符扩展完成，找到 ${count} 个镜像" >&2
    else
        # 无通配符，原样输出
        echo "$pattern"
    fi
}

# 同步单个镜像的函数
sync_image() {
    local image="$1"
    
    echo "Start sync image $image" >&2
    
    # 使用正则表达式提取两部分内容
    if [[ $image =~ (.*)/(.*)/(.*) ]]; then
        part1=${BASH_REMATCH[2]}
        part2=${BASH_REMATCH[3]}
        # 转换为目标镜像名称
        target_image="registry.cn-hangzhou.aliyuncs.com/spencerswagger/${part1}-${part2}"
        # 执行命令
        INCREMENTAL=true QUICKLY=true SYNC=true ./diff-image.sh "$image" "$target_image"
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

# 并行执行镜像同步
failed_count=0
success_count=0

for image in "${all_images[@]}"; do
    # 等待有空闲位置
    wait_for_jobs "$MAX_PARALLEL"
    
    # 在后台启动同步任务
    sync_image "$image" &
done

# 等待所有后台任务完成
wait

echo "任务完成" >&2