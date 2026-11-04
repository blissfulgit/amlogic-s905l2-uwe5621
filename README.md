# amlogic-s905l2-uwe5621

Bring up the on-board **UNISOC UWE5621DS** Wi-Fi + Bluetooth combo on **Amlogic S905L2** TV boxes running Armbian.

Amlogic S905L2 机顶盒（X7-5G 及衍生型号）板载 UNISOC UWE5621DS SDIO 双模无线芯片，在 Armbian / ophub 镜像下默认完全不可用。本仓库记录从零打通 WiFi + Bluetooth 的完整方案：设备树补丁、模块参数、固件、内核 HCI 补丁，以及一套开机就绪闸门。

---

## 适用范围

| 项目 | 值 |
|---|---|
| SoC | Amlogic S905L2（GXL / gxlx2 die） |
| DT compatible | `amlogic,x7-5g` `amlogic,s905l2` `amlogic,meson-gxl` |
| 无线芯片 | UNISOC UWE5621DS，`chipid 0x56630001` |
| SDIO host | `d0070000.mmc`（`meson-gxl-mmc`） |
| 系统 | Armbian 26.11 / 内核 6.18.x-ophub（aarch64） |
| 验证机型 | 长虹 CM201-1-CH 类 S905L2 盒子（1GB RAM） |

> UWE5621 / UWE5622 是同一驱动家族（`uwe5622_bsp_sdio`），UWE5622 设备大概率同样适用，但本项目只在 0x56630001 上实测。

## 不装这套会看到什么

```text
# 现象 1：SDIO 枚举到设备但 CIS 全 0
meson-gx-mmc d0070000.mmc: card claims to support voltages below defined range
mmc1: new high speed SDIO card at address 0001

# 现象 2：直接 modprobe 报 CP2 版本读取失败
WCN_ERR: didn't get CP2 version
uwe5622_bsp_sdio: probe of ... failed with error -1

# 现象 3：蓝牙控制器初始化被 HCI 命令拒绝打断
Bluetooth: hci0: Opcode 0x080f failed: -22
Bluetooth: hci0: Can't init device hci0: Invalid argument (22)
```

根因是 **DTB 里这颗芯片被写成了 `mediatek,mt7668`**，驱动匹配不上；即使手动加载驱动，`sdio_host` 参数、芯片专属 `.ini` 固件、以及内核对 `HCI_OP_WRITE_DEF_LINK_POLICY` 的严格校验也会各自卡住一步。

## 四层修复

| 层 | 内容 | 文件 |
|---|---|---|
| 1. 设备树 | 新增 `/soc/uwe-bsp` 节点；`mmc@70000/wifi@1` 的 `compatible` 改为 `unisoc,uwe_bsp`；补 `sd_emmc_a/c` 别名 | `dts/` |
| 2. 模块参数 | `options uwe5622_bsp_sdio sdio_host=d0070000.mmc` | `modprobe/` |
| 3. 固件 | `wifi_56630001_3ant.ini`（芯片射频校准，缺失会 assert 复位） | `firmware/` |
| 4. 内核 | 忽略 `HCI_OP_WRITE_DEF_LINK_POLICY` 的拒绝，避免整个 BT 控制器初始化失败 | `kernel/` |

DTS 改动一共只有 3 处，反编译对比结果：

```diff
 aliases {
+    sd_emmc_c = "/soc/apb@d0000000/mmc@74000";
+    sd_emmc_a = "/soc/apb@d0000000/mmc@70000";
     mmc0 = "/soc/apb@d0000000/mmc@70000";
@@
 /soc {
+    uwe-bsp {
+        compatible = "unisoc,uwe_bsp";
+        sdhci-name = <&sd_emmc_a>;
+        data-irq = <1>;
+        keep-power-on = <1>;
+        status = "okay";
+    };
@@
             wifi@1 {
-                compatible = "mediatek,mt7668";
+                compatible = "unisoc,uwe_bsp";
+                data-irq = <1>;
+                keep-power-on = <1>;
                 reg = <0x01>;
             };
```

## 安装

```sh
git clone https://github.com/blissfulgit/amlogic-s905l2-uwe5621.git
cd amlogic-s905l2-uwe5621
sudo ./install.sh            # 安装文件与 systemd 单元
sudo ./install.sh --set-fdt  # 同时把 uEnv.txt 的 FDT 指向 -uwe.dtb（会备份）
```

`install.sh` 做四件事：

1. 安装 `meson-gxl-s905l2-x7-5g-uwe.dtb` 到 `/boot/dtb/amlogic/`
2. 写入 `modprobe.d` 参数、systemd 单元、闸门脚本
3. `systemctl enable` WiFi 服务、闸门 timer、蓝牙兜底 timer
4. 检查固件是否就位，缺失则提示运行 `firmware/extract-from-android.sh`

固件**不随仓库分发**（版权归 UNISOC），请从你自己的设备提取，见 [`firmware/README.md`](firmware/README.md)。

装完必须**断电冷启**（这类盒子的热复位不可靠，见 [`docs/BOOT-RELIABILITY.md`](docs/BOOT-RELIABILITY.md)）。

## 验证

```sh
# 1. 设备树生效
tr '\0' ' ' < /proc/device-tree/compatible      # 应含 amlogic,s905l2
ls /proc/device-tree/soc/ | grep uwe            # 应有 uwe-bsp

# 2. 驱动与网卡
lsmod | grep uwe5622                            # uwe5622_bsp_sdio + sprdwl_ng
ip -br a | grep wlan0
iw dev wlan0 info

# 3. 蓝牙
hciconfig -a | grep -E 'hci0|UP RUNNING'

# 4. 就绪闸门
cat /run/hardware-status
```

预期结果（冷启实测，S905L2 + 6.18.60-ophub）：

```
20.70s  uwe5622-wifi.service 启动
27.25s  WiFi 完成
27.30s  hw-ready.service 开始
27.71s  闸门拉起 btattach
29.28s  STATE ready
```

## 开机就绪闸门

`hw-ready` 不是固定 `sleep`，而是逐项探测、带超时与降级标记：

```
sdio        lsmod 有 uwe5622_bsp_sdio      ≤30s
wlan0       /sys/class/net/wlan0 存在      ≤45s
wifi-ioctl  iw dev wlan0 info 能返回       ≤20s
hci0        hciconfig hci0 含 UP RUNNING   ≤45s
eth-link    carrier==1                     仅记录
thermal     thermal_zone0/temp 可读        缺失标 degraded
```

用法：

```sh
hw-ready-wait 60 && ./your-task.sh   # 当门闩用，超时返回 1
cat /run/hardware-status             # 逐项明细
systemctl status hw-ready            # 闸门本身
```

登录时会自动打印一行摘要：

```
hardware: ready (2s)  sdio=0s wlan0=0s wifi-ioctl=0s hci0=2s eth-link=2s thermal=2s
```

## 目录结构

```
.
├── dts/
│   ├── meson-gxl-s905l2-x7-5g-uwe.dtb      # 成品 DTB（可直接用）
│   ├── apply-to-dtb.sh                     # 对现有 DTB 打补丁（免编译内核）
│   └── README.md
├── kernel/
│   └── 0001-bluetooth-hci-ignore-default-link-policy.patch
├── systemd/
│   ├── uwe5622-wifi.service / uwe5622-wifi-up.sh
│   ├── btattach.service / uwe5622-bt-fallback.timer
│   └── hw-ready.{service,timer} / hw-ready-check.sh / hw-ready-wait / hw-ready-notice.sh
├── modprobe/
│   ├── uwe5622-sdio.conf                   # -> /etc/modprobe.d/
│   └── uwe5622-load.conf                   # -> /etc/modules-load.d/（默认禁用）
├── firmware/
│   ├── extract-from-android.sh             # 从本机安卓分区提取固件
│   └── README.md
├── docs/
│   ├── HARDWARE.md                         # 硬件识别与寄存器线索
│   ├── TROUBLESHOOTING.md                  # 踩过的坑
│   └── BOOT-RELIABILITY.md                 # 为什么必须拔电重启
└── install.sh
```

## 已知限制

- **WiFi 必须先于蓝牙初始化**。两者共用一颗芯片的 SDIO 通道，`btattach` 抢在 WCN 固件下载前会拽挂 WiFi。因此蓝牙最早只能在 WiFi 就绪后拉起（实测 27s 左右），这不是参数问题。
- **热重启不可靠**，必须断电冷启，见 `docs/BOOT-RELIABILITY.md`。
- 内核补丁需要自行编译内核（GitHub Actions 或本地交叉编译），`install.sh` 不处理这一步。
- 仅在 1GB RAM 的 S905L2 上验证，其他内存容量未测。

## 作者

| 角色 | 说明 |
|---|---|
| **望舒** ([@blissfulgit](https://github.com/blissfulgit)) | 项目主导。硬件所有者，负责拆机、刷机、真机验证与全部断电冷启测试；从安卓分区挖出厂商 DTB 与无线配置，确认了 UWE5621 的存在；提出「硬件就绪闸门」的需求。 |
| **千语**（WorkBuddy AI 助手） | 技术实现。DTB 反编译与差异分析、SDIO 拓扑梳理、systemd 依赖设计与排序环定位、闸门脚本、安装/提取脚本、全部文档撰写。 |

贡献细节见 [`AUTHORS.md`](AUTHORS.md)。

> 本项目代码与文档由 AI 助手生成，每一条结论都在真机上验证过（含失败案例，见 `docs/TROUBLESHOOTING.md`）。
> 若你在别的 S905L2 机型上发现不适用之处，欢迎提 issue —— 硬件差异比想象中大。

## 致谢

- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) —— 提供内核与统一镜像
- UNISOC UWE5622 驱动源码（GPL v2，内核树内 `drivers/net/wireless/uwe5622`）

## License

- 脚本、systemd 单元、文档：MIT（见 `LICENSE`）
- `dts/*.dtb`：GPL-2.0（内核 DT 衍生物）
- `kernel/*.patch`：GPL-2.0
- 固件二进制不包含在本仓库，版权归 UNISOC
