# 硬件识别

## 怎么确认你的盒子是这一套

```sh
# SoC 与机型
tr '\0' ' ' < /proc/device-tree/compatible
# amlogic,x7-5g amlogic,s905l2 amlogic,meson-gxl

tr '\0' ' ' < /proc/device-tree/model
# Amlogic Meson GXL (S905L2) X7 5G Tv Box

# 无线芯片（需要驱动能起来才能看到；起不来就用安卓系统看）
dmesg | grep -i 'chipid'
# WCN: marlin_get_wcn_chipid: chipid: 0x56630001
```

`chipid` 是决定用哪份 `.ini` 固件的关键：

| chipid | 芯片 | 固件前缀 |
|---|---|---|
| `0x56630001` | UWE5621DS | `wifi_56630001_*` |
| `0x56630000` | UWE5621 | `wifi_56630000_*` |
| `0x56220001` | UWE5622 | `wifi_56220001_*` |

## SDIO 拓扑

```
SoC (S905L2 / GXL)
└── apb@d0000000
    ├── mmc@70000   (sd_emmc_a, mmc0)  ← UWE5621 挂在这里
    │   └── wifi@1  (SDIO function 1)
    ├── mmc@72000   (sd_emmc_b, mmc1)  ← TF 卡
    └── mmc@74000   (sd_emmc_c, mmc2)  ← eMMC
```

对应设备树路径：

```
/sys/devices/platform/soc/d0070000.mmc/mmc_host/mmc1/   ← SDIO 卡枚举在这里
```

注意 **DT 里的节点名是 `mmc@70000`，但 sysfs 里的平台设备名是 `d0070000.mmc`**。
驱动模块参数要的是后者：

```sh
options uwe5622_bsp_sdio sdio_host=d0070000.mmc
```

写错成 `mmc@70000` 或 `d0070000` 都不会报错，只是 probe 静默失败。

## 电源与复位

| 信号 | 设备树 | 说明 |
|---|---|---|
| 芯片供电使能 | `sdio-pwrseq/reset-gpios` | `aml_wifi_stub` 会在 probe 时拉高/拉低完成上电 |
| eMMC 复位 | `emmc-pwrseq/reset-gpios` | 热复位时**不会**被拉低，这是热重启不可靠的原因之一 |

内核日志里能看到 stub 的动作：

```
aml_wifi_stub: bound wifi_en to sdio-pwrseq reset-gpios
aml_wifi_stub: power off: reset asserted
aml_wifi_stub: power on: reset deasserted
aml_wifi_stub: sdio_reinit: mmc_hw_reset(mmc0)
aml_wifi_stub: sdio_reinit: mmc_hw_reset ret=0
```

`mmc_hw_reset(mmc0)` 这一步说明芯片需要一次 SDIO 总线复位才能被干净地枚举。

## SDIO CIS 读出来全 0 是正常的

```
mmc1: new high speed SDIO card at address 0001
```

`cat /sys/bus/sdio/devices/*/device` 之类经常返回 `0x0000`，因为 UWE5621 用的是
自定义 CIS，标准 SDIO 属性读取拿不到有效值。**不要以此判断硬件没识别**。
真正有效的判据是 dmesg 里的 `WCN: marlin_probe ok!` 和 `chipid: 0x...`。

## 参考：从安卓侧挖线索

原厂安卓的无线配置在：

```
/system/etc/wifi/uwe5621/
├── wifi_56630001_3ant.ini
├── bt_configure_rf_marlin.ini
└── ...
```

厂商 DTB（在 boot.img 的 second 段，gzip 压缩的多 DTB）里有原始引脚定义：

```
power_on_pin   = <&gpio 85>
interrupt_pin  = <&gpio 97>
```

这些在主线 DTB 里没有，但 `sdio-pwrseq` 的 reset-gpios 已经覆盖了上电时序，不需要额外处理。
