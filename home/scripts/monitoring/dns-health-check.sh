#!/bin/bash
# DNS Health Check Script
# Monitors Pi-hole, Unbound, and Avahi services

set -euo pipefail

LOG_FILE="/var/log/dns-health.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

log_message() {
    echo "[$TIMESTAMP] $1" >> "$LOG_FILE"
    echo "[$TIMESTAMP] $1"
}

check_service() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        log_message "✓ $service is running"
        return 0
    else
        log_message "✗ $service is not running"
        return 1
    fi
}

check_dns_resolution() {
    local test_domain=$1
    local dns_server=$2
    if ! command -v dig >/dev/null 2>&1; then
        log_message "✗ dig command not found; install dnsutils"
        return 1
    fi
    if dig @"$dns_server" "$test_domain" +short >/dev/null 2>&1; then
        log_message "✓ DNS resolution working for $test_domain via $dns_server"
        return 0
    else
        log_message "✗ DNS resolution failed for $test_domain via $dns_server"
        return 1
    fi
}

check_sysctl_min() {
    local key=$1
    local min_value=$2
    local path="/proc/sys/${key//./\/}"

    if [[ ! -r "$path" ]]; then
        log_message "⚠ Unable to read kernel tunable $key at $path"
        return 0
    fi

    local current
    current=$(<"$path")
    if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= min_value )); then
        log_message "✓ $key=$current (>= $min_value)"
        return 0
    fi

    log_message "⚠ $key=$current (expected >= $min_value)"
    return 0
}

check_cpu_governor() {
    # The image boots with cpufreq.default_governor=schedutil (cmdline.txt).
    local expected="schedutil"
    local total=0
    local matching=0

    for governor_file in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -r "$governor_file" ]] || continue
        total=$((total + 1))
        if grep -q "^${expected}\$" "$governor_file"; then
            matching=$((matching + 1))
        fi
    done

    if [[ $total -eq 0 ]]; then
        log_message "ℹ CPU governor files unavailable on this platform"
        return 0
    fi

    if [[ $matching -eq $total ]]; then
        log_message "✓ CPU governors in $expected mode ($matching/$total)"
    else
        log_message "⚠ CPU governors in $expected mode ($matching/$total)"
    fi
}

check_unbound_cache_stats() {
    if ! command -v unbound-control >/dev/null 2>&1; then
        log_message "ℹ unbound-control not found; skipping cache stats"
        return 0
    fi

    # Unbound emits these as total.num.cachehits / total.num.cachemiss.
    local stats hits misses
    stats=$(unbound-control stats_noreset 2>/dev/null)
    hits=$(awk -F= '/^total\.num\.cachehits=/{print $2; exit}' <<< "$stats")
    misses=$(awk -F= '/^total\.num\.cachemiss=/{print $2; exit}' <<< "$stats")

    if [[ -n "$hits" && -n "$misses" ]]; then
        log_message "ℹ Unbound cache stats: hits=$hits misses=$misses"
    else
        log_message "⚠ Unable to read Unbound cache stats"
    fi
}

main() {
    local failures=0

    log_message "Starting DNS health check"

    # Check critical services
    check_service "pihole-FTL" || failures=$((failures + 1))
    check_service "unbound" || failures=$((failures + 1))
    check_service "avahi-daemon" || failures=$((failures + 1))
    check_service "systemd-resolved" || failures=$((failures + 1))

    # Check DNS resolution
    check_dns_resolution "google.com" "127.0.0.1" || failures=$((failures + 1))
    check_dns_resolution "github.com" "127.0.0.1" || failures=$((failures + 1))

    # Performance observability checks (informational)
    check_sysctl_min "net.core.rmem_max" 33554432
    check_sysctl_min "net.core.wmem_max" 33554432
    check_sysctl_min "net.core.netdev_max_backlog" 4096
    check_cpu_governor
    check_unbound_cache_stats

    # Check local mDNS
    if ! command -v avahi-resolve-host-name >/dev/null 2>&1; then
        log_message "✗ avahi-resolve-host-name command not found. Install avahi-utils if desired."
        failures=$((failures + 1))
    elif avahi-resolve-host-name "$(hostname).local" >/dev/null 2>&1; then
        log_message "✓ mDNS resolution working"
    else
        log_message "✗ mDNS resolution failed"
        failures=$((failures + 1))
    fi

    if [[ $failures -eq 0 ]]; then
        log_message "DNS health check completed with no failures"
        return 0
    fi

    log_message "DNS health check completed with $failures failure(s)"
    return 1
}

main "$@"