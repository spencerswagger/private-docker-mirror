#!/bin/bash

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
        
        # 使用 Docker Hub API 搜索匹配的镜像
        local search_url=""
        if [[ -n "$namespace" ]]; then
            search_url="https://hub.docker.com/v2/repositories/${namespace}/?page_size=100"
        else
            search_url="https://hub.docker.com/v2/repositories/library/?page_size=100"
        fi
        
        # 获取并过滤匹配的镜像
        local response=$(curl -s "$search_url")
        local results=$(echo "$response" | jq -r '.results[].name // empty' 2>/dev/null)
        
        # 过滤匹配模式的镜像名
        local regex_pattern="^${prefix//\*/.*}$"
        while IFS= read -r name; do
            if [[ "$name" =~ $regex_pattern ]]; then
                if [[ -n "$namespace" ]]; then
                    echo "${namespace}/${name}"
                else
                    echo "docker.io/library/${name}"
                fi
            fi
        done <<< "$results"
    else
        # 无通配符，原样输出
        echo "$pattern"
    fi
}

cat image.txt
while read -r line; do
    # 跳过空行和注释
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    # 标准化镜像名称（如果需要则添加 docker.io/library/ 前缀）
    normalized_line=$(normalize_image "$line")
    
    # 扩展通配符模式
    expanded_images=$(expand_wildcard "$normalized_line")
    
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        
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
        fi
    done <<< "$expanded_images"
done < image.txt

echo "任务完成" >&2