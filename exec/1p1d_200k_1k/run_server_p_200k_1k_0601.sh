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

export HCCL_CONNECT_TIMEOUT=1800
export HCCL_EXEC_TIMEOUT=3000
export HCCL_BUFFSIZE=256
export HCCL_OP_EXPANSION_MODE="AIV"
export HCCL_INTRA_ROCE_ENABLE=1

export VLLM_ENGINE_READY_TIMEOUT_S=3600
export CUDA_LAUNCH_BLOCKING=1
export VLLM_ENGINE_DEBUG_LOGGING=1
export OMP_PROC_BIND=false
export OMP_NUM_THREADS=1
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True

export VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT=480
export ASCEND_AGGREGATE_ENABLE=1
export ASCEND_TRANSPORT_PRINT=1
export ACL_OP_INIT_MODE=1
export ASCEND_A3_ENABLE=1

#export ASCEND_BUFFER_POOL=4:8
export PYTHONHASHSEED=1234
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib:/usr/local/lib64
export LD_LIBRARY_PATH=/usr/local/Ascend/ascend-toolkit/latest/python/site-packages:$LD_LIBRARY_PATH
#export LD_LIBRARY_PATH=/usr/local/Ascend/cann-8.5.1/python/site-packages/mooncake:$LD_LIBRARY_PATH
#export PYTHONPATH=$PYTHONPATH:/vllm-workspace/vllm

#export MC_TRANSFER_TIMEOUT=120
#export MOONCAKE_TRANSFER_TIMEOUT=120
#export MOONCAKE_CONNECT_TIMEOUT_MS=60000

export VLLM_ASCEND_ENABLE_FLASHCOMM1=1

# 执行拉起python脚本
python  ../../modules/1p1d_200k/launch_online_p.py \
    --dp-size 2 \
    --tp-size 8 \
    --dp-size-local 2 \
    --dp-rank-start 0 \
    --dp-address "$local_ip" \
    --dp-rpc-port 10521 \
    --vllm-start-port 6700 \
    --nic_name "$nic_name"
