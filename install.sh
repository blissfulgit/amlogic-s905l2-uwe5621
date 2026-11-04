#!/bin/sh
# install.sh -- 安装 S905L2 UWE5621 WiFi/BT 支持
#
# 用法:
#   sudo ./install.sh              # 只装文件与单元
#   sudo ./install.sh --set-fdt    # 同时把启动配置的 FDT 指向 -uwe.dtb（会备份）
#
# 注意: 装完必须断电冷启。这类盒子的热复位会让 DDR/eMMC 状态残留，
#       表现为「有时候起不来」。详见 docs/BOOT-RELIABILITY.md

set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
SET_FDT=0
[ "${1:-}" = "--set-fdt" ] && SET_FDT=1

DTB_NAME="meson-gxl-s905l2-x7-5g-uwe.dtb"
DTB_DIR="/boot/dtb/amlogic"

info() { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要用 root 运行"
[ -d "$DTB_DIR" ] || die "$DTB_DIR 不存在 —— 这不是 ophub/armbian 的 amlogic 镜像？"

# ---------------------------------------------------------------------------
# 0. 平台检查
# ---------------------------------------------------------------------------
COMPAT=$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || echo "")
case "$COMPAT" in
    *amlogic,s905l2*) ok "检测到 S905L2（$COMPAT）" ;;
    *amlogic,meson-gxl*) warn "检测到 GXL 家族但不是 s905l2：$COMPAT —— 继续，但 DTB 可能不匹配" ;;
    *) warn "未识别的平台（$COMPAT）—— 继续，请自行确认 DTB" ;;
esac

# ---------------------------------------------------------------------------
# 1. DTB
# ---------------------------------------------------------------------------
install -m644 "$SRC/dts/$DTB_NAME" "$DTB_DIR/$DTB_NAME"
ok "DTB -> $DTB_DIR/$DTB_NAME"

# ---------------------------------------------------------------------------
# 2. 模块参数
# ---------------------------------------------------------------------------
install -D -m644 "$SRC/modprobe/uwe5622-sdio.conf" /etc/modprobe.d/uwe5622.conf
install -D -m644 "$SRC/modprobe/uwe5622-load.conf" /etc/modules-load.d/uwe5622.conf
ok "modprobe.d / modules-load.d"

# ---------------------------------------------------------------------------
# 3. 脚本
# ---------------------------------------------------------------------------
install -D -m755 "$SRC/systemd/uwe5622-wifi-up.sh" /usr/local/sbin/uwe5622-wifi-up.sh
install -D -m755 "$SRC/systemd/hw-ready-check.sh"  /usr/local/sbin/hw-ready-check.sh
install -D -m755 "$SRC/systemd/hw-ready-wait"      /usr/local/bin/hw-ready-wait
install -D -m644 "$SRC/systemd/hw-ready-notice.sh" /etc/profile.d/hw-ready-notice.sh
ok "脚本 -> /usr/local/sbin, /usr/local/bin, /etc/profile.d"

# ---------------------------------------------------------------------------
# 4. systemd 单元
# ---------------------------------------------------------------------------
for u in uwe5622-wifi.service btattach.service hw-ready.service hw-ready.timer uwe5622-bt-fallback.timer; do
    install -D -m644 "$SRC/systemd/$u" "/etc/systemd/system/$u"
done
ok "systemd 单元"

systemctl daemon-reload
systemctl enable uwe5622-wifi.service hw-ready.timer uwe5622-bt-fallback.timer >/dev/null 2>&1
# btattach 必须是 static，不能有 multi-user.target.wants 链接
systemctl disable btattach.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/multi-user.target.wants/btattach.service
ok "已 enable: uwe5622-wifi / hw-ready.timer / bt-fallback.timer"

# ---------------------------------------------------------------------------
# 5. 启动配置里的 FDT
# ---------------------------------------------------------------------------
if [ "$SET_FDT" -eq 1 ]; then
    FDT_PATH="/dtb/amlogic/$DTB_NAME"
    CHANGED=0

    if [ -f /boot/uEnv.txt ] && grep -q '^FDT=' /boot/uEnv.txt; then
        cp -f /boot/uEnv.txt "/boot/uEnv.txt.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "s|^FDT=.*|FDT=$FDT_PATH|" /boot/uEnv.txt
        ok "uEnv.txt: FDT=$FDT_PATH"
        CHANGED=1
    fi

    if [ -f /boot/armbianEnv.txt ] && grep -q '^fdtfile=' /boot/armbianEnv.txt; then
        cp -f /boot/armbianEnv.txt "/boot/armbianEnv.txt.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "s|^fdtfile=.*|fdtfile=amlogic/$DTB_NAME|" /boot/armbianEnv.txt
        ok "armbianEnv.txt: fdtfile=amlogic/$DTB_NAME"
        CHANGED=1
    fi

    [ "$CHANGED" -eq 1 ] || warn "没找到 uEnv.txt/armbianEnv.txt 里的 FDT 字段，请手动设置"
else
    info "未修改启动配置（需要时加 --set-fdt）"
    if [ -f /boot/uEnv.txt ]; then
        info "当前 FDT 行: $(grep '^FDT=' /boot/uEnv.txt || echo '(无)')"
    fi
fi

# ---------------------------------------------------------------------------
# 6. 固件检查
# ---------------------------------------------------------------------------
FW_OK=0
for f in /lib/firmware/wifi_56630001_3ant.ini /lib/firmware/uwe5621ds/wifi_56630001_3ant.ini; do
    [ -f "$f" ] && FW_OK=1
done
if [ "$FW_OK" -eq 1 ]; then
    ok "固件 wifi_56630001_3ant.ini 已就位"
else
    warn "缺少 /lib/firmware/wifi_56630001_3ant.ini"
    warn "  -> 运行 firmware/extract-from-android.sh 从安卓分区提取"
    warn "  -> 没有它，WiFi 芯片会在 probe 时 assert 复位"
fi

# ---------------------------------------------------------------------------
# 7. 落盘
#
# 这类盒子的根分区常带 commit=600,data=writeback，直接拔电会丢掉最近
# 最多 10 分钟的写入。这里强制 flush，避免"装完拔电重启发现没生效"。
# ---------------------------------------------------------------------------
sync; sync
sleep 1
sync
ok "已 sync 落盘（Dirty: $(grep '^Dirty:' /proc/meminfo | awk '{print $2}') kB）"

cat <<EOF

安装完成。

下一步：
  1. 断电冷启（不要用 reboot —— 见 docs/BOOT-RELIABILITY.md）
  2. 启动后检查：
       cat /run/hardware-status
       iw dev wlan0 link
       hciconfig -a

如果只会用一次、不想装 systemd 单元，可以手动验证：
  modprobe uwe5622_bsp_sdio && sleep 5 && modprobe sprdwl_ng
EOF
