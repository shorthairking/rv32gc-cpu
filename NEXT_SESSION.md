# NEXT_SESSION.md — RV32-GC 新项目（重启版）跨会话交接

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu/`（dev 分支；master = 旧项目冻结历史，勿动）。
> 更新日期：2026-09-16（阶段二 2A M2 收尾中）。

## 1. 项目状态（截至本文件更新时）

- 阶段 0 ✅：重启五件套（AGENT.md / README.md / USAGE.md / prompts/×3）已提交，载体口径统一（commit `22ee44e`）。
- **阶段一 ✅（2026-09-14 完成，已 git 提交）**：15 篇文档全部落盘并通过母 Agent 复跑验收（文件/图/参数/引用标记/禁词六类判据），ISA 口径 T1–T8 引用闭环完成，知识库已重建（3711 文档，旧残留已清）。**当前停下等待用户审阅阶段一产物与 §5 裁决清单**。
  - `docs/design/01-overview-datapath.md` 02-pipeline 03-out-of-order 04-predictor 05-cache-memory 06-csr-privilege 07-verification（7 篇）
  - `docs/porting/01-overview.md` 02-uboot 03-linux-opensbi 04-nand-driver 05-rootfs（5 篇）
  - `docs/kb/platform-facts.md` isa-notes.md tools-and-flow.md（3 篇）

## 1.5 当前状态（2026-09-21 晚：2A 收官 + 2B/U-Boot 双线并行）

- **2A M1–M5 全部收官**（tag `2A-M5` 已推远端；master=dev=9fac069）：arch-test 全绿、60 MHz 时序达标（WNS +0.031/0 失败端点，面积 39.4%）、上板 `RESULT: RV32GC-M5-OK` @33 MHz 同域；板上三缺陷修复（R2 rdata 锁存 `7a06825`、mdu div_gen 字段序 `4a86a05`、步④ 窗口 `2e93a4f`）。
- **A 线 2B（用户已批）**：2B-1 前端+预测器 ✅（`f42827e`：regress 26/26、准确率 mixed 90.85% 选择器优于单侧、Spike 黄金轨迹 248/248）；**2B-2 后端：iq PASS(151 项)、IPC=2.0000（tb_back2_ipc 6000 条/3000 拍）、程序 0 锁步全绿（161/161、436 拍）、B1–B27 缺陷台账 sim/unit/back2_report.md、regress 29/30（仅锁步 FAIL 保留，T6 墙钟放宽档已加）**；B27 已定案两轮实证：检查点路线不可用（2B-1 前端只给预测-taken 组发检查点，禁改）、"旧代快照"被 `fhead_q−undo_fhead_w==dist` 六连证据证伪 ⇒ 失步在**重放内容/窗口**，判定实验已设计（见报告 B27 段）；全部未提交（rtl/back2/ + sim/unit back2 件 + scripts/regress.sh T6 档）。后续 2B-3 LSQ → 2B-4 合体 → 2B-5 时序上板。
- **B 线 U-Boot（基线=上游 fork dev 分支）**：B-1/B-2 板级骨架 ✅（u-boot `3d9e78e8e80`）；B-3 NAND 驱动 ✅（u-boot `124a604ebc5`，自包含 BCH-4 + DMA 描述符，13.6 万断言）；B-3.5 引导链 ✅（`1c8fce2`）；**QEMU chiplab machine ✅**（qemu/ chiplab-qemu-dev，-M chiplab，报告 docs/chiplab-qemu/）；**B-4/B-5 + E6–E8 ✅**（u-boot dev `0729af1c746`+`90373e8469b`，saveenv 持久/bootcmd 自动执行全绿）；**官方重打包 ✅**（spi_flash.img 956276B md5 27a9d9a5，旧件 .pre-E8.bak）；**Linux L-m1 ✅ + L-m2 ✅**（linux dev `46200caf`+`04e80124`，qemu `b7e2881e16`+`3c095bf329`，rv32gc-cpu tag `L2-NAND`；内核 0x03400000 可用内存 76MiB、NAND BCH-4 布局跨层交叉验证全 PASS，判据 L1–L8 全绿，报告 docs/linux-port/）；**L-m3 进行中**：UBI 层全通（空白 MTD 自动格式化/ubimkvol/UBIFS 首挂自格式化）、exec_op 擦除地址 bug 已修（原实现恒擦块 0）、**阻塞=UBI 多整页写未落盘**（u-boot E7 同构：SEQIN 锁存页号/PAGEPROG 用锁存，修复在途）、任务 2（纯 NAND 零注入冷启，nand_boot_test.py 就绪）与任务 3（精简 defconfig）未做；未提交（linux diff=defconfig+chiplab_nand.c 两文件），报告 docs/linux-port/README.md §9。
- **远端**：rv32gc-cpu origin 已切 SSH（git@github.com:shorthairking/rv32gc-cpu.git）；master/tag/dev 已推。u-boot/linux 两 fork 仓各建 dev 分支（u-boot 已切 SSH，linux 已切 SSH）。

### 1.5.1 ⏸ 暂停存档点 #2（2026-09-22 凌晨，用户指示"暂停当前所有任务并存档，等待指令再继续"）

- **所有子代理已 interrupt 停转**：`8009c161`（2B-2 第 18 轮进行中）、`501a646d`（L-m3 进行中）。无我方后台 job。禁令：用户指令到达前不得恢复任何子代理、不得提交任何仓库。
- **2B-2 现场（可编译检查点，未提交）**：程序 0/1 C1–C5 全绿（443/721 拍、IPC 0.3917/0.2469，C5 分档下限 0.30/0.19 已落地）；程序 2 C2 过、仅 C1 第 11 条（B28：`sb→lbu` 同拍进 LSU，更年轻 load 先发射读填充 0x13）；CHK 零违规、无停顿；regress 29/30（锁步 fail-closed 保留，T6 墙钟档已加）。**下一步已定**（back2_report.md §17.3）：发射侧修法——iq.v 导出 iss_oldest_o（选中项=队列最老）+ backend_top 门控 load 仅在最老时可发射（store 不门控防死锁），修法 (c)（alloc_rob+窗口外作废）随轮一并重落地；修完程序 2 C1–C4→C5 实测×0.8 定档→三程序全绿→regress 30/30→报告全绿。已定案结论：B27=日志下标不回绕（已修，7bit 切片）、2A C2=TB 缺 L1I 失效（已修，程序分基址 16KB 步进）、B28=发射序问题（修法见上）；IPC 证据 tb_back2_ipc=2.0000。改动范围：rtl/back2/、sim/unit/ back2 件、scripts/regress.sh（T6 档 12+/2−）；2A/front4 零修改。
- **L-m3 现场（未提交）**：UBI 层全通；真根因已定案=**子页读被框架 nand_read_subpage 接管**（NAND_SUBPAGE_READ 自动置位未清 + exec_op 不译 RNDOUT 0x05 ⇒ ECC 全 0xFF ⇒ 擦除判据静默返 0xFF）；已落补丁=清 NAND_SUBPAGE_READ+read_subpage=NULL、exec_op RNDOUT DATA_IN、n==2 仅列地址、SEQIN 锁存+PAGEPROG 提交帧；中断时正重编 Image→跑 nand_boot_test.py 三阶段+持久化终验→README §9 更新。**恢复时先核对 linux/ 工作树（defconfig + chiplab_nand.c 及可能的新改动）与编译状态**，再续 nand_boot_test.py。qemu 已提交至 `3c095bf329`；u-boot/opensbi/rv32gc-cpu 零修改。
- **备份/日志**：/tmp/b2chk/（r11c/r12/r12b/r13/r14/r15/r16/r17 日志与备份）、/tmp/b2work/、docs/linux-port/logs/（l3-* 等）。
- **恢复方式**：同一会话 send_message 对应 agent id；跨会话按 `sim/unit/back2_report.md`（§17.3 发射侧修法）与 `docs/linux-port/README.md` §9（子页读修复后续）fresh dispatch。

## 1.6 状态（M4 已收口；M5 上板待用户硬件参与）

## 2. 本会话关键裁决（2026-09-14，用户拍板）

1. 新项目载体 = **就地沿用 `rv32gc-cpu/` dev 分支**（不再另建 rv32gc-cpu-v2/；旧实现文件已从磁盘移除，历史在 master）。
2. 用户已发"开始阶段一"指令：info 复核 → coding 重写 docs/design+porting+kb → 收尾提交 → 停下审阅。
3. 子 Agent 路由（2026-09-21 更新）：`provider=opencode-go-chat`、`model=deepseek-v4.1-flash`、reasoning_effort=max（OpenCode Go 网关；旧 deepseek-official 口径作废）。

## 3. 平台硬事实快照（info 复核 + 母 Agent 复跑，引用分级见 docs/kb/platform-facts.md）

- `core_top` 例化 `chiplab/chip/soc_demo/loongson/soc_top.v:723`，48 端口；位宽真源 `config.h`（addr32/id4/len4/size3/burst2/lock 只接[0:0]/data32）。平台文档 nscscc_readme.md/Quick-Start.md 的 8bit len 与 [7:0] intrpt 为**过时文档**。
- DDR3 = AXI 默认从设备 0x0–0x07FF_FFFF；XIP 0x1C00_0000（别名 0x1FE8_0000）；无 boot ROM ⇒ RESET_PC=0x1C000000；confreg_sim 0x1FAF_0000 / confreg_syn 0x1FD0_0000 / UART 0x1FE0_01E0 / NAND 0x1FE7_8000(+0x40)。
- **CLINT 0x1F00_0000 / PLIC 0x1F10_0000 未被平台占用但会落 DDR3 默认通路 ⇒ 必须核内截获**。
- 时钟：clk_out1=50 MHz / clk_out2=33 MHz；上板口径 cpu_clk=uncore_clk=33 MHz 同域；config.h FREQ=33。
- `intrpt` 平台只接 [4:0]（`{3'b0,int_out[4:0]}`；int_out={1'b0,dma_int,nand_int,spi_inta_o,uart0_int,mac_int}）。
- **chiplab 工作树 dirty（HEAD a2e11b3）**：modified = soc_top.v（33MHz 补丁）、system_run.xpr、mig_axi_32.xci、axi_clock_converter_0.xcix；untracked = axi_2x1_mux 一批 Vivado 生成物。**处置待用户裁决**（纳入新基线 or 回退）。
- 软件底座：la32r-uboot 用 `RISCV_MMODE/RISCV_SMODE`（**无 RISCV_M_MODE 宏**；SIFIVE_CLINT depends RISCV_MMODE ⇒ S 模式 U-Boot 定时器走 SBI）；la32r-Linux=5.14.0（RISCV_M_MODE default !MMU，S 模式+SBI 路线成立）；opensbi/u-boot(2026.10)/linux(7.3-rc2) 本机可用。
- 分区 `256K(env),50M(kernel)ro,1M(dtb),-(rootfs)` 为**项目自定义约定**（旧 PROMPT.md:86），块对齐核算已通过：2+400+8+614=1024 块精确整除；起址 env 0x0 / kernel 0x40000 / dtb 0x3240000 / rootfs 0x3340000。
- **NAND 几何矛盾（门禁 D1）**："块 128 KiB"与"页 2048+64"不可同时成立；唯一自洽 = 主区 64 页×2048 + 备用 64×64。**D1/D2/D5 未关闭前禁止写 NAND 驱动实现与 UBIFS 参数定稿**。
- 环境：GCC 16.1.0 / Verilator 5.020 / iverilog 12.0 / Vivado 2023.2（坑①证据成立：需 LD_LIBRARY_PATH 前缀 lib/lnx64.o/Rhel/9）。**Spike 无源码无二进制（需重取编译）**；`fpga/run_vivado_batch.sh` 待建。

## 4. ISA 口径（已定版，引用见 docs/kb/isa-notes.md）

T1 mtval 写指令位=可选（本设计选择实现）；T2 取指 PMP 按 memory operation 独立检查、2B-parcel 是本设计选择（非规范强制）、无执行权限报 instruction access fault；T3 非对齐 vs page/access fault 优先级=实现可选（本设计选非对齐优先）；T4 AMO 被 PMP 拒恒 cause 7；T5 陷阱不降级委托、medeleg 逻辑 64 位（RV32 经 medelegh 别名）；T6 中断取点规范未明说（本设计纪律：副作用已落地之后取）；T7 MPRV 按 MPP 语义、xRET 到 <M 清 MPRV；T8 Zicbom rs1 不要求块对齐、CMO 不产生非对齐异常；menvcfg.CBIE/CBCFE 门控 S/U 模式 cbo.*。

## 5. 阶段一审阅裁决（2026-09-14，用户已拍板，全部生效）

1. **chiplab 回退**：已回退干净（HEAD `a2e11b3`，0 dirty；原接线 `clk_out1=cpu_clk`(50M)/`clk_out2=uncore_clk`(33M) 恢复）；不采用旧项目任何修改。
2. **chiplab 可改**：本项目可不受限制地修改 chiplab（按需，含 `soc_top.v`/`intrpt` 扩展）。
3. **CMO block size**（已定）：cbo.clean/flush block=64B（L2 行）、cbo.zero=32B（L1D 行）；设备树属性 `riscv,cbom-block-size`/`riscv,cboz-block-size` 发现；无自定义 CSR。
4. **mtvec/stvec Vectored**（已定）：实现。
5. **NAND**（已定）：无原始资料；以 chiplab RTL（`nand.v`/`apb_dev_top_with_nand.v`）与 la32r-Linux 驱动（`ls1a_nand.c`）为准；**不改 chiplab NAND 模块**；几何口径按"块 128KiB=主区 64 页×2048B，备用区另行"工作。
6. **Spike**（已定）：由用户在沙箱外编译，目标安装路径 `/opt/riscv/bin/spike`；编译命令见 §6；编好后知会母 Agent 记录版本。
7. **PMP 粒度**（已定）：保持 G=0（NA4 可用）；资源允许前提下性能优先，资源告警再议。

## 6. 常用命令

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu   # 项目仓库（dev 分支）
git log --oneline -3                          # 22ee44e = 阶段0 载体定稿
kb_manage action=reindex                      # 常驻知识库重建（docs/kb 变更后必跑）
node ../dsh-extension/bin/riscv-kb.js search "<词>"   # kb CLI
source /home/shorthair/fpga/Vivado/2023.2/settings64.sh
export LD_LIBRARY_PATH=/home/shorthair/fpga/Vivado/2023.2/lib/lnx64.o/Rhel/9:$LD_LIBRARY_PATH
/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc --version
```

## 6.5 Spike 编译（用户执行，沙箱外；装好后通知母 Agent）

```bash
# 1) 依赖（需 sudo，沙箱内不可用，由用户执行）
sudo apt-get install device-tree-compiler libboost-regex-dev libboost-system-dev

# 2) 取源码（二选一）
# A) 独立仓库（推荐）
git clone https://github.com/riscv-software-src/riscv-isa-sim ~/riscv-isa-sim
cd ~/riscv-isa-sim
# B) 或复用工具链子模块（版本与工具链匹配）
# cd /home/shorthair/dsh/rv32-cpu/riscv-gnu-toolchain && git submodule update --init spike && cd spike

# 3) 编译安装到 /opt/riscv（与工具链同前缀）
mkdir build && cd build
../configure --prefix=/opt/riscv --enable-commitlog
#   若提示不认识 --enable-commitlog（老版本无该选项），去掉它重试
make -j$(nproc)
sudo make install
spike --version     # 预期 /opt/riscv/bin/spike
```

- 验证（可选）：`spike --isa=rv32imafdc_zicsr_zifencei_zicntr_zicbom <elf>`。
- arch-test 官方调用口径：`spike --instructions=100000000 -l --log-commits --log=<trace> --isa=rv32imafd_zicclsm_zicsr_zifencei_zicntr_zaamo_zalrsc`（`--log-commits` 输出在 **stderr**）。
- ✅ **已就绪（2026-09-14）**：`/opt/riscv/bin/spike` 1.1.1-dev，经母 Agent 实测（ISA 串解析、commitlog 走 stderr、`--instructions` 限流、裸 ELF 需 `-m` 映射含头 PT_LOAD）。

## 7. 纪律提醒（对本文件读者）

- **kb 检索环境（2026-09-14 发现，待处理）**：常驻 `kb_search` 的 LSA 语义层已退化（返回无关命中）；`kb_get`（path+行号）与直接 `read` 手册源文件完全正常。已做：CLI `node dsh-extension/bin/riscv-kb.js build --no-lsa` 把磁盘索引重建为纯词法版；**待用户重启 `dsh web` 使常驻进程重载**。重启前子 Agent 查 ISA 细节一律用 `kb_get`/`read`（`riscv-isa-manual/src/**`），不依赖 `kb_search` 排序。
- 母 Agent 只调度；子 Agent 路由 opencode-go-chat/deepseek-v4.1-flash（2026-09-21 用户指令切换），**reasoning_effort 一律 "max"**（2026-09-14 用户指令；适配器支持 off/low/high/max）；知识盲区：kb → 联网 → 自试≤3 → 上报。
- **goal 纪律（AGENT.md §0.7，2026-09-17 收紧）**：母 Agent 未在自己 session 运行实质性任务（bash 验证/文件读写）时禁止 create_goal/update_goal resume；派发子 Agent 后结束回合等宿主完成通知（子 Agent 结束自动唤醒母 Agent 交接）；禁止轮询；子 Agent 自驱一次做完；goal 工具仅顶层 Agent 可用。历史 goal（goal-783b30b5）已 paused 且按新规不再 resume。
- 旧项目（master 分支、kb 中 rv32gc-project 来源）只作反面教训，禁止照抄。
- 阶段一结束必须停下等用户审阅后再进阶段二（2A 顺序 5 级基线核）。
