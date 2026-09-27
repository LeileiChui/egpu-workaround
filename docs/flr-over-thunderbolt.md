# 如何规避 "FLR over Thunderbolt"（可落地方案）

> 目标：在**不改内核、不改驱动源码**的前提下，阻止 NVIDIA 驱动在这台 TB eGPU 上
> 触发 PCIe FLR，从而绕开 `modprobe -r` 挂死 / 掉总线 / D3cold 拉不回这类问题。
>
> 结论：**用驱动自带的 registry key `RMPcieFLRPolicy=1` 强制禁用 FLR**。
> 该 key 在 NVIDIA 官方头文件里有明确定义。

---

## 1. 先定位 FLR 的调用链

### 1.1 谁在调

来自内核栈（P0 实测）：

```
pci_device_remove                      (内核 PCI 层)
 └─ cleanup_module [nvidia]            (modprobe -r)
     └─ nv_trigger_gpu_flr  ──► nv_stop_device → nv_shutdown_adapter
                                  → RmShutdownAdapter → nv_acpi_methods_uninit
                                  → acpi_remove_notify_handler
                                  → __flush_workqueue   ← 卡死点
```

同时，`nvidia.ko` 的**未解析符号表**给出了它实际走的内核复位接口：

```
$ nm -u /lib/modules/$(uname -r)/video/nvidia.ko | grep -E 'reset|flr'
                 U pcie_reset_flr
                 U acpi_remove_notify_handler
```

关键点：**它导入的是 `pcie_reset_flr`，而不是 `pci_reset_function`。**

### 1.2 结论一：`reset_method` sysfs 对它无效

内核的复位分派表（`drivers/pci/pci.c`）：

```c
const struct pci_reset_fn_method pci_reset_fn_methods[] = {
    { }, { pci_dev_specific_reset, .name="device_specific" },
    { pci_dev_acpi_reset, .name="acpi" }, { pcie_reset_flr, .name="flr" },
    { pci_af_flr, .name="af_flr" }, { pci_pm_reset, .name="pm" },
    { pci_reset_bus_function, .name="bus" }, ...
};
```

`pci_reset_function()` / `__pci_reset_function_locked()` 会遍历 `dev->reset_methods[]`
（即 `reset_method` sysfs 控制的东西）。但 **nvidia 直接调用 `pcie_reset_flr()`，
绕过了这张表** → 无论你把 `reset_method` 写成 `bus`、空串还是什么，都拦不住它。
（这也是为什么社区里 `echo none > reset_method` 既不存在、也没用。）

### 1.3 结论二：`pcie_reset_flr` 的两个早退门控

```c
int pcie_reset_flr(struct pci_dev *dev, bool probe) {
    if (dev->dev_flags & PCI_DEV_FLAGS_NO_FLR_RESET) return -ENOTTY;   // ①
    if (!(dev->devcap & PCI_EXP_DEVCAP_FLR))           return -ENOTTY; // ②
    if (probe) return 0;
    return pcie_flr(dev);
}
```

- ① `PCI_DEV_FLAGS_NO_FLR_RESET` 只由内核 `quirks.c: quirk_no_flr()`（`DECLARE_PCI_FIXUP_EARLY`）设置，
  现有清单里全是 AMD/Intel/MediaTek 的特定型号，**没有 NVIDIA**，且**没有全局 `pci=noflr`**。
- ② `dev->devcap` 是**枚举时缓存的** DevCap，DevCap 本身是只读寄存器 →
  userspace `setpci` 既改不动、也影响不了缓存。
- → **userspace 无法通过内核门控阻止它**（除非改内核加 quirk）。

---

## 2. 真正的解法：驱动自带 regkey `RMPcieFLRPolicy=1`

在 `NVIDIA/open-gpu-kernel-modules` 的
`src/nvidia/interface/nvrm_registry.h` 里：

```c
#define NV_REG_STR_RM_PCIE_FLR_POLICY                  "RMPcieFLRPolicy"
#define NV_REG_STR_RM_PCIE_FLR_POLICY_DEFAULT          0
#define NV_REG_STR_RM_PCIE_FLR_POLICY_FORCE_DISABLE    1
// Type DWORD
// Regkey to force disable Function Level Reset
```

对应的运行时字符串（`strings nvidia.ko`）：

```
NVRM: Pcie FLR Policy reg key = %d
NVRM: FLR is force disabled using regkey/similar mechanism. Failing early.
NVRM: FLR is either not supported or is disabled.
os_pci_trigger_flr
```

**即：`RMPcieFLRPolicy=1`（FORCE_DISABLE）会让驱动在 `os_pci_trigger_flr` 里早退，
根本不去调 `pcie_reset_flr`。**

### 用法

```bash
# 加载时（需要重编/重载模块）：
modprobe nvidia NVreg_RegistryDwords="RMPcieFLRPolicy=1"

# 或写进 /etc/modprobe.d/：
options nvidia NVreg_RegistryDwords="RMPcieFLRPolicy=1"
```

多个 key 用 `;` 分隔，例如
`NVreg_RegistryDwords="RMPcieFLRPolicy=1;RmForceExternalGpu=1"`。

### 顺带的兄弟 key

| Key | 作用 | 备注 |
|---|---|---|
| `RMPcieFLRPolicy` | `1` = 强制禁用 FLR | **本方案主手段** |
| `RMSecBusResetEnable` | Secondary Bus Reset 开关 | bus reset 在本硬件同样危险（C7），可考虑一并禁用 |
| `RMPcieFlrDevinitTimeout` | FLR devinit 超时倍率（1–4） | 只影响 FLR 后的等待，不阻止 FLR |

---

## 3. 手段矩阵（按可行性）

| # | 手段 | 作用面 | 可行性 | 风险 |
|---|---|---|---|---|
| **S1** | `NVreg_RegistryDwords="RMPcieFLRPolicy=1"` | 驱动内部 FLR | ✅ **纯用户态，立即可用** | 低；需重载模块验证 |
| S2 | 不卸载 / 不热拔（teardown 靠重启） | 整个 remove 路径 | ✅ 已在 `scripts/` 落地 | 运维约束 |
| S3 | 内核 quirk：给 `10de:2d04`（或 `is_thunderbolt` 的 NVIDIA 设备）置 `NO_FLR_RESET` | 内核 FLR 门控 | ⚠️ 需重编内核 | 中；且**绕不过 nvidia 的内部早退？不，能**（见 1.3①） |
| S4 | `reset_method` sysfs 改写 | 内核复位表 | ❌ 对 nvidia **无效**（1.2） | — |
| S5 | 内核 fixup 清 `dev->devcap` FLR 位 | 内核 FLR 门控 | ⚠️ 需重编内核 | 中 |
| S6 | 上游修 nvidia：`remove` 前 `pci_device_is_present()` + TB 下跳过 FLR + 注册 `pci_error_handlers` | 根治 | 🕓 等上游 | — |

推荐组合：**S1（关 FLR）+ S2（不卸载）**。S1 先上，S2 兜底；S3 作为可选的内核侧加固。

---

## 4. 需要注意

1. **`acpi_remove_notify_handler → __flush_workqueue` 是另一层**。卸载挂死的最终卡点在这里，
   位于 FLR 之后。S1 关掉 FLR **是否连带解决**这个 flush 挂死，**尚未验证**——
   很可能成立（FLR 把 endpoint 打乱 → 挂起的 ACPI 工作项卡住），但必须实测。
2. 关闭 FLR 后，**驱动侧的“复位恢复”能力也没了**。对本项目而言这不是损失
   （C7 已证明 FLR/bus reset 都救不了掉线），但要知道这个取舍。
3. `RMPcieFLRPolicy=1` 需要**重载模块**才生效；当前正卡在 D 状态，只能重启后验证。

---

## 5. 验证结果（2026-09-27，E1/E2 **已通过** ✅）

| # | 实验 | 结果 |
|---|---|---|
| **E1** | 加载时带 `NVreg_RegistryDwords=RMPcieFLRPolicy=1` | ✅ 生效：`/sys/module/nvidia/parameters/NVreg_RegistryDwords = RMPcieFLRPolicy=1`；GPU 正常 UP |
| **E2** | 在 E1 下 `modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia` | ✅✅ **2 秒内正常完成，不再挂死！** dmesg 仅 `nvidia-nvlink: Unregistered Nvlink Core` |
| **E3** | 完整 down→up 循环（`egpu-down.sh` → `egpu-up.sh`） | ✅ 卸载后 GPU 仍在总线；重新加载后 Gen3 x4、`nvidia-smi` 正常 |
| E4 | 仅内核 quirk（不加载 regkey） | 未做（已无必要） |

### 结论修正（相对 §4 的保留意见）

- **§4 的疑虑“ACPI flush 挂死是另一层”被证伪**：挂死的最终卡点虽是
  `acpi_remove_notify_handler → __flush_workqueue`，但它**由 FLR 触发**——
  FLR 把 TB 后的 endpoint 打乱，导致挂起的 ACPI 工作项无法完成。
  `RMPcieFLRPolicy=1` 关掉 FLR 后，整条 remove 路径恢复正常。
- 因此 **teardown 重新变为“可卸载”**，热插拔流程可以完整自动化（down/up 都能跑）。

> E2 是**关键判定**：结论 = teardown **可以**卸载，但**前提是模块带 RMPcieFLRPolicy=1 加载**。
> `scripts/egpu-down.sh` 已据此实现：检测不到该 regkey 就拒绝卸载（防挂死）。

### 仍未验证

- **E3' 热拔 dock（驱动加载中）**：内核会走 `pci_device_remove → nv_stop_device`。
  既然 FLR 已禁，理论上也应安全，但**尚未实测**（下一次插拔循环可顺带验证）。

---

## 6. 参考

- `NVIDIA/open-gpu-kernel-modules` `src/nvidia/interface/nvrm_registry.h`
  （`NV_REG_STR_RM_PCIE_FLR_POLICY` / `_FORCE_DISABLE`）
- 本机 `/lib/modules/7.3.0-rc4/video/nvidia.ko` 的 `strings` / `nm -u`
- 内核 `drivers/pci/pci.c`（`pcie_reset_flr` / `pcie_flr` / `pci_reset_fn_methods`）
  与 `drivers/pci/quirks.c`（`quirk_no_flr`）
- 本仓库：`scripts/egpu.conf` / `egpu-up.sh` / `egpu-down.sh`（`NVreg_RegistryDwords=RMPcieFLRPolicy=1`）
