# M4 里程碑报告 —— Vivado 2023.2 综合 / 时序（rv32gc-cpu 基线核）

- **日期**：2026-09-18；**器件**：`xc7a200tfbg676-2`（Artix-7，龙芯实验箱）；**工具**：Vivado 2023.2（batch/非工程模式）
- **入口**：`fpga/run_vivado_batch.sh`（三坑统一封装；**无任何散落的 `vivado -mode batch`**）
- **约束口径**：`fpga/soc_up.xdc`（平台时钟口径的本地只读拷贝，周期占位符由 tclarg 注入）
- **本次判据来源**：`docs/design/08-baseline-5stage.md` §M4 + 本任务书验收判据①~⑤

---

## 0. 结论摘要（TL;DR）

| 判据 | 结果 | 一句话 |
|---|---|---|
| ① `create_ip.tcl` rc=0，IP 全部生成 | ✅ **达成** | 5 个 IP（mult×3 / div×1 / **BRAM×1**），逐项配置自检 0 error，可重复运行（幂等） |
| ② `synth.tcl` rc=0、报告落 `fpga/out/` | ⚠️ **部分** | 流程与脚本全通、报告落盘；**整核综合在 Timing Optimization 阶段被 OOM 杀死**（Vivado RSS 28.7 GB / 机器 30 GB），根因见 §6 |
| ③ 时序 WNS ≥ 0 @60 MHz、资源在器件内 | ❌ **未达成**（面积阻塞 + 时序未收敛） | 面积：**FPU 单独 = 546 223 LUT = 器件 405.8 %**，整核综合 OOM；时序：**非 FPU 部分**放得下（27.8 %）但布线后 WNS **-6.652 ns @60 MHz**（≈42.9 MHz，§7.2） |
| ④ RTL 改动后回归不退化 | ✅ **达成** | `REGRESS: 23/23 PASS` + arch-test **I 39/39、Zicbom 3/3、SvZicbo 2/2、SvPMPZicbo 4/4、Sv 29/29**（改动 4 处，全部语义等价，§5） |
| ⑤ 交付说明（报告/关键路径/IP/约束/改动理由） | ✅ **达成** | 本文件 + `fpga/out/` 全部报告 |

**一句话**：M4 的**流程侧全部打通并自证**（IP 流、综合流、约束流、仿真侧双分支等价、基线不退化），并顺带**修掉了一个 79 k LUT 的面积黑洞**（Tag 阵列，见 §5 改动 4：非 FPU 全核 116 785 → **37 382 LUT**）；**面积侧仍有硬阻塞**——D 精度 FMA 的「精确对阶」行为模型（8192/4097 bit 移位域）单模块就 419 191 LUT，整个 FPU 是器件容量的 **4.06 倍**，导致整核既放不下、也无法完成顶层综合（OOM）。这不是"时序再优化一下"能解决的问题，需要 FPU 数据通路重写（§8：母 Agent 已裁决走**路线 A**，§8.1 给出精确定位清单与预期量级）。此外**非 FPU 部分布线后也未达 60 MHz**（-6.652 ns，长控制链，§7.2），已按裁决列为后续独立任务。

---

## 1. 环境与入口（三坑 + M4 新踩的坑④~⑨）

统一入口 `fpga/run_vivado_batch.sh <tcl> [tclargs...]`（`--dry-run` 可自检）：

| 坑 | 现象 | 处置 | 证据强度 |
|---|---|---|---|
| ① `libtinfo.so.5` 缺失 | Vivado 起不来 | `LD_LIBRARY_PATH` 前置 `lib/lnx64.o/Rhel/9` | 已封装 |
| ② 工程模式层次引擎失效 | 找不到 top | 走非工程模式（无 source 管理） | 已封装 |
| ③ 沙箱 HOME 污染 | 权限/状态写失败 | `HOME=<repo>/.vivado_home` | 已封装 |
| **④** `read_verilog` 不认 `-include_dirs` | `ERROR: [Common 17-170] Unknown option` | include 目录改交 **`synth_design -include_dirs`** | 实测，`synth.tcl` §2.3 |
| **⑤** RTL 里的 `N'(expr)` SV 转换 | `ERROR: [Synth 8-2716] syntax error near '''`（**整核无法综合**） | `rtl/plic/plic.v` 6 处改为等价比较（§5） | 实测：修复前 9 error / 后 0 |
| **⑥** `read_ip` 不产出可用综合源 | `ERROR: [Synth 8-439] module '<ip>' not found` | `read_ip` → **`generate_target {synthesis}`** → **`synth_ip`**（OOC DCP） | 实测对照 `fpga/scratch/ip_flow2.tcl` 模式 D |
| **⑦** 时钟约束晚于 `synth_design` | 综合不是时序驱动 ⇒ WNS 不可信 | XDC **在 `synth_design` 之前** `read_xdc` | 实测，`rv32_stage_xdc` |
| **⑧** 隐式工程默认 part 是 `xc7k70tfbv676-1` | `IP file is locked`（part 不匹配） | 先 `create_project -in_memory -part $PART` | 实测（首次全核综合失败即此因） |
| **⑨** `create_ip` 重复运行建 `<ip>_1` | `IP name ... already in use` | `ensure_ip`：磁盘已有 xci 就 `read_ip` 复用 | 实测修复后幂等 rc=0 |
| **⑩** RAM 推断**只支持单写口** | 多写口阵列不推断 RAM ⇒ 寄存器+大 mux（Tag 阵列 75 119 LUT） | 拆成两个单写口阵列 + `(* ram_style="distributed" *)`（§5 改动 4） | 实测 -79 403 LUT |

坑④~⑩ 已按"现象 + 证据 + 绕过"三件套补进 `docs/kb/tools-and-flow.md` §3。

**复现命令**（全部经统一入口）：
```sh
./fpga/run_vivado_batch.sh --dry-run fpga/tcl/create_ip.tcl      # 环境自检
./fpga/run_vivado_batch.sh fpga/tcl/create_ip.tcl                # ①：生成 5 个 IP
./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl                    # ②：整核综合（60 MHz）
./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl xc7a200tfbg676-2 10.0   # 100 MHz 余量跑法
./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl                     # 布局布线（基于 post_synth.dcp）
./fpga/run_vivado_batch.sh fpga/tcl/report_timing_detail.tcl fpga/out/post_synth.dcp 16.667 synth
```

---

## 2. 交付物清单

| 文件 | 作用 | 状态 |
|---|---|---|
| `fpga/run_vivado_batch.sh` | 三坑统一入口（未改；`--dry-run` 自检） | 既有 |
| `fpga/tcl/create_ip.tcl` | 5 个 IP：`rv32_mult_{signed,su,unsigned}`(mult_gen 12.0)、`rv32_div`(div_gen 5.1)、**`blk_mem_gen_cache_data`(blk_mem_gen 8.4)**；幂等 `ensure_ip` + 逐项配置断言 | 改（+BRAM 分节、+幂等） |
| `fpga/tcl/synth.tcl` | 非工程模式综合：`read_verilog`→`read_ip`→`generate_target`→`synth_ip`→`read_xdc`→`synth_design`→报告+DCP | 改（坑④⑥⑦⑧） |
| `fpga/tcl/impl.tcl` | `open_checkpoint post_synth.dcp`→opt/place/route→报告 | 改（坑⑥⑦） |
| `fpga/tcl/report_timing_detail.tcl` | **新增**：对任意检查点重下发周期并落盘 timing_summary + 关键路径 top20（用于 100 MHz 余量重分析） | 新增 |
| `fpga/soc_up.xdc` | **新增**：平台时钟口径的 core_top 约束（占位符周期；引脚约束不拷贝的理由见文件头） | 新增 |
| `fpga/out/*.rpt` `*.log` `*.dcp` | 利用率/时序/检查点/日志（判据②③证据） | 产物 |
| `fpga/scratch/**` | 排障与验证脚手架（IP 冒烟、BRAM 双分支对拍、IP 分支 TB 跑批、无 FPU 归因）；**非交付物**，见 §9 清理说明 | 脚手架 |

---

## 3. IP 清单与版本（判据①）

| IP 模块名 | IP 家族 / 版本 | 关键配置 | 用途（RTL 例化点） |
|---|---|---|---|
| `rv32_mult_signed` | `mult_gen` 12.0 | Parallel、Signed×Signed、32×32、`Use_Mults`(DSP)、`PipeStages=0`(纯组合)、P[63:0] | `rtl/exec/mdu.v`（mulh） |
| `rv32_mult_su` | `mult_gen` 12.0 | Signed×Unsigned、32×32、同上 | `rtl/exec/mdu.v`（mulhsu） |
| `rv32_mult_unsigned` | `mult_gen` 12.0 | Unsigned×Unsigned、32×32、同上 | `rtl/exec/mdu.v`（mul/mulhu） |
| `rv32_div` | `div_gen` 5.1 | Radix2、32/32、Unsigned、Remainder、ACLKEN/ARESETN、latency=**34**、tdata[63:0]={rem,quot} | `rtl/exec/mdu.v`（div/divu/rem/remu） |
| **`blk_mem_gen_cache_data`** | `blk_mem_gen` 8.4 | **Simple Dual Port**、32 bit×2048 深（每路）、字节写使能×4、`Enable_A/B` 用引脚、**`Operating_Mode_A=READ_FIRST`**、无输出寄存（读延迟 1 拍）、`PRIM=BRAM` | `rtl/cache/cache_array_bram.v` 综合分支（L1I 2 路 + L1D 4 路 = 例化 6 次） |

- `create_ip.tcl` 末尾打印 VLNV 清单（日志 `fpga/out/create_ip.vivado.log`）；每个 IP 都有 `assert_cfg` 配置断言（fail-closed）。
- **红线 1 合规**：以上全部是 **IP Catalog 的 IP**，RTL 与脚本中**没有任何 FPGA 原语**（全仓 `grep -rn "RAMB36\|RAMB18\|MMCME2\|BUFG\|DSP48E1" rtl/` 无命中）。

### 3.1 BRAM IP 的语义对齐与**双分支等价证据**

行为模型（`ifndef RV32GC_USE_VIVADO_IP`，仿真回归所用）与 BMG IP（`ifdef`，综合所用）逐条对齐 4 点：
1. **读延迟 1 拍**（不勾输出寄存）；2. **同址同拍「写+读」读出旧值**（`READ_FIRST`）；3. **字节写使能** `wea[3:0]`；4. **en 门控**写/读。

证据 1（**逐拍对拍，最强**）：`fpga/scratch/bram_equiv/` 把同一激励同时打进 IP 与 RTL 行为模型，逐拍比较 B 口读数据：
```
BRAM_EQUIV: PASS —— 逐拍比对 3101 次、差异 0 次（IP vs 行为模型）
```
（脚本 `run.sh` 为 fail-closed：必须捕获到 `checks≥2000 且 errors==0` 才可能 PASS；X 未初始化期已按设计口径掩掉并在脚本注释说明。）

证据 2（**原地验证**）：`fpga/scratch/ip_branch/run_ip_branch.sh` 在 **`-DRV32GC_USE_VIVADO_IP` 定义**下（即综合分支）链接 Vivado 生成的 IP 行为仿真模型，复用 `sim/unit` 既有 TB 判据：
```
IP_BRANCH: 4/4 PASS（tb_l1i / tb_l1d / tb_lsu / tb_fetch_unit，宏 RV32GC_USE_VIVADO_IP 已定义 + IP 行为仿真模型）
BRAM_EQUIV: PASS —— 逐拍比对 3101 次、差异 0 次
```
即：**Cache 数据阵列换成 BRAM IP 后，L1I/L1D/LSU/取指单元的既有判据全部不变**（这两条在 §5 改动 4 之后**已复跑确认仍然通过**，见 `fpga/scratch/ip_branch/work/`、`fpga/scratch/bram_equiv/work/`）。
> ⚠️ 同一脚本下 `tb_m3_ddr3`（core_top 级）**无法**在 IP 分支编译：MDU 的 mult_gen/div_gen 的 Vivado 仿真模型只有 **VHDL**（`sim/*.vhd`），iverilog 不能编。这是既有覆盖缺口（非本次引入），见 §9 风险 R3。

### 3.2 为什么 Tag 阵列**不**用 BRAM IP（M4 定稿）

`rtl/cache/cache_tag_array.v` 原注释设想"综合分支走 BMG（简单双口）"，实测**不可行**，三条理由（已写进 RTL 头注）：
1. **语义**：l1d 的 cbo.clean 维护扫描要求"只清 dirty、保留 tag/valid"。BRAM 读是同步的（数据下一拍才到），单写口做不到"同拍清 dirty 且保留 tag/valid"；改成"下一拍写回"会把清 dirty 推迟，且扫描最后一拍与恢复后的 store 抢同一写口 ⇒ 要么丢 dirty（数据不写回）、要么把无效行写出 valid=1（假命中），两条都是**静默错**。
   ⇒ 最终用**两个各自单写口的阵列**（`tagv_q`= {tag,valid}、`dirty_q`）表达原语义：dirty 单独存 ⇒ "清 dirty"就是一次普通写，不再需要 RMW（见 §5 改动 4；这也是本次 -79 k LUT 的关键）。
2. **面积(实测)**：每路 Tag = 256×21 bit = 5.25 kbit，6 路共 31.5 kbit；BRAM36 最小粒度 36 kbit ⇒ 每路独占 1 个 BRAM36（利用率 ~15%），而 LUTRAM 实测每路仅 **128 个 LUTRAM + ~20 FF**（§6.3）。容量小、随机寻址 ⇒ LUTRAM 是正确选择。
3. **红线 1 合规**：文件内**没有原语**（`ram_style="distributed"` 是综合属性），阵列由 RTL 推断；"用 IP"落在**真正有容量**的数据阵列上（16/32 KB 级，12 个 BRAM36 可核对）。

---

## 4. 判据逐条核对

| 判据 | 结果 | 关键输出 |
|---|---|---|
| ① create_ip rc=0、IP 清单 | ✅ | `fpga/out/create_ip.vivado.log`；5 个 IP，`== create_ip.tcl 完成` 后逐行 VLNV；重复运行不产生 `_1` 目录 |
| ② synth rc=0 + 报告落盘 | ⚠️ 部分 | 脚本流程全通（IP/约束/宏全对），**整核在 Timing Optimization 阶段 OOM**（§6.2）；**非 FPU 归因跑**：`RESULT_NOFPU: SYNTH_OK` + 报告落盘（§6.3） |
| ③ WNS ≥ 0 @60 MHz、资源在器件内 | ❌ | FPU = **546 223 LUT（405.8 %）**；非 FPU 全核 = §6.3（含 WNS/可达频率） |
| ④ RTL 改动后回归不退化 | ✅ | `REGRESS: 23/23 PASS`；arch-test `PASS (39/39)` + CMO/dirty 相关 4 组全绿（Zicbom 3/3、SvZicbo 2/2、SvPMPZicbo 4/4、Sv 29/29）；另加"IP 分支 TB 跑批"4/4 |
| ⑤ 交付说明 | ✅ | 本文件；关键路径见 §7 |

---

## 5. 本次对 RTL 的改动（4 处，全部语义等价、逐处自证）

> 口径：任务书允许的 RTL 改动是"时序/面积优化所需的最小改动"。本次 4 处分两类：
> **改动 1–3 是"使能性修复"**（不改就根本综合不了，其中改动 2/3 修的是"综合分支是空壳 ⇒ 网表功能破损"）；
> **改动 4 是实测驱动的面积优化**（-79 403 LUT，见下）。
> 每一处都给出"原状 → 现象/热点 → 改法 → 等价性证据"。

### 改动 1：`rtl/plic/plic.v`（6 处）—— 去掉 Vivado 不认的 SystemVerilog 定宽转换

- 原状：`5'(SOURCE_MIN)` / `5'(SOURCE_MAX)`（SV 定宽转换）。
- 现象：Vivado 的 Verilog（非 `-sv`）模式 `ERROR: [Synth 8-2716] syntax error near '''`，**整核无法综合**（9 error）；iverilog `-g2012` 能编过 ⇒ 只在综合侧暴露。
- 改法：直接写成 `(prio_off_word >= SOURCE_MIN)` 等；参数 ≤31 且左侧是 5 bit 无符号 ⇒ **无符号零扩展比较，逐位等价**。（同时保留 `prio_region`/对齐判定，索引口径不变。）
- 证据：修复前 9 error → 修复后 0 error；`./scripts/regress.sh` 23/23（含 `tb_plic`）不变；arch-test `rv32i/I` 39/39 不变。

### 改动 2：`rtl/cache/cache_array_bram.v` —— 落地综合分支的 BMG IP 例化（原为空壳）

- 原状：`ifdef RV32GC_USE_VIVADO_IP` 区间**只有注释**（例化被注释掉），`ifndef` 才是行为模型 ⇒ 宏定义时**两条分支都不生效**，`b_dout_r` 无驱动。
- 现象（实测）：综合把整个 Cache 逻辑剪掉（`l1d` 单独综合只剩 **39 LUT / 69 FF**），综合出的网表是**功能破损**的——即使综合"成功"，M4 判据⑤（BRAM IP 被例化）也不可能满足。
- 改法：写入 `blk_mem_gen_cache_data` 例化（SDP：`clka/ena/wea/addra/dina` + `clkb/enb/addrb/doutb`）；`a_dout_r` 在综合分支恒 0（SDP 写口无读通路；全设计无消费者：l1i/l1d 例化处均写 `.a_dout_r ()`）；补 **IP 规格一致性 `$fatal` 自检**（参数不符即 elaboration 失败，fail-closed）。
- 证据：§3.1 的 3101 拍逐拍等价 + 4 个 TB 在 IP 分支下判据不变。

### 改动 3：`rtl/cache/cache_tag_array.v` —— 去掉空的 `ifdef` 分支（两分支共用寄存器阵列）

- 原状：`ifdef` 区间同样只有注释 ⇒ 宏定义时 `rd_tag_r/rd_valid_r/rd_dirty_r` 无驱动，综合剪枝（与改动 2 同因）。
- 改法：删除 `ifdef/ifndef` 包裹，阵列实现**两分支共用**；头注写明 M4 定稿理由（§3.2 三条）。**改动 4 在此基础上进一步把阵列改成可推断 LUTRAM 的双阵列结构。**
- 证据：`tb_l1i`/`tb_l1d` 判据不变（回归 23/23）；本改动对**仿真完全无影响**（仿真分支本来就是它）。


### 改动 4（**面积优化**，实测驱动）：`rtl/cache/cache_tag_array.v` —— Tag 阵列改「两个单写口阵列 + LUTRAM 推断」

- **触发（哪条路径/哪个热点）**：不是时序路径，而是**面积热点**——无 FPU 归因综合的层次化利用率显示：6 路 Tag 阵列吃掉 **75 119 LUT + 31 872 FF**（占非 FPU 全核 LUT 的 **64 %**；`u_l1d` 一个模块 70 258 LUT）。根因：原实现把 `{tag,dirty,valid}` **打包**成一个阵列、并且有**两个写口**（`wr_en` 写整项、`dirty_clr_en` 写 dirty 位）。Vivado 的 RAM 推断**只支持单写口**，两个写口 ⇒ 退化成"寄存器堆 + 大规模读 mux"（报告里 `LUT as Distributed RAM = 0`、FF = 31 872 即此）。
- **怎么优化**：把元数据拆成两个**各自单写口**的阵列——`tagv_q` = `{tag,valid}`、`dirty_q` = `dirty`；写口用 `if (wr_en) … else if (dirty_clr_en) …` 明确优先级；两阵列都加 **`(* ram_style = "distributed" *)`**（综合属性，非原语，红线 1 允许）⇒ 推断为 LUTRAM。读口仍同步 1 拍、同址同拍读旧值（与 RAM 语义一致）。
- **语义等价性**：拆分只改变"元数据放在哪个存储元件"，读写值完全一致；前提是 **`wr_en` 与 `dirty_clr_en` 不同拍断言**——l1d 里二者互斥（`way_maint = maint_q & ~maint_clean_q` vs `maint_dirty_clr = maint_q & maint_clean_q`，且维护扫描期间 `cs_stall` 含 `maint_q` ⇒ 填充/store 不可能同拍）。该前提由新增的**契约自检**在仿真里强制：同拍断言即 `$display FAIL + $fatal`（不静默分歧）。
- **影响（对照综合，同一脚本同一周期）**：

  | 指标 | 改前 | 改后 | 变化 |
  |---|---|---|---|
  | LUT | 116 785（86.8 %） | **37 382（27.8 %）** | **-79 403（-68 %）** |
  | FF | 47 190 | **15 412** | -31 778 |
  | LUTRAM | 0 | 736 | +736 |
  | WNS @60 MHz（综合后） | -4.329 ns | **-2.783 ns** | +1.55 ns |
  | Fmax（综合后估算） | 47.63 MHz | **51.41 MHz** | +3.8 MHz |

- **不退化证据**：`REGRESS: 23/23 PASS`（含 `tb_l1d`/`tb_l1i`/`tb_lsu`/`tb_m3_ddr3`）+ arch-test **I 39/39、Zicbom 3/3、SvZicbo 2/2、SvPMPZicbo 4/4、Sv 29/29**（CMO/dirty 路径正是本次改动影响的路径，全部不变）。
- 途中踩坑记录：首版字段抽取写成 `rd_tagv_q[TAG_W-1:0]`（漏掉 valid 占的 bit0）⇒ `tb_l1i/tb_l1d` 立刻 FAIL（"回填后应命中"失败）；改为 `rd_tagv_q[1 +: TAG_W]` 后全绿。**这正是"改动必过既有 TB 判据"的价值**。

> 另：`rtl/**` 其余文件**零改动**；`sim/**`、`scripts/regress.sh`、chiplab 平台仓库**零改动**。

---

## 6. 面积实测与阻塞归因

### 6.1 FPU 单独综合（`fpga/scratch/fpu_area.tcl`，宏定义 ⇒ 综合分支）

- 日志：`fpga/out/fpu_area.vivado.log`（`synth_design` **CPU 32 分 08 秒 / 峰值内存 9.4 GB**）
- 报告：`fpga/out/scratch_fpu_utilization.rpt`、`..._hier.rpt`

| 指标 | 实测 | 器件容量 | 占比 |
|---|---|---|---|
| **Slice LUTs** | **546 223** | 134 600 | **405.81 %** |
| Slice Registers | 745 | 269 200 | 0.28 % |
| DSP48E1 | 22 | 740 | 2.97 % |
| BRAM | 0 | 365 | 0 % |

按模块（hier 报告）：

| 实例 | 模块 | LUT | 说明 |
|---|---|---|---|
| `u_fma_d` | `fpu_fma_d` | **419 191** | D 精度 FMA：**精确对阶**（8193 bit 加/减 + 8192 bit 舍入域）——**单模块 = 器件 3.1 倍** |
| `u_div_sqrt` | `fpu_div_sqrt` | 51 143 | 多拍迭代 + 8192 bit 舍入域 |
| `u_mul_d` | `fpu_mul_d` | 47 109 | 53×53=106 bit 精确积 + 8192 bit 舍入域 |
| `u_fma_s` | `fpu_fma_s` | 23 777 | S 精度 FMA（512 bit 域） |
| `u_mul_s` | `fpu_mul_s` | 4 442 | S 精度乘法 |
| `u_cmp` | `fpu_cmp` | 561 | 比较/分类 |

**根因**：`fpu_round_d`（共享舍入原语）内部是 **8192 bit 的变量移位 + 8192 bit sticky + 8192 bit 加法 + 分层 msb 搜索**，在全设计里实例化 6 次；`fpu_add_d`/`fpu_fma_d` 另有 **4096/8193 bit** 的对阶加/减。这是"以位宽换正确性"的**正确性优先**实现（2A 明确允许），代价就是 FPGA 面积。

### 6.2 整核综合：OOM（硬证据）

- 命令：`./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl`（60 MHz，IP 分支，日志 `fpga/out/synth.vivado.log`、控制台 `fpga/out/synth.stdout.txt`）
- 过程：RTL 细化 **0 error**（48 端口契约、IP 全部解析成功、宏已定义）→ `Cross Boundary Optimization` → `Area Optimization`（CPU 25 分 14 秒）→ `Timing Optimization` **阶段被 OOM 杀死**：
```
Out of memory: Killed process 467598 (vivado) total-vm:35038620kB, anon-rss:28729140kB
```
- 机器 30 GB 内存，Vivado RSS 达 **28.7 GB**。⇒ 在 FPU 保持现状的前提下，**整核顶层综合无法在本机完成**（不是脚本问题）。

### 6.3 归因实验：「除 FPU 之外」的整核（`fpga/scratch/nofpu_synth.tcl`）

把 FPU 换成**同端口空实现替身**（`fpga/scratch/nofpu/fpu_stub.v`，仅诊断用、不进入 `rtl/**`）后综合整核。
**结论：非 FPU 部分完全放得下（27.8%），且仍差 60 MHz 约 2.8 ns（综合后估算）。**

| 指标 | 优化前（Tag 阵列打包双写口） | **优化后（Tag 阵列单写口 LUTRAM）** | 器件容量 | 优化后占比 |
|---|---|---|---|---|
| Slice LUTs | 116 785 | **37 382** | 134 600 | **27.77 %** |
| └ LUT as Logic | 116 785 | 36 646 | — | — |
| └ **LUT as Distributed RAM** | **0** | **736** | 46 200 | 1.59 % |
| Slice Registers | 47 190 | **15 412** | 269 200 | 5.73 % |
| Block RAM Tile (RAMB36) | 12 | **12** | 365 | 3.29 % |
| DSP48E1 | 12 | 12 | 740 | 1.62 % |
| 综合 CPU 用时 | 802 s | 596 s | — | — |
| **WNS @60 MHz（综合后）** | **-4.329 ns** | **-2.783 ns** | — | — |
| 可达频率（综合后估算） | 47.63 MHz | **51.41 MHz** | — | — |

- **RAMB36 = 12 正好等于 6 路数据阵列 × 2 个 BRAM36** ⇒ 这是 M4 判据⑤「Block Memory Generator IP 被例化」的直接、可核对的证据（`blk_mem_gen_cache_data` 在 L1I 2 路 + L1D 4 路各例化一次）。
- 层次化明细（`fpga/out/scratch_nofpu_utilization_hier.rpt`）：`u_l1d` **70 258 → 3 346 LUT**（21×），其中 4 路 `u_tag` 从 15 239/15 460/15 670/22 836 LUT 降到 **818/197/731/574 LUT**（每路含 128 个 LUTRAM）。
- 时序仍差 2.783 ns（**综合后估算**，其 data path 里 route 占 72 %，未布局 ⇒ 偏悲观）；真实值见 §7.2（布局布线后）。

---

## 7. 关键路径

### 7.1 综合后（非 FPU 全核，60 MHz 约束，`fpga/out/scratch_nofpu_timing_paths.rpt`）

| # | Slack | Startpoint | Endpoint | 逻辑级数 | 延时拆分 | 路径性质 |
|---|---|---|---|---|---|---|
| 1 | **-2.783 ns** | `u_csr_file/pmp_addr_r_reg[26]/C` | `u_axi_master_ctrl/len_q_reg[2]/D` | 37（CARRY4×9 + LUT6×15 + …） | logic 6.117 ns (31.7 %) + **route 13.182 ns (68.3 %)** | CSR 锁存的 PMP 探测地址 → PMP 比较/PMA 判定 → AXI 主控突发的 `len`/`beats` 装载 |
| 2 | -2.783 ns（同源同锥） | `u_csr_file/pmp_addr_r_reg[26]/C` | `u_axi_master_ctrl/{len_q_reg[0..3], beats_q_reg[0]}/D` | 同上 | 同上 | 同上（同一组合锥的 5 个扇出） |
| 3 | 次热（第 2 组） | `u_plic/threshold_r_reg[1][0]/C` | `u_l1d/FSM_onehot_ms_state_q_reg[*]/{S,R}` | — | — | PLIC 阈值/优先级比较 → 中断请求 → 陷阱判定 → 储控 MSHR 状态机的异步置/复位端 |

要点：
1. **两条最差路径都是"控制链"**（PMP 探测地址→总线突发装载；PLIC 中断→储控 FSM），不是数据通路（不是 ALU/FPU/Cache 数据路径）。
2. 综合后报告里 **route 占 68–72 %**，路径上多根网 fanout 极大（`trap_valid` fo=142、`fencei_busy_reg_inv_0` fo=103）——这是**未布局**的悲观估算，布局后同一逻辑的 route 会明显下降。
3. 因此**权威数字看布局布线后**（§7.2）。若布线后仍为负，最小改动方向有二（都是"加一级寄存器"，不改功能语义）：
   - PLIC 的**请求输出**加一级寄存（对核而言中断是异步电平，晚 1 拍不改变 ISA 语义；需过 `tb_plic` 判据）；
   - CSR 的 **PMP 探测/总线属性判定**出口加一级寄存（该信息本身就是"下一拍才用"）。
   本次**未**擅自实施：① 属改时序结构，需母 Agent/用户确认；② 现有证据（route 占 68 %）表明应先看布线后结果再决定。

### 7.2 布局布线后（`fpga/scratch/nofpu_impl.tcl`）

> **说明（判据②"impl.tcl 若跑"）**：`fpga/tcl/impl.tcl` 以 `fpga/out/post_synth.dcp` 为入口，而整核综合被 OOM 杀死 ⇒ **该检查点不存在**，`impl.tcl` 未能在整核上端到端跑通。为了给出**真实的布线后时序**并验证 `impl.tcl` 同一套流程（`open_checkpoint → opt_design → place_design → route_design → 报告`），这里用 `fpga/scratch/nofpu_impl.tcl` 在**非 FPU 归因检查点**上跑通了全流程（脚本与 impl.tcl 同构，仅检查点/报告名不同）。FPU 修复后 `impl.tcl` 可直接对整核复用。

**① 默认流程**（`opt_design → place_design → route_design`，报告 `scratch_nofpu_impl_*_default.rpt`）：

| 项 | 实测 |
|---|---|
| **WNS(setup) @60 MHz** | **-6.652 ns** ⇒ 可达频率 **≈ 42.88 MHz** |
| WHS(hold) | **+0.055 ns**（保持无违例） |
| 资源（布线后） | LUT 37 472（28.0 %）、FF 15 424、LUTRAM 736、BRAM36 12、DSP 12 |
| 关键路径 | `u_plic/threshold_r_reg[1][2]` → **L1D 数据阵列 BRAM 的 `ENBWREN`**；37 级逻辑；22.842 ns = logic 5.215 ns (22.8 %) + **route 17.627 ns (77.2 %)** |

**② 流程层时序恢复**（母 Agent 裁决③：`place_design -directive ExtraTimingOpt → phys_opt_design -directive AggressiveExplore → route_design -directive MoreGlobalIterations → phys_opt_design`（route 后）；**不改一行 RTL**；报告 `scratch_nofpu_impl_*` 无后缀版）：

| 项 | 默认流程 | 流程层恢复后 | 回收 |
|---|---|---|---|
| **WNS @60 MHz** | -6.652 ns | **-5.812 ns** | **+0.840 ns（13 %）** |
| 可达频率 | 42.88 MHz | **44.49 MHz** | +1.61 MHz |
| WHS | +0.055 ns | +0.083 ns | — |
| 资源 | LUT 37 472 | LUT 37 615（28.1 %） | 基本不变 |
| 关键路径 | PLIC 阈值 → L1D BRAM `ENBWREN` | **`u_csr_file/satp_r_reg[24]`（已复制的 MMU CSR）→ `u_axi_master_ctrl/len_q_reg[3]`**；22.480 ns = logic 6.172 (27.5 %) + **route 16.308 ns (72.5 %)** | 换成另一条同型控制链 |

**结论（母 Agent 裁决③ 的答复）**：**纯流程层恢复不足以达 60 MHz**——只回收 0.84 ns，仍差 5.81 ns。两条最差路径都是同型结构：**"CSR/特权状态（PLIC 阈值、satp/PMP）→ 陷阱/翻译判定 → 存储/总线请求控制（L1D 读使能、AXI 突发长度）"的超长控制链**，逻辑 27–37 级、route 占 72–77 %。
⇒ 后续独立任务建议（本次**不改 RTL**）：把这两处**控制判定提前一拍**——
① **M 级路由/写使能判定流水化**：`satp/PMP/翻译结果` → 物理地址/总线属性 出口加一级寄存器（该信息本就是"下一拍才用"）；
② **PLIC 请求聚合寄存**：`threshold/priority → eip` 出口加一级（中断对核是异步电平，晚 1 拍不改变 ISA 语义，但需过 `tb_plic` 判据）；
两处都是"加寄存器、不改语义"，但必须重跑 regress + 相关 arch-test（`tb_plic`/`tb_csr_file`/`tb_l1d`/`tb_lsu`/Sv 家族）。



### 7.3 关键路径 top 10（布线后，phys_opt 流程；完整 20 条见 `fpga/out/scratch_nofpu_impl_timing_paths.rpt`）

| # | Slack | Startpoint | Endpoint | 说明 |
|---|---|---|---|---|
| 1 | -5.812 ns | `u_csr_file/satp_r_reg[24]_rep_replica_3/C` | `u_axi_master_ctrl/len_q_reg[3]/D` | satp（Sv32 根页表基址）→ 翻译/PMA 判定 → AXI 突发长度装载 |
| 2 | -5.774 ns | 同上 | `u_axi_master_ctrl/len_q_reg[1]_lopt_replica/D` | 同上（复制后的同名端点） |
| 3 | -5.731 ns | 同上 | `u_axi_master_ctrl/len_q_reg[2]/D` | 同上 |
| 4 | -5.729 ns | 同上 | `u_fetch_unit/u_pc_gen/pc_r_reg[26]_replica_1/D` | satp → 取指侧翻译 → PC 重定向装载 |
| 5 | -5.728 ns | 同上 | `u_axi_master_ctrl/len_q_reg[0]/D` | 同上（len[0]） |
| 6 | -5.724 ns | 同上 | `u_fetch_unit/u_pc_gen/pc_r_reg[25]_replica_4/D` | 同上 |
| 7 | -5.722 ns | 同上 | `u_axi_master_ctrl/len_q_reg[2]_lopt_replica/D` | 同上 |
| 8 | -5.715 ns | 同上 | `u_fetch_unit/u_pc_gen/pc_r_reg[12]_replica_3/D` | 同上 |
| 9 | -5.704 ns | 同上 | `u_axi_master_ctrl/len_q_reg[3]_lopt_replica/D` | 同上 |
| 10 | -5.691 ns | 同上 | `u_fetch_unit/u_pc_gen/pc_r_reg[14]_replica_2/D` | 同上 |

**同一组合锥的两组扇出**：`u_csr_file/satp_r_reg[24]` 一个源驱动 (a) AXI 主控突发长度 `len_q[*]`、(b) 取指 PC 寄存器 `pc_r[*]`。即**"MMU CSR → 地址翻译/属性判定 → 存储与取指控制"**是当前唯一的时序瓶颈锥；默认流程下的瓶颈锥是同型的 "PLIC 阈值 → L1D 读使能"（§7.2 ①）。两条都属于裁决③ 指出的"控制判定应提前一拍流水化"。

### 7.4 时钟方案（Clocking Wizard）结论

**M4 未使用 Clocking Wizard / MMCM**：`synth.tcl`/`impl.tcl` 只综合核内逻辑，`aclk` 由平台 `soc_top.v` 的 PLL（`clk_pll_33`）驱动，上板口径 33 MHz 同域（08 §3、AGENT.md §3.1）⇒ 本阶段无时钟生成需求。`fpga/tcl/create_ip.tcl` 已留 `## 其他 IP（Clocking Wizard 等）` 分节与口径注释；若 M5 改为核内生成 100 MHz（Clocking Wizard `clk_wiz`），按红线 1 在该分节追加（**禁止手写 MMUCME2/BUFG 原语**）。

---

## 8. 为什么"最小 RTL 优化"救不了 + 可选路线

> **母 Agent 裁决（2026-09-18）**：走**路线 A**（重写 FPU 数据通路，窄域+sticky）。B 因 FPO IP 缺 RMM 舍入、与「IP 双分支逐拍等价」红线冲突而否决；C（不上板 F/D）只是过渡、不能作为 2A 最终态。A 是**独立大任务**，不在本次 M4 范围；本节按裁决给出 **A 路线的精确定位清单与预期量级**（§8.1）。
> 非 FPU 关键路径（§7.2）同样列为**后续独立任务**（在 M 级路由/写使能判定上提前一拍流水化），本次**不改 RTL**。

- 任务书设想的"时序不达标 ⇒ pipeline 重定时/复制/约束调整"适用于**路径太深**的情形；本次是**面积超容 4 倍**（且顶层综合 OOM）。流水化只增加寄存器、不减少 LUT，**不可能**把 546 k LUT 的 FPU 塞进 134.6 k LUT 的器件。
- 可选的**根本**修法（都需要母 Agent/用户决策，超出 M4「最小改动」边界）：

| 路线 | 做法 | 代价/风险 |
|---|---|---|
| **A. FPU 窄域重写（推荐）** | 舍入单元改为"~120 bit 窗口 + sticky 树"的经典结构（结果位只取决于舍入位附近窗口 + 低位或树），FMA 对阶改为"大指数侧对齐 + 小侧 sticky 压缩"；保持**逐位语义不变** | 需重跑 F 80 / D 106 arch-test + 600k 向量（`.work_fpu/HW_ROUND_VERIFIED.md` 的方法）；是"重写核心部件"，不是 M4 范围内的小改 |
| **B. Vivado Floating-Point Operator IP 化综合分支** | RTL 头注（fpu_add/mul/div_sqrt）原本声明的方案：`ifdef RV32GC_USE_VIVADO_IP` 例化 FP IP | **实测探针结论：不能直接满足 ISA**——IP 有 `C_Has_INVALID_OP/DIVIDE_BY_ZERO/OVERFLOW/UNDERFLOW` 等标志位，但**舍入模式只有 RNE/RTZ/RUP/RDN，没有 RISC-V 的 RMM（ties to max magnitude）**；且 NaN payload/subnormal 口径需自行兜底 ⇒ 会引入"综合分支 ≠ 已验证仿真分支"的语义漂移（arch-test 跑的是仿真分支，抓不到） |
| **C. 本阶段接受"无 FPU 可上板"** | 上板镜像暂只用 RV32IMAC + Zicsr/…（把 F/D 从 bitstream 里排除） | 与硬性指标（RV32IMAFDC）冲突，只能作为过渡；需用户裁决 |

### 8.1 路线 A 的**精确定位清单**（母 Agent 裁决：走 A；本任务只给定位与方案，不改）

**超宽域结构（按 LUT 代价排序；行号以 2026-09-18 的 dev 工作树为准）**：

| # | 位置 | 结构 | 位宽 | 实例数 | 为什么宽 | 窄域 + sticky 的替代 |
|---|---|---|---|---|---|---|
| 1 | `rtl/exec/fpu_add.v:295-381`（`fpu_round_d`） | `sigx >> rsh` / `<< lsh` + `sticky = \|(sigx & ((1<<rsh_m1)-1))` + `q = q0 + inc` + `msb8192(q)` | **8192 bit** | **6**（`fpu_add.v:566,862`、`fpu_mul.v:151`、`fpu_cvt.v:274,289`、`fpu_div_sqrt.v:244`） | 用"全宽移位保精确"，再在舍入点取 bit | 只保留**舍入窗口**：`msb(sig)` 已知 ⇒ 只需 `sig[msb-1 : msb-120]` 这 ~120 bit + **低位 sticky 或树**（`\|sig[msb-121:0]`）；`q` 只需 ~64 bit 加法器；`msb8192(q)` 只需在 ~64 bit 上做（q 的 msb 就在窗口内） |
| 2 | `rtl/exec/fpu_add.v:317-341`（同 `fpu_round_d` 的 `sigx/q_shifted/q`） | 8192 bit 桶形移位器 + 8192 bit 加法器 | 8192 bit | 6 | 同上 | 同上（窗口化后移位器 ≤ 128 bit 输入、64 bit 输出） |
| 3 | `rtl/exec/fpu_add.v:832-841`（**`fpu_fma_d` 对阶**） | `p_al = {8086'b0, prod} << sh_p` / `k_al = {8139'b0, c_sig} << sh_k` + 8193 bit 加/减 + `sum_mag` | **8192/8193 bit** | 1（LUT **419 191**，全设计最大头） | 106 bit 精确积与 53 bit 加数按"最大指数跨度 4092"全宽对齐 | 经典 FMA 对阶：**大指数侧**至少右移对齐 + **小侧只留 sticky**；两操作数只需在 `[msb-2 : msb-108]` 窗口内相加，低位数用"或树 + 1 位 sticky 压缩"；结果再进 #1 的窄舍入单元 |
| 4 | `rtl/exec/fpu_add.v:540-548`（**`fpu_add_d` 对阶**） | `a_al/b_al = {4043'b0, sig} << shift` + 4097 bit 加/减 | **4096/4097 bit** | 1 | 指数差 ≤ 2046 + 53 bit 有效数 | 同 #3：对齐只做右移（小侧），大侧不动；用 53+3 bit 的 guard/round/sticky 结构（IEEE 经典 3 位 + sticky） |
| 5 | `rtl/exec/fpu_add.v:135-157`（`msb8192`）、`103-133`（`msb1024`/`msb512`） | 分层优先搜索（16×512 → 8×64 → 64 逐位） | 8192 / 1024 / 512 bit | 函数（被 #1/#2 及 cvt 复用） | 全宽求最高位 | 窄域后只需对 ~128 bit 窗口求 msb（1 级 128→64→…）；或直接用"结果已知在窗口内"的位置推断 |
| 6 | `rtl/exec/fpu_add.v:164-290`（`fpu_round_s`） | 1024 bit 同构结构 | 1024 bit | 6（`fpu_add.v:466,704`、`fpu_mul.v:79`、`fpu_cvt.v:270,318`、`fpu_div_sqrt.v:242`） | 同上（S 侧） | 同 #1：窗口 24+3 bit + sticky |
| 7 | `rtl/exec/fpu_mul.v:151` 附近的 `fpu_mul_d` | 53×53 精确积（106 bit）+ 复用 #1 | 106 bit（自身很省） | 1 | 精确积必须保留 | **保留**（106 bit 乘法走 DSP，无需改） |
| 8 | `rtl/exec/fpu_div_sqrt.v:237-245` | 把 `rem_r[DW-1:0]` 零扩展到 8192/1024 bit 再送 #1/#6 | — | 1 | 复用同一舍入原语 | 只送窗口位（`rem_r` 的有效高位段 + sticky） |

**预期面积量级（供 A 路线立项参考）**：由 6.1 的层次报告外推——按 #1/#3 的窗口化，8192→~128 bit ⇒ 移位/sticky/加法/msb 的 LUT 大致按 **1/64** 量级下降；`fpu_fma_d` 419 191 → **约 8–15 k LUT**（保留 106 bit 乘法器与特殊值/异常判定），整个 FPU 546 223 → **约 25–45 k LUT**（即回落到与非 FPU 全核同一量级），器件 134.6 k 内可容纳。**必须同时保证**：舍入 5 种模式（含 RMM）、`fflags` 逐位精确、NaN-boxing/规范 NaN、亚正规与"精确抵消零的符号"等现有边界（回归网 = 现有 F 80 / D 106 例 arch-test + `.work_fpu/HW_ROUND_VERIFIED.md` 的 60 万向量法）。

- 本任务**未**擅自实施 A/B/C：① 都超出"最小改动"边界；② B 已用实测证据证明不满足 ISA；③ 任何一条都会改变已验收的功能语义面。**请母 Agent/用户裁决后再派工。**

---

## 9. 遗留与风险

| # | 项 | 说明 | 建议 |
|---|---|---|---|
| R1 | **FPU 面积阻塞** | §6；M4 判据②③与"上板"直接受阻 | 见 §8 路线 A/B/C |
| R2 | `core_top.v` **13 处 implicit declaration** 警告 | 形如 `trap_cause_i` 在 2215 行才 `wire [31:0]` 声明、2142 行已使用；Vivado 报 `[Synth 8-8895] already implicitly declared`。Verilog 隐式网是 1 bit，**若 Vivado 未正确采纳后置显式声明，会造成静默位宽截断**（仿真 iverilog 无此警告，测不出来） | M5 前：核对这些网在综合网表里的实际位宽（或直接把这些声明前移——零语义风险的整理）；本任务未改（不在授权范围） |
| R3 | MDU IP 分支**无仿真覆盖** | `mult_gen`/`div_gen` 的 Vivado 仿真模型只有 VHDL ⇒ iverilog 跑不了 IP 分支的 core 级 TB | 若要闭环：用 xsim/GHDL 跑一次 `tb_m3_ddr3`（IP 分支），或补 Verilog 行为替身 |
| R4 | ~~Tag 阵列 LUTRAM 推断未钉死~~ **已解决** | 改动 4 已加 `(* ram_style="distributed" *)`；实测每路推断出 128 个 LUTRAM、6 路共 736 LUTRAM，`LUT as Distributed RAM` 从 0 → 736 | 已闭环 |
| R5 | `fpga/scratch/**` 是排障脚手架 | 含 4 个临时 tcl/脚本与 `work/` 产物 | 可整体删除；若保留，建议只留 `bram_equiv/`、`ip_branch/`（有复用价值的证据脚本） |
| R6 | 100 MHz 余量数据 | 受限核 OOM（FPU 面积 406 %），未能在整核上给出 100 MHz WNS；非 FPU 部分当前 60 MHz 都未收敛（§7.2），100 MHz 更远 | FPU 修好 + 时序重构后用 `synth.tcl xc7a200tfbg676-2 10.0` 一次跑出 |
| R7 | `fpga/ip/**` 未进 `.gitignore` | 5 个 IP 目录（含 BMG 的 VHDL 参考源、仿真模型）会随提交进仓库；它们是 `create_ip.tcl` 可完全重建的产物 | 建议 `.gitignore` 增 `fpga/ip/`（与 `fpga/out/` 同口径）；若要"开箱即综合"则改为显式提交并在报告里记版本（VLNV 见 §3） |
| R8 | `fpga/scratch/**` 归置 | 归因/对拍脚手架（含 `work/` 中间产物） | 母 Agent 决定：建议保留 `bram_equiv/`、`ip_branch/`（有复用价值的验证脚本），其余（`fpu_area.tcl`、`ip_flow*.tcl`、`ip_wrap.v`、`nofpu*`）可删 |

---

## 10. 关键命令与日志对照表

| 用途 | 命令 | 日志/报告 |
|---|---|---|
| IP 生成 | `./fpga/run_vivado_batch.sh fpga/tcl/create_ip.tcl` | `fpga/out/create_ip.vivado.log` |
| 整核综合（60 MHz） | `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl` | `fpga/out/synth.vivado.log`、`synth.stdout.txt` |
| 归因：无 FPU 综合 | `./fpga/run_vivado_batch.sh fpga/scratch/nofpu_synth.tcl 16.667` | `fpga/out/scratch_nofpu_*.rpt` |
| FPU 单独综合 | `./fpga/run_vivado_batch.sh fpga/scratch/fpu_area.tcl fpu` | `fpga/out/scratch_fpu_utilization*.rpt` |
| 检查点详细时序 | `./fpga/run_vivado_batch.sh fpga/tcl/report_timing_detail.tcl fpga/out/post_synth.dcp 16.667 synth` | `synth_timing_summary.rpt`、`synth_timing_paths.rpt` |
| BRAM 双分支对拍 | `./fpga/scratch/bram_equiv/run.sh` | `fpga/scratch/bram_equiv/work/run.log` |
| IP 分支 TB 跑批 | `./fpga/scratch/ip_branch/run_ip_branch.sh tb_l1i tb_l1d tb_lsu tb_fetch_unit` | `fpga/scratch/ip_branch/work/*.log` |
| 基线回归 | `./scripts/regress.sh` / `./sim/arch_test/run.sh --group rv32i/I --jobs 16` | `fpga/out/post_edit_sim_verify.log` |

---

## 11. 按母 Agent 裁决的后续任务清单（交接用）

| # | 任务 | 范围/定位 | 验收 |
|---|---|---|---|
| T1 | **FPU 窄域+sticky 重写（路线 A）** | §8.1 的 8 项定位（`fpu_round_d/s` 的 8192/1024 bit 域、`fpu_fma_d` 的 8192/8193 bit 对阶、`fpu_add_d` 的 4096/4097 bit 对阶、`msb8192/msb1024/msb512`） | 面积回落到 ~25–45 k LUT（FPU 整体）；F 80 / D 106 arch-test + `.work_fpu` 60 万向量逐位一致；整核综合 rc=0 且不 OOM |
| T2 | **非 FPU 关键路径流水化** | §7.2/§7.3：① `satp/PMP/翻译结果` → 物理地址/总线属性出口加一级寄存；② PLIC `threshold/priority → eip` 出口加一级寄存 | 布线后 WNS ≥ 0 @60 MHz（当前 -5.812 ns）；regress 23/23 + `tb_plic`/`tb_csr_file`/`tb_l1d`/`tb_lsu`/Sv 家族全绿 |
| T3 | 整核综合（FPU 修复后） | `./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl`（60 MHz）与 `... 10.0`（100 MHz 余量）+ `impl.tcl` | M4 判据②③ 真正达成（WNS ≥ 0、资源在器件内），并给出 100 MHz 余量 |
| T4 | `core_top.v` 13 处 implicit declaration 核对/前移 | §9 R2 | Vivado 综合无 `8-8895`；位宽与声明一致（可用综合网表核对） |
| T5 | `fpga/ip/**` 的 git 归置 | §9 R7 | `.gitignore` 增 `fpga/ip/`（或显式提交并记录 VLNV） |
| T6 | MDU IP 分支的仿真闭环（可选） | §9 R3：`mult_gen`/`div_gen` 仿真模型只有 VHDL | xsim/GHDL 跑一次 IP 分支的 core 级 TB，或补 Verilog 行为替身 |
