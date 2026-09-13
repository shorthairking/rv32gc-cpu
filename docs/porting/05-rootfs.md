# 根文件系统方案

> 上游文档：`00-overview.md`、`02-linux.md`。

---

## 1. 两阶段策略

| 阶段 | 方案 | 优点 | 风险 |
|---|---|---|---|
| **第一阶段** | **initramfs（busybox，内建进内核）** | 不依赖 NAND/UBI 驱动的正确性即可启动到 shell；构建简单；LA32R 板也是这么做的 | 内存占用（约 4~8 MiB），重启丢失修改 |
| **第二阶段** | **UBIFS on NAND（`rootfs` 分区）** | 真正"把 NAND 当硬盘"；掉电可恢复；满足任务"从 nand 启动"的完整语义 | 依赖 NAND 驱动 + ECC + UBI 的正确性（先完成第一、二阶段验证） |

**推荐执行顺序**：initramfs 先跑通 → NAND 读写验证通过 → 再切 UBIFS 作为根分区（内核命令行 `root=ubi0:rootfs rootfstype=ubifs ubi.mtd=rootfs`）。

## 2. initramfs 构建（第一阶段）

```bash
# 1) busybox（静态链接，ilp32d）
sw/rootfs/build_busybox.sh          # 使用 riscv32-unknown-linux-gnu- 工具链，CONFIG_STATIC=y
# 2) 组装 initramfs 目录树（overlay + busybox）
sw/rootfs/gen_initramfs.sh          # 生成 cpio.gz 到 sw/rootfs/initramfs.cpio.gz
# 3) 内核内建（或由 U-Boot 作为 ramdisk 加载）
CONFIG_INITRAMFS_SOURCE="sw/rootfs/initramfs"
```

**最小根文件系统内容**：

```
/init                → 挂载 /proc /sys /dev，启动 /bin/sh（或 /sbin/init）
/bin/busybox         → 全部小程序（ash, ls, cat, mount, mdev, ifconfig, ...）
/etc/inittab         → ::sysinit:/etc/init.d/rcS
/etc/init.d/rcS      → mount -t proc/sysfs/devtmpfs；mdev -s
/dev/console /dev/null
/lib/                → （静态链接时不需要）
```

**启动参数**：`console=ttyS0,115200 earlycon rdinit=/sbin/init`（initramfs 内建时内核会自动使用内建 cpio；若由 U-Boot 传 ramdisk，则用 `booti <kernel> <ramdisk> <dtb>`）。

## 3. UBIFS 根文件系统（第二阶段）

```bash
# 1) 制作 rootfs 镜像目录（overlay + busybox + 应用）
# 2) 生成 UBIFS 镜像（主机侧需要 mtd-utils）
mkfs.ubifs -r rootfs_dir -m 2048 -e 126976 -c 800 -o rootfs.ubifs
ubinize -o rootfs.ubi -m 2048 -p 128KiB -s 2048 ubinize.cfg
# 3) 写入 NAND（U-Boot）
tftpboot ${ramdisk_addr_r} rootfs.ubi
mtd erase rootfs
mtd write rootfs ${ramdisk_addr_r} ${filesize}
# 4) 内核命令行
setenv bootargs "console=ttyS0,115200 ubi.mtd=rootfs root=ubi0:rootfs rootfstype=ubifs rw"
```

**参数说明**（必须与 NAND 几何一致）：`-m 2048`（最小 I/O = 页大小）、`-p 128KiB`（擦除块）、`-e 126976`（LEB 大小 = 128 KiB − 2 × 2048）、`-s 2048`（子页大小）。若实测几何不同，按实测值修改。

## 4. 与 NAND 驱动的耦合点

1. UBI/UBIFS 依赖 **ECC 正确**（否则读出的页数据错误导致 UBI 校验失败）：必须先完成 `04-nand.md` 的 N9 之前的验证；
2. UBI 需要**坏块表**：控制器的坏块识别方式需实测（一般读 spare 区第 1/2 字节）；
3. 掉电恢复测试：写入过程中断电，重启后 UBI 应能恢复（这是"当硬盘用"的关键验收项）。

## 5. 容量规划

| 项 | 大小 | 说明 |
|---|---|---|
| NAND 总容量 | 128 MiB | `nand_type 2'h2`（1 Gbit）RTL 默认 |
| 可用块数 | 1024 块（128 KiB/块） | 扣除坏块与 UBI 开销 |
| 内核 + DTB | ≈ 5~8 MiB | 压缩后 Image |
| rootfs（busybox + 应用） | 目标 ≤ 40 MiB | 预留增长空间 |
| UBI 开销 | ≈ 2%（LEB/PEB 比例）+ 坏块预留 | `-c 800` 对应约 100 MiB |

## 6. 验收判据

- [ ] 第一阶段：内核启动后自动进入 shell，`ls /` / `cat /proc/cpuinfo` / `free` 正常；
- [ ] 第二阶段：`mount` 显示 `ubi0:rootfs on / type ubifs (rw)`；创建文件 → 重启 → 文件仍在；
- [ ] 掉电测试：写入过程中断电，重启后文件系统可挂载且无数据损坏；
- [ ] 空间：`df -h` 显示约 70+ MiB 可用；
- [ ] 性能：`dd` 顺序读 ≥ 1 MB/s、写 ≥ 200 KB/s（NAND + DMA + 33 MHz AXI 的现实预期）。
