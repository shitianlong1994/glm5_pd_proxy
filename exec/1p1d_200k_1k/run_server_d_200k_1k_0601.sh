#!/bin/bash

# 清理旧进程
ps -ef|grep VLLM|awk '{print $2}'|xargs -I {} kill -9 {}

# 创建IP和网卡变量
nic_name=""
local_ip=""

# 检测以192开头的IP及对应网卡名并赋值
for nic in $(ifconfig | grep -E '^[a-z0-9]+:' | grep -v lo | awk -F':' '{print $1}'); do
    ip=$(ifconfig $nic | grep -E 'inet ' | awk '{print $2}' | grep '^192\.')
    if [ -n "$ip" ]; then
        nic_name=$nic
        local_ip=$ip
        break
    fi
done

if [ -z "$nic_name" ]; then
    nic_name=$(ifconfig | grep -E '^[a-z0-9]+:' | grep -v lo | head -n1 | awk -F':' '{print $1}')
    local_ip=$(ifconfig $nic_name | grep -E 'inet ' | awk '{print $2}' | head -n1)
fi

echo "使用网卡: $nic_name"
echo "使用IP: $local_ip"

# 使能所有所需环境变量
export GLOO_SOCKET_IFNAME=$nic_name
export TP_SOCKET_IFNAME=$nic_name

export HCCL_IF_IP=$local_ip
export HCCL_SOCKET_IFNAME=$nic_name

# 根据 RUN_DCP 环境变量选择 base 或 DCP 配置参数
if [ -n "$RUN_DCP" ]; then
    echo "RUN_DCP is set, using DCP configuration"
    python ../../modules/1p1d_200k/launch_online_d.py \
        --dp-size 4 \
        --tp-size 4 \
        --dp-size-local 4 \
        --dp-rank-start 0 \
        --dp-address "$local_ip" \
        --dp-rpc-port 10523 \
        --vllm-start-port 6721 \
        --nic_name "$nic_name"
else
    echo "RUN_DCP is not set, using base configuration"
    python  ../../modules/1p1d_200k/launch_online_d.py \
        --dp-size 8 \
        --tp-size 2 \
        --dp-size-local 8 \
        --dp-rank-start 0 \
        --dp-address "$local_ip" \
        --dp-rpc-port 10523 \
        --vllm-start-port 6721 \
        --nic_name "$nic_name"
fi
