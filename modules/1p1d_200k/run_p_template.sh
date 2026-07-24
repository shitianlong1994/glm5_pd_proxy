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

export OMP_PROC_BIND=false
export OMP_NUM_THREADS=1
export PYTHONHASHSEED=0
moon_cake_config=$(realpath ../../modules/mooncake.json)
export MOONCAKE_CONFIG_PATH=$moon_cake_config

export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE=256
export ACL_OP_INIT_MODE=1
export ASCEND_A3_ENABLE=1
export HCCL_INTRA_ROCE_ENABLE=1
export VLLM_NIXL_ABORT_REQUEST_TIMEOUT=300000

export ASCEND_RT_VISIBLE_DEVICES=$1
export VLLM_ASCEND_ENABLE_FLASHCOMM1=1
export VLLM_ASCEND_ENABLE_FUSED_MC2=1
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib

## export plog
export INFER_SERVICE_ID=`echo $HOSTNAME | awk -F'.' '{print $1}'`
ascend_log_dir=/mnt/sfs_turbo/logs/${INFER_SERVICE_ID}
rm -rf $ascend_log_dir
export ASCEND_PROCESS_LOG_PATH=/mnt/sfs_turbo/logs/${INFER_SERVICE_ID}/ascend

## export vllm env
VLLM_LOG_DIR=/mnt/sfs_turbo/logs/${INFER_SERVICE_ID}/vllm
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
    --speculative-config '{"num_speculative_tokens": 1, "method":"deepseek_mtp","enforce_eager":true}' \
    --profiler-config \
    '{"profiler": "torch",
    "torch_profiler_dir": "./vllm_profile",
    "torch_profiler_with_stack": false}' \
    --seed 1024 \
    --served-model-name glm-5 \
    --max-model-len 204800 \
    --additional-config '{"recompute_scheduler_enable" : false,"multistream_overlap_shared_expert": true, "enable_dsa_cp":true,"enable_sparse_sfa_c8": true, "enable_sparse_li_c8": true,"c8_enable_reshape_optim":false}' \
    --max-num-batched-tokens 8192 \
    --trust-remote-code \
    --max-num-seqs 64 \
    --async-scheduling \
    --enable-chunked-prefill \
    --enable-prefix-caching \
    --quantization ascend \
    --gpu-memory-utilization 0.9 \
    --enforce-eager \
    --disable-hybrid-kv-cache-manager \
    --enable-auto-tool-choice \
    --tool-call-parser glm47 \
    --reasoning-parser glm45 \
    --kv-transfer-config \
    '{
    "kv_connector": "MultiConnector",
    "kv_role": "kv_producer",
    "kv_load_failure_policy": "recompute",
    "kv_connector_extra_config": {
        "connectors": [
            {
                "kv_connector": "MooncakeConnectorV1",
                "kv_role": "kv_producer",
                "kv_port": "30000",
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
                "kv_role": "kv_producer",
                "kv_connector_extra_config": {
                    "lookup_rpc_port":"0",
                    "backend": "mooncake"
                }
            }
        ]
    }
    }' 2>&1 | tee >(grep --line-buffered -E "/metrics|/health|/models" >> "${VLLM_LOG_DIR}/metrics.log") >(grep --line-buffered -v -E "/metrics|/health|/models" >> "${VLLM_LOG_DIR}/vllm.log")
