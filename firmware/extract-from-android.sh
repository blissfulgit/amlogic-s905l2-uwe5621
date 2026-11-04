#!/bin/sh
# extract-from-android.sh -- 从安卓系统里提取 UWE5621 的射频校准文件
#
# 这些 .ini 是芯片出厂校准数据，版权归 UNISOC，不随本仓库分发。
# 每台设备的校准值略有差异，所以最佳做法是从你自己的盒子提取。
#
# 用法:
#   ./extract-from-android.sh /path/to/mounted/system      # 已挂载的安卓 system 分区
#   ./extract-from-android.sh --image /dev/mmcblk2         # 直接给块设备/镜像
#   ./extract-from-android.sh --list /dev/mmcblk2          # 只列出自带的分区
#
# 提取结果复制到 /lib/firmware/
#
# 安卓侧的典型路径:
#   /system/etc/wifi/uwe5621/wifi_*.ini
#   /system/etc/wifi/uwe5621/bt_configure*.ini

set -eu

DEST=/lib/firmware
MNT=/mnt/_android_system

info() { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root"

MODE="dir"
ARG=""

case "${1:-}" in
    --image) MODE="image"; ARG="${2:-}" ;;
    --list)  MODE="list";  ARG="${2:-}" ;;
    "")      die "用法: $0 <已挂载目录> | --image <设备> | --list <设备>" ;;
    *)       MODE="dir";   ARG="$1" ;;
esac

# ---------------------------------------------------------------------------
# 只列出候选分区（安卓的 system 通常是 ext4，且没有 label）
# ---------------------------------------------------------------------------
if [ "$MODE" = "list" ]; then
    [ -b "$ARG" ] || die "$ARG 不是块设备"
    info "扫描 $ARG 上的 ext4 分区（可能需要几秒）"
    # 用 file 命令识别头部，避免挂载一遍
    for off in $(seq 0 1 40); do
        skip=$((off * 64 * 1024 * 1024))
        sig=$(dd if="$ARG" bs=1 skip=$((skip + 1080)) count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
        [ "$sig" = "53ef" ] && echo "  offset $skip  ($((skip / 1024 / 1024)) MiB)  <- ext4 超级块"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# 挂载
# ---------------------------------------------------------------------------
cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$MNT"

if [ "$MODE" = "image" ]; then
    [ -e "$ARG" ] || die "$ARG 不存在"
    info "挂载 $ARG（只读）"
    # 整盘挂载不上时，尝试常见偏移（安卓 boot/system 分区起始）
    if ! mount -o ro,offset=1681915904 "$ARG" "$MNT" 2>/dev/null; then
        info "偏移 1681915904 失败，尝试从 0 开始"
        mount -o ro "$ARG" "$MNT" 2>/dev/null || die "挂载失败，先用 --list 找出分区偏移"
    fi
else
    ARG=$(cd "$ARG" && pwd)
    # 传进来的可能是挂载点，也可能是分区根
    if [ -d "$ARG/system/etc" ]; then
        MNT="$ARG"
    elif [ -d "$ARG/etc/wifi" ]; then
        MNT="$(dirname "$ARG")"
    else
        die "$ARG 里找不到 system/etc 或 etc/wifi"
    fi
fi

# ---------------------------------------------------------------------------
# 查找并复制
# ---------------------------------------------------------------------------
info "查找 wifi 配置"
FOUND=0
for d in "$MNT/system/etc/wifi" "$MNT/etc/wifi" "$MNT/system/vendor/etc/wifi"; do
    [ -d "$d" ] || continue
    info "扫描 $d"
    for f in $(find "$d" -type f \( -name 'wifi_*.ini' -o -name 'bt_configure*.ini' \) 2>/dev/null); do
        echo "    $f  ($(wc -c < "$f") bytes)"
        FOUND=$((FOUND + 1))
    done
done

[ "$FOUND" -gt 0 ] || die "没找到 .ini 文件，确认路径是否正确"

printf '\n复制到 %s ? [y/N] ' "$DEST"
read -r ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { info "已取消"; exit 0; }

for d in "$MNT/system/etc/wifi" "$MNT/etc/wifi" "$MNT/system/vendor/etc/wifi"; do
    [ -d "$d" ] || continue
    find "$d" -type f \( -name 'wifi_*.ini' -o -name 'bt_configure*.ini' \) -exec cp -v {} "$DEST/" \;
done

# uwe5622 驱动也会在 /lib/firmware/uwe5621ds/ 下找
if [ -d "$DEST/uwe5621ds" ]; then
    for f in "$DEST"/wifi_5663*.ini; do
        [ -f "$f" ] && cp -v "$f" "$DEST/uwe5621ds/" || true
    done
fi

ok "完成。核对芯片型号："
ls -l "$DEST"/wifi_5663*.ini 2>/dev/null || warn "没有 wifi_5663*.ini，芯片可能是 UWE5622（0x5622xxxx）"

cat <<'EOF'

说明：
  wifi_<chipid>_<天线数>ant.ini 的文件名里 chipid 必须与实际芯片一致。
  本机型 chipid = 0x56630001 -> 需要 wifi_56630001_3ant.ini
  chipid 可以在 dmesg 里看到：
      WCN: marlin_get_wcn_chipid: chipid: 0x56630001

  天线数不对（2ant vs 3ant）也能起来，但射频性能会明显下降。
EOF
