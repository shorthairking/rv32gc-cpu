# KB-06 工具链与第三方组件构建

## 1. 工作区已有工具

| 工具 | 路径/版本 | 用途 |
|---|---|---|
| RISC-V GCC | `/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc`，GCC **16.1.0**，glibc，默认 `-march=rv32imafdc_zicsr_zifencei_zmmul_zaamo_zalrsc_zca_zcd_zcf -mabi=ilp32d` | 内核/uboot/OpenSBI/用户态/裸机测试 |
| Vivado | `/home/shorthair/fpga/2025.2/Vivado/bin/vivado`（v2025.2） | 综合/实现/下载；自带 XSim（`xvlog/xelab/xsim`） |
| git / make / gcc / flex / bison / perl | 系统自带 | 构建工具 |
| **缺失** | verilator、iverilog、spike、qemu、sail、uv、ruby | 需安装/构建（见下） |

**沙箱限制**：`sudo` 不可用（`no new privileges`），系统包安装需用户在沙箱外执行；源码编译可在工作区内完成。

## 2. 仿真器获取

```bash
# 方案 A（推荐，用户在沙箱外执行）：Ubuntu 24.04 官方包
sudo apt install verilator iverilog gtkwave    # verilator 5.020 / iverilog 12.0

# 方案 B：源码编译（在 rv32gc-cpu/tools/ 下，不污染系统）
git clone https://github.com/verilator/verilator -b v5.020 --depth 1
cd verilator && autoconf && ./configure --prefix=$PWD/../install && make -j$(nproc) && make install
git clone https://github.com/steveicarus/iverilog -b v12_0 --depth 1
cd iverilog && sh autoconf.sh && ./configure --prefix=$PWD/../install && make -j$(nproc) && make install

# 方案 C：Vivado 自带 XSim（无需安装，速度慢）
xvlog -sv rtl/**/*.v sim/tb/*.v && xelab -debug typical tb_top -s tb && xsim tb -R
```

## 3. 参考模型（Spike）

arch-test 的参考签名与"提交级黄金轨迹"都依赖参考模型；Sail 依赖 OCaml 工具链较重，**推荐用 Spike**：

```bash
git clone https://github.com/riscv-software-src/riscv-isa-sim --depth 1
cd riscv-isa-sim && mkdir build && cd build
../configure --prefix=$HOME/.local      # 需要 dtc、boost（或 --without-boost）
make -j$(nproc) && make install
# 运行 RV32GC
spike --isa=rv32imafdc_zicsr_zifencei --log-commits -l pk payload.elf
```

- Spike 支持 `+signature=<file>` 生成签名（arch-test 需要 `--signature-granularity 4`）；
- `--log-commits` 输出提交级轨迹（pc / 指令 / rd / 写数据），用于与本 RTL 的 `debug0_wb_*` 轨迹逐条比对。

## 4. OpenSBI（RV32，M 模式固件）

```bash
git clone https://github.com/riscv-software-src/opensbi --depth 1
cd opensbi
make CROSS_COMPILE=riscv32-unknown-linux-gnu- PLATFORM=generic \
     FW_DYNAMIC=y -j$(nproc)
# 产出：build/platform/generic/firmware/fw_dynamic.bin（配合 U-Boot 的 SBI 传递）
#      fw_payload.bin（把 U-Boot 作为 payload 打包，调试期更方便）
```

- 需要设备树中 `riscv,clint0` 与 `sifive,plic-1.0.0` 节点（本 CPU 已按此实现）；
- OpenSBI 要求 PMP（≥8 项，本设计 16 项）。

## 5. 用户态与根文件系统工具

```bash
# busybox（静态）
git clone https://github.com/mirror/busybox --depth 1
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- defconfig
# 打开 CONFIG_STATIC=y，然后：
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j$(nproc)

# mtd-utils（主机侧制作 UBIFS 镜像；需要 zlib/lzo 等）
git clone https://github.com/sigma-star/mtd-utils  # 或 https://git.infradead.org/mtd-utils.git
./autogen.sh && ./configure --without-xattr && make -j$(nproc)
# 产出 mkfs.ubifs / ubinize
```

## 6. 编译选项约定

| 目标 | `-march` | `-mabi` | 说明 |
|---|---|---|---|
| 内核 | `rv32imafdc_zicsr_zifencei_zicntr_zicbom` | `ilp32` | 内核强制 ilp32（`arch/riscv/Makefile`） |
| U-Boot | `rv32imac_zicsr_zifencei_zicntr_zicbom` | `ilp32` | U-Boot 通常不需要 F/D |
| OpenSBI | `rv32ima_zicsr_zifencei` | `ilp32` | 固件最小化 |
| 用户态/busybox | 默认 | `ilp32d` | 工具链默认硬浮点 |
| 裸机测试 | 按测试需要 | `ilp32`/`ilp32d` | 与 arch-test 的 per-test `-march` 对齐 |

**注意**：GCC 16 默认把 C 扩展拆成 `Zca/Zcd/Zcf`；为避免歧义，构建脚本中**显式写出**完整 `-march`。

## 7. 常见构建问题

| 问题 | 处理 |
|---|---|
| 工具链默认 `ilp32d` 与内核 `ilp32` 混用 | 这是 RISC-V Linux 的常规做法（内核软浮点 ABI + 用户态硬浮点 ABI），不要强行统一 |
| arch-test 框架需要 `uv`/`mise`/`ruby`/Sail | 用 Spike 生成签名，或手写构建脚本（见 `08-verification.md` §2.2） |
| `-Wl,--no-warn-rwx-segments` | binutils 2.39+ 的警告，arch-test 构建时需要显式加上 |
| U-Boot 用 glibc 工具链报头文件错误 | 改用自建 `riscv32-unknown-elf`（工作区 `riscv-gnu-toolchain` 源码可编译） |
