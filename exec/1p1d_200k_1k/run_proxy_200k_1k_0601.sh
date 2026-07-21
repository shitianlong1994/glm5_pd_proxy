#!/bin/bash

# 使用方法: ./run_proxy_simple.sh <P节点IP> <D节点IP>
# 示例: ./run_proxy_simple.sh 192.168.0.55 192.168.0.175

# 检查参数

read node_p_ip node_d_ip <<< $(PYTHONUNBUFFERED=1 python ../../modules/get_ips.py)

PREFILL_REPEAT=2      # P节点重复次数（2个P实例）
DECODER_REPEAT=8      # D节点重复次数（8个D实例）

# 自动生成参数
prefiller_hosts=""
for i in $(seq 1 $PREFILL_REPEAT); do
    prefiller_hosts="$prefiller_hosts $node_p_ip"
done

decoder_hosts=""
for i in $(seq 1 $DECODER_REPEAT); do
    decoder_hosts="$decoder_hosts $node_d_ip"
done

echo $prefiller_hosts
echo $decoder_hosts


echo ""
echo "=========================================="
echo "Proxy 配置"
echo "=========================================="
echo "P节点: $P_IP (重复${PREFILL_REPEAT}次)"
echo "D节点: $D_IP (重复${DECODER_REPEAT}次)"
echo "=========================================="
echo ""

# 取消代理
unset http_proxy
unset https_proxy

export INFER_SERVICE_ID=`echo $HOSTNAME | awk -F'-' '{print $6}'`
export INFER_INSTANCE_ID=`echo $HOSTNAME | awk -F'-' '{print $(NF-3)"-"$(NF-2)"-"$(NF-1)"-"$NF}'`

## export vllm env
VLLM_LOG_DIR=/mnt/sfs_turbo/logs/${INFER_SERVICE_ID}/${INFER_INSTANCE_ID}/vllm
mkdir -p "$VLLM_LOG_DIR"

# 启动proxy
python ../../modules/1p1d_200k/load_balance_proxy_server_example.py \
    --port 8077 \
    --host 0.0.0.0 \
    --prefiller-hosts $prefiller_hosts \
    --prefiller-ports 6700 6701 \
    --decoder-hosts $decoder_hosts \
    --decoder-ports 6721 6722 6723 6724 6725 6726 6727 6728 2>&1|tee -a "${VLLM_LOG_DIR}/proxy.log"
