# AUTHORS

本项目由一人一机在真实硬件上死磕出来。分工如下。

---

## 望舒 · [@blissfulgit](https://github.com/blissfulgit)

**角色：项目主导 / 硬件方**

- 拆解并识别盒子型号，确认是 Amlogic S905L2（GXL / gxlx2 die）而非系统标签显示的 S905L3
- 从原厂安卓系统里挖出 `/system/etc/wifi/uwe5621/` 的射频校准文件，确定板载芯片是 UNISOC UWE5621DS
- 从 `boot.img` 的 second 段提取厂商多 DTB，找到 `power_on_pin = <&gpio 85>`、`interrupt_pin = <&gpio 97>` 等原始线索
- 决定「先在 U 盘里调通、再写进 eMMC」的路线，避免反复刷机损坏原系统
- 承担全部断电冷启验证 —— 每次改完 systemd 单元都要拔电重来，累计数十次
- 提出关键需求：*「能否加个脚本检测到所有硬件设备就绪再放行进入可操作状态」*，由此产生了 `hw-ready` 闸门
- 发现并反馈了「按按钮重启有时起不来」「重启命令没效果」等现象，直接指向了项目文档里最有价值的一篇 `BOOT-RELIABILITY.md`

## 千语 · WorkBuddy AI 助手

**角色：技术实现 / 文档**

- 反编译 `meson-gxl-s905l2-x7-5g.dtb` 与定制版并做 diff，把全部改动收敛到 **3 处**（`/soc/uwe-bsp` 节点、`wifi@1` 的 `compatible`、`aliases`）
- 定位 SDIO 拓扑：`mmc@70000` ↔ 平台设备 `d0070000.mmc`，弄清驱动模块参数 `sdio_host=` 为什么必须写后者
- 排查并修复 systemd 排序环 —— 一个**不报错、`--failed` 也是空**的故障，最后靠 `systemd-analyze verify` 才看到 `Job btattach.service/start deleted`
- 设计 `hw-ready` 闸门：逐项探测 + 超时降级 + 落盘状态，替代固定 `sleep`
- 编写 `apply-to-dtb.sh`（免编译打补丁，已实测与成品语义一致）、`install.sh`、`extract-from-android.sh`
- 撰写 README 与 `docs/` 三篇，整理 10 个踩坑记录
- 编写内核补丁 `0001-bluetooth-hci-ignore-default-link-policy.patch`（`HCI_OP_WRITE_DEF_LINK_POLICY` 容错）

---

## 关于「AI 参与」这件事

本项目的代码、脚本、文档全部由千语生成，望舒在真机上逐条验证。
**没有验证过的结论不会写进仓库**——包括那些失败的尝试（`modprobe -r` 卡死、`commit=600` 丢文件、
按按钮重启的物理原因），它们都在 `docs/TROUBLESHOOTING.md` 和 `docs/BOOT-RELIABILITY.md` 里如实记录。

AI 会犯错。这个项目里就犯过两个，都是望舒的真机反馈才暴露的：

1. `fdtput -t x` 把 `data-irq` 写成 4 字节，驱动按 u8 读会得到 0 —— 改用 `-t bx` 才正确
2. 把 `hw-ready` 全套文件写好后没 `sync` 就让拔电，`commit=600` 导致全部丢失 —— 现在 `install.sh` 里强制落盘

所以：**遇到与本机不符的地方，请相信你的 dmesg，而不是这份文档。**
