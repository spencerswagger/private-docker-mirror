#!/bin/bash

while read -r line; do
    # 使用正则表达式提取两部分内容
    if [[ $line =~ (.*)/(.*) ]]; then
        part1=${BASH_REMATCH[1]}
        part2=${BASH_REMATCH[2]}
        # 转换为目标镜像名称
        target_image="registry.cn-hangzhou.aliyuncs.com/spencerswagger/${part1}-${part2}"
        # 执行命令
        INCREMENTAL=true QUICKLY=true SYNC=true ./diff-image.sh "$line" "$target_image"
    else
        echo "Invalid image name: $line"
    fi
done < image.txt