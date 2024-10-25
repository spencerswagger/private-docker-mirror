#!/bin/bash
cat image.txt
while read -r line; do
    echo "Start sync image $line" >&2
    # 使用正则表达式提取两部分内容
    if [[ $line =~ (.*)/(.*) ]]; then
        part1=${BASH_REMATCH[1]}
        part2=${BASH_REMATCH[2]}
        # 转换为目标镜像名称
        target_image="registry.cn-hangzhou.aliyuncs.com/spencerswagger/${part1}-${part2}"
        # 执行命令
        INCREMENTAL=true QUICKLY=true SYNC=true ./diff-image.sh "$line" "$target_image"
    else
        echo "Invalid image name: $line" >&2
    fi
done < image.txt

echo "Task Completed" >&2