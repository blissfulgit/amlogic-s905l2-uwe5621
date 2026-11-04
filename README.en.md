# amlogic-s905l2-uwe5621

> [中文说明](README.md) · English

Bring up the on-board **UNISOC UWE5621DS** Wi-Fi + Bluetooth combo on **Amlogic S905L2** TV boxes running Armbian.

Out of the box, the stock ophub device tree describes this chip as `mediatek,mt7668`, so neither Wi-Fi nor Bluetooth ever works. This repo is the complete, verified recipe: device-tree patch, module parameters, firmware, a kernel HCI fix, and a boot readiness gate.

---

## Scope

| | |
|---|---|
| SoC | Amlogic S905L2 (GXL / gxlx2 die) |
| DT compatible | `amlogic,x7-5g` `amlogic,s905l2` `amlogic,meson-gxl` |
| Radio | UNISOC UWE5621DS, `chipid 0x56630001` |
| SDIO host | `d0070000.mmc` (`meson-gxl-mmc`) |
| OS | Armbian 26.11 / kernel 6.18.x-ophub (aarch64) |
| Tested on | Changhong CM201-1-CH class S905L2 box, 1 GB RAM |

> UWE5621 and UWE5622 share the same driver family (`uwe5622_bsp_sdio`). UWE5622 devices will likely work too, but only `0x56630001` was verified here.

## Symptoms without this fix

```text
# 1. SDIO enumerates, but CIS reads back all zeros
mmc1: new high speed SDIO card at address 0001

# 2. Loading the driver too early fails
WCN_ERR: didn't get CP2 version
uwe5622_bsp_sdio: probe of ... failed with error -1

# 3. Bluetooth controller init aborts on an HCI command
Bluetooth: hci0: Opcode 0x080f failed: -22
Bluetooth: hci0: Can't init device hci0: Invalid argument (22)
```

Four independent things have to be fixed, and each one fails differently.

## The four fixes

| Layer | What | Where |
|---|---|---|
| 1. Device tree | Add `/soc/uwe-bsp`, switch `mmc@70000/wifi@1` from `mediatek,mt7668` to `unisoc,uwe_bsp`, add `sd_emmc_a/c` aliases | `dts/` |
| 2. Module param | `options uwe5622_bsp_sdio sdio_host=d0070000.mmc` | `modprobe/` |
| 3. Firmware | `wifi_56630001_3ant.ini` — RF calibration; without it the chip asserts and resets | `firmware/` |
| 4. Kernel | Ignore the `HCI_OP_WRITE_DEF_LINK_POLICY` rejection instead of failing controller init | `kernel/` |

The whole DTS delta is three hunks:

```diff
 aliases {
+    sd_emmc_c = "/soc/apb@d0000000/mmc@74000";
+    sd_emmc_a = "/soc/apb@d0000000/mmc@70000";
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

> The node name `uwe-bsp` uses a **hyphen**, while `compatible` uses an **underscore**. The driver looks the node up by exact name — `uwe_bsp` silently fails to match, no error logged, Wi-Fi never appears.

## Install

```sh
git clone https://github.com/blissfulgit/amlogic-s905l2-uwe5621.git
cd amlogic-s905l2-uwe5621
sudo ./install.sh              # install files and systemd units
sudo ./install.sh --set-fdt    # also point uEnv.txt at -uwe.dtb (backed up first)
```

Firmware is **not** distributed here (it is UNISOC factory calibration data, unique per device). Extract it from your own box — see [`firmware/README.md`](firmware/README.md).

Then **power-cycle** the box. A warm reboot is unreliable on this hardware: [`docs/BOOT-RELIABILITY.md`](docs/BOOT-RELIABILITY.md).

## Verify

```sh
tr '\0' ' ' < /proc/device-tree/compatible      # should contain amlogic,s905l2
ls /proc/device-tree/soc/ | grep uwe            # uwe-bsp present

lsmod | grep uwe5622                            # uwe5622_bsp_sdio + sprdwl_ng
iw dev wlan0 info
hciconfig -a | grep -E 'hci0|UP RUNNING'

cat /run/hardware-status
```

Expected cold-boot timeline (measured, S905L2 + 6.18.60-ophub):

```
20.70s  uwe5622-wifi.service starts
27.25s  Wi-Fi ready
27.30s  hw-ready.service runs
27.71s  gate starts btattach
29.28s  STATE ready
```

## The readiness gate

`hw-ready` does not `sleep` for a guessed duration. It probes each item with a timeout and marks degradations:

```
sdio        uwe5622_bsp_sdio in lsmod        <=30s
wlan0       /sys/class/net/wlan0 exists      <=45s
wifi-ioctl  iw dev wlan0 info succeeds       <=20s
hci0        hciconfig hci0 shows UP RUNNING  <=45s
eth-link    carrier==1                       record only
thermal     thermal_zone0/temp readable      missing => degraded
```

Usage:

```sh
hw-ready-wait 60 && ./your-task.sh   # blocks until ready, rc=1 on timeout
cat /run/hardware-status             # per-item timings
systemctl status hw-ready
```

Login banner:

```
hardware: ready (2s)  sdio=0s wlan0=0s wifi-ioctl=0s hci0=2s eth-link=2s thermal=2s
```

## Layout

```
.
├── dts/          patched DTB + on-device patch script
├── kernel/       0001-bluetooth-hci-ignore-default-link-policy.patch
├── systemd/      Wi-Fi bring-up, BT attach, readiness gate
├── modprobe/     sdio_host binding (and a deliberate no-op modules-load)
├── firmware/     extraction script only, no binaries
└── docs/         hardware, troubleshooting, boot reliability
```

## Limitations

- **Wi-Fi must initialise before Bluetooth.** Both share one SDIO channel on the same chip; `btattach` racing the WCN firmware download breaks Wi-Fi. Bluetooth therefore cannot come up before Wi-Fi is ready (~27 s here). This is a hardware ordering constraint, not a tunable.
- **Warm reboot is unreliable.** Power-cycle instead.
- The kernel patch requires rebuilding the kernel (GitHub Actions or cross-compile). `install.sh` does not do that.
- Verified on 1 GB RAM only.

## Credits

| Role | |
|---|---|
| **望舒** ([@blissfulgit](https://github.com/blissfulgit)) | Project lead. Hardware owner: teardown, flashing, vendor firmware extraction from the Android partition, and every cold-boot verification. Raised the original requirement for a readiness gate. |
| **千语** (WorkBuddy AI assistant) | Implementation. DTB decompilation and diffing, SDIO topology, systemd dependency design and ordering-cycle debugging, the gate, all scripts and documentation. |

Details in [`AUTHORS.md`](AUTHORS.md).

> Code and docs were authored by an AI assistant and verified on real hardware. Two AI mistakes are documented in `AUTHORS.md` — if your box disagrees with this document, trust your `dmesg`.

## License

Scripts, units, docs: MIT. `dts/*.dtb` and `kernel/*.patch`: GPL-2.0. Firmware is not distributed.
