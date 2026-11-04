# 踩过的坑

按"症状 → 原因 → 解法"记录。全部为本机型实测。

---

## 1. `WCN_ERR: didn't get CP2 version` / `probe of ... failed with error -1`

**症状**

```
WCN_ERR: didn't get CP2 version
uwe5622_bsp_sdio: probe of ... failed with error -1
```

之后再 modprobe 也不会恢复，必须重启。

**原因**：驱动在 `sysinit` 阶段（`/etc/modules-load.d/`）被加载。此时 `sdio-pwrseq` 的
regulator 与 mmc 控制器还没就绪，芯片上电时序不完整。

**解法**：把模块名从 `modules-load.d` 里删掉，改由 systemd 服务在 `multi-user.target` 之后加载：

```sh
[Unit]
After=multi-user.target
Wants=multi-user.target
```

配套的 `modules-load.d/uwe5622.conf` 留空（只留注释），防止以后又被加回去。

---

## 2. 设备树节点名必须带连字符 `uwe-bsp`

**症状**：SDIO 卡能枚举，但驱动找不到 host，`chipid` 永远读不出来，`wlan0` 不出现。

**原因**：驱动用 `of_find_node_by_name("uwe-bsp")` 查找节点。写成 `uwe_bsp`（下划线）匹配失败，
且**不报错**——`of_find_node_by_name` 返回 NULL 后驱动走默认分支，静默失败。

**解法**：节点名严格写 `uwe-bsp`，`compatible = "unisoc,uwe_bsp"`（compatible 里是下划线，
两者不一样，别搞混）。

---

## 3. systemd 排序环：开机没蓝牙，且**没有任何报错**

**症状**

- 开机后没有 `/dev/ttyBT0`、没有 `hci0`
- `systemctl --failed` 是空的
- `systemctl status btattach.service` 显示 `inactive (dead)`，没有失败记录

**原因**：`uwe5622-wifi.service` 里写了 `After=multi-user.target` + `WantedBy=multi-user.target`
（自环，systemd 容忍），此时只要再有别的 unit 写 `After=uwe5622-wifi.service` 且
`WantedBy=multi-user.target`，就构成显式循环。systemd 的处置是**直接删除其中一个启动任务**，
不是报错。

只有 `systemd-analyze verify` 能看出来：

```
multi-user.target: Found ordering cycle on btattach.service/start
multi-user.target: Found dependency on uwe5622-wifi.service/start
multi-user.target: Found dependency on multi-user.target/start
multi-user.target: Job btattach.service/start deleted to break ordering cycle
```

**解法**：让 btattach 脱离 multi-user 事务——**不写 `[Install]`**，由 timer 触发。这样
`After=uwe5622-wifi.service` 反而变成了纯粹的排序约束，不再成环。

```sh
# 写完任何与本服务有依赖关系的 unit，必须跑：
systemd-analyze verify /etc/systemd/system/xxx.service
```

---

## 4. `sleep 40` 在服务里被杀掉

**症状**：脚本里写 `sleep 40` 来等芯片就绪，服务启动到 10s 就 `timeout`。

**原因**：Armbian 的 `DefaultTimeoutStartSec=10s`。`Type=oneshot` 的 `ExecStart` 里所有耗时都算在
启动超时内。

**解法**：用 `Type=oneshot` + `TimeoutStartSec=` 显式放宽，或者干脆把「等待」从服务里挪到
timer（`OnBootSec=`），让 systemd 自己计时。

---

## 5. 蓝牙抢跑把 WiFi 拽挂

**症状**：先 attach 蓝牙的情况下，WiFi 固件下载失败，`wlan0` 不出现；反过来先 WiFi 再蓝牙就正常。

**原因**：UWE5621 是单芯片双模，BT 走同一个 SDIO 通道上的 tty 设备。`btattach` 会占用/复位芯片，
抢在 `marlin start to download` 完成前执行就会打断固件下载。

**解法**：btattach 必须 `After=uwe5622-wifi.service`，并且服务内再等 `/dev/ttyBT0` 出现。
实测时间线：

```
20.70s  WiFi 服务启动
27.25s  固件下载完成
27.71s  btattach 启动
```

**这是硬约束，不是调参问题。** 想更快只能让 WiFi 本身更早起来。

---

## 6. `modprobe -r sprdwl_ng` 会让进程卡在 D 状态

**症状**：`modprobe -r` 之后命令不返回，进程 `D` 状态，`kill -9` 无效，只能重启。

**原因**：卸载路径里有等待 SDIO 中断完成的逻辑，芯片在忙时会永久等待。

**解法**：**不要用 `modprobe -r` 做兜底重试**。需要重来时，重启系统，或者用
`aml_wifi_stub` 的 `sdio_reinit` 路径（`mmc_hw_reset`）。

---

## 7. 蓝牙 `Opcode 0x080f failed: -22`

**症状**

```
Bluetooth: hci0: Opcode 0x080f failed: -22
Bluetooth: hci0: Can't init device hci0: Invalid argument (22)
```

`hciconfig -a` 里没有 `hci0`，或者有但 `DOWN`。

**原因**：`hci_setup_link_policy_sync()` 给控制器发 `HCI_OP_WRITE_DEF_LINK_POLICY` (0x080f)，
UWE5621 返回 `Invalid HCI Command Parameters`，内核据此判定整个控制器初始化失败。

**解法**：打 `kernel/0001-bluetooth-hci-ignore-default-link-policy.patch`，把这次失败降级为 warning：

```c
if (__hci_cmd_sync_status(hdev, HCI_OP_WRITE_DEF_LINK_POLICY,
                          sizeof(cp), &cp, HCI_CMD_TIMEOUT) < 0)
    bt_dev_warn(hdev, "controller rejected default link policy, ignoring");
return 0;
```

控制器本身是好的（reset 成功、BD_ADDR 正常），只是不支持这条命令。

---

## 8. 根分区 `commit=600`，拔电丢文件

**症状**：刚写的配置文件，拔电重启后不见了；`/etc/systemd/system/` 的 mtime 停在更早的时刻。

**原因**：Armbian 默认挂载参数 `commit=600,data=writeback`，ext4 允许最长 10 分钟才落盘。
直接拔电会丢掉页缓存里的内容（不是文件系统损坏）。

**解法**：

```sh
sync; sync; sleep 1; sync
# 或用 grep Dirty /proc/meminfo 确认接近 0
```

或用 `mount -o remount,commit=60 /` 把窗口缩短到 1 分钟。

---

## 9. 黑屏 ≠ 没启动

首启需要扩容 rootfs + HDMI 慢初始化，黑屏 2–3 分钟是正常的。

判断是否活着：

```sh
ping <box-ip>
# 或串口 ttyAML0 @ 115200
```

---

## 10. `armbian-install` / `armbian-update` 会改 FDT

`armbian-install` 安装到 eMMC 时会按型号重写 `uEnv.txt` 的 `FDT=`，把你自定义的 dtb 改回标准版。
装完必须核对：

```sh
grep '^FDT=' /boot/uEnv.txt
```

`armbian-update` 升级内核会覆盖 `/boot/dtb/`，自定义 dtb 需要重新放回去（它会把原 FDT 备份到
`/root/.backup/`，可以从那里找回）。
