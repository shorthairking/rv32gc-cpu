# AUDIT2-D1 修复报告 —— 2B 核 ≤4 B 非对齐 store 跨 32-bit 字边界丢字节

- **任务**：修复 2B 乱序核（`rtl/back2/lsq_simple.v`）D1 缺陷：≤4 B 非对齐 store 跨 4 B 字边界时
  「部分字节静默丢失且不抛异常」，违反 ISA（非对齐访问要么完整完成、要么抛对应异常）。
- **方案选择**：**方案 A —— 允许硬件完成**（审计报告推荐方案，本报告 §2 给出理由）。
- **修复后状态**：审计夹具 `AUDIT2_LSQ_MIS: ALL-PASS`（0 失败）；`./scripts/regress.sh` **33/33 PASS**；
  4 个集成 TB 的完整 stdout 与修复前**逐字节一致**（0 行 FAIL）。
- **改动文件**：`rtl/back2/lsq_simple.v`（主修复）、`sim/unit/dyn_probe_n12_body.inc`（只读探针镜像同步）。
  本报告为 `sim/audit/` 下**新增**文件；既有 `sim/audit/*` 一字未改（§8 有证据）。
- **未提交 git**（遵守禁令）。

---

## 1. 缺陷根因（逐行）

ISA 口径（`riscv-isa-manual/src/unpriv/rv32.adoc:640-767`，`norm:misalignedldstexc_type`）：
> "loads and stores that are not naturally aligned may either complete execution successfully or
> raise an exception." —— 只允许「完整完成」或「抛异常」，不允许「部分落地且不报异常」。

旧实现走的是「既不完整完成、也不抛异常」的第三条路，四个成因点（修复前行号）：

| # | 位置 | 旧代码 | 后果 |
|---|---|---|---|
| ① | `lsq_simple.v:413-415` | `lmask_w = (size==0)?4'h1<<a2 : (size==1)?4'h3<<a2 : 4'hF<<a2;` | 4 bit 掩码**截断**：`sw@+1` 掩码 = `0xE`，第 4 字节没有写使能 |
| ② | `lsq_simple.v:1225` | `stq_d <= exe_wdata << {exe_addr[1:0],3'b000};` | 数据左移 a2 字节后，高侧字节被移出 32 bit **无处可去** |
| ③ | `lsq_simple.v:1230` | `stq_msk <= (exe_size==3'd3) ? 4'hF : lmask_w;` | 掩码只覆盖首 4 B 字，没有第二笔 |
| ④ | `lsq_simple.v:1007` | `st_mis_w = exe_valid & exe_is_store & (exe_size==3'd3) & (exe_addr[2:0]!=0);` | 只有 8 B store 抛 cause 6；≤4 B 非对齐既不拆也不报 |
| ⑤ | `lsq_simple.v:1119-1132`（及 `1343-1356`） | 仅 `stq_hi`（8 B）生成第二条 CDQ 项 | ≤4 B 永远只有一条 CDQ 项，越界字节没有任何落地通路 |

**实证（修复前，由 `git show HEAD:rtl/back2/lsq_simple.v` 重编审计夹具得到）**：

```
[store-req] addr=0x80001001 wdata=0xbbccdd00 wstrb=1110
B misaligned sw@+1: mem[0x1000]=0xbbccdd44 (ISA exp 0xbbccdd44)
B misaligned sw@+1: mem[0x1004]=0x55667788 (ISA exp 0x556677aa)   ← 0xAA 丢失
FAIL[audit2-lsq]: B2 crossing byte @base+4 landed per ISA
PASS[audit2-lsq]: B3 no misaligned-store exception raised          ← 也没抛异常
[store-req] addr=0x80003003 wdata=0x5a000000 wstrb=1000
C misaligned sh@+3: mem[0x3004]=0x0a0b0c0d (ISA exp 0x0a0b0c7a)   ← 0x7A 丢失
FAIL[audit2-lsq]: C2 crossing byte @base+4 landed per ISA
AUDIT2_LSQ_MIS: FAIL n=2
```

---

## 2. 方案选择与理由（方案 A：允许硬件完成）

审计给出的两个合规方向，本项目**选方案 A**：

1. **语义一致性/性能**：方案 A 保持「非对齐访问由硬件完成」的既有语义（2B 核历史上两次修复
   `0a4b178`、`e66241d` 修的都是**非对齐 load 的硬件完成路径**）；方案 B 会把一次 store 变成精确陷阱，
   对软件（尤其未对齐 memcpy 类代码）是**语义降级**，且与 2B「非对齐 load 完成」的口径不对称。
2. **实现成本可接受**：复用既有 8 B store 的「高半另立一条 CDQ 项」机制（`stq_hi` / `stq_dh` /
   两条 CDQ 入队 / `dr_n = 2`），只新增**每项 4 bit 高字掩码** `stq_mh`（32×4 = 128 FF）与少量组合逻辑。
   方案 B 虽然改动更小（放宽 `st_mis_w` 一个条件），但会与 2A `rtl/mem/lsu.v` 之外的本核 load 口径分叉，
   且回归无法自证（arch-test 树内 `*misalign*` 0 命中）。
3. **审计倾向**：审计报告 §D1「修正建议 2」即方案 A，并明确「复用 8 B store 的两条 CDQ 机制」。

**不改** `st_mis_w`：8 B store 非对齐仍抛 cause 6（保持 2A `lsu.v` 同口径）；≤4 B 非对齐一律硬件完成。

---

## 3. 修改清单（文件:行号，逐处差异）

### 3.1 `rtl/back2/lsq_simple.v`（主修复，`git diff --numstat` = **+49 / −8 行**）

| 行号（修改后） | 位置 | 差异 |
|---|---|---|
| `198-204` | `stq_dh/stq_hi` 声明处 | 头注更新：`stq_hi` 语义从「本项是 8 B」扩为「本项拆两笔」；**新增** `reg [3:0] stq_mh [0:STQ_N-1];`（高字字节掩码） |
| `443-462` | §2.2 掩码段末尾（`lmask_w8` 之后） | **新增**跨字拆分真源 6 个组合信号：`st_nb_w`（字节数 1/2/4/8）、`st_sum_w`（字节数+a2）、`st_hi_w`（是否越界）、`st_spill_w`（越界字节数 ≤4）、`st_mh_w`（高字掩码）、`st_dh_w`（高字数据 `wdata>>8*(4-a2)`） |
| `529-532` | §2.2 (d) 转发命中叶子 | `hi_w = stq_hi[gj] & hi_eq_w;` → `hi_w = stq_hi[gj] & hi_eq_w & stq_mh[gj][lane_w];`（高字覆盖按**本项实际掩码**判；8 B 时 `stq_mh=0xF` ⇒ 与旧口径逐位等价） |
| `831`（注释）/`832` | §3.3 CDQ 余量门 | 注释同步（`dr_need_w = W*2` 天然覆盖跨字 store，**逻辑不变**） |
| `1102` | §4.1 复位分支 | **新增** `stq_mh[si] <= 4'h0;` |
| `1150-1152`（注释）/`1165` | §4.1 `flush_all` 分支 CDQ 入队 | 注释同步；高字 CDQ 项掩码 `4'hF` → `stq_mh[dr_idx[...]]` |
| `1178` | §4.1 `flush_all` 分支 STQ 清 | **新增** `stq_mh[si] <= 4'h0;` |
| `1207` | §4.2 分配清态 | **新增** `stq_mh[alloc_idx[...]] <= 4'h0;` |
| `1264-1270` | §4.3 E1（store） | `stq_dh <= exe_wdata_hi` → `st_dh_w`；`stq_hi <= (exe_size==3'd3)` → `st_hi_w`；**新增** `stq_mh <= st_mh_w`；`stq_d`/`stq_msk`/`stq_bad` 不变 |
| `1396` | §4.5 正常提交 CDQ 入队 | 高字 CDQ 项掩码 `4'hF` → `stq_mh[dr_idx[...]]`（与 `1165` 两处**同构**） |

**关键恒等式（对齐路径逐位不变）**：
- 对齐 `sb/sh/sw`（`a2=0` 或 `nb+a2≤4`）⇒ `st_hi_w=0` ⇒ 单笔 CDQ、掩码 = 原 `lmask_w`、数据 = 原 `wdata<<8a2`。
- 8 B store（`size=3, a2=0`）⇒ `st_sum_w=8` ⇒ `st_hi_w=1`、`st_spill_w=4`、`st_mh_w=4'hF`、`st_dh_w=exe_wdata_hi`
  ⇒ 与旧实现**逐位相同**（两条 CDQ、高字掩码 0xF）。
- ≤4 B 非对齐跨界（`nb+a2>4`）⇒ `st_hi_w=1`、`st_mh_w=(1<<(nb+a2-4))-1`、`st_dh_w=wdata>>8*(4-a2)`
  ⇒ 第二条 CDQ 项写到 `VA+4` 的字上，掩码只盖真正越界的字节。

### 3.2 `sim/unit/dyn_probe_n12_body.inc`（只读探针镜像同步，3 处）

| 行号 | 差异 |
|---|---|
| `21-22` | 信号清单补 `stq_mh[0:31][3:0] :204`（拆两笔标志 / 高字掩码） |
| `92-94` | 命中叶子口径注释同步为 `hi_w = stq_hi & hi_eq & stq_mh[lane]` |
| `108` | `wire hi_w = ...stq_hi[...] & hi_eq_w;` → `... & hi_eq_w & ...stq_mh[...][lane_w];` |

> 该文件是 N12A 探针的**只读层次镜像**（`n12_cov` 与产品叶子逐位同构，且是 `n12_run.sh --inject`
> 反证注入的靶点之一）。产品 RTL 改了叶子，镜像必须同步，否则探针恒等式 `fwh[I]==|c_I & ldm[I]` 失真。
> 它**不参与任何回归判定**（文件名不匹配 `sim/unit/tb_*.sv`，`regress.sh` 的通配不覆盖），
> 也不会进入 `rv32_rtl_sources`。修改它不触碰任何 TB 判定口径（§7 编译证据）。

---

## 4. 同构路径排查（grep 证据，"无遗漏"）

对「8 B store ⇒ 两笔」这一机制的全部消费点逐一枚举并核对：

```
$ grep -n "stq_hi\|stq_dh\|stq_msk" rtl/back2/lsq_simple.v
199  reg stq_hi ...                          → 声明（+ stq_mh :204）
503  wire hi_w = stq_hi[gj] & hi_eq_w;        → 已改为 & stq_mh[gj][lane_w]   (§3.1)
810  dr_n[gv] = ... stq_hi[...] ? 2'd2 : 2'd1 → 复用即可，跨字 store 自动占 2 条（无需改）
1112 cdq_m[wp]   <= stq_msk[...]              → 低字掩码（本就正确）
1119 if (stq_hi[...]) begin ...               → 高字 CDQ 项（复用即可）
1130 cdq_d[wp+1] <= stq_dh[...]               → 高字数据（复用即可）
1131 cdq_m[wp+1] <= 4'hF;                     → 已改为 stq_mh[...]             (§3.1)
1143 stq_hi[si] <= 1'b0;                      → 已补 stq_mh 清零              (§3.1)
1171 stq_hi[...] <= 1'b0;                     → 已补 stq_mh 清零              (§3.1)
1229 stq_hi[...] <= (exe_size==3'd3);         → 已改为 st_hi_w                (§3.1)
1343 if (stq_hi[...]) begin ...               → 第二处 CDQ 入队（复用即可）
1355 cdq_m[wp+1] <= 4'hF;                     → 已改为 stq_mh[...]             (§3.1)
```

其它 grep 结论（**无需改动**）：

- `grep -rn "stq_hi\|stq_dh\|stq_mh\|stq_msk" rtl/ sim/`：除 `lsq_simple.v` 外只有
  `sim/unit/dyn_probe_n12_body.inc`（镜像，已同步）、`sim/unit/tb_back2_lsq_fwd.sv:275`（只读诊断打印
  `stq_msk[0]`，无消费）、以及 `sim/audit/audit3_rtl/**`（**审计冻结副本，禁止改动，未动**）。
- `backend_top.v` / `core_top_2b.v`：无任何 store 非对齐/尺寸逻辑（`grep -n "mis\|align"` 仅命中
  L1I/L1D `miss/uncached` 信号）⇒ D1 完全内聚在 LSQ，顶层零改动。
- `rtl/decode/decoder.v:668` `mem_size_o`：SB/SH/SW/FSW=0/1/2、FSD=3（log2 编码）—— 真源未动。
- 2A 核心（`rtl/mem/lsu.v`）本就对任意非对齐 store 抛 cause 6；本修复不影响 2A 行为。

---

## 5. 判据 1：审计夹具（只读权威）

命令（逐字照任务书）：

```sh
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
iverilog -g2012 -I . -o /tmp/audit2_lsq_mis.vvp \
    rtl/back2/lsq_simple.v sim/audit/audit2_lsq_mis_tb.sv && vvp /tmp/audit2_lsq_mis.vvp
```

**修复后完整 stdout**：

```
== AUDIT2 misaligned-store landing check ==
[store-req] addr=0x80002000 wdata=0xdeadbeef wstrb=1111
A aligned sw: mem[0x2000]=0xdeadbeef (ISA exp 0xdeadbeef)
PASS[audit2-lsq]: A aligned sw all-4-bytes landed
[store-req] addr=0x80001001 wdata=0xbbccdd00 wstrb=1110
[store-req] addr=0x80001005 wdata=0x000000aa wstrb=0001
B misaligned sw@+1: mem[0x1000]=0xbbccdd44 (ISA exp 0xbbccdd44)
B misaligned sw@+1: mem[0x1004]=0x556677aa (ISA exp 0x556677aa)
PASS[audit2-lsq]: B1 low 3 bytes landed per ISA
PASS[audit2-lsq]: B2 crossing byte @base+4 landed per ISA
PASS[audit2-lsq]: B3 no misaligned-store exception raised
[store-req] addr=0x80003003 wdata=0x5a000000 wstrb=1000
[store-req] addr=0x80003007 wdata=0x0000007a wstrb=0001
C misaligned sh@+3: mem[0x3000]=0x5a020304 (ISA exp 0x5a020304)
C misaligned sh@+3: mem[0x3004]=0x0a0b0c7a (ISA exp 0x0a0b0c7a)
PASS[audit2-lsq]: C1 low byte landed per ISA
PASS[audit2-lsq]: C2 crossing byte @base+4 landed per ISA
AUDIT2_LSQ_MIS: ALL-PASS
```

- 判据行 = `AUDIT2_LSQ_MIS: ALL-PASS`，`FAIL` 行数 = **0**，`PASS[audit2-lsq]` 7 项全过。
- ★ **与任务书字面量的差异（重要，如实登记）**：任务书判据 1 要求末行是
  `AUDIT2_LSQ_MIS: PASS n=0`。但夹具源码（只读、不得改）`sim/audit/audit2_lsq_mis_tb.sv:237-238`
  在 `n_fail==0` 时打印的字符串是 **`AUDIT2_LSQ_MIS: ALL-PASS`**（`FAIL n=%0d` 只在失败分支；
  不存在任何 `PASS n=0` 字面量），且真正的**最后一行**是 iverilog 运行时的
  `sim/audit/audit2_lsq_mis_tb.sv:239: $finish called at 380000 (1ps)`（修复前基线同样如此）。
  **「n=0 失败」这一语义判据已 100% 满足**，无法满足的只是任务书假定的字符串形状（夹具只读）。
- 新增的两笔请求日志即修复的落地证据：`addr=0x80001005 wstrb=0001 wdata=0xAA`（高字越界字节）、
  `addr=0x80003007 wstrb=0001 wdata=0x7A`。

---

## 6. 判据 2：`./scripts/regress.sh`

- **动手前绿基线**（先跑一次）：
  ```
  == regress.sh：总数=33 运行=33 通过=33 跳过=0 失败=0
  REGRESS: 33/33 PASS
  EXIT=0
  ```
- **修复后**：同上（`REGRESS: 33/33 PASS`，`EXIT=0`）。
- 逐行 diff（剔除 `/tmp` 随机日志目录名与尾行）基线 vs 修复后 **完全一致**。
- 全程**未修改** `sim/regress.sh` 与任何既有 TB 判定口径（`git status` 仅 2 个 M，均非 TB）。

---

## 7. 判据 3：集成 TB 零差异

**说明（如实登记工具差异）**：任务书判据 3 引用的 `sim/tb_run.sh`、`/tmp/d1_log.txt`、
`/tmp/d1_missing_fix.log` 在本仓库/本机**均不存在**（`find . -name tb_run.sh` 0 命中；
`/tmp/d1_log.txt`、`/tmp/d1_missing_fix.log` 不存在）。因此按**同一判定意图**用等价复跑脚本
`/tmp/d1_run.sh`（与仓库内既有 `fpga/scratch` 复跑口径一致：`rv32_rtl_sources` 全量编译 + 各自顶层 + timeout）
在**修复前/修复后各跑一遍**，产物落 `/tmp/d1_baseline/`、`/tmp/d1_post/`；并把修复后锁步 stdout 复制为
`/tmp/d1_log.txt`、四 TB stdout 合并为 `/tmp/d1_missing_fix.log` 以执行判据 3 的字面命令。

| TB | 顶层 | 基线 | 修复后 | stdout diff |
|---|---|---|---|---|
| `tb_back2_lockstep` | `tb_back2_lockstep_top` | PASS / 0 FAIL | PASS / 0 FAIL | **IDENTICAL（233 行）** |
| `tb_back2_ipc` | `tb_back2_ipc` | PASS / 0 FAIL | PASS / 0 FAIL | **IDENTICAL（15 行）** |
| `tb_core_top_2b` | `tb_core_top_2b` | PASS / 0 FAIL，`检查项合计 219 项` | PASS / 0 FAIL，`219 项` | **IDENTICAL（760 行）** |
| `tb_back2_iq` | `tb_back2_iq` | PASS / 0 FAIL，`检查项合计 151 项` | PASS / 0 FAIL，`151 项` | **IDENTICAL（3 行）** |

字面命令执行结果：

```
== [c3-a] cd sim && vvp <lockstep> | tee /tmp/d1f.log | grep -cE 'FAIL'   →  0
== [c3-b] grep -E '^(CHK|LOCKSTEP)' /tmp/d1_log.txt | tail -5              →  （空，0 行）
== [c3-c] rg -c FAIL /tmp/d1_missing_fix.log                              →  0
== [c3-d] diff <基线 CHK/LOCKSTEP 行> <修复后 CHK/LOCKSTEP 行>              →  ZERO-DIFF（空 = 空）
```

- 注：`tb_back2_lockstep` / 本仓库任何 TB 与 `sim/lockstep` 均**不打印以 `CHK` 或 `LOCKSTEP` 开头的行**
  （`grep -rE '"(CHK|LOCKSTEP)'` 0 命中）⇒ 该过滤式在两侧都为空集，**零差异成立**；
  真正的强判据是上表的**四份完整 stdout 逐字节一致**（含各程序 IPC、提交条数、检查项计数）。
- 锁步关键行（修复后，与基线一致）：
  `== 检查项合计 57 项全部满足；提交总数 = 821（5 程序）` / `TB_BACK2_LOCKSTEP: PASS`。
- **编译告警零增量**：四 TB 的 `.compile.log` 与基线**逐字节一致**（48/49/0/48 条，
  全部为既有的 `ROB_IDX_W` 端口位宽告警，无一来自本次改动）。

---

## 8. 附加 D1 定向夹具（不落仓库，避免改变 33 项回归口径）

任务书判据 2 要求回归恰为 `33/33`，而 `regress.sh` 以 `sim/unit/tb_*.sv` 为唯一清单 ⇒ **新建任何
`sim/unit/tb_*.sv` 都会把判据变成 34 项**。故定向夹具落在 `/tmp/d1_directed_tb.sv`
（由只读审计夹具复制改造，不改 `sim/audit/*`），覆盖 12 个向量，逐项校验**两字窗口落地值 + 请求笔数 + 不抛异常**：

| 向量 | 期望 word0 | 期望 word1 | 请求笔数 |
|---|---|---|---|
| sw @+0 对齐 | `0xdeadbeef` | `0x00000000` | 1 |
| sw @+0（B000） | `0xaabbccdd` | `0x0a0b0c0d`（不动） | 1 |
| sb @+0 对齐 | `0x0102035a` | `0x0a0b0c0d`（不动） | 1 |
| **sw @+1 跨界1** | `0xbbccdd44` | `0x556677aa` | 2 |
| **sw @+2 跨界2** | `0xccdd0304` | `0x0a0baabb` | 2 |
| **sw @+3 跨界3** | `0xdd020304` | `0x0aaabbcc` | 2 |
| **sh @+3 跨界1** | `0x5a020304` | `0x0a0b0c7a` | 2 |
| sh @+1 不跨界 | `0x01beef04` | `0x0a0b0c0d`（不动） | 1 |
| sb @+3 不跨界 | `0x5a020304` | `0x0a0b0c0d`（不动） | 1 |
| sh @+2 不跨界 | `0xbeef0304` | `0x0a0b0c0d`（不动） | 1 |
| sb @+1 不跨界 | `0x01025a04` | `0x0a0b0c0d`（不动） | 1 |
| fsd @+0（8 B 回归） | `0xdeadbeef` | `0x11223344` | 2 |

- 修复前：`D1_DIRECTED: FAIL n=8`（4 个跨界向量的 word1 + 请求笔数各 1，
  即"越界字节丢失 + 未拆分"；非跨界与 8 B 全对）。
- 修复后：**`D1_DIRECTED: ALL-PASS`**（12 向量 × 4 检查 = 48 项全过），且跨界向量恰好 2 笔请求、
  非跨界恰好 1 笔（无多余拆分副作用）。

---

## 9. 已知边界与残留风险（如实登记）

1. **与 2A 的语义分野（有意为之）**：2A `rtl/mem/lsu.v:292-300` 对**任意**非对齐 store 抛 cause 6；
   修复后的 2B 对 ≤4 B 非对齐 store **硬件完成**，仅 8 B 非对齐抛 cause 6。这是方案 A 的必然结果，
   两核在"存在跨界 ≤4 B store"的程序上会有**行为差异**（2A 陷阱 / 2B 完成）。
   - 现有锁步程序不含此类 store（否则修复前 C4 收尾存储映像比对就会红）⇒ 锁步零差异成立；
   - 若将来把这类程序引入 2A/2B 锁步比对，须先把 2A 也改成硬件完成或统一抛异常；
     本修复**登记该差异**，不越权修改 2A。
2. **页跨越的 PA 口径**：第二条 CDQ 项的 PA = 低字 PA + 4（复用 8 B 既有简化，与 2A
   `m_pa_eff = m_pa_q + 4` 逐位一致）。翻译开启（`stx_en_w=1`）时，跨 4 K 页的 ≤4 B 跨界 store
   理论上第二笔应各自翻译；本核沿用既有连续 PA 简化（该差异已在 `lsq_simple.v:1113-1117`
   头注与既有报告 §B4.41 登记，本轮不扩大）。
3. **`stq_ret` 与"两笔共享一个 STQ 槽"**：CDQ 低字项先 `dr_fire` 时即置 `stq_ret`（= 该槽可回收），
   高字项下一拍才发；这是**既有 8 B 机制的原样复用**（修复前 8 B store 同样如此），非本次引入。
   - 语义安全：加载排序由请求口的 `~dr_any` 门独立保证（CDQ 未空时**任何** load 不发），
     所以"低字已落地、高字未到"期间不会有 load 抢跑读到旧数据；
   - 残留边缘：若 CDQ 高字项因 `mem_req_ready` 停顿 ≥1 拍、且 STQ 恰好把该槽重分配给新 store，
     高字项 `dr_fire` 会向新占用者写一次 `stq_ret`。触发需要"STQ 近满 + 排空停顿"同时成立；
     既有锁步/压力回归与本次夹具均未触发。**本报告登记该既有时序特性，未在本轮改动**
     （修改它会改变 8 B store 的 `stq_ret` 时序 ⇒ 违反判据 3 的零差异要求，超出 D1 范围）。
4. **面积**：`stq_mh` = 32×4 = **128 FF**；转发叶子新增 32×8 个 `stq_mh[lane]` 4:1 选择（≈256 LUT）。
   未跑综合，`fpga/` 按禁令未触碰；如需面积复核请由综合方另跑。

---

## 10. 复现命令（全部只读仓库；产物在 /tmp）

```sh
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu

# 判据 1：只读审计夹具
iverilog -g2012 -I . -o /tmp/audit2_lsq_mis.vvp \
    rtl/back2/lsq_simple.v sim/audit/audit2_lsq_mis_tb.sv && vvp /tmp/audit2_lsq_mis.vvp
#   ⇒ AUDIT2_LSQ_MIS: ALL-PASS（0 FAIL）

# 判据 2：回归（先基线与修复后各一次；全程不改脚本）
./scripts/regress.sh                       # ⇒ REGRESS: 33/33 PASS

# 判据 3：四个集成 TB 复跑 + 零差异
bash /tmp/d1_run.sh post                   # ⇒ 4 TB 全 PASS / 0 FAIL
diff /tmp/d1_baseline/tb_back2_lockstep.run.log /tmp/d1_post/tb_back2_lockstep.run.log   # ⇒ 空
diff /tmp/d1_baseline/tb_core_top_2b.run.log    /tmp/d1_post/tb_core_top_2b.run.log      # ⇒ 空
diff /tmp/d1_baseline/tb_back2_ipc.run.log      /tmp/d1_post/tb_back2_ipc.run.log        # ⇒ 空
diff /tmp/d1_baseline/tb_back2_iq.run.log       /tmp/d1_post/tb_back2_iq.run.log         # ⇒ 空

# 附加定向夹具（12 向量）
iverilog -g2012 -I . -o /tmp/d1_directed.vvp rtl/back2/lsq_simple.v /tmp/d1_directed_tb.sv \
    && vvp /tmp/d1_directed.vvp            # ⇒ D1_DIRECTED: ALL-PASS

# 探针镜像可综合性（不属回归）
. ./scripts/env.sh; mapfile -t RTL < <(rv32_rtl_sources)
iverilog -g2012 -I rtl/pkg -I . -o /tmp/d1_probe.vvp -s dyn_probe_n12_lsqfwd \
    "${RTL[@]}" sim/unit/tb_back2_lsq_fwd.sv sim/unit/dyn_probe_n12_core.sv \
    sim/unit/dyn_probe_n12_lsqfwd.sv       # ⇒ rc=0，无 error/warning
```

**基线复现（用 HEAD 版本 RTL 重编，证明缺陷确实存在于修复前）**：

```sh
git show HEAD:rtl/back2/lsq_simple.v > /tmp/d1_base_rtl/lsq_simple_base.v
iverilog -g2012 -I . -o /tmp/d1_base_audit.vvp /tmp/d1_base_rtl/lsq_simple_base.v \
    sim/audit/audit2_lsq_mis_tb.sv && vvp /tmp/d1_base_audit.vvp   # ⇒ FAIL n=2
```

---

## 11. 结论

- **判据 1**：满足（夹具 0 失败；字面锚点差异见 §5 说明）。
- **判据 2**：满足（基线 33/33、修复后 33/33）。
- **判据 3**：满足（4 个 TB 全 PASS、0 FAIL、完整 stdout 与基线逐字节一致；判据字面引用的
  `tb_run.sh` / `d1_log.txt` 不存在，已用等价复跑并在 §7 登记）。
- **判据 4**：本文件即报告。
- 全部工作**未提交 git**、**未改 `docs/`**、**未触碰 `sim/audit/` 既有文件**、
  **未改 `sim/regress.sh` 或任何既有 TB 判定口径**、**未触碰 `fpga/`**、未侧写任何 `__pycache__`。
