#!/bin/sh
# apply-to-dtb.sh -- 给现有的 meson-gxl-s905l2-x7-5g.dtb 打上 UWE5621 补丁
#
# 用法:
#   ./apply-to-dtb.sh <input.dtb> <output.dtb>
#
# 依赖: device-tree-compiler (fdtget / fdtput)
#   apt install device-tree-compiler
#
# 效果（与仓库内成品 dtb 等价）:
#   1. /aliases 增加 sd_emmc_a / sd_emmc_c
#   2. /soc 下新增 uwe-bsp 节点，sdhci-name 指向 mmc@70000 的 phandle
#   3. mmc@70000/wifi@1 的 compatible 从 mediatek,mt7668 改为 unisoc,uwe_bsp
#
# 实测环境: Linux 6.18.60-ophub, DTC 1.7.2

set -eu

SRC="${1:-}"
DST="${2:-}"

if [ -z "$SRC" ] || [ -z "$DST" ]; then
    echo "usage: $0 <input.dtb> <output.dtb>" >&2
    exit 1
fi

[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }
command -v fdtget >/dev/null || { echo "error: need fdtget (apt install device-tree-compiler)" >&2; exit 1; }
command -v fdtput >/dev/null || { echo "error: need fdtput" >&2; exit 1; }

MMC_SDIO="/soc/apb@d0000000/mmc@70000"
MMC_EMMC="/soc/apb@d0000000/mmc@74000"
WIFI_NODE="$MMC_SDIO/wifi@1"

# --- 前置检查 ---
if ! fdtget -t s "$SRC" "$WIFI_NODE" compatible >/dev/null 2>&1; then
    echo "error: $WIFI_NODE not found -- 这不是 S905L2 X7-5G 的 DTB？" >&2
    exit 1
fi

cp -f "$SRC" "$DST"

# 基址 DTB 里 mmc@70000 的 phandle（驱动读 u32 后按 phandle 反查 host）
PH=$(fdtget -t x "$DST" "$MMC_SDIO" phandle)
if [ -z "$PH" ]; then
    echo "error: mmc@70000 没有 phandle，无法设置 sdhci-name" >&2
    exit 1
fi
echo "[i] mmc@70000 phandle = 0x$PH"

# --- 1. aliases ---
fdtput -t s "$DST" /aliases sd_emmc_a "$MMC_SDIO"
fdtput -t s "$DST" /aliases sd_emmc_c "$MMC_EMMC"
echo "[+] aliases.sd_emmc_a / sd_emmc_c"

# --- 2. /soc/uwe-bsp ---
fdtput -c "$DST" /soc/uwe-bsp 2>/dev/null || true
fdtput -t s "$DST" /soc/uwe-bsp compatible     "unisoc,uwe_bsp"
fdtput -t x "$DST" /soc/uwe-bsp sdhci-name     "0x$PH"
# data-irq / keep-power-on 必须是 1 字节（DT 里写作 [01]），不能用 4 字节的 <0x01>：
# 驱动按 u8 读取，4 字节值在大端 DT 里首字节是 0x00，会被读成 0。
fdtput -t bx "$DST" /soc/uwe-bsp data-irq       "01"
fdtput -t bx "$DST" /soc/uwe-bsp keep-power-on  "01"
fdtput -t s "$DST" /soc/uwe-bsp status         "okay"
echo "[+] /soc/uwe-bsp"

# --- 3. wifi@1 ---
fdtput -t s "$DST" "$WIFI_NODE" compatible     "unisoc,uwe_bsp"
fdtput -t bx "$DST" "$WIFI_NODE" data-irq       "01"
fdtput -t bx "$DST" "$WIFI_NODE" keep-power-on  "01"
echo "[+] $WIFI_NODE -> unisoc,uwe_bsp"

# --- 验证 ---
echo "[*] 校验:"
for p in compatible sdhci-name data-irq keep-power-on status; do
    printf '    uwe-bsp.%-14s = %s\n' "$p" "$(fdtget -t x "$DST" /soc/uwe-bsp "$p" 2>/dev/null || echo '(missing)')"
done
printf '    wifi@1.compatible     = %s\n' "$(fdtget -t s "$DST" "$WIFI_NODE" compatible)"

echo "[ok] 已写入 $DST"
