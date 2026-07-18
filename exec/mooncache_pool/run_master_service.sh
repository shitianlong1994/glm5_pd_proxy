config_path=$(realpath ../../modules/mooncake.json)
host_ip="${1:-192.168.0.48}"
port=50088  
if [[ ! -f "$config_path" ]]; then
    echo "错误: 配置文件不存在: $config_path"
    exit 1
fi

sed -i 's/"master_server_address": "[^"]*"/"master_server_address": "'"${host_ip}"':'"${port}"'"/' $config_path

mooncake_master --port $port --eviction_high_watermark_ratio 0.9 --eviction_ratio 0.1 --default_kv_lease_ttl 11000