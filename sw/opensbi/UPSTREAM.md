# UPSTREAM：OpenSBI 基线与 FW_JUMP 参数

> 依据 `rv32gc-cpu/docs/porting/03-linux-opensbi.md` §7.2 交付要求。落档时间：2026-09-21。
> 相关运行期证据：`docs/linux-port/logs/linux-boot-final.log`（`Boot HART Domain: root`、
> `Next Mode: S-mode`、`SBI specification v3.0 detected`）、`docs/linux-port/README.md` §5。

## 1. 基线

| 项 | 值 |
|---|---|
| 基线树 | `/home/shorthair/dsh/rv32-cpu/opensbi`（上游） |
| 本轮动作 | **零改动、零重建**：直接复用既有构建产物（L-m1/L-m2 均未改 OpenSBI 源码） |
| 产物 | `rv32gc-cpu/sw/boot/out/opensbi-build/platform/generic/firmware/fw_jump.bin`（272 080 B，md5 `b83ddf6105412e2cd81028c02f1f9a33`） |
| 平台/固件类型 | `PLATFORM=generic` + `FW_JUMP=y` |

## 2. FW_JUMP 参数（与引导链/内核的联动）

| 参数 | 值 | 必须与谁一致 |
|---|---|---|
| `FW_TEXT_START` | `0x01000000` | boot_stub 的 OpenSBI 目的地址（`BOOT_DST_OPENSBI`） |
| `FW_JUMP_ADDR` | `0x02000000` | U-Boot `CONFIG_TEXT_BASE`（`TEXT_BASE=0x02000000`） |
| `FW_JUMP_FDT_ADDR` | `0x03000000` | boot_stub 的 DTB 目的地址；**该地址被 U-Boot 的 DTB 占用，内核不得放在这里**（报告 §8.6） |

## 3. 复现命令（本轮未执行，仅登记口径）

```sh
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
./sw/boot/build_opensbi_rv32.sh          # 等价手写命令：
# make -C ../opensbi O=$PWD/sw/boot/out/opensbi-build PLATFORM=generic #      CROSS_COMPILE=riscv32-unknown-linux-gnu- FW_JUMP=y #      FW_TEXT_START=0x01000000 FW_JUMP_ADDR=0x02000000 FW_JUMP_FDT_ADDR=0x03000000 -j16
```

## 4. 运行期实测（S 模式 + SBI 链路）

```
Boot HART Domain            : root
Domain0 Next Address        : 0x02000000
Domain0 Next Arg1           : 0x03000000
Domain0 Next Mode           : S-mode
（内核侧）SBI specification v3.0 detected
          SBI TIME/IPI/RFENCE/DBCN/FWFT extension detected
          earlycon: sbi0
          OF: reserved mem: 0x01000000..0x0103ffff (256 KiB) nomap non-reusable mmode_resv1@1000000
          OF: reserved mem: 0x01040000..0x0104ffff (64 KiB)  nomap non-reusable mmode_resv0@1040000
```

最后两行是 OpenSBI 往 FDT 里注入的保留内存节点 ⇒ **FDT 传递链（boot_stub → OpenSBI →
U-Boot `booti` → Linux）完整**，且 OpenSBI 常驻区被内核正确保留（不被当成可用 RAM）。
