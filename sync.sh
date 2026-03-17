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
        # 提取通配符前的前缀（去掉末尾的 *）
        local prefix="${pattern%\*}"
        local namespace=""
        local search_term=""
        
        # 解析镜像名格式
        # 格式 1: docker.io/library/alpine* -> namespace=library, search_term=alpine
        # 格式 2: docker.io/openlistteam/openlist* -> namespace=openlistteam, search_term=openlist
        # 格式 3: arm64v8/* -> namespace=arm64v8, search_term=*
        # 格式 4: library/* -> namespace=library, search_term=*
        
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
        
        # 使用 Docker Hub API 搜索匹配的镜像
        local search_url=""
        if [[ -n "$namespace" ]]; then
            search_url="https://hub.docker.com/v2/repositories/${namespace}/?page_size=100"
        else
            search_url="https://hub.docker.com/v2/repositories/library/?page_size=100"
        fi
        
        echo "正在搜索镜像：${search_url}" >&2
        
        # 获取并过滤匹配的镜像
        local response=""
        if command -v curl &> /dev/null; then
            response=$(curl -s "$search_url")
        elif command -v wget &> /dev/null; then
            response=$(wget -qO- "$search_url")
        else
            echo "错误：未找到 curl 或 wget，无法扩展通配符" >&2
            echo "$pattern"
            return
        fi
        
        if [[ -z "$response" ]]; then
            echo "警告：Docker Hub API 返回空响应，跳过通配符扩展" >&2
            echo "$pattern"
            return
        fi
        
        local results=""
        if command -v jq &> /dev/null; then
            results=$(echo "$response" | jq -r '.results[].name // empty' 2>/dev/null)
        else
            echo "警告：未安装 jq，使用 grep 解析 JSON" >&2
            results=$(echo "$response" | grep -oP '"name"\s*:\s*"\K[^"]+' || :)
        fi
        
        if [[ -z "$results" ]]; then
            echo "警告：未找到匹配的镜像，跳过通配符扩展" >&2
            echo "$pattern"
            return
        fi
        
        # 如果 search_term 为空或为 *，则返回所有镜像
        if [[ -z "$search_term" || "$search_term" == "*" ]]; then
            echo "匹配所有镜像" >&2
            local count=0
            while IFS= read -r name; do
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
            done <<< "$results"
            echo "找到 ${count} 个匹配的镜像" >&2
            return
        fi
        
        # 过滤匹配模式的镜像名
        local regex_pattern="^${search_term//\*/.*}$"
        echo "匹配模式：${regex_pattern}" >&2
        local count=0
        while IFS= read -r name; do
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
        done <<< "$results"
        echo "找到 ${count} 个匹配的镜像" >&2
    else
        # 无通配符，原样输出
        echo "$pattern"
    fi
}

cat image.txt
while read -r line; do
    # 跳过空行和注释
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    # 先扩展通配符模式（在标准化之前，因为通配符可能出现在任何位置）
    expanded_images=$(expand_wildcard "$line")
    
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        
        # 标准化镜像名称（如果需要则添加 docker.io/ 前缀）
        normalized_image=$(normalize_image "$image")
        
        echo "Start sync image $normalized_image" >&2
        
        # 使用正则表达式提取两部分内容
        if [[ $normalized_image =~ (.*)/(.*)/(.*) ]]; then
            part1=${BASH_REMATCH[2]}
            part2=${BASH_REMATCH[3]}
            # 转换为目标镜像名称
            target_image="registry.cn-hangzhou.aliyuncs.com/spencerswagger/${part1}-${part2}"
            # 执行命令
            INCREMENTAL=true QUICKLY=true SYNC=true ./diff-image.sh "$normalized_image" "$target_image"
        else
            echo "无效的镜像名称：$normalized_image" >&2
        fi
    done <<< "$expanded_images"
done < image.txt

echo "任务完成" >&2