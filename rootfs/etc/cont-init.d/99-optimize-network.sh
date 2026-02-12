#!/bin/bash
# Network performance tuning for Backblaze upload throughput.
# These settings optimize TCP for large file uploads over WAN connections.
# Most require elevated privileges (--privileged or --sysctl Docker flags).

set -euo pipefail

if [ "${OPTIMIZE_NETWORK:-true}" != "true" ]; then
    echo "Network optimization disabled (OPTIMIZE_NETWORK!=true)"
    exit 0
fi

echo "Applying network performance optimizations..."

apply_sysctl() {
    local key="$1"
    local value="$2"
    if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
        echo "  Applied: ${key}=${value}"
    else
        echo "  Skipped: ${key} (needs --privileged or --sysctl ${key}=${value})"
    fi
}

# Increase max socket buffer sizes to 16MB.
# Default Linux values (212992) are too small for high-throughput WAN uploads.
apply_sysctl net.core.rmem_max 16777216
apply_sysctl net.core.wmem_max 16777216

# Widen TCP autotuning range: min=4KB, default=256KB, max=16MB.
# Larger buffers allow TCP to fill high-bandwidth, high-latency pipes.
apply_sysctl net.ipv4.tcp_rmem "4096 262144 16777216"
apply_sysctl net.ipv4.tcp_wmem "4096 262144 16777216"

# Disable slow start restart after idle periods.
# Backblaze uploads are bursty (10MB chunks); without this, throughput drops
# to near-zero between chunks and has to ramp back up.
apply_sysctl net.ipv4.tcp_slow_start_after_idle 0

# Enable TCP window scaling (RFC 1323) for windows > 64KB.
apply_sysctl net.ipv4.tcp_window_scaling 1

# Enable MTU probing to avoid fragmentation on paths with smaller MTUs.
apply_sysctl net.ipv4.tcp_mtu_probing 1

# Enable BBR congestion control if available.
# BBR models the network path instead of reacting to loss, yielding
# significantly better throughput for upload-heavy workloads.
if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    apply_sysctl net.ipv4.tcp_congestion_control bbr
    apply_sysctl net.core.default_qdisc fq
elif modprobe tcp_bbr 2>/dev/null && grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    apply_sysctl net.ipv4.tcp_congestion_control bbr
    apply_sysctl net.core.default_qdisc fq
else
    echo "  Skipped: BBR congestion control (module not available)"
fi

# Increase the network device backlog for bursty traffic.
apply_sysctl net.core.netdev_max_backlog 5000

echo "Network optimization complete."
