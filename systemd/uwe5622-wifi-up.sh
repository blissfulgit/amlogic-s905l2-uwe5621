#!/bin/sh
# UWE5621 WiFi bring-up
#
# 注意：必须在系统基本启动完成后再加载。
# 启动早期（sysinit / modules-load.d 阶段）加载会导致 CP2 固件起不来：
#   WCN_ERR: didn't get CP2 version
#   uwe5622_bsp_sdio: probe failed with error -1
# 这是因为 sdio-pwrseq 的 regulator 与 mmc 控制器尚未就绪。

set -u

# 已经起来了就什么都不做（幂等，允许重复执行）
[ -d /sys/class/net/wlan0 ] && exit 0

# 1. 加载 BSP 驱动（内部会拉 sdio-pwrseq 的 reset-gpios 给芯片上电）
modprobe uwe5622_bsp_sdio || exit 1

# 2. 等芯片固件下载完成。WCN 固件约 5s 下完，抢跑会失败
sleep 5

# 3. 加载 WiFi 协议栈驱动
modprobe sprdwl_ng || exit 1

# 4. 等 wlan0 出现（最多 30s）
i=0
while [ $i -lt 30 ]; do
    [ -d /sys/class/net/wlan0 ] && break
    sleep 1
    i=$((i+1))
done
[ -d /sys/class/net/wlan0 ] || exit 1

# 5. 配置监管域 / 解除 rfkill / 拉起接口
iw reg set CN 2>/dev/null || true
rfkill unblock wifi 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true

exit 0
