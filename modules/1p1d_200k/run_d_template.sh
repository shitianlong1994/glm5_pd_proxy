#!/bin/bash

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

export HCCL_OP_EXPANSION_MODE="AIV"
export OMP_PROC_BIND=false
export OMP_NUM_THREADS=1

export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE=512

export ASCEND_AGGREGATE_ENABLE=1
export ASCEND_TRANSPORT_PRINT=1
export ACL_OP_INIT_MODE=1
export ASCEND_A3_ENABLE=1

export HCCL_INTRA_ROCE_ENABLE=1
export VLLM_NIXL_ABORT_REQUEST_TIMEOUT=300000
export PYTHONHASHSEED=0
moon_cake_config=$(realpath ../../modules/mooncake.json)
export MOONCAKE_CONFIG_PATH=$moon_cake_config


export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib

## export plog
export INFER_SERVICE_ID=`echo $HOSTNAME | awk -F'.' '{print $1}'`
ascend_log_dir=/mnt/sfs_turbo/logs/${INFER_SERVICE_ID}/
rm -rf $ascend_log_dir
export ASCEND_PROCESS_LOG_PATH=/mnt/sfs_turbo/logs/${INFER_SERVICE_ID}/ascend

export TASK_QUEUE_ENABLE=1
export ASCEND_RT_VISIBLE_DEVICES=$1
export VLLM_ASCEND_ENABLE_FUSED_MC2=1

## export vllm env
VLLM_LOG_DIR=/mnt/sfs_turbo/logs/${INFER_SERVICE_ID}/${INFER_INSTANCE_ID}/vllm
mkdir -p ${VLLM_LOG_DIR}

vllm serve /mnt/sfs_turbo_glm5/model/GLM-5.2-w4a8c8-0716/ \
    --host 0.0.0.0 \
    --port $2 \
    --data-parallel-size $3 \
    --data-parallel-rank $4 \
    --data-parallel-address $5 \
    --data-parallel-rpc-port $6 \
    --tensor-parallel-size $7 \
    --enable-expert-parallel \
    --profiler-config \
    '{"profiler": "torch",
    "torch_profiler_dir": "./vllm_profile",
    "torch_profiler_with_stack": false}' \
    --seed 1024 \
    --served-model-name glm-5 \
    --disable-hybrid-kv-cache-manager \
    --max-model-len 204800 \
    --max-num-batched-tokens 128 \
    --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY"}' \
    --additional-config '{"recompute_scheduler_enable": true, "enable_sparse_sfa_c8": true, "enable_sparse_li_c8": true}' \
    --trust-remote-code \
    --speculative-config '{"num_speculative_tokens": 5, "method":"deepseek_mtp","enforce_eager":true}' \
    --max-num-seqs 48 \
    --gpu-memory-utilization 0.92 \
    --async-scheduling \
    --quantization ascend \
    --enable-auto-tool-choice \
    --tool-call-parser glm47 \
    --reasoning-parser glm45 \
    --kv-transfer-config \
    '{
    "kv_connector": "MultiConnector",
    "kv_role": "kv_consumer",
    "kv_load_failure_policy": "recompute",
    "kv_connector_extra_config": {
        "connectors": [
        {
                "kv_connector": "MooncakeConnectorV1",
                "kv_role": "kv_consumer",
                "kv_port": "30200",
                "kv_connector_extra_config": {
                    "prefill": {
                        "dp_size": 2,
                        "tp_size": 8
                    },
                    "decode": {
                        "dp_size": 8,
                        "tp_size": 2
                    }
                }
            },
            {
                "kv_connector": "AscendStoreConnector",
                "kv_role": "kv_consumer",
                "kv_connector_extra_config": {
                    "lookup_rpc_port":"0",
                    "backend": "mooncake"
                }
            }
        ]
    }
    }' 2>&1 | tee >(grep --line-buffered -E "/metrics|/health|/models" >> "${VLLM_LOG_DIR}/metrics.log") >(grep --line-buffered -v -E "/metrics|/health|/models" >> "${VLLM_LOG_DIR}/vllm.log")

