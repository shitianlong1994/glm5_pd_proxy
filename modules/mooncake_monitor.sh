#!/bin/bash
set -euo pipefail

ETCD_ENDPOINTS=""
MASTER_ADDR=""
OUTPUT_FILE=""
JSON_OUTPUT=""
LOOP_INTERVAL=0
TREND_INTERVAL=0
TREND_COUNT=0
ETCD_KEY="mooncake-store/mooncake/master_view"
TREND_DATA_FILE=""

show_help() {
    cat <<EOF
Usage: bash mooncake_monitor.sh [OPTIONS]

Mooncake Master Metrics Collector

Options:
  --etcd-endpoints ENDPOINTS   etcd endpoints, semicolon separated
  --master-addr ADDR           Skip etcd discovery, use master address directly (ip:port)
  -o, --output FILE            Output dashboard to file (default: stdout)
  --json-output FILE           Output JSON data to file
  --loop SECONDS               Run in loop mode with interval in seconds (default: 0, single run)
  --trend-interval SECONDS     Trend mode: collection interval in seconds (default: 30)
  --trend-count COUNT          Trend mode: number of collections (default: 10)
  -h, --help                   Show this help message

Examples:
  bash mooncake_monitor.sh --etcd-endpoints "etcd0:32379;etcd1:32379;etcd2:32379"
  bash mooncake_monitor.sh --master-addr 172.16.0.175:54050
  bash mooncake_monitor.sh --etcd-endpoints "etcd0:32379" -o dashboard.txt --json-output dashboard.json
  bash mooncake_monitor.sh --master-addr 172.16.0.175:54050 --loop 30 -o dashboard.txt
  bash mooncake_monitor.sh --master-addr 172.16.0.175:54050 --trend-interval 30 --trend-count 10

  Note: metrics port is auto-calculated as master service port + 2
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --etcd-endpoints)
            ETCD_ENDPOINTS="$2"; shift 2 ;;
        --master-addr)
            MASTER_ADDR="$2"; shift 2 ;;
        -o|--output)
            OUTPUT_FILE="$2"; shift 2 ;;
        --json-output)
            JSON_OUTPUT="$2"; shift 2 ;;
        --loop)
            LOOP_INTERVAL="$2"; shift 2 ;;
        --trend-interval)
            TREND_INTERVAL="$2"; shift 2 ;;
        --trend-count)
            TREND_COUNT="$2"; shift 2 ;;
        -h|--help)
            show_help; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; show_help; exit 1 ;;
    esac
done

if [ -z "$ETCD_ENDPOINTS" ] && [ -z "$MASTER_ADDR" ]; then
    ETCD_ENDPOINTS="etcd0311-0-0.etcd0311-0-headless.default.svc.cluster.local:32379;etcd0311-0-1.etcd0311-0-headless.default.svc.cluster.local:32379;etcd0311-0-2.etcd0311-0-headless.default.svc.cluster.local:32379"
fi

fmt_bytes() {
    local b=${1:-0}
    if [ "$b" = "N/A" ] || [ -z "$b" ]; then
        echo "N/A"
        return
    fi
    b=$(echo "$b" | awk '{printf "%.0f", $1+0}')
    if [ "$b" -ge 1099511627776 ] 2>/dev/null; then
        echo "$(awk "BEGIN{printf \"%.2f\", $b/1099511627776}") TB"
    elif [ "$b" -ge 1073741824 ] 2>/dev/null; then
        echo "$(awk "BEGIN{printf \"%.2f\", $b/1073741824}") GB"
    elif [ "$b" -ge 1048576 ] 2>/dev/null; then
        echo "$(awk "BEGIN{printf \"%.2f\", $b/1048576}") MB"
    else
        echo "$(awk "BEGIN{printf \"%.0f\", $b}") B"
    fi
}

fmt_pct() {
    local num=$1 den=$2
    if [ -z "$num" ] || [ -z "$den" ] || [ "$den" = "0" ] || [ "$num" = "N/A" ] || [ "$den" = "N/A" ]; then
        echo "N/A"
        return
    fi
    awk "BEGIN{printf \"%.2f%%\", $num/$den*100}"
}

discover_master() {
    local IFS=';'
    for ep in $ETCD_ENDPOINTS; do
        ep=$(echo "$ep" | sed 's|^etcd://||' | xargs)
        local host=$(echo "$ep" | cut -d: -f1)
        local port=$(echo "$ep" | cut -d: -f2)
        [ -z "$port" ] && port=2379

        local encoded_key=$(echo -n "$ETCD_KEY" | xxd -p | tr -d '\n' | sed 's/\(..\)/\\x\1/g')
        encoded_key=$(printf '%s' "$ETCD_KEY" | xxd -p | tr -d '\n')

        local result
        result=$(curl -s --max-time 5 "http://${host}:${port}/v3/kv/range" \
            -H "Content-Type: application/json" \
            -d "{\"key\":\"$(echo -n "$ETCD_KEY" | base64)\"}" 2>/dev/null) || continue

        local value_b64
        value_b64=$(echo "$result" | grep -o '"value":"[^"]*"' | head -1 | sed 's/"value":"//;s/"//')
        if [ -n "$value_b64" ]; then
            local addr
            addr=$(echo "$value_b64" | base64 -d 2>/dev/null || echo "$value_b64" | tr -d '"')
            if [ -n "$addr" ]; then
                echo "$addr"
                return 0
            fi
        fi
    done
    return 1
}

discover_master_etcdctl() {
    local IFS=';'
    for ep in $ETCD_ENDPOINTS; do
        ep=$(echo "$ep" | sed 's|^etcd://||' | xargs)
        local result
        result=$(ETCDCTL_API=3 etcdctl --endpoints="http://${ep}" get "$ETCD_KEY" --print-value-only 2>/dev/null) || continue
        if [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
    done
    return 1
}

fetch_metrics() {
    local master_addr=$1
    local ip=$(echo "$master_addr" | cut -d: -f1)
    local svc_port=$(echo "$master_addr" | cut -d: -f2)
    local metrics_port=$((svc_port + 2))
    curl -s --max-time 10 "http://${ip}:${metrics_port}/metrics" 2>/dev/null
}

get_metric() {
    local raw=$1 name=$2
    echo "$raw" | grep "^${name} " | awk '{print $2}' | head -1
}

get_metric_label() {
    local raw=$1 name=$2 label_key=$3 label_val=$4
    echo "$raw" | grep "^${name}{" | grep "${label_key}=\"${label_val}\"" | awk '{print $NF}' | head -1
}

count_metric_entries() {
    local raw=$1 name=$2
    echo "$raw" | grep -c "^${name}{" 2>/dev/null || echo 0
}

count_metric_gt_zero() {
    local raw=$1 name=$2
    echo "$raw" | awk "/^${name}\\{/{if(\$NF+0 > 0) c++} END{print c+0}"
}

build_dashboard() {
    local raw=$1 master_addr=$2
    local now=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S CST')

    local allocated capacity file_allocated file_capacity key_count soft_pin active_clients
    allocated=$(get_metric "$raw" "master_allocated_bytes")
    capacity=$(get_metric "$raw" "master_total_capacity_bytes")
    file_allocated=$(get_metric "$raw" "master_allocated_file_size_bytes")
    file_capacity=$(get_metric "$raw" "master_total_file_capacity_bytes")
    key_count=$(get_metric "$raw" "master_key_count")
    soft_pin=$(get_metric "$raw" "master_soft_pin_key_count")
    active_clients=$(get_metric "$raw" "master_active_clients")

    local seg_stats
    seg_stats=$(echo "$raw" | awk '
        /^segment_allocated_bytes\{/ {
            match($0, /segment="([^"]+)"/, m); seg=m[1];
            alloc[seg]=$NF+0
        }
        /^segment_total_capacity_bytes\{/ {
            match($0, /segment="([^"]+)"/, m); seg=m[1];
            cap[seg]=$NF+0
        }
        END {
            total=0; active=0; zombie=0
            for(seg in alloc) {
                if(alloc[seg]==0 && cap[seg]==0) { zombie++; continue }
                total++
                if(alloc[seg]>0) active++
            }
            idle=total-active
            printf "%d %d %d %d", total, active, idle, zombie
        }')
    local total_segs=$(echo "$seg_stats" | cut -d' ' -f1)
    local active_segs=$(echo "$seg_stats" | cut -d' ' -f2)
    local idle_segs=$(echo "$seg_stats" | cut -d' ' -f3)
    local zombie_segs=$(echo "$seg_stats" | cut -d' ' -f4)

    local node_stats_raw
    node_stats_raw=$(echo "$raw" | awk '
        /^segment_allocated_bytes\{/ {
            match($0, /segment="([^"]+)"/, m); seg=m[1]; ip=seg; sub(/:.*$/, "", ip);
            alloc_ip[ip]+=$NF; cnt_ip[ip]++; active_ip[ip]+=($NF+0>0?1:0)
        }
        /^segment_total_capacity_bytes\{/ {
            match($0, /segment="([^"]+)"/, m); seg=m[1]; ip=seg; sub(/:.*$/, "", ip);
            cap_ip[ip]+=$NF
        }
        END {
            valid=0; zombie=0
            for(ip in alloc_ip) {
                if(alloc_ip[ip]==0 && cap_ip[ip]==0) { zombie++; continue }
                valid++
            }
            printf "%d %d", valid, zombie
        }')
    local unique_nodes=$(echo "$node_stats_raw" | cut -d' ' -f1)
    local zombie_node_count=$(echo "$node_stats_raw" | cut -d' ' -f2)

    local attempted successful evicted_keys evicted_size discard_cnt release_cnt
    attempted=$(get_metric "$raw" "master_attempted_evictions_total")
    successful=$(get_metric "$raw" "master_successful_evictions_total")
    evicted_keys=$(get_metric "$raw" "master_evicted_key_count")
    evicted_size=$(get_metric "$raw" "master_evicted_size_bytes")
    discard_cnt=$(get_metric "$raw" "master_put_start_discard_cnt")
    release_cnt=$(get_metric "$raw" "master_put_start_release_cnt")

    local val_count val_sum
    val_count=$(get_metric "$raw" "master_value_size_bytes_count")
    val_sum=$(get_metric "$raw" "master_value_size_bytes_sum")

    {
        echo "================================================================================"
        echo "  Mooncake Master Monitoring Dashboard"
        echo "  Time: ${now}  |  Master: ${master_addr}"
        echo "================================================================================"
        echo ""
        echo "--- Storage Overview ---"
        echo "  Memory Storage:  $(fmt_bytes ${allocated:-0}) / $(fmt_bytes ${capacity:-0}) ($(fmt_pct ${allocated:-0} ${capacity:-1}))"
        echo "  File Storage:    $(fmt_bytes ${file_allocated:-0}) / $(fmt_bytes ${file_capacity:-0}) ($(fmt_pct ${file_allocated:-0} ${file_capacity:-1}))"
        echo "  Key Count:       ${key_count:-N/A}"
        echo "  Soft-Pinned:     ${soft_pin:-N/A}"
        echo "  Active Clients:  ${active_clients:-N/A}"
        echo ""
        echo "--- Segment Distribution ---"
        echo "  Total Segments:   ${total_segs}"
        echo "  Active Segments:  ${active_segs} ($(fmt_pct ${active_segs} ${total_segs}))"
        echo "  Idle Segments:    ${idle_segs} ($(fmt_pct ${idle_segs} ${total_segs}))"
        echo "  Unique Nodes:     ${unique_nodes}"
        echo "  Zombie Nodes:     ${zombie_node_count} (allocated=0, capacity=0, excluded from stats)"
        echo "  Zombie Segments:  ${zombie_segs} (excluded from stats)"
        echo ""

        # Per-node summary
        echo "  Per-Node Summary:"
        printf "  %-18s %10s %8s %14s %14s %8s\n" "IP" "Segments" "Active" "Allocated" "Capacity" "Usage"
        printf "  %-18s %10s %8s %14s %14s %8s\n" "------------------" "----------" "--------" "--------------" "--------------" "--------"

        local node_ips
        node_ips=$(echo "$raw" | awk '
            /^segment_allocated_bytes\{/ {
                match($0, /segment="([^"]+)"/, m); ip=m[1]; sub(/:.*$/, "", ip);
                alloc[ip]+=$NF; cnt[ip]++
            }
            /^segment_total_capacity_bytes\{/ {
                match($0, /segment="([^"]+)"/, m); ip=m[1]; sub(/:.*$/, "", ip);
                cap[ip]+=$NF
            }
            END{for(ip in alloc) if(alloc[ip]>0 || cap[ip]>0) print ip}' | sort)
        for ip in $node_ips; do
            local n_total=0 n_active=0 n_alloc=0 n_cap=0
            n_total=$(echo "$raw" | awk -v ip="$ip" '
                /^segment_allocated_bytes\{/ && $0 ~ "segment=\""ip":" {c++}
                END{print c+0}')
            n_active=$(echo "$raw" | awk -v ip="$ip" '
                /^segment_allocated_bytes\{/ && $0 ~ "segment=\""ip":" {if($NF+0>0) c++}
                END{print c+0}')
            n_alloc=$(echo "$raw" | awk -v ip="$ip" '
                /^segment_allocated_bytes\{/ && $0 ~ "segment=\""ip":" {s+=$NF}
                END{print s+0}')
            n_cap=$(echo "$raw" | awk -v ip="$ip" '
                /^segment_total_capacity_bytes\{/ && $0 ~ "segment=\""ip":" {s+=$NF}
                END{print s+0}')
            local usage=$(fmt_pct "$n_alloc" "$n_cap")
            printf "  %-18s %10d %8d %14s %14s %8s\n" "$ip" "$n_total" "$n_active" "$(fmt_bytes $n_alloc)" "$(fmt_bytes $n_cap)" "$usage"
        done

        echo ""
        echo "--- Request Statistics ---"
        printf "  %-20s %14s %12s %10s\n" "Request Type" "Total" "Failures" "Fail Rate"
        printf "  %-20s %14s %12s %10s\n" "--------------------" "--------------" "------------" "----------"

        local req_pairs="PutStart:master_put_start_requests_total:master_put_start_failures_total
PutEnd:master_put_end_requests_total:master_put_end_failures_total
PutRevoke:master_put_revoke_requests_total:master_put_revoke_failures_total
ExistKey:master_exist_key_requests_total:master_exist_key_failures_total
GetReplicaList:master_get_replica_list_requests_total:master_get_replica_list_failures_total
Remove:master_remove_requests_total:master_remove_failures_total
RemoveAll:master_remove_all_requests_total:master_remove_all_failures_total
Ping:master_ping_requests_total:master_ping_failures_total
MountSegment:master_mount_segment_requests_total:master_mount_segment_failures_total
UnmountSegment:master_unmount_segment_requests_total:master_unmount_segment_failures_total
RemountSegment:master_remount_segment_requests_total:master_remount_segment_failures_total"

        echo "$req_pairs" | while IFS=: read name req_m fail_m; do
            local rv=$(get_metric "$raw" "$req_m")
            local fv=$(get_metric "$raw" "$fail_m")
            rv=${rv:-0}; fv=${fv:-0}
            local fr="0%"
            [ "$rv" != "0" ] && [ -n "$rv" ] && fr=$(awk "BEGIN{printf \"%.4f%%\", $fv/$rv*100}")
            printf "  %-20s %14s %12s %10s\n" "$name" "$rv" "$fv" "$fr"
        done

        echo ""
        echo "--- Batch Request Statistics ---"
        printf "  %-24s %14s %12s %10s\n" "Request Type" "Total" "Failures" "Fail Rate"
        printf "  %-24s %14s %12s %10s\n" "------------------------" "--------------" "------------" "----------"

        local batch_pairs="BatchPutStart:master_batch_put_start_requests_total:master_batch_put_start_failures_total
BatchPutEnd:master_batch_put_end_requests_total:master_batch_put_end_failures_total
BatchPutRevoke:master_batch_put_revoke_requests_total:master_batch_put_revoke_failures_total
BatchExistKey:master_batch_exist_key_requests_total:master_batch_exist_key_failures_total
BatchGetReplicaList:master_batch_get_replica_list_requests_total:master_batch_get_replica_list_failures_total
BatchQueryIp:master_batch_query_ip_requests_total:master_batch_query_ip_failures_total
BatchReplicaClear:master_batch_replica_clear_requests_total:master_batch_replica_clear_failures_total
EvictDiskReplica:master_evict_disk_replica_requests_total:master_evict_disk_replica_failures_total"

        echo "$batch_pairs" | while IFS=: read name req_m fail_m; do
            local rv=$(get_metric "$raw" "$req_m")
            local fv=$(get_metric "$raw" "$fail_m")
            rv=${rv:-0}; fv=${fv:-0}
            local fr="0%"
            [ "$rv" != "0" ] && [ -n "$rv" ] && fr=$(awk "BEGIN{printf \"%.4f%%\", $fv/$rv*100}")
            printf "  %-24s %14s %12s %10s\n" "$name" "$rv" "$fv" "$fr"
        done

        echo ""
        echo "--- Eviction Statistics ---"
        echo "  Attempted Evictions:   ${attempted:-0}"
        echo "  Successful Evictions:  ${successful:-0}"
        echo "  Eviction Success Rate: $(fmt_pct ${successful:-0} ${attempted:-1})"
        echo "  Evicted Key Count:     ${evicted_keys:-N/A}"
        echo "  Evicted Size:          $(fmt_bytes ${evicted_size:-0})"
        echo "  PutStart Discard Cnt:  ${discard_cnt:-0}"
        echo "  PutStart Release Cnt:  ${release_cnt:-0}"

        local alloc_fail
        alloc_fail=$(get_metric "$raw" "master_put_start_alloc_failures_total")
        echo "  PutStart Alloc Fails:  ${alloc_fail:-0}"

        echo ""
        echo "--- HA Status ---"
        local ha_standby ha_transitions ha_oplog_lag ha_oplog_pending ha_mutation_queue
        ha_standby=$(get_metric "$raw" "ha_standby_state")
        ha_transitions=$(get_metric "$raw" "ha_state_transitions_total")
        ha_oplog_lag=$(get_metric "$raw" "ha_oplog_standby_lag")
        ha_oplog_pending=$(get_metric "$raw" "ha_oplog_pending_entries")
        ha_mutation_queue=$(get_metric "$raw" "ha_pending_mutation_queue_size")
        if [ -n "$ha_standby" ] || [ -n "$ha_transitions" ]; then
            local role="Primary"
            [ "${ha_standby:-0}" = "1" ] && role="Standby"
            echo "  Role:                ${role}"
            echo "  State Transitions:   ${ha_transitions:-0}"
            echo "  OpLog Standby Lag:   ${ha_oplog_lag:-N/A}"
            echo "  OpLog Pending:       ${ha_oplog_pending:-N/A}"
            echo "  Mutation Queue Size: ${ha_mutation_queue:-N/A}"
        else
            echo "  HA not configured (single master mode)"
        fi

        echo ""
        echo "--- Move/Copy Task Statistics ---"
        printf "  %-20s %14s %12s %10s\n" "Task Type" "Total" "Failures" "Fail Rate"
        printf "  %-20s %14s %12s %10s\n" "--------------------" "--------------" "------------" "----------"

        local task_pairs="MoveStart:master_move_start_requests_total:master_move_start_failures_total
MoveEnd:master_move_end_requests_total:master_move_end_failures_total
MoveRevoke:master_move_revoke_requests_total:master_move_revoke_failures_total
CopyStart:master_copy_start_requests_total:master_copy_start_failures_total
CopyEnd:master_copy_end_requests_total:master_copy_end_failures_total
CopyRevoke:master_copy_revoke_requests_total:master_copy_revoke_failures_total
CreateMoveTask:master_create_move_task_requests_total:master_create_move_task_failures_total
CreateCopyTask:master_create_copy_task_requests_total:master_create_copy_task_failures_total
FetchTasks:master_fetch_tasks_requests_total:master_fetch_tasks_failures_total
QueryTask:master_query_task_requests_total:master_query_task_failures_total
UpdateTask:master_update_task_requests_total:master_update_task_failures_total"

        echo "$task_pairs" | while IFS=: read name req_m fail_m; do
            local rv=$(get_metric "$raw" "$req_m")
            local fv=$(get_metric "$raw" "$fail_m")
            rv=${rv:-0}; fv=${fv:-0}
            local fr="0%"
            [ "$rv" != "0" ] && [ -n "$rv" ] && fr=$(awk "BEGIN{printf \"%.4f%%\", $fv/$rv*100}")
            printf "  %-20s %14s %12s %10s\n" "$name" "$rv" "$fv" "$fr"
        done

        echo ""
        echo "--- Value Size Distribution ---"
        if [ -n "$val_count" ] && [ "$val_count" != "0" ] && [ -n "$val_sum" ]; then
            local avg_val=$(awk "BEGIN{printf \"%.2f\", $val_sum/$val_count/1048576}")
            echo "  Total Values:  ${val_count}"
            echo "  Total Size:    $(fmt_bytes ${val_sum})"
            echo "  Avg Value:     ${avg_val} MB"
        else
            echo "  Total Values:  ${val_count:-N/A}"
        fi

        echo ""
        echo "================================================================================"
    }

    # JSON output
    if [ -n "$JSON_OUTPUT" ]; then
        local mem_usage=$(awk "BEGIN{printf \"%.2f\", ${allocated:-0}/${capacity:-1}*100}")
        local evict_rate=$(awk "BEGIN{printf \"%.2f\", ${successful:-0}/${attempted:-1}*100}")
        cat > "$JSON_OUTPUT" <<EOFJ
{
  "timestamp": "${now}",
  "master_address": "${master_addr}",
  "storage": {
    "memory_allocated_bytes": ${allocated:-0},
    "memory_capacity_bytes": ${capacity:-0},
    "memory_usage_pct": ${mem_usage},
    "file_allocated_bytes": ${file_allocated:-0},
    "file_capacity_bytes": ${file_capacity:-0},
    "key_count": ${key_count:-0},
    "soft_pinned_keys": ${soft_pin:-0},
    "active_clients": ${active_clients:-0}
  },
  "segments": {
    "total": ${total_segs},
    "active": ${active_segs},
    "idle": ${idle_segs},
    "unique_nodes": ${unique_nodes},
    "zombie_nodes": ${zombie_node_count},
    "zombie_segments": ${zombie_segs}
  },
  "eviction": {
    "attempted": ${attempted:-0},
    "successful": ${successful:-0},
    "success_rate_pct": ${evict_rate},
    "evicted_keys": ${evicted_keys:-0},
    "evicted_size_bytes": ${evicted_size:-0}
  }
}
EOFJ
        echo "JSON data written to ${JSON_OUTPUT}"
    fi
}

extract_trend_metrics() {
    local raw=$1
    local now=$(TZ='Asia/Shanghai' date '+%H:%M:%S')

    local allocated capacity key_count active_clients
    allocated=$(get_metric "$raw" "master_allocated_bytes")
    capacity=$(get_metric "$raw" "master_total_capacity_bytes")
    key_count=$(get_metric "$raw" "master_key_count")
    active_clients=$(get_metric "$raw" "master_active_clients")

    local seg_stats
    seg_stats=$(echo "$raw" | awk '
        /^segment_allocated_bytes\{/ {
            match($0, /segment="([^"]+)"/, m); seg=m[1];
            alloc[seg]=$NF+0
        }
        /^segment_total_capacity_bytes\{/ {
            match($0, /segment="([^"]+)"/, m); seg=m[1];
            cap[seg]=$NF+0
        }
        END {
            total=0; active=0
            for(seg in alloc) {
                if(alloc[seg]==0 && cap[seg]==0) continue
                total++
                if(alloc[seg]>0) active++
            }
            printf "%d %d", total, active
        }')
    local total_segs=$(echo "$seg_stats" | cut -d' ' -f1)
    local active_segs=$(echo "$seg_stats" | cut -d' ' -f2)

    local put_start put_end get_replica mount_seg evict_attempted evict_successful alloc_fail
    put_start=$(get_metric "$raw" "master_put_start_requests_total")
    put_end=$(get_metric "$raw" "master_put_end_requests_total")
    get_replica=$(get_metric "$raw" "master_get_replica_list_requests_total")
    mount_seg=$(get_metric "$raw" "master_mount_segment_requests_total")
    evict_attempted=$(get_metric "$raw" "master_attempted_evictions_total")
    evict_successful=$(get_metric "$raw" "master_successful_evictions_total")
    alloc_fail=$(get_metric "$raw" "master_put_start_alloc_failures_total")

    local mem_usage="0"
    allocated=${allocated:-0}
    capacity=${capacity:-0}
    key_count=${key_count:-0}
    active_clients=${active_clients:-0}
    put_start=${put_start:-0}
    put_end=${put_end:-0}
    get_replica=${get_replica:-0}
    mount_seg=${mount_seg:-0}
    evict_attempted=${evict_attempted:-0}
    evict_successful=${evict_successful:-0}
    alloc_fail=${alloc_fail:-0}
    total_segs=${total_segs:-0}
    active_segs=${active_segs:-0}
    if [ -n "$capacity" ] && [ "$capacity" != "0" ] && [ "$capacity" -gt 0 ] 2>/dev/null; then
        mem_usage=$(awk "BEGIN{printf \"%.2f\", ${allocated}/${capacity}*100}")
    fi

    echo "${now}|${allocated}|${capacity}|${mem_usage}|${key_count}|${active_clients}|${total_segs}|${active_segs}|${put_start}|${put_end}|${get_replica}|${mount_seg}|${evict_attempted}|${evict_successful}|${alloc_fail}"
}

build_trend_report() {
    local data_file=$1 master_addr=$2 interval=$3 count=$4
    local now=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S CST')

    {
        echo "================================================================================"
        echo "  Mooncake Master Trend Report"
        echo "  Time: ${now}  |  Master: ${master_addr}"
        echo "  Collection: ${count} samples @ ${interval}s interval (total ~$((interval * count))s)"
        echo "================================================================================"
        echo ""

        local n_lines
        n_lines=$(wc -l < "$data_file" 2>/dev/null || echo 0)
        if [ "$n_lines" -lt 1 ]; then
            echo "  No data collected."
            echo "================================================================================"
            return
        fi

        echo "--- Memory Usage Trend ---"
        printf "  %-10s %12s %12s %10s\n" "Time" "Allocated" "Capacity" "Usage%"
        printf "  %-10s %12s %12s %10s\n" "----------" "------------" "------------" "----------"
        while IFS='|' read ts alloc cap usage rest; do
            printf "  %-10s %12s %12s %10s\n" "$ts" "$(fmt_bytes $alloc)" "$(fmt_bytes $cap)" "${usage}%"
        done < "$data_file"

        echo ""
        echo "--- Segment Trend ---"
        printf "  %-10s %10s %10s\n" "Time" "Total" "Active"
        printf "  %-10s %10s %10s\n" "----------" "----------" "----------"
        while IFS='|' read ts _ _ _ _ _ total active rest; do
            printf "  %-10s %10s %10s\n" "$ts" "$total" "$active"
        done < "$data_file"

        echo ""
        echo "--- Key & Client Trend ---"
        printf "  %-10s %10s %10s\n" "Time" "Keys" "Clients"
        printf "  %-10s %10s %10s\n" "----------" "----------" "----------"
        while IFS='|' read ts _ _ _ keys clients rest; do
            printf "  %-10s %10s %10s\n" "$ts" "$keys" "$clients"
        done < "$data_file"

        echo ""
        echo "--- Request Rate Trend (requests/interval) ---"
        printf "  %-10s %10s %10s %10s %10s\n" "Time" "PutStart" "PutEnd" "GetReplL" "MountSeg"
        printf "  %-10s %10s %10s %10s %10s\n" "----------" "----------" "----------" "----------" "----------"

        local prev_put_start="" prev_put_end="" prev_get_rep="" prev_mount=""
        while IFS='|' read ts _ _ _ _ _ _ _ put_start put_end get_rep mount rest; do
            put_start=${put_start:-0}; put_end=${put_end:-0}; get_rep=${get_rep:-0}; mount=${mount:-0}
            if [ -z "$prev_put_start" ]; then
                printf "  %-10s %10s %10s %10s %10s\n" "$ts" "-" "-" "-" "-"
            else
                local d_ps=$((put_start - prev_put_start))
                local d_pe=$((put_end - prev_put_end))
                local d_gr=$((get_rep - prev_get_rep))
                local d_ms=$((mount - prev_mount))
                printf "  %-10s %10d %10d %10d %10d\n" "$ts" "$d_ps" "$d_pe" "$d_gr" "$d_ms"
            fi
            prev_put_start=$put_start
            prev_put_end=$put_end
            prev_get_rep=$get_rep
            prev_mount=$mount
        done < "$data_file"

        echo ""
        echo "--- Eviction & Failure Trend (delta per interval) ---"
        printf "  %-10s %10s %10s %10s\n" "Time" "EvictAtmp" "EvictSucc" "AllocFail"
        printf "  %-10s %10s %10s %10s\n" "----------" "----------" "----------" "----------"

        local prev_ea="" prev_es="" prev_af=""
        while IFS='|' read ts _ _ _ _ _ _ _ _ _ _ _ ea es af; do
            ea=${ea:-0}; es=${es:-0}; af=${af:-0}
            if [ -z "$prev_ea" ]; then
                printf "  %-10s %10s %10s %10s\n" "$ts" "-" "-" "-"
            else
                local d_ea=$((ea - prev_ea))
                local d_es=$((es - prev_es))
                local d_af=$((af - prev_af))
                printf "  %-10s %10d %10d %10d\n" "$ts" "$d_ea" "$d_es" "$d_af"
            fi
            prev_ea=$ea
            prev_es=$es
            prev_af=$af
        done < "$data_file"

        echo ""
        echo "--- Trend Summary ---"
        local first_line last_line
        first_line=$(head -1 "$data_file")
        last_line=$(tail -1 "$data_file")

        local f_alloc=0 f_cap=0 f_usage=0 f_keys=0 f_clients=0 f_total=0 f_active=0 f_ps=0 f_pe=0 f_gr=0 f_ms=0 f_ea=0 f_es=0 f_af=0
        IFS='|' read f_ts f_alloc f_cap f_usage f_keys f_clients f_total f_active f_ps f_pe f_gr f_ms f_ea f_es f_af <<< "$first_line"

        local l_alloc=0 l_cap=0 l_usage=0 l_keys=0 l_clients=0 l_total=0 l_active=0 l_ps=0 l_pe=0 l_gr=0 l_ms=0 l_ea=0 l_es=0 l_af=0
        IFS='|' read l_ts l_alloc l_cap l_usage l_keys l_clients l_total l_active l_ps l_pe l_gr l_ms l_ea l_es l_af <<< "$last_line"

        f_alloc=${f_alloc:-0}; f_keys=${f_keys:-0}; f_clients=${f_clients:-0}; f_active=${f_active:-0}
        f_ps=${f_ps:-0}; f_ea=${f_ea:-0}; f_af=${f_af:-0}
        l_alloc=${l_alloc:-0}; l_keys=${l_keys:-0}; l_clients=${l_clients:-0}; l_active=${l_active:-0}
        l_ps=${l_ps:-0}; l_ea=${l_ea:-0}; l_af=${l_af:-0}

        local d_alloc=$((l_alloc - f_alloc))
        local d_keys=$((l_keys - f_keys))
        local d_clients=$((l_clients - f_clients))
        local d_active=$((l_active - f_active))
        local d_ps=$((l_ps - f_ps))
        local d_ea=$((l_ea - f_ea))
        local d_af=$((l_af - f_af))

        echo "  Memory Alloc Delta:  $(fmt_bytes ${d_alloc#-}) (${d_alloc} bytes)"
        if [ "$d_alloc" -gt 0 ]; then
            echo "  Memory Trend:        INCREASING"
        elif [ "$d_alloc" -lt 0 ]; then
            echo "  Memory Trend:        DECREASING"
        else
            echo "  Memory Trend:        STABLE"
        fi

        echo "  Key Count Delta:     ${d_keys}"
        echo "  Active Segs Delta:   ${d_active}"
        echo "  Client Count Delta:  ${d_clients}"
        echo "  PutStart Total Delta:${d_ps}"
        echo "  Eviction Total Delta:${d_ea}"
        echo "  AllocFail Total Delta:${d_af}"

        if [ "$d_af" -gt 0 ]; then
            echo "  *** WARNING: ${d_af} new allocation failures detected during observation ***"
        fi
        if [ "$d_ea" -gt 0 ] && [ "$d_ps" -gt 0 ]; then
            local evict_pct=$(awk "BEGIN{printf \"%.2f\", $d_ea/$d_ps*100}")
            echo "  Eviction/PutStart:   ${evict_pct}% (eviction pressure indicator)"
        fi

        echo ""
        echo "================================================================================"
    }
}

main() {
    local master_addr="$MASTER_ADDR"
    if [ -z "$master_addr" ]; then
        master_addr=$(discover_master) || master_addr=$(discover_master_etcdctl) || {
            echo "ERROR: Failed to discover master address from etcd" >&2
            exit 1
        }
    fi

    if [ "$TREND_INTERVAL" -gt 0 ] && [ "$TREND_COUNT" -gt 0 ]; then
        TREND_DATA_FILE=$(mktemp 2>/dev/null || echo "/tmp/mooncake_trend_$$_$(date +%s)")
        trap "rm -f '$TREND_DATA_FILE'" EXIT
        : > "$TREND_DATA_FILE"

        echo "Trend mode: collecting ${TREND_COUNT} samples @ ${TREND_INTERVAL}s interval (total ~$((TREND_INTERVAL * TREND_COUNT))s)" >&2

        local i=0
        while [ "$i" -lt "$TREND_COUNT" ]; do
            local raw
            raw=$(fetch_metrics "$master_addr") || raw=""
            if [ -z "$raw" ]; then
                echo "WARN: Failed to fetch metrics at sample $((i+1))" >&2
            else
                extract_trend_metrics "$raw" >> "$TREND_DATA_FILE" || echo "WARN: Failed to parse sample $((i+1))" >&2
                echo "  Sample $((i+1))/${TREND_COUNT} collected" >&2
            fi

            i=$((i + 1))
            [ "$i" -lt "$TREND_COUNT" ] && sleep "$TREND_INTERVAL"
        done

        local last_raw
        last_raw=$(fetch_metrics "$master_addr") || last_raw=""

        if [ -n "$OUTPUT_FILE" ]; then
            if [ -n "$last_raw" ]; then
                build_dashboard "$last_raw" "$master_addr" > "$OUTPUT_FILE" || true
            fi
            build_trend_report "$TREND_DATA_FILE" "$master_addr" "$TREND_INTERVAL" "$TREND_COUNT" >> "$OUTPUT_FILE" || true
            echo "Dashboard + Trend report written to ${OUTPUT_FILE}"
        else
            if [ -n "$last_raw" ]; then
                build_dashboard "$last_raw" "$master_addr" || true
            fi
            build_trend_report "$TREND_DATA_FILE" "$master_addr" "$TREND_INTERVAL" "$TREND_COUNT" || true
        fi

        if [ -n "$JSON_OUTPUT" ]; then
            echo "WARN: --json-output not supported in trend mode, use single run or --loop mode" >&2
        fi

        return
    fi

    while true; do
        local raw
        raw=$(fetch_metrics "$master_addr")
        if [ -z "$raw" ]; then
            echo "ERROR: Failed to fetch metrics from ${master_addr}" >&2
            [ "$LOOP_INTERVAL" = "0" ] && exit 1
            sleep "$LOOP_INTERVAL"
            continue
        fi

        if [ -n "$OUTPUT_FILE" ]; then
            build_dashboard "$raw" "$master_addr" > "$OUTPUT_FILE"
            echo "Dashboard written to ${OUTPUT_FILE}"
        else
            build_dashboard "$raw" "$master_addr"
        fi

        [ "$LOOP_INTERVAL" = "0" ] && break
        sleep "$LOOP_INTERVAL"
    done
}

main

