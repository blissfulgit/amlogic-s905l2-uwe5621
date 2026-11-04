# firmware/

本目录**不包含任何二进制固件**。

## 需要哪些文件

| 文件 | 来源 | 是否必需 |
|---|---|---|
| `wifi_56630001_3ant.ini` | 安卓 `/system/etc/wifi/uwe5621/` | **必需**。缺失时芯片会 assert 复位，wlan0 永远不出现 |
| `bt_configure_rf_marlin*.ini` | 同上 | 蓝牙射频校准，缺失通常仍能起来 |
| `wcnmodem.bin`、`WIFI_RAM_CODE_*` | ophub 内核固件包 | 随 Armbian 镜像自带 |

## 为什么不分发

这些 `.ini` 是 UNISOC 的芯片出厂校准数据，版权归芯片厂商；而且**每台设备的校准值略有差异**
（天线阻抗、功率曲线都是在产线单独测的）。从别人机器上拷来的文件能让 WiFi 工作，但发射功率
可能偏离法规限值。

所以本仓库只提供提取脚本：`extract-from-android.sh`。

## 提取方法

### 情况 A：还有安卓系统可挂载

```sh
sudo ./extract-from-android.sh /mnt/android    # 已挂载的 system 分区
```

脚本会扫描 `/system/etc/wifi/` 下的 `wifi_*.ini` 与 `bt_configure*.ini`，逐个列给你确认后复制到 `/lib/firmware/`。

### 情况 B：只有块设备（eMMC 镜像 / 整盘）

```sh
sudo ./extract-from-android.sh --list /dev/mmcblk2     # 先找 ext4 分区偏移
sudo ./extract-from-android.sh --image /dev/mmcblk2    # 默认从 1681915904 偏移挂载
```

安卓的 `system` 分区通常没有 label，脚本靠 ext4 超级块魔数（偏移 1080 处的 `53ef`）扫出候选。

### 情况 C：从原厂固件包提取

原厂 `update.zip` 里的 `system.img` 是 sparse 格式，先展开：

```sh
simg2img system.img system.raw.img
sudo ./extract-from-android.sh --image system.raw.img
```

## 安装位置

```sh
# 驱动优先从这里找
sudo cp wifi_56630001_3ant.ini /lib/firmware/
sudo cp wifi_56630001_3ant.ini /lib/firmware/uwe5621ds/
sudo cp bt_configure_rf_marlin*.ini /lib/firmware/uwe5621ds/
```

## 确认 chipid 与天线数

冷启后看 dmesg：

```
WCN: marlin_get_wcn_chipid: chipid: 0x56630001
```

文件名规则是 `wifi_<chipid>_<天线数>ant.ini`：

- `0x56630001` → `wifi_56630001_3ant.ini`
- `0x56630000` → `wifi_56630000_3ant.ini`（驱动自带）

芯片实际有几个天线接口要看板子。S905L2 这类盒子多数是 1 或 2 天线，但**固件文件名里的数字
必须与驱动加载的那份匹配**——如果 3ant 版本起不来，试 `2ant`：

```sh
sudo cp wifi_56630001_2ant.ini /lib/firmware/wifi_56630001_3ant.ini
```

（不改名也行，但驱动是按固定格式拼路径的，改名最省事。）
