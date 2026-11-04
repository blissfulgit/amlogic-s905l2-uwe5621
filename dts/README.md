# dts/ —— 设备树改动

## 为什么需要改 DTB

S905L2 X7-5G 的官方 DTB 把 SDIO 上的无线芯片描述成：

```dts
wifi@1 {
    compatible = "mediatek,mt7668";
    reg = <0x01>;
};
```

而实际板载的是 **UNISOC UWE5621DS（chipid 0x56630001）**。`uwe5622_bsp_sdio` 驱动通过
`/soc/uwe-bsp` 节点拿 SDIO host 与中断配置，节点不存在就永远 probe 不到芯片。

## 三处改动

反编译对比（`meson-gxl-s905l2-x7-5g.dtb` vs `-uwe.dtb`）后，差异一共 37 行：

```diff
--- base.dts
+++ uwe.dts
@@ aliases
+    sd_emmc_c = "/soc/apb@d0000000/mmc@74000";
+    sd_emmc_a = "/soc/apb@d0000000/mmc@70000";

@@ /soc
+    uwe-bsp {
+        compatible = "unisoc,uwe_bsp";
+        sdhci-name = <&sd_emmc_a>;   /* 编译后是 phandle 数值 */
+        data-irq = <1>;
+        keep-power-on = <1>;
+        status = "okay";
+    };

@@ /soc/apb@d0000000/mmc@70000/wifi@1
-    compatible = "mediatek,mt7668";
+    compatible = "unisoc,uwe_bsp";
+    data-irq = <1>;
+    keep-power-on = <1>;
```

字段含义：

| 属性 | 作用 |
|---|---|
| `compatible = "unisoc,uwe_bsp"` | 驱动匹配键，**必须带连字符**。写成 `uwe_bsp` 会匹配失败 |
| `sdhci-name` | SDIO host 的 phandle，驱动据此找 `mmc_host`。对应模块参数 `sdio_host=d0070000.mmc` |
| `data-irq` | 数据中断（`1` = 使用 SDIO 数据线中断路径） |
| `keep-power-on` | 复位时保持芯片供电，避免 WiFi 与 BT 抢电 |

> ⚠️ `uwe-bsp` 节点名里的连字符很关键。当初写成 `uwe_bsp` 时，驱动 `of_find_node_by_name` 找不到节点，表现为 SDIO CIS 全 0、`probe -1`。

## 三种应用方式

### 方式 A：直接用成品 DTB（推荐）

```sh
sudo cp dts/meson-gxl-s905l2-x7-5g-uwe.dtb /boot/dtb/amlogic/
```

然后让 U-Boot 加载它：

```sh
# ophub 镜像的 /boot/uEnv.txt
FDT=/dtb/amlogic/meson-gxl-s905l2-x7-5g-uwe.dtb
```

Armbian 标准镜像则改 `/boot/armbianEnv.txt`：

```
fdtfile=amlogic/meson-gxl-s905l2-x7-5g-uwe.dtb
```

### 方式 B：给现有 DTB 打补丁

不想用别人编译好的二进制时：

```sh
sudo apt install device-tree-compiler
sudo ./dts/apply-to-dtb.sh \
    /boot/dtb/amlogic/meson-gxl-s905l2-x7-5g.dtb \
    /boot/dtb/amlogic/meson-gxl-s905l2-x7-5g-uwe.dtb
```

脚本用 `fdtget` 读出 `mmc@70000` 的真实 phandle 再写进 `sdhci-name`，所以不依赖硬编码值。

### 方式 C：改内核源码

在内核树的 `arch/arm64/boot/dts/amlogic/meson-gxl-s905l2-x7-5g.dts` 里直接加上面那段 diff，
重新编译 dtbs。好处是跟内核版本同步，坏处是要重编。

ophub 的 GitHub Actions 支持 `patch_dir` 参数，可以把 `.patch` 丢进去让它自动应用。

## 验证

冷启后：

```sh
tr '\0' ' ' < /proc/device-tree/compatible
# amlogic,x7-5g amlogic,s905l2 amlogic,meson-gxl

ls /proc/device-tree/soc/ | grep uwe
# uwe-bsp

fdtget -t x /proc/device-tree/soc/uwe-bsp sdhci-name   # 应等于 mmc@70000 的 phandle
fdtget -t s /proc/device-tree/soc/apb@d0000000/mmc@70000/wifi@1 compatible
# unisoc,uwe_bsp
```

dmesg 里应能看到：

```
WCN: marlin_probe ok!
WCN: marlin_get_wcn_chipid: chipid: 0x56630001
WCN: combin_img 3 marlin_firmware_write finish and successful
```

## 注意

- **只改了 DTB 不会自动加载驱动**，还需要 `modprobe.d` 里的 `sdio_host` 参数和芯片专属 `.ini` 固件。
- 如果你用的是**不同的 S905L2 机型**（比如 IPBS9505），`mmc@70000` 的路径一致，但网卡 `wifi@1` 可能在别的 SDIO 控制器下；先用 `ls /proc/device-tree/soc/apb@d0000000/` 确认。
- DTB 是内核 DT 的衍生物，按 GPL-2.0 分发。
