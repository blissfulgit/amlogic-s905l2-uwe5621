#!/bin/sh
# hw-ready-check.sh -- 硬件就绪闸门
#
# 依次探测 SDIO 芯片 / wlan0 / WiFi 驱动响应 / hci0 / 有线链路 / 温度传感器。
# 全部通过 -> STATE ready；任一超时 -> STATE degraded（仍然放行，但如实标记）。
#
# 设计原则：
#   - 不用固定 sleep 猜时间，逐项等真实条件
#   - 超时不锁死系统（无头盒子锁死就再也进不去）
#   - 结果落盘到 /run/hardware-status，便于事后核对每一阶段耗时

STATUS=/run/hardware-status
READY=/run/hardware-ready
DEGRADED=0

_now() { cut -d. -f1 /proc/uptime 2>/dev/null || echo 0; }
T0=$(_now)
_el() { echo "$(( $(_now) - T0 ))s"; }
mark() { printf '%-8s %-14s %s\n' "$1" "$2" "$(_el)" >> "$STATUS"; }

wait_for() {
    _name=$1; _limit=$2; shift 2
    _i=0
    while [ "$_i" -lt "$_limit" ]; do
        if "$@" >/dev/null 2>&1; then
            mark OK "$_name"
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    mark TIMEOUT "$_name"
    DEGRADED=1
    return 1
}

chk_sdio()       { lsmod | grep -q '^uwe5622_bsp_sdio'; }
chk_netdev()     { [ -e /sys/class/net/wlan0 ]; }
chk_wifi_ioctl() { iw dev wlan0 info 2>/dev/null | grep -q 'Interface wlan0'; }
chk_hci()        { hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'; }
chk_eth()        { [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ]; }

mkdir -p /run
: > "$STATUS"
rm -f "$READY"

# --- WiFi 链路（蓝牙依赖它，必须先过） ---
wait_for sdio       30 chk_sdio
wait_for wlan0      45 chk_netdev
wait_for wifi-ioctl 20 chk_wifi_ioctl

# --- 蓝牙：确保 tty 节点存在，拉起 btattach，再等 hci0 UP ---
[ -e /dev/ttyBT0 ] || modprobe sprdbt_tty >/dev/null 2>&1
systemctl is-active --quiet btattach.service || systemctl start --no-block btattach.service
wait_for hci0 45 chk_hci

# --- 有线链路（无载波属正常，仅记录，不算失败） ---
if chk_eth; then mark OK eth-link; else mark SKIP eth-nocarrier; fi

# --- 温度传感器 ---
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    mark OK thermal
else
    mark SKIP thermal
    DEGRADED=1
fi

if [ "$DEGRADED" -eq 0 ]; then
    printf 'STATE    ready          %s\n' "$(_el)" >> "$STATUS"
else
    printf 'STATE    degraded       %s\n' "$(_el)" >> "$STATUS"
fi
touch "$READY"
exit 0
