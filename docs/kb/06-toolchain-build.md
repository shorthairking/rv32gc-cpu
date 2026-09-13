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

### 3.1 本项目已完成的 Spike 构建（2026-09-13）

```bash
# 已执行并验证：
cd rv32gc-cpu/tools
git clone --depth 1 https://github.com/riscv-software-src/riscv-isa-sim.git spike
cd spike && mkdir build && cd build
../configure --prefix=$PWD/../../spike-install && make -j16 && make install
# 产出：tools/spike-install/bin/spike（版本 1.1.1-dev，支持 --isa=rv32i、--log-commits）
```
用途：① 生成 riscv-arch-test 的参考签名；② 生成提交级黄金轨迹（`--log-commits`）与 RTL 轨迹比对。
`tools/` 已在 `.gitignore` 中（不入库）。

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

## 7. 在沙箱内运行 Vivado CLI 的要点（实测）

| 问题 | 现象 | 解决 |
|---|---|---|
| Vivado 无法写 `$HOME/.Xilinx` | `Failed to create directory to save app.xml at '/home/<user>/.Xilinx/...'` → `ERROR: [Common 17-1219]`、`catalog_2025.2.xml: cannot open file`，随后 `Exiting Vivado` | 把 `HOME` 指向**工作区内**目录再运行：`HOME=/home/shorthair/dsh/rv32-cpu/rv32gc-cpu/.vivado_home vivado -mode batch …`（该目录已加入 `.gitignore`） |
| 批处理模式无 GUI | 需要 `-mode batch -nojournal -nolog -source <tcl>` | 所有工程生成/综合/实现/下载都用 tcl，符合任务"用 CLI 而非 GUI"的要求 |
| 生成 IP | `create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name <name>` + `set_property -dict [...]` + `generate_target {…} [get_ips <name>]` | 参考 `fpga/tcl/create_clk_wiz_cpu.tcl`（已实测通过） |
| 同名 IP 重复创建 | `ERROR: IP name 'x' is already in use in this project` | 换 module_name，或先 `delete_ip_run`/`remove_files` 清理 |

**实测：CPU 时钟 Clocking Wizard（MMCM）解**（`xc7a200tfbg676-2`，Vivado 2025.2）

| 请求 | VCO | 实际输出 |
|---|---|---|
| 100 MHz | 1000.0 MHz（DIVCLK=1, MULT=10.0, CLKOUT0=10.0） | 100.0000 MHz |
| 75 MHz | 1003.1 MHz（DIVCLK=4, MULT=40.125, CLKOUT0=13.375） | 75.0000 MHz |
| 60 MHz | 997.5 MHz（DIVCLK=5, MULT=49.875, CLKOUT0=16.625） | 60.0000 MHz |
| 50 MHz | 1000.0 MHz（DIVCLK=1, MULT=10.0, CLKOUT0=20.0） | 50.0000 MHz |

> 自动求解模式下 `MMCM_CLKFBOUT_MULT_F`/`MMCM_CLKOUT0_DIVIDE_F` 为 disabled 参数，**不要显式写入**（会被忽略）；给出输入/输出频率后读回实际解即可。平台现有时钟 `clk_pll_33` 为 PLLE2_ADV（`DIVCLK_DIVIDE=2`、`MULT=33` → VCO=1650 MHz，可能超 -2 的 PLLE2 上限），本项目不改动它，只用其 33 MHz 输出。

## 8. 常见构建问题

| 问题 | 处理 |
|---|---|
| 工具链默认 `ilp32d` 与内核 `ilp32` 混用 | 这是 RISC-V Linux 的常规做法（内核软浮点 ABI + 用户态硬浮点 ABI），不要强行统一 |
| arch-test 框架需要 `uv`/`mise`/`ruby`/Sail | 用 Spike 生成签名，或手写构建脚本（见 `08-verification.md` §2.2） |
| `-Wl,--no-warn-rwx-segments` | binutils 2.39+ 的警告，arch-test 构建时需要显式加上 |
| U-Boot 用 glibc 工具链报头文件错误 | 改用自建 `riscv32-unknown-elf`（工作区 `riscv-gnu-toolchain` 源码可编译） |
