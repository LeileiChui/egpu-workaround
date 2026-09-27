# Thunderbolt/USB4 NVIDIA eGPU — 全流程文档

> 把这台机器上「插坞 → PCIe 封顶 Gen4+HASD → 延迟加载 nvidia」的流程做成 **udev + systemd 全自动**，
> 在 **compute-only** 下长期稳定运行。本文只记录**正确路径**（可复制执行）。

---

## 1. 系统与拓扑

| | |
|---|---|
| 主机 | Gentoo Linux，kernel `7.3.0-rc4`，Intel Core Ultra X7 358H（Panther Lake） |
| 扩展坞 | FEVM FNGT5 PRO（TB5，JHL9480 桥，`8086:5786`） |
| eGPU | NVIDIA RTX 5060 Ti 16GB（`10de:2d04`）+ HDMI audio（`10de:22eb`） |
| 驱动 | `x11-drivers/nvidia-drivers-615.71.09`（stock，**不打驱动补丁**） |
| 桌面 | niri（Wayland），**渲染在 Intel iGPU**（`xe`） |

PCIe 路径：

```
0000:00:07.0  Intel USB-C Root Port          [8086:e44e]   ← 开机即存在
 └ 0000:02:00.0  JHL9480（上游）
    └ 0000:03:00.0  JHL9480（下游）                            ← cap 写这里
       ├ 0000:04:00.0  NVIDIA RTX 5060 Ti   [10de:2d04]       ← cap 也写这里
       └ 0000:04:00.1  NVIDIA HDMI audio    [10de:22eb]
```

启动参数（`/etc/default/grub` → `GRUB_CMDLINE_LINUX`）：

```
... iommu=pt fbcon=font:TER16x32 pci=realloc pcie_aspm=off
```

---

## 2. 原理

### 2.1 故障根因

TB/USB4 隧道的下游口（JHL9480）会在**负载变化时自主重新协商链路速率**（retrain）。这次重训练会把 GPU 上的
GSP 固件打崩，产生 `Xid 154`，严重时整机硬锁。

### 2.2 对策

在 **nvidia.ko 绑定之前**，把链路锁死在 **PCIe Gen4 + HASD**（禁用硬件自主升速）：

- 写 `LnkCtl2`（`CAP_EXP+0x30`）：`Target Link Speed = Gen4`，`bit5 = HASD`；
- 触发 retrain（`LnkCtl` bit5）；
- **父桥（`03:00.0`）和 GPU 端点（`04:00.0`）两端都写**（端点侧防自主升速）。

> 实测细节：硬件**默认**的 `LnkCtl2` 就是 `0x0044`（target 已是 Gen4、HASD=0），GPU 端默认 `0x0005`；
> 因此本 cap 的实质动作是**加上 `bit5`（HASD）**——"保留硬件默认速率 + 禁用自主升速"，而不是降压降速。

**Gen4 相对 Gen3 的实测收益**（本机热插拔路径）：单向 +7.5~15%，双向聚合 +3.7%
（总带宽被 40 Gb/s 的 TB 隧道限制在 ~6.2 GB/s）。9 分钟满载压测：无 Xid、无自主重训练。
> 注意：Gen4 只在「开机后插坞」的热插拔路径验证过；冷启动路径社区有冻机记录——本方案不走冷启动路径，也不要手动去试。

### 2.3 卸载路径：禁用 FLR

`nvidia.ko` 在卸载/掉线路径里**直接调用 `pcie_reset_flr`**，绕过内核的 `reset_methods[]` 表，
所以 `reset_method` sysfs 管不住它，会 D 状态挂死。解法是驱动自带的 registry key：

```
NVreg_RegistryDwords="RMPcieFLRPolicy=1"
```

带上它，`modprobe -r nvidia` 秒级完成。**任何方式加载 nvidia 都必须带这个参数。**

### 2.4 compute-only

eGPU 只做计算（CUDA），**不做显示**。为此：

- `nvidia_drm` / `nvidia_modeset` 用 `install /bin/false` **硬封**（`blacklist` 挡不住按需加载）；
- 用 Portage `INSTALL_MASK` 隐藏 NVIDIA 的图形入口文件（Vulkan ICD / implicit layer / VulkanSC / EGL / OpenCL）；
- CUDA 不受影响（走 `libcuda.so`，不经过这些入口文件）。

**绝对不要加载 `nvidia_drm`**：合成器会长期攥住 GPU 的 DRM 节点，导致 `modprobe -r` 永远被拒，
整条「卸载 → 重枚举 → 重载」的恢复链被堵死。

---

## 3. 安装

依赖：`pciutils`（`setpci`）、`kmod`、`systemd`、`util-linux`、`bash`、`coreutils`。

```bash
cd <repo>
sudo ./scripts/install.sh      # 同步到 local overlay 并 emerge app-misc/egpu-workaround
```

安装后由 Portage 管理，卸载用 `sudo ./scripts/uninstall.sh` 或 `emerge -C app-misc/egpu-workaround`。

> `INSTALL_MASK` 片段随包部署（`/etc/portage/{env,package.env}/nvidia-no-graphics*`），
> 下次 `emerge x11-drivers/nvidia-drivers`（或内核更新后的 `@module-rebuild`）即生效——
> 届时那 5 个图形入口文件**不会被安装**。

---

## 4. 组件

| 文件 | 作用 |
|---|---|
| `/usr/sbin/egpu-up.sh` | bring-up：rescan → 可达性 → BAR0 → PM 钉住 → cap → 加载 nvidia |
| `/usr/sbin/egpu-down.sh` | tear-down：卸载 nvidia（regkey 门控） |
| `/usr/sbin/egpu-bridge-cap.sh` | Gen4+HASD 封顶（`apply` / `status` / `restore` / `detect`；目标速率由 `egpu.conf` 的 `CAP_TARGET_SPEED` 决定） |
| `/usr/sbin/egpu-status.sh` | 分层健康审计（退出码 0/1/2） |
| `/usr/lib/udev/rules.d/90-egpu.rules` | TB add/remove → systemd；TB 路径 PM 钉住 |
| `/usr/lib/systemd/system/egpu-up.service` | oneshot，由 udev 触发 |
| `/usr/lib/systemd/system/egpu-down.service` | oneshot，由 udev 触发 |
| `/usr/lib/systemd/system-sleep/50-egpu` | 挂起前卸载、恢复后 bring-up |
| `/etc/modprobe.d/50-egpu-nvidia.conf` | blacklist + options + `install /bin/false` |
| `/etc/portage/env/nvidia-no-graphics.conf` | `INSTALL_MASK`（隐藏图形入口文件） |
| `/etc/portage/package.env/nvidia-no-graphics` | ↑ 关联 `x11-drivers/nvidia-drivers` |
| `/etc/egpu.conf` | 设备 ID、cap 目标、超时、模块参数（`CONFIG_PROTECT`） |
| `/run/egpu/state` | 运行态：`UP` / `NO_GPU` / `BAR_FAIL` / `DOWN` … |

---

## 5. 运行时流程

### 5.1 插坞

```
udev (thunderbolt 0-1 add)
 └ egpu-up.service → egpu-up.sh
    1. 幂等：已 UP 则只补 cap + PM
    2. PCI rescan（期间每 3s 重发一次，等隧道枚举就绪）
    3. 等 GPU 出现（超时→重建 TB 交换机枚举后重试）
    4. 去重 stale 设备；校验 BAR0（为 0 → remove 父桥 + rescan，最多 3 次）
    5. **PM 钉住**：父链 `power/control=on` + `d3cold_allowed=0`
    6. **cap**：父桥 + GPU 两端 Gen4 + HASD + retrain（目标速率取 `CAP_TARGET_SPEED`）
    7. `modprobe nvidia NVreg_DynamicPowerManagement=0x00 NVreg_RegistryDwords=RMPcieFLRPolicy=1`
    8. 再 assert 一次 PM（确保是最后写者），校验 `nvidia-smi` → state=UP
```

### 5.2 拔坞

```
udev (thunderbolt 0-1 remove)
 └ egpu-down.service → egpu-down.sh
    · 仅当当前模块带 RMPcieFLRPolicy=1 时才卸载（否则拒卸，避免 FLR 挂死）
    · modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
```

### 5.3 挂起 / 恢复

`sleep hook` 在挂起前卸载 nvidia、恢复后后台 bring-up。**注意**：s2idle 会把 dock↔GPU 物理链路弄死，
恢复不了时需**给扩展坞断电重上电**（见 §7）。

---

## 6. 日常操作与验证

```bash
# 健康审计（分层，OK/WARN/FAIL + 退出码）
sudo egpu-status.sh

# 只读查看 cap 与链路
sudo egpu-bridge-cap.sh status

# 运行态
cat /run/egpu/state
journalctl -t egpu -n50
```

实测基线（用于回归对照）：

| 项目 | 值 |
|---|---|
| 链路 | PCIe **Gen4 x4**（`LnkCtl2` 桥 `0x0064` / GPU `0x0024`，两端 HASD=1） |
| H2D / D2H memcpy | 3.29 / 3.90 GB/s（Gen3 时 3.06 / 3.38） |
| 双向聚合（`stress-link`） | 6.22 GB/s（Gen3 时 6.00） |
| L2 / DRAM | 2.2 TB/s / 428 GB/s |
| cuBLAS SGEMM FP32 | **19.86 TFLOPS** |
| gpu_burn 600s | errors=0 |
| 稳态 Xid | 0（拔线瞬时 `Xid 79` 属正常） |

---

## 7. 故障处理

| 现象 | 处理 |
|---|---|
| `state=NO_GPU` / `BAR_FAIL`，GPU 掉总线 | **给扩展坞断电 10–15 秒再上电**（软件复位无效） |
| GPU 半死（config 可读但 MMIO 死，`NVRM: fallen off the bus`） | 重插雷电线；脚本会自动做 TB 交换机重枚举 |
| 挂起（s2idle）后 eGPU 不回来 | 给扩展坞断电重上电（这是已知限制） |
| `egpu-down.sh` 报告「卸载失败 / DOWN_FAIL」 | 说明模块未带 `RMPcieFLRPolicy=1`；用 `egpu-up.sh` 重载后再拔 |
| 桌面「假崩」/ VT 被抢 | `chvt 1` |

**手动操作**（一般不需要，自动化已覆盖）：

```bash
sudo egpu-up.sh        # 手动 bring-up（幂等）
sudo egpu-down.sh      # 手动卸载
```

---

## 8. 必须遵守的规则

1. **开机不要插着扩展坞** —— 进桌面后再插（否则 iGPU `xe` 可能报 `GSC proxy component not bound`）。
2. **先 cap，后 `modprobe`** —— 顺序由 `egpu-up.sh` 保证，不要手工绕过。
3. **加载 nvidia 必须带 `RMPcieFLRPolicy=1`** —— 由 `modprobe.d options` 保证（任何加载路径都生效）。
4. **不要加载 `nvidia_drm`** —— 会堵死卸载/恢复链。
5. **链路封顶用 Gen4 + HASD**（由 `egpu.conf` 的 `CAP_TARGET_SPEED=4` 决定）。
   冷启动路径社区有 Gen4 冻机记录——本方案不走冷启动（先开机后插坞），但不要手动在冷启动下试。
6. **不信任 `lspci` 的 `DLActive` / `LnkSta`** —— TB 路径下是虚拟的；判据用 `nvidia-smi` 是否成功。
7. **不信任「设备是否存在」** —— TB 不产生热拔事件；判据是 **config 是否可达**。
8. **`switch remove` 前必须确认 nvidia 已干净卸载** —— 否则会卡在 D 状态（需重启）。
9. **掉总线/半死链路只能靠断电重上电** —— `remove` / `reset_subordinate` / FLR 都救不回。
10. **扩展坞的 PCIe 隧道枚举可能晚到** —— 脚本会在等待期间周期重发 `rescan`。

---

## 9. 卸载 / 回退

```bash
sudo ./scripts/uninstall.sh                                   # 卸载包（保留 overlay 目录）
KEEP_OVERLAY=0 sudo ./scripts/uninstall.sh                    # 连 overlay 一起删
```

- 启动参数回退：恢复 `/etc/default/grub` 备份后 `grub-mkconfig -o /boot/grub/grub.cfg`。
- 图形能力回退（若日后要 Vulkan/OpenCL）：从 `/etc/modprobe.d/50-egpu-nvidia.conf` 删掉
  `install nvidia_modeset /bin/false`（**保留** `install nvidia_drm /bin/false`），
  并从 `INSTALL_MASK` 移除相应入口文件。

---

## 10. 目录

```
README.md                     本文件：全流程文档
LICENSE                       MIT
scripts/                      运行时脚本 + 部署脚本（install.sh / uninstall.sh）
packaging/egpu-workaround/    Gentoo ebuild + files/（udev 规则 / systemd 单元 / modprobe.d / INSTALL_MASK 片段）
docs/flr-over-thunderbolt.md  为什么用 RMPcieFLRPolicy=1 规避 FLR（原理与验证）
```

> 开发时的 `plan/`、`probe/`、`workarounds/` 为设计与取证档案，未纳入本仓库。
