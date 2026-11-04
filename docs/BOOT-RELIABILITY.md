# 为什么这台盒子必须拔电重启

结论：**内核没有断电能力，`reboot` 只复位 CPU 核，DDR / eMMC / SDIO / 电源域全都保持原状。**

## 证据

| 检查项 | 结果 | 含义 |
|---|---|---|
| `/proc/device-tree/soc/` | 无 `syscon-poweroff` / `syscon-reboot` 节点 | 没有可控的电源/复位寄存器入口 |
| dmesg 里的 PMIC | 无（只有 `vcc-3v3`、`vddao-3v3`、`vddio-boot` 等固定 regulator） | 电源是分立 DCDC，EN 脚由硬件逻辑控制 |
| `/proc/bus/input/devices` | 只有 `meson_ao_cec`、`meson-ir` | **按钮不在内核视野内**，纯硬件逻辑 |
| PSCI | `PSCIv0.2 detected` | `reboot` 最终走 `SYSTEM_RESET` |
| `/sys/kernel/reboot/mode` | `cold` | 已是最"重"的软复位，仍不碰电源 |
| kexec | `# CONFIG_KEXEC_FILE is not set` | 绕不过去了 |

## 软复位到底漏了什么

```
PSCI SYSTEM_RESET 复位：CPU 核心、GIC、部分总线
不复位：DDR 控制器、eMMC 控制器、SDIO、电源域、PMIC 状态机
```

热复位后 boot ROM 重新跑 BL1 → BL2 → U-Boot，但：

- **DDR 已经训练过**，U-Boot 再跑一遍参数可能对不上 → 卡在早期；
- **eMMC 没掉电**，还在 HS 模式，`emmc-pwrseq` 的 `reset-gpios` 不会被拉低 → 读 boot0 可能失败；
- **SDIO 的 UWE5621 半初始化**，`sdio-pwrseq` 同样不会被自动复位（所以 `aml_wifi_stub` 开机要专门做一次 `mmc_hw_reset(mmc0)`）。

## 日志上能直接看到失败循环

```
IDX  BOOT ID                            FIRST ENTRY              LAST ENTRY
-3   bf1e926c…                          15:00:03                 15:00:06
-2   c4583bb6…                          15:00:03                 15:00:06
```

两个不同的 boot id 挤在同一个 3 秒窗口里 —— 一次启动只活了几秒就又复位了。
而正常关机时，journal 末尾会有 systemd 的 shutdown 记录；被拔电的那次直接断在 cron 输出上。

## 按钮为什么也不行

DTB 里没有 `gpio-keys`，说明按钮**不经过内核**。机顶盒这种按钮通常是：

1. 接 PMIC / DCDC 的 EN 脚 —— 短按只切换待机，主电源轨不一定掉到 0，电容残压留着；
2. 接 SoC 的 `RESET#` —— 只复位芯片，电源完全不断。

真正的 power-on reset 要求 VCC 掉到阈值以下并维持几十到几百毫秒。按钮按一下那点时间，加上板上
的电解电容，做不到干净放电，于是**每次重启的起始状态都不一样**——这就是"有时候能起、有时候不能"。

## 实践建议

| 做法 | 效果 |
|---|---|
| **断电 10 秒** | 唯一可靠。用带开关的插座最省事 |
| `reboot` | 约一半概率卡死，卡死后仍需断电 |
| `reboot -f` / `echo b > /proc/sysrq-trigger` | 只跳过 sync，硬件复位质量不改善，**还会丢数据** |
| 按钮短按后立刻再按 | 让 PMIC 使能状态机停在中间态，更容易起不来 |
| **kexec** | 理论最优（跳过 firmware，不碰 DDR/eMMC），但需要重编内核开 `CONFIG_KEXEC_FILE` |

### 正确姿势

1. 需要重启时，先 `sync`（或 `poweroff` 让它自己同步完）；
2. 断电，**等 10 秒**；
3. 再上电。

### 判断是不是真死了

黑屏不等于没启动。首启扩容 + HDMI 初始化要 2–3 分钟。先 `ping`：

```sh
ping -c 2 <box-ip>
```

通了就是活着，只是没画面。

## 如果你确实需要频繁软重启

唯一的正规解法是重编内核打开 kexec：

```
CONFIG_KEXEC_FILE=y
CONFIG_KEXEC=y
```

然后 `kexec -l /boot/zImage --initrd=/boot/uInitrd --reuse-cmdline && kexec -e`。
它直接跳转到新内核，完全不经过 U-Boot 和 DDR 重训，可以避开上述所有问题。

代价是要重新编译内核并长期维护；如果只是偶尔重启，拔电更划算。
