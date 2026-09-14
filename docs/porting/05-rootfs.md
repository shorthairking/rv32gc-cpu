# 根文件系统方案（busybox/initramfs 起步 → UBIFS 落 NAND）

> **文档定位**：RV32-GC 项目根文件系统的**演进路线、镜像生成流程与可靠性验证方案**。
> **上游依赖**：Linux 内核移植见 `docs/porting/03-linux-opensbi.md`；NAND 驱动与 MTD 分层见 `docs/porting/04-nand-driver.md`；分区口径见 `docs/porting/01-overview.md` §3。

---

## 1. 路线总览

```
阶段 1  busybox + initramfs（内嵌内核，RAM 中运行）
              │  目标：先把用户态跑起来，验证内核 + S 模式 + Sv32 + SBI 链路
              ▼
阶段 2  initramfs 引导 + NAND 挂载（内核从 NAND 读，根仍在 RAM）
              │  目标：验证 NAND 驱动在 Linux 下的读写与 MTD 分区识别
              ▼
阶段 3  UBIFS 落在 NAND rootfs 分区
              │  目标：真正的持久化根文件系统，掉电可恢复
              ▼
阶段 4  掉电 / 压力验证
```

- **演进纪律** [工程约定]：**阶段 1 不通过不得进入阶段 2**。initramfs 阶段的价值是把"内核能不能起来"与"NAND 驱动对不对"**解耦**——否则一个启动失败会同时有十几个可能原因。

---

## 2. 阶段 1：busybox + initramfs

### 2.1 为什么从 initramfs 起步

| 理由 | 说明 |
|---|---|
| 解耦 | 根文件系统在 RAM 中，**不依赖 NAND 驱动**，可独立验证内核 + SBI + Sv32 |
| 快速迭代 | 改一次 busybox 配置只需重打包 `cpio`，不需要烧写 NAND |
| 兜底 | initramfs 可**长期保留**为 rescue 根，NAND 故障时仍能启动 |

### 2.2 构建要点

**busybox**

- 静态链接编译（`CONFIG_STATIC=y`），避免 initramfs 阶段还要解决动态库依赖。
- 交叉工具链：`/opt/riscv/bin/riscv32-unknown-linux-gnu-`（GCC 16.1.0）。[环境实测]
- **必须确认工具链的 ABI 与内核一致**（RV32 下注意 `ilp32` / `ilp32d` 的选择必须与内核 `CONFIG_FPU`/浮点 ABI 一致）。

**initramfs 打包**

- 目录骨架：`/init`（**必须是 PID 1**）、`/bin`、`/sbin`、`/dev`、`/proc`、`/sys`、`/etc`。
- 打包命令（`cpio` 的 `newc` 格式是内核要求的）：

  ```sh
  cd <rootfs-dir>
  find . -print0 | cpio --null -ov --format=newc > ../initramfs.cpio
  gzip -9 ../initramfs.cpio          # 可选压缩
  ```

- **内核侧**：`CONFIG_BLK_DEV_INITRD=y` + `CONFIG_INITRAMFS_SOURCE=<path>` 内嵌；或由 U-Boot 以外部 initrd 传入。
  → 上游 `linux/arch/riscv/configs/nommu_virt_defconfig` 中可见 `CONFIG_BLK_DEV_INITRD=y` 的用法。[RTL 实测] `linux/arch/riscv/configs/nommu_virt_defconfig:3`

- **`/init` 的硬性要求**：必须是**可执行**的二进制或脚本，且**不能依赖尚未挂载的 `/proc`、`/sys`**；早期只做最小动作（挂载 `proc`/`sys`、起 shell）。

### 2.3 验收判据（阶段 1）

| # | 判据 | 判定方式 |
|---|---|---|
| F1 | 内核进入用户态 | 日志出现 `Run /init as init process` |
| F2 | `init` 启动成功 | 出现 busybox shell 提示符 |
| F3 | `proc`/`sys` 可挂载 | `mount -t proc` 成功，`/proc/cpuinfo` 可读 |
| F4 | **SBI 调用可用** | 定时器/关机路径正常（如 `poweroff` 走 SBI） |
| F5 | **Sv32 生效** | 用户态可运行且 MMU 未 fault |

---

## 3. 阶段 2：initramfs 引导 + NAND 挂载

### 3.1 目标

在内核已能启动的前提下，**单独验证 NAND 驱动在 Linux 下的行为**：

1. NAND 控制器 probe 成功；
2. MTD 分区表按 `mtdparts` 正确切分（4 个分区）；
3. 能从 NAND **读**内核/dtb 分区并**逐字节比对**；
4. 能**写**并**读回**。

### 3.2 验收判据（阶段 2）

| # | 判据 | 判定方式 |
|---|---|---|
| F6 | MTD 分区识别 | `/proc/mtd` 出现 4 个分区，名称与 `mtdparts` 一致 |
| F7 | 分区大小与对齐 | 与 `01-overview.md` §3.2 核算表一致（256K / 50M / 1M / 剩余） |
| F8 | NAND 读正确 | `dd if=/dev/mtdblock1 of=... bs=...` 后与源镜像 `cmp` 一致 |
| F9 | NAND 写回读 | 写一页 → 读回 → 逐字节比对 |
| F10 | **ECC 纠错** | 注入 1 bit 错误后仍能正确读回 |
| F11 | 坏块跳过 | 人为标记坏块，读写自动跳过 |

- **注意**：阶段 2 仍用 initramfs 作根，**`rootfs` 分区只做裸读写测试**，尚未格式化为 UBIFS。

---

## 4. 阶段 3：UBIFS 落在 NAND

### 4.1 为什么选 UBIFS

| 特性 | 价值 |
|---|---|
| 为**裸 flash**设计 | 直接工作在 MTD 之上（经 UBI 层），不需要 FTL 模拟块设备 |
| **掉电安全** | 日志式结构 + 原子提交，掉电后能恢复到一致状态 |
| **磨损均衡** | UBI 层自带，延长 NAND 寿命 |
| **坏块容忍** | UBI 在坏块上自动搬迁 |

- **替代方案对比**：

  | 方案 | 评价 |
  |---|---|
  | **UBIFS** | ✅ **推荐**：原生 flash 文件系统，掉电安全 |
  | JFFS2 | 可用，但挂载慢（全片扫描）、磨损均衡较弱 |
  | YAFFS2 | 老，非主线友好 |
  | 只读 squashfs + overlay | 只读根可行，但持久化层仍需 UBIFS |

### 4.2 栈结构

```
┌──────────────────────┐
│       UBIFS          │  文件系统（挂载点 /）
├──────────────────────┤
│        UBI           │  磨损均衡、坏块管理、卷管理
├──────────────────────┤
│        MTD           │  分区（rootfs 分区）
├──────────────────────┤
│   NAND 驱动 + 控制器  │  见 04-nand-driver.md
└──────────────────────┘
```

### 4.3 内核配置要点 [工程约定]

| 项 | 值 |
|---|---|
| `CONFIG_MTD=y` | 必需 |
| `CONFIG_MTD_UBI=y` | 必需（UBI 层） |
| `CONFIG_UBIFS_FS=y` | 必需（文件系统） |
| `CONFIG_MTD_UBI_BLOCK` | 按需（如需块设备仿真） |
| 分区表 | `mtdparts` + DTS `partitions`，**同源** |
| 坏块表 | 见 `04-nand-driver.md` §6.2 |

- **⚠️ UBI 的固有代价**：UBI 会对分区做"**保留块**"处理（PEB 管理），**实际可用容量小于 MTD 分区容量**。因此 `rootfs` 分区的 614 块**不能全给 UBIFS**——需扣除 UBI 开销（坏块表、磨损均衡预留）。
  → **处置**：`rootfs` 分区按"剩余全给"定义即可（`01-overview.md` §3.1 用的是 `-`），**UBI 内部开销由 UBI 自己管理**，不要在分区表里预留。

### 4.4 镜像制作流程

[工程约定] UBIFS 镜像在**离线**制作（`mkfs.ubifs` + `ubinize`）：

```sh
# 1) 制作 UBIFS 镜像
mkfs.ubifs -r <rootfs-dir> -m 2048 -e <LEB-size> -c <max-LEB-count> \
           -o ubifs.img

# 2) 打包成 UBI 镜像（需 ubinize.cfg 描述卷）
ubinize -o ubi.img -m 2048 -p <PEB-size> ubinize.cfg
```

- **关键参数必须与 NAND 几何一致**（`-m` 最小 I/O、`-e` LEB 大小、`-p` PEB 大小、`-c` 最大 LEB 数）。
  → **这些参数的取值依赖 `04-nand-driver.md` §1 的几何口径，该口径当前有矛盾（§1.2），必须关闭后才能定稿镜像参数。**
  → 对本文 NAND：`-p 128KiB`（PEB = 块大小）、`-m 2048`（页大小）。
- **烧写**：由 U-Boot 侧完成（`nand erase` + `nand write`，或 `ubi write`/`ubifs` 系列命令）。
- **注**：上述 `mkfs.ubifs`/`ubinize` 是宿主工具链的通用用法，**具体参数值必须按实际几何核算**，不得照抄示例。

### 4.5 验收判据（阶段 3）

| # | 判据 | 判定方式 |
|---|---|---|
| F12 | UBI 卷创建成功 | 内核日志 `UBI: attached mtd3` 类行 |
| F13 | UBIFS 挂载成功 | 日志 `UBIFS: mounted UBI device` |
| F14 | **根从 UBIFS 启动** | `root=` 指向 UBI 卷，进入 shell 且 `mount` 显示 rootfs 为 ubifs |
| F15 | 持久化 | 写文件 → 重启 → 文件仍在 |
| F16 | 剩余空间合理 | `df` 显示容量扣除 UBI 开销后仍可用 |

---

## 5. 镜像生成流程（objcopy 按 LMA 切镜像）

### 5.1 原则

- **按 LMA（Load Memory Address）切分**，**不是 VMA**。[旧项目转述] 见 `docs/kb/tools-and-flow.md` §4
- **原因**：链接脚本中 `.data` 等段的 VMA（运行地址）与 LMA（加载地址）通常不同；烧写镜像必须携带 LMA 语义，否则 `.data` 初值丢失。

### 5.2 流程

```
内核 ELF ──objcopy(按段/LMA)──▶ *.bin ──▶ (可选压缩) ──▶ NAND kernel 分区
DTS      ──dtc──────────────▶  *.dtb ──▶                NAND dtb 分区
rootfs   ──mkfs.ubifs+ubinize──▶ ubi.img ──▶            NAND rootfs 分区
U-Boot   ──(补丁/board 层)────▶ u-boot.bin ──▶           SPI NOR
OpenSBI  ──make FW_JUMP──────▶ fw_jump.bin ──▶          SPI NOR / DDR
```

### 5.3 强制要求 [工程约定]

1. **打包脚本必须打印每段的 LMA/VMA 对照表**（`readelf -l` / `objdump -h` 输出），作为打包日志的一部分 —— 否则无法审查镜像是否切对。
2. **镜像大小必须核对分区容量**：

   | 镜像 | 上限 | 出处 |
   |---|---|---|
   | 内核镜像 | ≤ **50 MiB**（`kernel` 分区） | `01-overview.md` §3.1 |
   | DTB | ≤ **1 MiB**（`dtb` 分区） | 同上 |
   | U-Boot env | ≤ **256 KiB**（`env` 分区） | 同上 |
   | rootfs | ≤ 剩余 ~76.8 MiB | `01-overview.md` §3.2 |

3. **超限即构建失败**（fail-closed），不得静默截断。

### 5.4 验收判据（镜像）

| # | 判据 | 判定方式 |
|---|---|---|
| F17 | 镜像大小未超分区 | 脚本核对并打印 |
| F18 | LMA/VMA 对照已打印 | 打包日志含 `readelf -l` 输出 |
| F19 | 烧写后校验 | U-Boot 读回比对，或内核侧 `cmp` |

---

## 6. 掉电 / 压力验证方案

### 6.1 为什么必须做

NAND + UBIFS 的**唯一核心卖点就是掉电安全**。**不做掉电验证 = 没有验证 UBIFS 真的在工作**（与 `docs/kb/tools-and-flow.md` §5 的"变异测试"纪律一致）。

### 6.2 掉电测试 [工程约定]

| 项 | 方法 | 判定 |
|---|---|---|
| **随机掉电** | 在持续写文件的过程中**随机时刻断电**，重启后检查 | 文件系统能挂载；已提交的文件完整；无数据损坏蔓延 |
| **写入中断** | 写入大文件到一半断电 | 重启后 `fsck` 无致命错误或能自动恢复 |
| **反复次数** | **≥ 100 次**随机掉电循环 | 无累积性损坏；坏块数不显著增长 |
| **断电点覆盖** | 覆盖 UBI 提交、GC（垃圾回收）、磨损均衡搬迁等阶段 | 各阶段断电均可恢复 |

- **实施手段**：可控电源开关，或直接复位（`resetn`）；**必须记录断点时刻**，否则无法复现。

### 6.3 压力测试（读写） [工程约定]

| 项 | 方法 |
|---|---|
| **顺序写** | 连续写满 rootfs 剩余空间，观察速率与错误 |
| **随机写** | 小文件随机读写混合，长时间运行 |
| **擦除循环** | 对单块反复擦写，验证坏块管理触发 |
| **坏块注入** | 人为标记坏块，验证 UBI 搬迁 |
| **并发** | 多进程同时读写（如 `dd` + `tar`），验证一致性 |
| **长时稳定** | ≥ 24 h 连续运行，无 panic / 无 I/O error |

### 6.4 验收判据（可靠性）

| # | 判据 | 判定方式 |
|---|---|---|
| F20 | 掉电后可恢复 | ≥ 100 次随机掉电循环，每次均能启动到 shell |
| F21 | 无静默数据损坏 | 掉电后已提交文件逐字节校验一致 |
| F22 | 坏块增长受控 | 压力测试前后坏块数对比，增长在预期内 |
| F23 | 长时稳定 | ≥ 24 h 无 panic |
| F24 | **对比实验** | 关闭日志/原子提交后，同样的掉电测试**必须失败** —— 证明测试真的在测 |

- **F24 是关键反证实验**：若关闭掉电保护后测试仍然全通过，说明**测试没有真正制造出危险窗口**，需要重新设计断点策略。

---

## 7. 不确定项与风险

| # | 项 | 处置 |
|---|---|---|
| R1 | **NAND 几何矛盾未关闭**（`04-nand-driver.md` §1.2） | **阻塞项**：UBIFS 的 `-e`/`-p`/`-c` 参数无法定稿 |
| R2 | UBI 保留块开销 | 由 UBI 自行管理；实测 `df` 确认可用容量 |
| R3 | RV32 下 **UBIFS 可用性** | UBIFS 在 32 位平台是支持的，但需确认内核 5.14 树（`la32r-Linux`）的 `CONFIG_UBIFS_FS` 可用 |
| R4 | busybox ABI 与内核一致 | 明确 `ilp32` / `ilp32d` 选择，与内核浮点配置对齐 |
| R5 | initramfs 打包的 `cpio` 格式 | 必须 `newc`；格式错内核认不出 |
| R6 | 掉电测试的**硬件手段** | 需可控电源或复位开关；无此条件则本项无法验收（须报告母 Agent） |

---

## 8. 交付要求

[工程约定]

1. **busybox 配置** + **initramfs 打包脚本** + **UBIFS 镜像制作脚本**（含几何参数核算）；
2. **内核 defconfig fragment**（initramfs / MTD / UBI / UBIFS 相关项）；
3. **验证脚本**：按 §2.3 / §3.2 / §4.5 / §5.4 / §6.4 的判据逐项实现，**"未捕获即失败"**，兜底文案**不得含 `PASS`**；
4. **自证报告**：含 **F24 对比实验记录**与掉电循环记录；
5. **不确定项登记**：同步至 §7 与 `docs/kb/platform-facts.md` §9。
