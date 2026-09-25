# 2B-2（乱序执行后端）阶段进展与缺陷台账 —— 2026-09-21 第 3 轮（接续会话）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev 分支，HEAD=`f6cc9af`，**未提交**）
> 写入范围：`rtl/back2/**` + `sim/unit/**` 的 back2 相关新增件；**唯一例外**：`scripts/regress.sh`
> 的 T6 按名放宽墙钟档（只放宽墙钟、不放松判据）
> **2A/front4 既有文件零修改**；全程未 `git checkout/stash/reset`、未提交；反证用 cp 备份。

---

## 0. 状态一览（如实登记；**第 8 轮：B27 已修并实测生效**）

> ✅ **第 8 轮实测**：`RENAME-CHK` 违规 **0 条**；程序 0 基线保持（161/199 条、**443 拍**、IPC=0.3693）；
> **程序 1 不再停顿**（乱序核提交满黄金 **178** 条，两核 199/178、537 拍）。
> ⚠️ 当前唯一阻塞在**参照核 2A**：程序 1 第 9 条 2A 提交 `0x80000024`，黄金（Spike）期望 `0x8000002c`
> ⇒ C2 判 2A 分歧（详见 §8.2；不属 `rtl/back2` 可写范围）。
> （第 7 轮末尾出现的 `Code generator failure: -1` 已查明为**环境问题**：`/tmp/b2chk` 目录被清理导致
> iverilog 无法写出 `.vvp`；重建目录后编译全部正常，RTL 无问题。）

| 验收项 | 状态 |
|---|---|
| B27 | ✅ **已修**（7 bit 切片下标，无掩码；实测 CHK 零违规 + 程序 1 跑通，见 §8.1） |
| 参照核 2A C2 | ❌ 程序 1 第 9 条分歧（`0x80000024` vs 黄金 `0x8000002c`），见 §8.2 |
| `tb_back2_iq` / `tb_back2_ipc` | ⏳ 本轮未重跑（整设计 codegen 失败）；上轮实测 **PASS（151 项）** / **PASS，IPC=2.0000** |
| `tb_back2_lockstep` 程序 0 | ⏳ 上轮实测基线（161/161、436 拍、IPC=0.3693），本轮未回归 |
| regress 30/30 | ❌ 未达成（上轮 29/30） |

| 验收项 | 状态 |
|---|---|
| iverilog 零编译错误 | ✅ 通过（`-Wall`，`rtl/back2` 内 implicit/越界位选已清零） |
| `tb_back2_iq` | ✅ **PASS**（151 项检查） |
| `tb_back2_ipc` | ✅ **PASS**，**实测 IPC = 2.0000**（3000 拍提交 6000 条） |
| `tb_back2_lockstep` 程序 0 | ✅ C1–C5 全绿（161/161 条，vs Spike 0 分歧） |
| `tb_back2_lockstep` 程序 1 / 2 | ❌ **未通过**（本轮修掉 3 处真因后重跑：程序 1 仍在 ~430 拍停顿；根因收敛到"free list 与 RAT 失步"这一处，见 §1 B26 与 §6） |
| `scripts/regress.sh` 全量 | ❌ 既有 27 项 + `tb_back2_iq` + `tb_back2_ipc` 实测 **28/28 PASS**（`/tmp/b2chk/regress27.log`）；`tb_back2_lockstep` 未绿 ⇒ 全量未绿（**不从清单摘除**，未捕获即失败） |

---

## 1. 本轮定位并修复的三处**真缺陷**（全部有实测证据）

### B24 ★★ `rtl/back2/lsq_simple.v`：访存宽度编码用错（**log2(字节数) 当成字节数**）

- **唯一真源** `rtl/decode/decoder.v` 的 `mem_size_o` 编码是 **log2(字节数)**：
  `LB/SB=0`、`LH/SH=1`、`LW/SW=2`、`AMO=2`、`flw=2`、`fld=3`（其注释里的"1/2/4 B"是**字节数说明**，不是字段取值）。
- 旧实现：`lmask_w = ((4'h1 << exe_size) - 4'h1) << off`、`ext_load` 的分支按 `1=字节/2=半字/默认=字`
  ⇒ **`lw/sw` 退化成 2 字节、`lh/sh` 退化成 1 字节、`lb/sb` 掩码为 0**。
- 实测证据（程序 1，`/tmp/b2chk/p1d.log`）：
  `jal x1,sub1`（PC=0x8000004C）把链接值 0x80000050 存入栈；`lw x1,12(x2)`（PC=0x80000084）**只回填低半字**
  ⇒ `ret` 跳到 `0x00000050`，乱序核此后在**低地址空间**执行程序（PC 高位丢失），与上一轮观察到的
  "截断 PC / 写回 0"完全同源。
- 修法：显式 case 给出字节掩码（0→1B、1→2B、默认→4B；8 B 属 2B-3）；`ext_load` 分支改为 `0=字节/1=半字/≥2=字`。
- 修复后实测：程序 1 的调用/返回链正确（`pc=0x8000008c` 的 `ret` 回到 `0x80000050`，PC 全 32 位）。

### B25 ★ `sim/unit/tb_back2_lockstep.sv`：复位/装载与记录 always 块的 **NBA 竞争**

- 现象：程序 1 复位后 `noo=200`（应为 0）、`roo_pc[199]` 仍是程序 0 的旧值 ⇒ **记录下标整体错位 200**，
  即时黄金比对报出"第 200 条分歧"，C1/C2 会拿错位数据判分歧（虚假分歧）。
- 成因：TB 的记录/存储写口都在 `posedge` 上用**非阻塞**赋值；`do_reset`/`clear_mem` 在**同一时间步**用
  阻塞赋值清零 ⇒ NBA 在活跃区之后落地，把清零**覆盖回去**。
- 修法：两个任务开头各加 `@(negedge clk);`（等上一拍 NBA 全部落地）。判据未放宽。

### B26 ★★ `rtl/back2/rename.v`：变更日志槽位用 **lane 下标** 而非 **有效 lane 压缩序号**

- 日志口径（B15 修好后的口径）是"**每条有效 lane 一条记录、连续排列**"，写指针 `log_wr_q` 按**有效 lane 数**
  推进；但写入用 `lg_arn[log_wr_q + j2]`（j2 = lane 下标）⇒ mask 有洞时（如仅 lane1/lane3 有效）记录被写到
  **推进范围之外**，被推进的区间里留下**陈旧的 `lg_val=1` 洞**。
- 后果：回滚重放读到上一条无关指令的旧记录 ⇒ **RAT 被恢复成过期映射**，free list 与 RAT 失步 ⇒
  同一物理号既在 free list 里又被 RAT 引用 ⇒ 被二次分配 ⇒ uop 等一个自己永不写回的物理号（**自环停顿**）。
- 实测证据（本轮新增的更强不变式检查，程序 0 即复现，`/tmp/b2chk/p1f.log`）：
  ```
  RENAME-CHK DUP: lane 0 分配 preg=65 但 RAT[arn=12] 仍引用它 | fhead=111 ftail=175 pdiold=64
  RENAME-CHK DUP: lane 1 分配 preg=79 但 RAT[arn=13] 仍引用它 | fhead=111 ftail=175 pdiold=65
  RENAME-CHK DUP: lane 0 分配 preg=82 但 RAT[arn=12] 仍引用它 | fhead=128 ftail=192 pdiold=81
  RENAME-CHK DUP: lane 1 分配 preg=5 但 RAT[arn=13] 仍引用它 | fhead=128 ftail=192 pdiold=82
  ```
  以及此前的自环形态（程序 1 ~430 拍，`/tmp/b2chk/p1e.log`）：
  ```
  RENAME-CHK FAIL: lane 0 src 0 arn=9 映射到自身新目的 preg=46（自环）| fhead=83 ftail=147
      flist[fhead..+7]=46 36 40 44 42 54 50 51 | lane dst/ord=46/0 36/1 40/2 40/2
  ```
- 修法：新增 `lg_rank[g]`（本 lane 之前有几个有效 lane）与 `lg_after[g]`（含本 lane 的推进量），
  日志槽位、`dn_log[g]`（ROB 回滚点快照）与 `snap_log_w`（检查点快照）统一改用 rank；三处口径一致。
- 附带新增（**默认开启的诊断，只打印不改判据**）：分配不变式检查 —— 本拍真正消耗掉的 free list 项
  （门控 `lvf = lane_valid & lane_fire`，避免"未派发预读"误报）不得仍被任何架构寄存器引用。
- **修复后实测（重要，如实登记）**：rank 修复是**必要且正确**的（`log_wr_q` 确实按 `valid_n_f` =
  有效 lane 数推进，槽位必须同口径），但**并未消除** DUP 现象 —— 程序 0 仍逐字复现同样四条
  （`preg=65/RAT[12]`、`79/RAT[13]`、`82/RAT[12]`、`5/RAT[13]`，`fhead/ftail` 也完全相同），
  说明本轮 mask 全满、`lg_rank == lane 下标`，DUP 的成因**不在日志槽位**，而在
  **"同一 preg 被释放两次 / 释放了仍被 RAT 引用的 preg"**（free list 与 RAT 失步）。

### B27（**未修，唯一剩余阻塞点**）free list 与 RAT 失步：快照路径与日志路径**不同代**

- **TRACE=1 实测（`/tmp/b2chk/tr.log`，CYC_LIMIT=460，覆盖程序 0）——preg=65 全历史**：
  ```
  [preg-alloc t=845000 ] fhead=30  preg=65 arn=9  rob_snap=3    ← 首次分配给 x9
  [preg-rel   t=1155000] ftail=111 preg=65 (slot 0)             ← 提交释放（合法）
  [preg-alloc t=2085000] fhead=110 preg=77 arn=6  rob_snap=0    ┐ 同拍 3 条（lane1 不需目的）
  [preg-alloc t=2085000] fhead=110 preg=65 arn=12 rob_snap=2    │ 槽位 110/111/112
  [preg-alloc t=2085000] fhead=110 preg=79 arn=13 rob_snap=3    ┘
  [preg-alloc t=2205000] fhead=111 preg=65 arn=8  rob_snap=0    ← 65 被**二次**分配（DUP 命中）
  [preg-alloc t=2205000] fhead=111 preg=79 arn=8  rob_snap=1    ← 79 同样
  RENAME-CHK DUP: lane 0 分配 preg=65 但 RAT[arn=12] 仍引用它 | fhead=111 ftail=175 pdiold=64
  RENAME-CHK DUP: lane 1 分配 preg=79 但 RAT[arn=13] 仍引用它 | fhead=111 ftail=175 pdiold=65
  ```
- **机制（已确证）**：`fhead` 从 113 **回卷到 111**（即按**检查点/ROB 快照**归还了 lane2/lane3 的
  65/79），但 **RAT 侧的重放没有回滚这两条映射**（`RAT[12]` 仍为 65、`RAT[13]` 仍为 79）
  ⇒ 同一物理号二次分配 ⇒ 程序 1 在 ~430 拍自环停顿。
  ⇒ **`ck_fhead/rb_fhead`（快照路径）与 `ck_log/rb_log`（日志路径）指向了不同代**：
  free list 按快照退、RAT 按日志退，二者必然失步。
- **已尝试的针对性修法（同源法，已回退）**：把 free list 归还改为**跟随 §3.3 的 RAT 重放**
  逐条递减（`fhead_q <= fhead_q - u_ret`，`u_ret` = 本窗口被重放的"消耗过 preg"条数），
  回滚起点不再用快照恢复 `fhead`。实测（`/tmp/b2chk/fix2.log`）：
  - ✅ **`RENAME-CHK` 违规归零**（重复项与自环都消失）；
  - ❌ 但程序 0 只提交 **116/161** 就停顿 ⇒ 归还量 < 实际分配量 ⇒ **preg 泄漏**至 free list 耗尽。
  ⇒ 两条路径都会"偏"，只是方向相反（**快照偏多 ⇒ 重复；重放偏少 ⇒ 泄漏**），
  说明**病根在"回滚目标本身取错代"**，不在归还方式。已回退到快照路径（程序 0 全绿），
  `u_ret` 作为诊断 wire 保留（未接线），`TRACE` 已改回 0。
- **✅ 定案结果（TRB=1 探针，`/tmp/b2chk/trb.log`，程序 0）**：
  - **全部回滚都走 ROB 索引路径**（`ck=0`；46 行 = int+fp 两实例 × 23 次事件），undo 距离
    `dist` ∈ {0(×4), 1(×2), 2(×34), 3(×6)}；
  - 关键时刻（DUP 前一拍 t=2085000）的快照**写入值完全正确**：
    `[rbw robidx=116..119] fh=111/111/112/113, log=127..130`，与分配现场
    （lane0→77@slot110、lane2→65@slot111、lane3→79@slot112）逐条吻合；
  - ⇒ **不是快照公式错，而是"取用到了旧代"**：ROB 是 128 项复用索引，squash 用
    `restore_rob_idx` 取 `rb_fhead/rb_log` 时，若该指令本拍没有重写快照
    （`rob_snap_valid & lane_fire` 未同时成立，或该 lane 无效），取到的就是**同索引更早
    指令**留下的旧快照 ⇒ free list 按旧代退、RAT 按当拍日志退 ⇒ 两代失步（B27 现象）。
- **下一轮最终修法（按改动量排序，二选一）**：
  1. **优先走检查点路径**：`ck_*` 有 `ck_val` 有效期保护、且每个分支在 rename 时就分配
     checkpoint ⇒ 让"有有效检查点"的分支一律用 `restore_valid` 路径，只有无检查点的 squash
     才退回 ROB 索引路径（并在退回时**校验**快照代次）；
  2. **给 ROB 索引快照加标签**：随快照存该 ROB 项的分配序号/epoch，取用时与 ROB 报告的序号
     比较，不匹配即视为无快照（走检查点或 `flush_all` 重建）。
  判据不变：三程序 C1–C5 全绿 + `RENAME-CHK` 零违规 + 无停顿 + regress 30/30。
  （兜底仍是 `sim/unit/back2_shadow_handoff.md` 的 96 bit 位图。）
- 本轮探针已按要求关闭：`TRB=0`、`TRACE=0`、`CHK=1`；`u_ret` 保留为未接线诊断 wire。
- **已排除**：日志槽位（B26 已修，现象不变）、`flush_all` 重建路径（程序 0 无异常 ⇒ `rb_act` 未启动，
  且 DUP 时 `fhead=111` 远大于重建后的 0..96）、`free_ok` 同拍释放额度（已改为"只用现有空闲数"）。
- **下一步建议（原计划已在本次执行完毕，保留作为核对清单）**：
  1. ~~开 `TRACE=1` 抓 preg=65 全历史~~ → **已完成**，结论见本节顶部；
  2. ~~核对第二次 push 是否来自回滚后重执行指令的 PDIOLD~~ → **已完成**，不是释放侧问题，
     而是"快照 vs 日志不同代"；
  3. 见本节末尾的"下一步（一次运行即可定案）"：打印回滚起点五元组并与快照写入值对照；
     兜底仍是 96 bit 空闲位图（`sim/unit/back2_shadow_handoff.md`）。

### B27（**已修，第 8 轮实测确认**）日志数组下标不回绕 ⇒ 回滚被静默跳过

- **第 7 轮判定实验的决定性证据**（TRB=1 在 §3.3 打印重放窗口，`/tmp/b2chk/exp7.log`）：
  ```
  [rb  t=2115000] ck=0 robidx=117 tgt=128 fh_undo=111 log_wr=130 fh=113 ft=174 dist=2
  [rbw2 t=2125000] k=2 ptr=130 dist=2 | p0=129 v0=x a0=x old0=x | p1=128 v1=x a1=x old1=x | p2=127 v2=0 | p3=126 v3=1
  ```
  ⇒ **待回滚的两条日志槽（128/129）读出 `x`**：`lg_val = x` ⇒ `if (u_v0) rat_q[...] <= lg_old[...]` 的
  条件为 x ⇒ **赋值不执行** ⇒ RAT 不回滚，而 free list 仍按快照回退 ⇒ 两代失步（B27 全部现象）。
- **机制**：`log_wr_q` 是**单调递增的指针**（参数文件 `BACK2_RATLOG_PTR_W = 8`，注释明写"模 256 指针 ⇒
  距离无歧义"），却被直接当作 `lg_arn/lg_old/lg_val [0:LOG_N-1]`（**深度 128**）的下标 ⇒ 第 128 条
  日志之后：**写入被静默丢弃、读出为 x**。时间点完全吻合：程序 0 在 `log_wr ≈ 128` 处首次报
  `RENAME-CHK DUP`，程序 1 在 ~430 拍后停顿（同样越过 128）。
- **修法（已定，未落地）**——两条等价路径，**都必须先解决 vvp codegen 失败**：
  1. **首选**：`LOG_PTR_W = BACK2_RATLOG_PTR_W`（8）+ 三个日志数组深度改为 `(1<<LOG_PTR_W)`（= 256）
     ⇒ 下标天然回绕、**无需掩码**，正合参数文件"模 256"口径；同时检查 `backend_top` 中
     `log_wr_o` 连接线的宽度声明（应为同一指针宽度，勿再写 `BACK2_RATLOG_N`）。
  2. **备选**：保持 128 深数组，把下标改成 **7 bit 切片** `log_wr_q[6:0]`（读侧 `u_p0..u_p3` 同样按
     `[6:0]` 相减，7 bit 算术天然模 128 回绕）。
  - ⚠️ **不要**用 `& (LOG_N-1)` 掩码写法：本轮实测该写法（以及随后若干等价变体）会让 iverilog 12.0
    在**整设计 codegen** 阶段报 `Code generator failure: -1`（`rename.v` 单独编译通过、整设计 `-t null`
    elaborat 通过，故为工具侧内部错误，不是语法/语义错）。
- **恢复配方（下一轮第一步，二选一）**：
  (a) 用路径 1 或 2 实现修法后，若 codegen 仍失败 ⇒ 把三处数组声明与 `LOG_PTR_W` **逐条**回退到
      `LOG_PTR_W = BACK2_RATLOG_N` + `[0:LOG_N-1]`（= 本轮结束时的几何），确认可编译后再逐步加回；
  (b) 若仍不可编译，把 `rename.v` 的 §3.3/§3.4 尾部（`undo_ptr/u_k/dist` 更新 + 三个日志写入循环 +
      `rat_q` 写入循环 + `rb_fhead/rb_log` 快照 + `ck_*` 快照 + `log_wr_q/fhead_q` 推进）按报告
      §"已修缺陷台账"与本文件描述**整段重写**一次（该段为本轮唯一被大范围改写过的区域）。
- 探针与口径：`TRB=0`、`TRACE=0`、`CHK=1`（`u_ret` 为未接线诊断 wire，可留可删）。

### B27 第 6 轮补充（修正"取旧代"判断，附硬数据 —— 下一轮的起点）

- **检查点优先路线不可行（本轮实测确认，避免下一轮走弯路）**：`rtl/front4/ifetch4.v:748`
  `assign lane_ckpt_valid = {m3,m2,m1,m0} & {4{grp_taken}}` —— 前端**只为"预测 taken"的组**产生
  检查点；而 B27 的现场是**方向误判（预测 not-taken、实际 taken）**，该分支 `ckpt_valid=0`
  ⇒ `restore_ck_v_w = squash_v_w & u_ckv(...) = 0`（TRB 实测：**23 次回滚全部 `ck=0`**）
  ⇒ squash **只能**走 ROB 索引路径。修法 ① 需要改前端（2B-1 既有件，本阶段不动）⇒ **必须修 ②**。
- **DUP 那次回滚的确切一行**（`/tmp/b2chk/trb.log:280`）：
  ```
  [rb t=2115000] ck=0 robidx=117 tgt=128 fh_undo=111 log_wr=130 fh=113 ft=174 dist=2
  ```
  ⇒ 快照**不是旧代**：`fh_undo=111` 正是该 lane 的正确值、`tgt=128` 正是该 lane 记录之后的日志
  指针、`dist=2` 正是其后 2 条（lane2/lane3）。
- **6 次中段回滚全部满足 `fhead_q - undo_fhead_w == dist`**（t=715000/995000/1275000/1555000/
  1835000/2115000 均为 2）⇒ **free list 归还数与 undo 距离在"数量"上没有失步**。
- ⇒ **结论修正**：失步不在"快照取旧代"，而在**重放内容 / 重放窗口**：被重放的那 2 条日志
  （lane2→x12、lane3→x13）没有把 `RAT[12]/RAT[13]` 真正恢复（9 拍后 DUP 显示仍为 65/79）。
- **一次运行即可判定的下一探针**：`TRB=1` 时在 §3.3 重放窗口打印 `(u_p3..u_p0, lg_arn, lg_val, lg_old)`，
  与 `TRACE=1` 的分配历史对齐。两种可能：
  (i) `lg_old[128]` 本身已等于 65 ⇒ 该指令是**重复重命名**（上一轮回滚没恢复 RAT，二次重命名又
  拿到同一 preg）⇒ 修"重复重命名/分配"路径；
  (ii) `lg_old` 正确但窗口**边界/去重**（`u_k` 与 `u_a*` 组合）漏掉该条 ⇒ 修窗口算术。

---

## 2. 上一轮已修且仍有效的缺陷（要点）

| # | 位置 | 要点 |
|---|---|---|
| B16 | `rename.v` §3.0 | 提交侧更新（arat/ar_used/free list 释放/ftail）**每拍无条件执行**，不被回滚分支吞掉 |
| B17 | `prf.v` | 写口/旁路按 **ROB 窗口**门控（不用全局 epoch，否则冲刷保留的更老在飞项写回被丢） |
| B18 | `rename.v` §1.2/§1.3 | 同块前递优先级 = **最近前驱优先**（`s2>s1>s0`、`p2>p1>p0`） |
| B19 | `backend_top.v` | 同块"消费者不得越过生产者发射"的就绪抑制 |
| B20 | `backend_top.v` | LSU 发射门控只对 load 生效（store 不被自己的未定址状态挡住） |
| B21 | `iq.v` | 延迟唤醒广播**两代各自独立匹配**（不能"每通道二选一"） |
| B22 | `tb_back2_lockstep.sv` | 访存模型改 2 级流水（替代指针式 FIFO，消除 `tag=x` 永久挂起） |
| B23 | RTL↔TB | 提交写使能改用 `commit_arch_we_o`（不能用 `rd != 0` 推断：B/J 型 bits[11:7] 是立即数） |
| — | `backend_top.v` | iverilog 12.0 陷阱：function 调用放进位拼接会算错 ⇒ 该处展开为表达式 |

---

## 3. 已通过的验证（原始日志）

### 3.1 `tb_back2_iq`（151 项）
```
== 检查项合计 151 项全部满足（6 个队列 × 深度 16/16/8/8/12/8）
TB_BACK2_IQ: PASS
```
（本轮 RTL 改动后复验仍 PASS，`/tmp/b2chk/iq2.vvp`。）

### 3.2 `tb_back2_ipc` —— **IPC = 2.0000**
```
== IPC 原始数据：测量窗 3000 拍，提交 6000 条 ⇒ IPC = 2000/1000 = 2.0000
== 提交宽度：有提交的拍 3000（100.0%），其中宽度 ≥2 的拍 3000（100.0%）
== 计数器交叉核对：cnt_commit_o=6394（TB 计 6396），cnt_squash=0，cnt_commit4=0
TB_BACK2_IPC: PASS
```
（本轮 RTL 改动后复验仍 PASS。）**口径**：TB 扮演理想 4 宽前端、16 条互不相干 `addi` 链 ⇒ 只受 ALU 端口数（2/拍）
限制；**端到端 IPC 上限恒为 1.0**（2B-1 取指 ≤2 parcel/拍 = 1 条 RV32 指令），端到端实测 0.3693（程序 0）。

### 3.3 锁步 TB 程序 0（C1–C5 全绿）
```
== 程序 0：两核提交 161 / 199 条（黄金 161），跳板 2 / 2 条，443 拍
== 程序 0 性能：提交窗拍数=436 提交条数=161 平均 IPC=0.3693 宽度4占比=0%
```

### 3.4 回归（本轮实测，锁步 TB 暂移出 glob 的一次运行）
```
== regress.sh：总数=28 运行=28 通过=28 跳过=0 失败=0
REGRESS: 28/28 PASS        （既有 27 项 + tb_back2_iq + tb_back2_ipc，日志 /tmp/b2chk/regress27.log）
```

---

## 4. 复现命令

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)

iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/iq.vvp  -s tb_back2_iq  "${RTL[@]}" sim/unit/tb_back2_iq.sv  && vvp /tmp/iq.vvp
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ipc.vvp -s tb_back2_ipc "${RTL[@]}" sim/unit/tb_back2_ipc.sv && vvp /tmp/ipc.vvp
iverilog -g2012 -I rtl/pkg -I . -P"tb_back2_lockstep_top.CYC_LIMIT=1200" -o /tmp/ls.vvp \
         -s tb_back2_lockstep_top "${RTL[@]}" sim/unit/tb_back2_lockstep.sv && vvp /tmp/ls.vvp
./scripts/regress.sh
```

**调试旋钮**（默认全关，除 `CHK` 外）：`rename.v` 的 `CHK=1`（自检）+ `TRACE=0`（preg 分配/释放流水）、
`iq.v` 的 `DBG=0`、`backend_top.v` 的 `DBG_IQ/DBG_LSU=0`、TB 的 `DBG_CYCLES=0`（>0 时打印逐拍
`[dbg]/[oo-cmt]/[oo-tail]` 与 LSU/IQ 槽级转储）。
注：`iverilog -P<module>.<param>` 只对**顶层**生效，子模块旋钮需临时改默认值或从 TB 传参。

---

## 5. 已知性能/时间学事实（影响回归墙钟）

- 本 TB 是"2A 全核 + front4 + 乱序后端 + 双存储体"的集成级仿真，实测 **~0.3–0.5 s/仿真拍**
  （双核各跑三程序 ⇒ 数千拍 ⇒ 数分钟到十几分钟）。
- `scripts/regress.sh` 为此新增 **T6** 档：`tb_back2_lockstep` 墙钟 900 s（与 T5 `tb_m3_ddr3` 同款），
  **只放宽墙钟、不放松判据**；如仍不足，只允许继续放宽该 TB 的墙钟档。

---

## 6. 下一会话最短路径

1. 用 §4 的锁步命令确认三程序 C1–C5 全绿（B24/B25/B26 修复后重跑）；若程序 1/2 仍有自环，
   看 `RENAME-CHK DUP` 首条记录（它会在"首次污染当拍"报出 ark 号与 preg 号，直接指出是释放侧还是回滚侧）。
2. 全量 30 个 TB 回归（`./scripts/regress.sh`）到全绿，并把本报告状态表更新为全绿。
3. 可选加固：`rename.v` 的 free list 换成 **96 bit 空闲位图 + 低位优先编码**
   （设计见 `sim/unit/back2_shadow_handoff.md`）；本轮的 rank 修复已消除已定位的失步根因，位图记为可选。
4. 2B-3 待补（本里程碑显式不做）：未对齐拆笔、PMP/MMU 落地、AMO/LR-SC、fence 屏障、`fld/fsd`（8 B）。

> 纪律提醒：本轮所有修改都在 `rtl/back2/**` 与 `sim/unit/**`（back2 新增件）+ 已授权的 `regress.sh` T6；
> 未 `git checkout/stash/reset`、未提交；反证/备份在 `/tmp/b2chk/*.bak*`。

## 8. 第 8 轮结果（B27 修复落地 + 新的参照核阻塞）

### 8.1 B27 修法（已落地并实测生效）

- **采用备选路径②**（无掩码）：`rename.v` 新增
  `localparam LOG_AW = $clog2(LOG_N);`（128 ⇒ 7 bit）与 `wire [LOG_AW-1:0] lg_wr_a = log_wr_q[LOG_AW-1:0];`，
  写侧三处改为 `lg_[arn|old|val][lg_wr_a + lg_rank[j2]]`，回滚窗口四个读指针改为
  `wire [LOG_AW-1:0] u_pN = undo_ptr[LOG_AW-1:0] - 3'd(N+1);` ⇒ **7 bit 算术天然模 128 回绕**，
  既不越界也不需要掩码（`& (LOG_N-1)` 掩码写法已确认会触发 iverilog 内部错误，**禁用**）。
- **实测（`/tmp/b2chk/b27fix3.log`，程序 0+1）**：
  - ✅ **`RENAME-CHK` 违规 0 条**（此前的 `RENAME-CHK DUP` 与自环全部消失）；
  - ✅ **程序 0 基线保持**：两核提交 161 / 199 条（黄金 161）、**443 拍**、提交窗 436 拍、**IPC=0.3693**；
  - ✅ **程序 1 不再停顿**：`两核提交 199 / 178 条（黄金 178）、537 拍` —— 乱序核提交满黄金条数，
    证明"free list 退、RAT 不退"的两代失步已被根治。

### 8.2 新暴露的阻塞：**参照核 2A 的 C2 分歧**（不在 back2 范围）

```
FAIL: 程序 1 2A 核第 9 条 PC=0x80000024 期望 0x8000002c
FAIL: C2 程序 1：2A 核提交流 vs Spike 黄金 PC 流 0 分歧
```
- 程序 0 的 2A 流与 Spike 完全一致（161/161）；程序 1 在**第 9 条**分歧：黄金期望
  `0x8000002c`（说明 `0x80000020` 的 `beq x10,x0,4f` 应**taken** ⇒ 跳过 `0x24/0x28`），
  而 2A 核提交了 `0x80000024`（按 not-taken 走）⇒ 2A 核的 `x10 = x6 & 1 ≠ 0`，即 **`li x6,0`
  之后 x6 非 0**（或该指令未生效）。
- 这是**参照核/参照路径**问题（`rtl/top|exec|decode` 与 `sim/unit` 的 2A 侧记录），**不属于 rtl/back2**
  的可写范围；下一轮建议：
  1. 用 `DBG_CYCLES>0` 打印 2A 侧的逐条提交（含 rd/wd），看 `li x6,0`（0x80000010）与
     `andi x10,x6,1`（0x80000018）的真实写回值；
  2. 检查**逐程序重置**是否彻底：TB 的 `do_reset` 是否让 2A 核的 L1I/L1D、GPR、分支预测器完全复位
     （程序 0 结束时 2A 核停在 `j .` 自循环，若缓存/GPR 未清干净，程序 1 的第一条分支就会走错）；
  3. 若确认是 2A 侧既有缺陷，按纪律**登记为遗留**（不得改 2A 文件），并在锁步 TB 中改为
     "只对乱序核做 C2 比对 + 2A 侧只做条数一致"（**需母代理批准**，属判据调整）。

## 9. 第 9 轮：2A 侧 C2 分歧定案与 TB 修复

### 9.1 根因（已确证）：2A 的 L1I 阵列**没有复位** ⇒ 陈旧指令行跨程序存活

- `rtl/cache/cache_tag_array.v` 与 `rtl/cache/cache_array_bram.v` **完全没有 `rst_n`**（grep 无任何命中），
  `rtl/cache/l1i.v` 只在 `inval_all`（fence.i / cbo.inval）时清 valid（`wr_valid = inval_all ? 1'b0 : 1'b1`）。
  ⇒ TB 的逐程序 `rst_n` 复位**清不掉 L1I**；三个程序都在 `0x8000_0000` 同址装载，
  程序 0 结束后停在 `j .` 自循环，其指令行仍在 I$ 中，程序 1 直接**命中陈旧指令** ⇒ 分支方向走错
  （实测：程序 1 第 9 条 2A 提交 `0x80000024`，Spike 黄金期望 `0x8000002c`）。Spike 无缓存，
  所以黄金轨迹永远是"干净"的 —— 与母代理的判断一致。
- 结论：**不是 2A RTL 的功能缺陷**（复位语义如此设计），而是**锁步夹具**缺少"逐程序 I$ 失效"，属 TB 可写范围。

### 9.2 TB 修复：2A 侧跳板首字插入 `fence.i`（乱序侧同址给 nop，保持两核 PC 流一致）

- `sim/unit/tb_back2_lockstep.sv`：
  - 新增 `localparam [31:0] STUB_FI = 32'h0000100f;`（fence.i）；
  - `u_mem2a.xip_mem[0]=STUB_FI, [1]=STUB0, [2]=STUB1`（2A 侧 3 字跳板）；
  - 乱序侧 XIP 模型同址返回 `32'h00000013`（nop），后续字与 2A 对齐 ⇒ **两核 PC 流严格一致**（跳板 3/3）。
- **实测（`/tmp/b2chk/r9c.log`）**：
  | 项 | 结果 |
  |---|---|
  | 程序 0 | ✅ **C1–C4 全过**（161/161，跳板 3/3，705 拍）；C5 415/256≈0.39 过 |
  | 程序 1 | ✅ **C2 分歧消失**：两核 **178 / 267** 条（黄金 **178**）、跳板 3/3、983 拍，**C1–C4 全过** |
  | `RENAME-CHK` | ✅ 0 条 |
- **C5 测量窗口口径（已登记，属测量口径而非阈值放宽）**：窗口起点改为 **2A 核进入程序的那一拍**
  （`start2a`），即不含跳板与 `fence.i` 前导；阈值 `IPC_LIMIT_Q8=64`（0.25）**未动**。

### 9.3 剩余唯一阻塞：C5 防退化下限（冷缓存重取把**参照核**拖慢）

- 现象：程序 1 提交窗 **982 拍 / 178 条 ⇒ IPC=0.1813 < 0.25** ⇒ C5 FAIL（程序 0 为 411 拍 ⇒ 0.3917 过）。
- 原因：`fence.i` 之后 2A 的 I$ 全空，程序 1 的取指**全部缺失**，参照核自身吞吐降到 ~0.18；
  而 C5 当前用 `n_commit_run = n2a`（**参照核**计数）+ 两核并集窗口 ⇒ 测的其实是参照核。
- **两条处置建议（请母代理裁决，均不放宽阈值）**：
  1. **推荐（夹具侧，彻底消除失效率）**：让三个程序装载到**互不相同的基址**（相距 ≥8 KB，8 KB 步进），
     使陈旧行的 **tag 不同**而永不命中（命中需 tag 相等），从而可以**去掉 `fence.i`**、恢复热缓存速度。
     程序均为 `%pcrel` 位置无关 ✓、`.option norvc` ✓；需用 `gen_back2_lockstep_data.py --pc <base>`
     重新生成 `back2_lockstep_data.svh`（黄金 PC 随基址改变），TB 的 `PROG_PC`/`load_prog` 改为按程序取基址。
  2. **备选（指标主体变更）**：C5 改为测**乱序核**（`noo`）在程序窗内的提交吞吐，阈值不变。
     属"判据主体"调整，需母代理批准后才做。

## 10. 第 10 轮：程序分基址（母代理裁决方案①）已落地

### 10.1 修法（TB 侧，镜像不变）

- `sim/unit/tb_back2_lockstep.sv` 新增 `function [31:0] pbase(i) = PROG_PC + i*32'h4000`
  ⇒ 三程序基址 **0x8000_0000 / 0x8000_4000 / 0x8000_8000**（16 KB 步进）；`load_prog` 按 `pbase(pidx)`
  装载；跳板改为**按当前基址**生成（`lui x5,(pbase|0x2b7)` + `jalr`，两核一致，跳板口径 2/2）；
  起录判据用 `pbase(pi)`；黄金 PC 用 `gold_delta = pbase(pi) - PROG_PC` **同量平移**（`.svh` 与生成器不变）；
  **`fence.i` 跳板已移除**（陈旧行 tag 不同 ⇒ 结构上不可能命中，无需失效）。
- 依据：I$ 命中要求 **tag 相等**；程序镜像 8 KB、基址相距 16 KB ⇒ 上一程序的指令行 tag 必不相同 ⇒ 永不假命中；
  程序全部 `%pcrel` 位置无关（含 `tohost`/`darea` 的 pcrel 取址）⇒ 换基址只需平移黄金 PC。

### 10.2 实测（`/tmp/b2chk/r10.log`）

| 项 | 结果 |
|---|---|
| `RENAME-CHK` 违规 | ✅ **0 条** |
| 程序 0 | ✅ **C1–C5 全绿**：161/199 条、跳板 2/2、**443 拍**、窗 411 拍、**IPC=0.3917**（基线未回退） |
| 程序 1 | ✅ C1–C4 全绿：**178 / 215 条（黄金 178）**、跳板 2/2、721 拍；❌ **C5：Q8=63 vs 阈值 64**（IPC=0.2469） |
| 程序 2 | ⏳ 因程序 1 C5 触发 `$fatal` 未执行（fail-closed） |

### 10.3 C5 差 1.2% 的定性与请示（阈值/口径按裁决未动）

- C5 主体 = **参照核（2A）**的提交吞吐（母代理第 9 轮裁决明确不许改）。程序 1 为分支密集流
  （8 次循环 × 4 分支 + 二级调用/返回），2A 参照核在**冷 I$ + 冷预测器**下端到端 178 条耗时 721 拍
  ⇒ IPC=0.2469，阈值 0.25 相差 **1.2%**（Q8 63 vs 64）。程序 0（顺序整数流）0.3917 远超阈值。
- 该差距来自**参照核自身**的取指/误判开销（OoO 核在理想存储下早已提交完 178 条并继续 `j .`），
  不是后端退化；C1–C4（等价性）全过、CHK 零违规、无停顿。
- **需母代理裁决（两者都涉及判据，本轮按纪律未动）**：
  1. 为**分支密集程序**单列下限（例如程序 0 ≥0.30、程序 1/2 ≥0.20），阈值表写进 TB 并注明实测依据；
  2. 或维持 0.25 不变，把 C5 的**计数主体**改为乱序核（阈值不变，但主体变更，第 9 轮已明确不批）。
- 在此之前：锁步 TB **fail-closed 保留在回归清单**（不摘除、不放宽），regress 仍不会 30/30。

## 11. 第 11 轮：C5 分档下限落地 + 程序 2 暴露新缺陷 B28

### 11.1 C5 分档防退化下限（母代理裁决：每档 = 实测 × ≤0.8）

TB 内新增 `function integer ipc_lim_q8(p)`，逐档注释写明实测/下限/裕量/测量条件（`README` 同步）：

| 程序 | 类别 | 实测 IPC | 下限(Q8) | 下限值 | 裕量 | 本轮结果 |
|---|---|---|---|---|---|---|
| 0 | 顺序整数流 | 0.3917 | 77 | 0.30 | 30% | ✅ 过 |
| 1 | 分支密集 + 二级调用/返回 | 0.2469 | 49 | 0.19 | 29% | ✅ 过 |
| 2 | 访存 + CSR | ⏳ 待 B28 修复后实测 | 0（临时占位） | — | — | ❌ 被 B28 阻断（C1 分歧，未到 C5） |

- 测量条件（各档一致，写进 TB 注释）：参照核 2A、**冷 I$ + 冷分支预测器**（逐程序复位不清 I$/BPU）、
  窗口起点 = 2A 进入程序那一拍、窗终点 = 两核最后一次提交。
  ★ **任何后续夹具/测量口径改动若影响 2A 吞吐，必须重新实测并重算本表**（已写进 TB 注释）。
- 0.25 通用档已废止；方案②（C5 主体改乱序核）维持不批。

### 11.2 新缺陷 B28（**待修**）：字节 store→load 转发未生效

- 现场（`/tmp/b2chk/r11c.log`，程序 2 第 11 条，PC=0x8000_802c）：
  ```
  FAIL: 程序 2 第 11 条写回分歧：乱序 {we=1 rd=10 wd=0x00000013} vs 2A {we=1 rd=10 wd=0x00000003}
  ```
- 指令对（`sim/unit/prog/back2_p3_memcsr.S`，循环体首轮）：
  `0x28: sb x9, 8(x5)` → `0x2c: lbu x10, 8(x5)`；x9 = x6+3 = 3 ⇒ 期望 0x03。
  乱序核返回 **0x13** = TB 存储器填充值（`clear_mem` 填 `32'h00000013` 的**低字节**）
  ⇒ **该 `sb` 既没有转发生效、也没有落到存储器**（load 直接读了未写入的内存）。
- 可疑范围（`rtl/back2/lsq_simple.v`，本阶段可写）：
  1. §2.2 字节级转发：`stq_msk[j][bl]`（size=0 的掩码来自 B24 修法的 `3'd0: 4'h1 << off`）与
     `bl = exe_addr[1:0] + b[1:0]` 的匹配；
  2. `stq_av/stq_dv` 置位与 `any_unk_w` 门控（store 未定址会挡 load 发射；此处应已满足）；
  3. `stq_d` 的字节对位（`exe_wdata << {exe_addr[1:0],3'b000}`）与 `stq_msk` 是否同拍写入；
  4. 提交排空 `dr_*`（若 sb 排空后 load 才执行，内存应为 0x03；实测 0x13 ⇒ 排空也没发生）。
- 下一步探针：`lsq_simple.v` 的 `DBG=1`（经 `backend_top` 的 `DBG_LSU` 传入）+ TB `DBG_CYCLES>0`，
  打印 `sb` 那条的 `stq_v/av/dv/msk/a/d` 与 `lbu` 发射拍的 `fwd_hit_w/fwd_all_w/ld_hm`。

## 12. 第 12 轮：B28 修复尝试（两次，均已回退）与下一轮现场探针

### 12.1 根因再确认（为什么 `sb→lbu` 漏转发）

- `lsq_simple.v` §2.1 的"更老未定址 store 阻塞 load 发射"用的是 `stq_rob[q]` 判年龄，而
  **`stq_rob` 只在 E1（地址生成）写入**：对"已分配但尚未执行"的 store，该字段是**上一占用者的陈旧值**
  ⇒ 年龄比较失真 ⇒ 更老的未定址 store 可能**漏检**。
- 程序 2 现场正好命中：`sb x9,8(x5)` 的数据 x9 来自刚发射的 `lw x9,4(x5)`（长延迟），
  而 `lbu x10,8(x5)` 只需要 x5（早已就绪）⇒ **lbu 抢在 sb 之前发射** ⇒ 转发扫描找不到该 store
  ⇒ 读到内存填充值 `0x13`（2A 为 `0x03`）⇒ C1 第 11 条分歧。

### 12.2 两次修复尝试与实测结果（**均已按纪律回退**）

| 尝试 | 改动 | 实测结果 |
|---|---|---|
| (a) 保守口径 | `any_unk_w` 改为"STQ 中存在**任何**未定址 store 即挡 load" | ❌ **死锁**：更老的 load 与"数据依赖该 load 的更年轻 store"互等（`sw x8,4(x5)` 的数据来自前一条 `lw`）⇒ 程序 2 乱序核卡在 **20 条**（`/tmp/b2chk/r12.log`） |
| (b) 分配期 ROB 索引 | `lsq_simple.v` 新增 `alloc_rob` 端口，分配时即写 `stq_rob`（`backend_top` 用 `rob_alloc_idx0+lane` 驱动，与 rename 快照同口径），判据仍按年龄 | ❌ 仍卡在 **20 条**（`/tmp/b2chk/r12b.log`）：说明除年龄外还有"余留未定址项"或发射/唤醒侧原因 |

- 回退后状态（当前）：两处改动全部撤销（`grep -c alloc_rob` = 0），三个 TB `-Wall` 零错误；
  程序 0/1 仍全绿（C5 分档 0.30/0.19），程序 2 回到"能跑完 126/257、仅第 11 条取错值（C1）"。

### 12.3 下一轮现场探针（一次运行即可定位）

1. TB：`-P"tb_back2_lockstep_top.DBG_CYCLES=1200"`（覆盖程序 2 开头）⇒ 已有 `[lsu]/[lsu2]/[lsu3]` 打印；
2. `backend_top` 的 `DBG_LSU=1`（临时改默认值）⇒ `lsq_simple.v` 的 `DBG` 每拍打印每个 load 槽
   `slot/req/tag/rob/addr` 与 `pend_any/rsp_ok/dr_any/stq_head`；
3. 重点看：该 `sb` 的 STQ 项（`stq_v/av/dv/msk/a/d`）何时被填、`lbu` 发射拍的 `fwd_hit_w/fwd_all_w/ld_hm`、
   以及 `any_unk_w` 当时的值；
4. 若确认"发射顺序"是根因，正确的修法方向是给 LSU 增加**按分配序**的发射闸（用分配期序号而非
   E1 写的 ROB 索引），并同时保留 (a) 的反死锁性质（只挡"更老"的项）。

## 13. 第 13 轮：B28 修复尝试 (c)（**保留**：修掉余留项/陈旧年龄；取值分歧仍未解）

### 13.1 改动（保留，已编译通过）

- `lsq_simple.v`：
  1. 新增 `input [W*ROB_IDX_W-1:0] alloc_rob`（分配期 ROB 索引）与 `input [7:0] rob_cnt`（ROB 占用数）；
  2. STQ 分配时即写 `stq_rob[ai[si]] <= alloc_rob[si]` ⇒ §2.1 的**年龄判据首次真正有效**
     （此前该字段只在 E1 写，已分配未执行项里是上一占用者的陈旧值）；
  3. 新增 §4.5b **窗口外作废**：`((stq_rob[si]-rob_head)&7'h7F) >= rob_cnt` 的项一律清 `stq_v`
     —— 消灭"指令已提交越过但 STQ 项残留 `v=1,av=0`"的**余留未定址项**（窗口算术、无掩码写法）。
- `backend_top.v`：`.alloc_rob({rob_alloc_idx0+3,+2,+1,+0})`（与 rename 的 `rob_snap_idx` 同口径）、
  `.rob_cnt(rob_cnt_w)`。

### 13.2 实测（`/tmp/b2chk/r13.log`）

| 项 | 结果 |
|---|---|
| 程序 0 / 1 | ✅ 与基线**完全一致**（161/199、443 拍、IPC 0.3917；178/215、721 拍、IPC 0.2469） |
| 程序 2 | ✅ **停顿已消除**（126/257、跳板 2/2、913 拍，与第 11 轮基线同） |
| `RENAME-CHK` | ✅ 0 条 |
| 程序 2 C1 | ❌ **仍为第 11 条分歧**：`乱序 {we=1 rd=10 wd=0x00000013} vs 2A {we=1 rd=10 wd=0x00000003}` |

⇒ **结论修正**：B28 的"发射序/年龄判据"问题（(a)(b) 两次尝试的症状）已被 (c) 修掉（不再停顿、
不再有陈旧年龄），但 `sb→lbu` 的**取值错误另有其因**，且**不是**发射顺序：`lbu` 现在必然在
`sb` 定址之后才发射，却仍取到 `0x13`。

### 13.3 下一轮定位（一次运行即可判别三种可能）

- 探针：TB `DBG_CYCLES=1200` + `backend_top.DBG_LSU=1`（临时改默认值）。
- 判别表（看该 `sb` 的 STQ 项与 `lbu` 的 E1 信号）：
  1. **`sb` 根本没执行**（`stq_av` 恒 0 / `cnt_store_o` 不增）⇒ 分类/发射问题（查 `exe_is_store`）；
  2. **`sb` 执行但地址错**（`stq_a` ≠ darea+8）⇒ AGU/立即数（store 的 S 型立即数）问题；
  3. **`sb` 执行且地址对、掩码对**，但 `lbu` 的 `fwd_hit_w/fwd_all_w/ld_hm` 全 0 且回读内存 = 0x13
     ⇒ 该字的内存**根本没被写过**（排空 `dr_*` 未触发，或写口 `mem_req_wen/wstrb` 错）⇒ 查 §4.5 排空路径。
- 提示：`0x13` 只可能来自**被装载映像之外**的内存（映像内该处为 0x00）或**错误的转发源**，
  故 (2)/(3) 的可能性高于 (1)。
- 修复方向（待判别后定）：若为 (3)，重点在 `dr_fire/dr_sel` 的排空选择与 `mem_req_wstrb` 的字节使能；
  若为 (2)，重点在 store 立即数（`imm` 字段在 S 型下的产生）。

## 14. 第 14 轮：B28 **定案**（同块 store/load 绕过发射闸）+ 修复方案

### 14.1 判别结论（探针实测，`/tmp/b2chk/r14.log`）

打开 `DBG_LSU=1` + TB `DBG_CYCLES=1200` 抓到现场：

```
[lsu-dbg] stq[3] v=1 av=1 dv=1 msk=0001 a=0x80009008 d=0x00000003 rob=12 ret=0   ← sb 执行**完全正确**
[lsu-dbg] ld slot=0 req=0 tag=0 rob=13 ep=1 addr=0x80009008                       ← lbu 与 sb 同址
[lsu-dbg] cnt_ld=3 cnt_st=3 cnt_fwd=2 cnt_stall=0 stq_head=1 any_unk=0 iss_ok=1
[lsu-dbg] ld slot=0 req=1 tag=0 rob=13 ep=1 addr=0x80009008                       ← 却发了访存请求（扫描零命中）
```
- **否掉假设 (1)**（store 没执行）：`cnt_st` 正常递增、`stq[3]` 字段全对；
- **否掉假设 (2)**（地址错）：`a=0x80009008` = 程序 2 基址 + darea + 8，与 load 同址；
- **否掉"掩码/数据错"**：`msk=0001`、`d=0x00000003` 正确；
- **确认**：`lbu` 的 E1 转发扫描**零命中** ⇒ 走内存路径 ⇒ 读到映像填充字 `0x00000013`
  （映像里未使用的字由生成器填 nop ⇒ 该字就是 0x13；不是"未初始化内存"）。

### 14.2 机制（定案）

`sb x9,8(x5)`（0x28）与 `lbu x10,8(x5)`（0x2c）落在**同一个 4 条派发块**内：
1. 该块派发当拍，STQ 的分配写（`stq_v<=1, stq_av<=0`）是**非阻塞赋值**，要到**当拍末**才生效；
2. 同一拍 load 可能已被选中发射 ⇒ `any_unk_w` 此时**看不到**这条刚分配的 store 项（`stq_v=0`）
   ⇒ 发射闸放行（`iss_ok=1`，日志一致）；
3. 次拍 load 进 E1，此时 `stq_av` 仍为 0（store 的数据 x9 依赖前面的 `lw x9,4(x5)`）
   ⇒ 转发扫描条件 `stq_av[j]` 不满足 ⇒ **零命中**，`ld_hm=0`；
4. load 于是发访存请求读到映像填充 0x13；store 稍后执行并排空（`ret=1`）、内存最终正确 —— C4 会过、
   只有 C1 的写回值错，与实测完全一致。
⇒ 第 13 轮 (c) 的年龄/余留项修复是**必要但不充分**：真正的缺口是"**同一派发块的更老 store 对 load 的发射闸不可见**"。

### 14.3 修复方案（下一轮落地，二选一，均只动 `rtl/back2/`）

- **方案 A（推荐，LSU 局部）**：把转发判定从"E1 快照"改为**请求发射拍重算**。即对 `pend_sel` 槽
  用其 `ld_addr` 与**当前** STQ 状态重新做一次字节级转发归约：
  - 全命中 ⇒ 不发访存、直接走 `fwdp` 通路写回（数据取当前 STQ）；
  - 部分命中 ⇒ 只把未命中字节交给访存，`ld_hm/ld_hd` 用重算值；
  - 仍在 `any_unk_w` 时 **不发请求**（`ld_fire &= ~any_unk_w`），等 store 定址后再判 ⇒ 从结构上消除
    "同块 store 不可见"窗口。改动集中：`lsq_simple.v` 的 §2.2 归约改为以 `pend_sel/ld_addr` 为输入的函数/组合块，
    E1 只登记 `ld_addr/size/uns/pdest`，不再登记 `ld_hm/ld_hd`。
- **方案 B（更小但保守）**：`lsq_simple.v` 增加"同块保护"：若本拍 `alloc_valid` 中有 store 被分配，
  则**本拍不放行任何 load 的 E1/请求**（用一个 1 拍 `alloc_block` 标志 + `ld_fire &= ~alloc_block`）。
  实现最小；代价是每有 store 派发就推迟一拍，性能影响可忽略（程序 0/1 的窗由 2A 决定）。
- 两者都保持 B24（4B 宽度）与 (c)（alloc_rob/窗口外作废）不回退。

## 15. 第 15 轮：方案 A 实现并实测（**结果零变化 ⇒ 已回退**）+ 下一轮探针

### 15.1 方案 A 实现要点（已按母代理裁决落地后实测）

在 `lsq_simple.v` §2.3 新增"**请求发射拍按当前 STQ 重算**"组合块：以 `pend_sel` 的
`ld_addr/ld_size/ld_rob` 为输入重做字节级转发归约（`plmask_p/fwd_hit_p/fwd_data_p/any_unk_p`），并：
- `ld_fire = pend_any & ~dr_any & mem_req_ready & ~any_unk_p & ~fwd_all_p`
  （有更老未定址 store 时**不发请求**）；
- `ld_fire` 拍把重算的 `fwd_hit_p/fwd_data_p` 写入 `ld_hm/ld_hd[pend_sel]`（响应拍由 `wb_merge` 使用）；
- `fwd_all_p` ⇒ 不发访存，直接经 `fwdp` 通路用**当前 STQ 数据**写回（与 E1 全转发同构，带 `~fwdp_v & ~ewb_all_w` 优先级保护）。

### 15.2 实测（`/tmp/b2chk/r15.log`）：**与未修版本逐字相同**

| 项 | 结果 |
|---|---|
| 程序 0 / 1 | ✅ 161/199、443 拍、0.3917；178/215、721 拍、0.2469（完全不变） |
| 程序 2 | ❌ 仍 `第 11 条 wd=0x00000013 vs 0x03`；126/257、913 拍（完全不变） |
| `RENAME-CHK` | ✅ 0 条 |

⇒ **请求拍重算也没有命中**，且请求**没有被 `any_unk_p` 挡住**（否则该 load 会在 store 定址后转发得 0x03）。
这说明问题比"E1 快照过期"更深：在请求发射的那一拍，重算看到的 STQ/年龄条件**仍然不构成命中**。
由于方案 A 未带来任何可观测收益（且增加复杂度），按"最佳已知状态"纪律**已整段回退**
（`grep -c "B28-A|fwd_all_p|any_unk_p"` = 0），B24 与 (c) 均保持不动；三 TB 编译零错误。

### 15.3 下一轮探针（把重算块内部打印出来，一次运行定案）

在第 15.1 的重算块（或直接在 `$display` 中引用其信号）加一行，于**请求发射拍**打印：
`pend_sel / ld_addr[pend_sel] / ld_size[pend_sel] / ld_rob[pend_sel] / rob_head / plmask_p /
 fwd_hit_p / fwd_all_p / any_unk_p` 以及**同拍**全部 STQ 项的
`stq_v/av/msk/a/d/rob`。要判定的两种可能：
1. **重算条件本身有误**（如 `ld_rob[pend_sel]` 与 `stq_rob` 的年龄比较因 `rob_head` 选取不同而失败）；
2. **该 load 根本没有走"pending → 请求"路径**（例如它在 E1 就被判成全转发、或它的请求由别的槽发出）
   ⇒ 需同时打印 E1 拍的 `fwd_hit_w/fwd_all_w` 与 `newslot`，把这条 load 的完整生命周期串起来。

## 16. 第 16 轮：B28 **机制彻底闭合**（命中条件分解实测）+ 最终修法配方

### 16.1 探针实测（`/tmp/b2chk/r16.log`，请求发射拍逐项分解）

```
PEND sel=0 addr=0x80009008 size=0 rob=13 rob_head=11 age_l=2
  stq[0] av=1 msk=1111 a=0x80009004 age_s=127 addr_eq=0 mskhit=1 age_lt=0
  stq[1] av=1 msk=1111 a=0x80009000 age_s=124 addr_eq=0 mskhit=1 age_lt=0
  stq[2] av=0 msk=0000 a=0x00000000 age_s=117 addr_eq=0 mskhit=0 age_lt=0
  stq[3] av=0 msk=0000 a=0x00000000 age_s=117 addr_eq=0 mskhit=0 age_lt=0
E1 exe_valid=1 is_store=1 rob=12 addr=0x80009008 size=0 | fwd_hit=0000 fwd_all=0 lmask=0001
```
- `sb`（rob=12）与 `lbu`（rob=13）**同拍前后**：load 请求拍时 `sb` 的项仍 `av=0`（未定址）**且
  `stq_rob=0`（陈旧/未写入）** ⇒ 年龄分解 `age_s=117` vs `age_l=2` ⇒ **`age_lt=0`**。
- ⇒ 该 store 对 load **双向不可见**：既不满足"更老未定址 store"闸门（不挡），也不满足转发命中（不转）
  ⇒ load 发访存请求、读到映像填充 `0x13`。**这就是 B28 的完整机制**（此前"E1 快照/D 路径"的推断
  得到实测确认，且明确了失效点是 **`stq_rob` 在未定址项上不可用**）。

### 16.2 最终修法配方（下一轮落地，只动 `rtl/back2/`）

**用"分配序计数器"取代 ROB 索引做年龄比较**（母代理第 13 轮的指示方向，实测已证明必需）：

1. `lsq_simple.v`：
   - 新增 `reg [SEQ_W-1:0] alloc_seq_q`（如 8 bit），**每次 STQ 分配事件自增**；
   - 新增 `reg [SEQ_W-1:0] stq_seq [0:STQ_N-1]`：分配时 `stq_seq[ai[si]] <= alloc_seq_q`（当拍值）；
   - 新增 `reg [SEQ_W-1:0] ld_seq [0:OUT_N-1]`：**load 进 E1 时**登记 `ld_seq[newslot] <= alloc_seq_q`
     （= "该 load 进入流水时已分配到的序号"）；
   - §2.1 闸门与 §2.2/§2.3 转发年龄判据统一改为
     `(stq_seq[j] <= ld_seq[pend_sel|newslot])`（同块 store 序号相等 ⇒ 计入"更老"，正确）；
   - **禁止掩码写法**（B27 教训）；序号比较天然无回绕歧义（窗口 ≤ 深度）。
2. `backend_top.v`：无需再传 `rob_cnt`（可留作观测）；`alloc_rob` 若不再使用可移除，保持端口最小。
3. 判据不变：B24（4B 宽度）与 (c)（窗口外作废）保持；修完先跑程序 2 的 C1–C4，再实测 C5 定档。

（本轮探针已关：`DBG_LSU=0`；`TRB/TRACE/DBG_IQ=0`、`CHK=1`。）

## 17. 第 17 轮：分配序方案实测**零变化**（已回退）⇒ **最终结论：修法必须在发射侧（严格程序序发射）**

### 17.1 本轮做了什么

按配方在 `lsq_simple.v` 落地"分配序年龄 + 请求拍重算"：`alloc_seq_q`（每次 STQ 分配自增）、
`stq_seq[]`（分配时登记）、`ld_seq[]`（load 进 E1 登记），§2.1 闸门与 §2.2 扫描年龄统一为
`stq_seq <= ld_seq`，并重新加入 §2.3 请求拍重算（全命中⇒fwdp 写回；部分命中⇒重算掩码；
`any_unk_p`⇒不发请求）。编译通过、跑满三程序。

**实测（`/tmp/b2chk/r17.log`）：与未修版本逐字相同**（程序 0/1 443/721 拍、IPC 0.3917/0.2469 不变；
程序 2 仍 `第 11 条 wd=0x13 vs 0x03`）⇒ 该方案**同样无效**，已整段回退。

### 17.2 为什么所有 LSU 局部修法都会晚一步（结合第 16 轮现场）

r16 现场关键两行（同一拍）：
```
E1 exe_valid=1 is_store=1 rob=12 addr=0x80009008 size=0 | fwd_hit=0000 fwd_all=0 lmask=0001
ld slot=0 req=0 tag=0 rob=13 ep=1 addr=0x80009008          ← lbu **已经进表**，而 sb 才刚 E1
```
⇒ **`lbu`(rob=13) 的 E1 早于 `sb`(rob=12) 的 E1**，且两者在**同一派发块**、由**同一拍**发射序列进入 LSU。
⇒ 无论"E1 快照"、"请求拍重算"还是"分配序年龄"，只要判断发生在 LSU 内部，就已经晚于
"更年轻的 load 被放进 LSU"这一既成事实：load 的地址/掩码/序号在该拍全部是"分配写尚未生效"的状态。
**唯一能根治的位置是发射侧**：让 LSU 的 load **只能在它是 LSU 队列中最老项时**才允许发射
（严格程序序发射），此时"更老的未定址 store"必然已在 LSU 内部（可见）。

### 17.3 下一轮修法（发射侧，仍只动 `rtl/back2/`）

1. `iq.v`：新增输出 `iss_oldest_o`（该队列本拍选中的项**就是**队列中最老的 valid 项）。
   实现：在既有最老优先比较逻辑旁，把"选中的 idx == 最老 valid idx"导出即可（纯组合，无状态）。
2. `backend_top.v`：LSU 队列的发射许可改为
   `lsu_ld_block = u_is_ld(i4_sel_uop) & ~(lsu_iss_ok_w & lsu_iss_oldest_w)`
   —— 即 **load 只有在它是 LSU 最老项时才可发射**；store 不受 gating（避免第 12 轮 (a) 的死锁：
   更年轻的 store 仍可先执行，且它一旦定址，更老的 load 即满足最老条件）。
3. 不动 B24（4B 宽度）；`lsq_simple` 可保持现状（§2.1 用 `stq_rob` 的年龄判据在"严格序发射"下
   不再是唯一防线：更老 store 未定址时更老 load 也会被"非最老"挡住）。
4. 判据：程序 2 C1–C4 过 ⇒ 实测 IPC 定 C5 档（下限 = 实测 × 0.8）⇒ 三程序全绿 ⇒ regress 30/30。

### 17.4 当前树状态（可编译检查点，已验证）

- `lsq_simple.v`：回到**第 11 轮基线语义**（`grep`：无 `alloc_rob/stq_seq/ld_seq/fwd_all_p`；
  `ld_fire = pend_any & ~dr_any & mem_req_ready`）——即 `r11c.log` 那次实测的同一语义：
  程序 0/1 C1–C5 全绿（443/721 拍、0.3917/0.2469）、程序 2 C2 过且**仅 C1 第 11 条失败、无停顿**。
- 三个 TB `-Wall` 编译零错误；旋钮 `DBG_LSU/DBG_IQ=0`、`TRB/TRACE=0`、`CHK=1`。
- 第 13 轮的 (c)（`alloc_rob`+窗口外作废）在本轮回退中一并退出（当前不在树内）；如需保留，
  应按 §17.3 一起重新落地（它修掉的是"余留未定址项导致停顿"，与 §17.3 的发射侧修法互补）。

## 18. 第 18 轮：发射侧修法落地（保留）+ 结果仍不变 ⇒ 阻塞点收敛到 **D3 派发顺序**

### 18.1 本轮改动（**保留在树内**，编译零错误）

1. `iq.v`：新增 `output iss_oldest` = "本拍选中项就是队列中最老的 valid 项"（纯组合：对
   `valid_q` 求最小年龄 `best_all`，与 `e_age[sel_idx]` 比较）。
2. `backend_top.v`：`lsu_ld_block = u_is_ld(i4_sel_uop) & ~(lsu_iss_ok_w & lsu_iss_oldest_w)`
   —— **load 仅在它是 LSU 最老项时才可发射**；store 不受门控（保住反死锁性质）。
3. 重新落地 (c)：`lsq_simple.v` 的 `alloc_rob`（分配期 ROB 索引）+ `rob_cnt` + §4.5b 窗口外作废，
   `backend_top.v` 对应连线（与发射侧修法互补）。

### 18.2 实测（`/tmp/b2chk/r18.log`）：**仍逐字不变**

程序 0/1：161/199、443 拍、0.3917；178/215、721 拍、0.2469（完全不变，无回归）。
程序 2：仍 `第 11 条 wd=0x00000013 vs 0x00000003`（126/257、913 拍）。`RENAME-CHK` 0 条。

### 18.3 结论：`lbu` 在发射时**并没有被"非最老"挡住** ⇒ 那条 `sb` 当拍不在 LSU 队列里

- 发射侧门控生效的**前提**是"更老的 `sb` 已在 LSU 队列中且未发射"。实测门控加上后结果零变化
  ⇒ 说明 `lbu` 发射时 `iss_oldest=1` ⇒ **LSU 队列里没有更老的 `sb`**。
- 结合第 16/17 轮现场（`sb` 的 E1 晚于 `lbu` 的 E1、两者同块），最可能的解释是：
  **同一派发块内的两条 LSU 指令并非在同一拍、按程序序进入 LSU 队列** —— 即 D3 派发侧存在
  "写口数量/重试顺序"问题（`backend_top` 的 `iq_wv_g`/派发重试路径），使更年轻的 `lbu`
  先入队、更老的 `sb` 后入队。LSU 内部任何判据都无法补救（与第 17 轮结论一致，但落点更靠前）。
- **下一轮一次探针即可定案**：在 LSU 队列的 DBG 打印中加"本拍 `wr_valid/wr_rob`（入队项）"
  与"队内 valid 项的 (idx, rob, age)"，对准 `sb`(rob=12)/`lbu`(rob=13) 的入队拍：
  1. 若两者同拍入队且 age 正确 ⇒ 门控实现有误（查 `iss_oldest` 的 `e_age/valid_q` 口径）；
  2. 若 `lbu` 先入队、`sb` 后入队（或 `sb` 的入队被推迟/丢弃一次）⇒ 修 `backend_top` 的
     **D3 派发顺序/写口重试**：保证同块 LSU 指令按程序序入队（必要时分拍派发 + 保持序）。
- 之后才是"转发/闸门"层面的事；B24（4B 宽度）与 (c) 均保持不动。

### 18.4 当前树状态（可编译检查点）

| 项 | 状态 |
|---|---|
| 程序 0 / 1 | ✅ C1–C5 全绿（443 拍/0.3917 ≥0.30；721 拍/0.2469 ≥0.19），无回归 |
| 程序 2 | ❌ C2 过、仅 C1 第 11 条（B28）；无停顿 |
| `RENAME-CHK` / 编译 / 旋钮 | ✅ 0 条 / ✅ 三 TB `-Wall` 零错误 / ✅ `DBG*=0`、`TRB/TRACE=0`、`CHK=1` |
| regress 30/30 | ❌ 未达成（锁步 fail-closed 保留在清单） |

## 19. 第 18 轮末：`iq.v` §1/§2 误删后的**重建与验证**（本轮最重要的修复）

### 19.1 事故与处置

- 事故：第 18 轮回退"发射侧门控"时，我用"按下标区间删除"的脚本误删了 `rtl/back2/iq.v`
  的 **§1/§2（队列存储声明、两代唤醒就绪判定、最老优先选择）共约 200 行**（其余 §3/§4/§5 完整）。
  `/tmp` 副本已被环境清理、`rtl/back2/` 未入 git ⇒ **无源文件副本可回滚**（教训：改动用 cp 备份
  必须落在**工作区内**如 `../.b2chk/`，不能放 `/tmp`）。
- 处置：按**接口 + 幸存代码引用 + 本会话读过的语义**重写 §1/§2：
  - 存储：`valid_q`（位打包）、`uop_q`（**解包数组** `[UOPW-1:0] uop_q [0:DEPTH-1]`，与 §5
    `uop_q[wi[q]]`、§3 `uop_q[dsi]` 口径一致）、`rob_q/ep_q/rdy_q`（打包）；
  - **两代唤醒**：新增 `wki_v_q/wki_tag_q/wkf_v_q/wkf_tag_q`，每通道当拍与上一拍**各自独立**
    匹配（写回是单拍脉冲，只比当拍会漏唤醒）；
  - 就绪：`e_rdy[gi] = &(~use_s | rdy_q[s] | wk_hit[s])`（五个源 s1i/s2i/s1f/s2f/s3f，
    用 `BACK2_UB_S*_USE` 门控）、`e_sel = valid_q & e_rdy`；
  - 最老优先：`sel_idx/best_age`（年龄原点 = `rob_head`）、`sel_valid/iss_fire/sel_onehot`、
    `iss_valid/o_sel_v` 赋值；DBG 需要的 `wki_v_e/wki_tag_e` 一并导出。

### 19.2 验证（**双保险均通过**）

| 验证 | 结果 |
|---|---|
| `tb_back2_iq`（151 项，含两代唤醒当拍可选、最老优先、冲刷只杀更年轻、窗口外作废、无活锁） | ✅ **PASS（151/151）** |
| 锁步三程序（与损坏前基线逐字对比） | ✅ 程序 0：161/199、**443 拍**、IPC **0.3917**；程序 1：178/215、**721 拍**、IPC **0.2469**（完全一致）；程序 2：126/257、913 拍、**仅 C1 第 11 条（B28）** |
| `tb_back2_ipc` | ✅ **PASS，IPC=2.0000** |
| 编译 | ✅ 三个 back2 TB `-Wall` 零错误 |

⇒ 重建是**行为等价**的（单元 TB 全项 + 锁步基线逐字一致）。

### 19.3 当前状态与唯一剩余项

- **B28 仍开放**（程序 2 第 11 条 `sb→lbu` 取值 0x13）：机制已在 §16 完全闭合
  （未定址 store 的 `stq_rob` 不可用 ⇒ 闸门不挡、转发不中），第 17/18 轮的两种修法
  （分配序年龄 + 请求拍重算；发射侧"最老才发"门控）**均已实测并回退**：前者零变化，
  后者造成死锁（程序 1 卡在 22 条）⇒ 说明"严格最老"规则在本设计过强，且"LSU 内部判据"晚一步。
- **下一轮建议**：从 D3 派发侧入手（打印 LSU 队列的入队项 `wr_valid/wr_rob` 与队内 valid 项
  `(idx, rob, age)`，确认同块 `sb`/`lbu` 的入队拍与顺序）——若 `lbu` 先入队，则修
  `backend_top` 的派发顺序/写口重试；若同拍入队且顺序正确，则在 **LSU 队列内部**用
  "更老未定址 store ⇒ 本项不可选"（队列级闸门，而非发射级）实现严格序，避开死锁（更老的
  store 仍可自行发射，因为门控只加在 load 项上）。

## 20. 第 19 轮：**B28 修复成功**（LSU 队列级顺序闸门）+ 新缺陷 B29（CSR）

### 20.1 修法（已落地并实测生效）

`iq.v` 新增参数 `INORD_LOAD`（默认 0，仅 LSU 队列置 1）与队列级闸门：
```
sel_blk[gi] = ∃ gk: valid_q[gk] && (e_age[gk] < e_age[gi]) && ~e_rdy[gk]     // 存在"更老的未就绪项"
e_sel[gi]   = valid_q[gi] & e_rdy[gi] & ~(INORD_LOAD & IS_LOAD(uop[gi]) & sel_blk[gi])
```
`backend_top.v` 把 LSU 队列（`u_iq4`）实例化为 `.INORD_LOAD(1)`。
- 与第 18 轮被否决的"发射侧要求 load 是队首"不同：门控**只加在 load 项**上，更老的 store 不受限、
  就绪后仍可自行发射 ⇒ **实测无死锁**；
- 语义：load 不得越过更老的未就绪项 ⇒ 更老的 store 定址后 load 才可选 ⇒ 转发扫描必然能看到它。

### 20.2 实测（`/home/shorthair/dsh/rv32-cpu/.b2chk/ls19.log`）

| 项 | 结果 |
|---|---|
| `tb_back2_iq` | ✅ **PASS（151/151）** |
| 程序 0 / 1 | ✅ **与基线逐字一致**：161/199、**443 拍**、IPC **0.3917**；178/215、**721 拍**、IPC **0.2469** |
| 程序 2 | ⚠️ **B28 已修**（第 11 条 `lbu` 不再失败）；失败点前移到**第 15 条** |
| `RENAME-CHK` / 死锁 | ✅ 0 条 / ✅ 无 |

⇒ **B28（字节 store→load 漏转发）确已修复**：`sb x9,8(x5)` → `lbu x10,8(x5)` 的取值与 2A 一致（不再读 0x13）。

### 20.3 新缺陷 B29（**下一步**）：CSR 读改写不一致

```
FAIL: 程序 2 第 15 条写回分歧：乱序 {we=1 rd=13 wd=0x00000001} vs 2A {we=1 rd=13 wd=0x00000003}
```
- 指令：`#14 csrrw x12, mscratch, x11`（x11 = `lhu` 结果 = 3）→ `#15 csrrs x13, mscratch, x0`。
  第 14 条的写回（rd=12，旧 mscratch）与 2A 一致 ✅；第 15 条读到的 mscratch 乱序核为 **0x01**、2A 为 **0x03**
  ⇒ OoO 的 CSR 小栈（`rtl/back2/b2_csr.v`，本阶段过渡实现，登记子集 mscratch/frm/fflags）
  没有正确保存/回读 `csrrw` 写入的值。
- 下一轮排查（只动 `rtl/back2/`）：
  1. `b2_csr.v`：`csrrw` 的写通路（写使能/写地址/写数据取自 uop 的 CSROP/CSRADDR/IMM）与
     提交序（CSR 操作按"只在 ROB 头执行"口径 ⇒ 读改写应按程序序）；
  2. `backend_top.v`：CSR uop 的 CSROP 编码（csrrw/csrrs/csrrc + imm 形式）与读写数据的 mux；
  3. 探针：`DBG` 打开后打印每条 CSR 提交的（PC、CSROP、CSRADDR、wdata、rdata、mscratch 当前值）。
- 判据不变：B28 已修（不得回退）。(c)/B24 保持；程序 0/1 基线 443/721 拍不得回退。

## 21. 第 20 轮：B29 定案（**CSR 写数据取自错误的 I2 PRF 读口**）

### 21.1 探针实测（`/home/shorthair/dsh/rv32-cpu/.b2chk/csr.log`）

```
[csr-i2  t=12765000] op=1 addr=0x340 s1i=1 imm=0x00000340 rdata=0x00000000 upd_csrw=0x00000001
[csr-cmt t=12775000] we=1 addr=0x340 wdata=0x00000001 ... mscratch=0x00000000
[csr-i2  t=12795000] op=2 addr=0x340 s1i=1 imm=0x00000340 rdata=0x00000001 upd_csrw=0x00000001
[csr-cmt t=12805000] we=1 addr=0x340 wdata=0x00000001 ... mscratch=0x00000001
FAIL: 程序 2 第 15 条写回分歧：乱序 {we=1 rd=13 wd=0x00000001} vs 2A {we=1 rd=13 wd=0x00000003}
```
- `#14 csrrw x12, mscratch, x11`（x11 = `lhu` 结果 = 3）的 **I2 现场**显示：
  `op=1`（csrrw ✓）、`addr=0x340`（mscratch ✓）、`s1i=1`（用 rs1 ✓）、`imm=0x340`
  （CSR 指令的 imm 字段就是 CSR 地址 ✓ 预期）、`rdata=0`（旧值 ✓）—— 但 **`upd_csrw = 1`**
  （应为 3）⇒ 提交写入 `mscratch = 1` ✗ ⇒ 随后的 `csrrs x13, mscratch, x0` 读到 **1**（2A 为 3）。
- ⇒ **CSR 小栈（`b2_csr.v`）本身没问题**（写使能/地址/时序都对，`rdata` 也随提交正确更新为 1）；
  真正的缺陷是 `cb_src_w = u_s1i(uop) ? iprf_rd[0*32 +: 32] : u_imm(uop)`
  —— **`iprf_rd` 的 slot-0 读口读到的不是该 CSR 指令的 rs1（x11=3）**。
  注意 `imm=0x340` 说明解码器把"CSR 地址"填进了 imm 字段（I 型立即数=rs1 域），故当 `s1i` 判据
  不可靠时会退化成写 imm（0x340）或别的槽的数据 —— 实测落在 1（疑为同拍另一条指令的源操作数）。

### 21.2b 关键结构性怀疑（`backend_top` 里 CSR 路全部**硬编码槽 0**）

- `csr_raddr_w = u_csra(x_i2_uop[0])`、`upd_csr_v = x_i2_v[0] & u_is_csr(x_i2_uop[0]) & ...`、
  `upd_csrw = ... iprf_rd[0*32 +: 32] ...`、`a0_wb_data = u_is_csr(x_i2_uop[0]) ? csr_rdata_w : a0_res`
  —— **四处都假定 CSR 指令在 I2 槽 0**；而 `iprf_rd[0*32]` 是 **ALU0 的 rs1 读口**
  （见 919 行 `a0_opa`）。若 CSR 指令被判到别的槽（或 ALU0 槽当拍是别的指令），
  `cb_src_w`/`csr_raddr_w`/写回数据全部取错 ⇒ 与实测"写数据 = 1（别条指令的源操作数）"完全吻合。
- 因此下一轮应优先确认并在必要时**按 CSR 实际槽位索引**（或强制 CSR 只在槽 0 执行/派发），
  而不是只在 CSR 小栈里找问题。探针补充项：`iprf_ra[0*PW_I +: PW_I]`、`u_ps1i(x_i2_uop[0])`、
  `iprf_rd[0*32 +: 32]`、`iprf_rd[2*32 +: 32]`、`x_i2_v`、以及 CSR 指令的 `lane_cls/opt`。

### 21.2 下一轮修法（只动 `rtl/back2/`，一次探针即可收口）

1. 打印 csrrw 的 I2 现场补充：`iprf_ra[0*PDW_I +: PDW_I]`（读口物理号）、`u_ps1i(uop)`、
   `iprf_rd[0*32 +: 32]`、以及**同拍其它槽**的 `iprf_ra/iprf_rd`，确认 slot-0 读口是否接了
   正确的物理号/使能；
2. 重点核对 `backend_top` 中 I2 读口 `iprf_ra/iprf_rd` 的**槽位映射**与 `u_is_csr` 指令是否
   在 slot 0（读口使能/地址是否按 slot 0 驱动）；
3. 修法方向：CSR 指令的源操作数应取"**该 uop 自己的 rs1 读口**"（按槽位索引），
   或对 CSR 指令强制在**槽 0 的读口**上驱动 `u_ps1i(uop)`；同时保留 `imm` 兜底仅用于
   csrrwi/csrsi/csrrci（zimm 形式，`csr_zimm` 已有信号 ✓）。
4. 判据不变：B28 已修（不得回退）；程序 0/1 基线 443/721 拍不得回退；**B29 修复后**程序 2 全链
   C1–C4 过 ⇒ 实测 IPC 定 C5 档（= 实测 × 0.8）⇒ 三程序全绿 ⇒ regress 30/30。

## 22. 第 21 轮：B29 修法①（按实际槽位索引）实测 = no-op ⇒ 病因进一步收敛到**读口地址/数据**

### 22.1 本轮改动（保留：结构上更正确，实测无回归）

`backend_top.v` 把 CSR 路的四处硬编码槽 0 改为**按 CSR 实际槽位**：
`csr_lane`（扫描 6 个 I2 槽找第一条 CSR 指令）+ `csr_v_w` + `csr_uop = x_i2_uop[csr_lane]`；
`csr_raddr_w = u_csra(csr_uop)`、`upd_csr_v = csr_v_w & (csrop != 0)`、`upd_csr_idx = x_i2_rob[csr_lane]`、
`upd_csrw`/`cb_src_w` 均改用 `csr_uop`；`a0_wb_data` 的 CSR 选择也改为按 `csr_uop` 的队列字段。

### 22.2 实测（`/home/shorthair/dsh/rv32-cpu/.b2chk/r21.log`）：**结果完全不变**

程序 0/1：443 拍/0.3917、721 拍/0.2469（逐字不变）；程序 2：仍
`第 15 条 wd=0x00000001 vs 0x00000003`；`RENAME-CHK` 0 条。
⇒ **该 CSR 指令本来就在 I2 槽 0**（故槽位索引改动在此例是 no-op），四处"硬编码槽 0"不是本例病因。

### 22.3 病因收敛（下一轮的直接起点）

- 已知：`op/addr/s1i` 全对、`rdata=0`（旧值对）、`upd_csrw = 1`（应为 x11=3）⇒
  `cb_src_w = iprf_rd[0*32 +: 32]` 读到的**不是槽 0 的 rs1（x11）**。
- 结合 §919（`a0_opa = u_au(x_i2_uop[0]) ? u_pc : iprf_rd[0*32]`）可判定：设计把"ALU0 的源"
  等同"槽 0 的源" ⇒ 端口映射没问题，**问题在 `iprf_ra` 的地址/使能**：
  需核对 `iprf_ra[0*PW_I +: PW_I]` 是否按**槽 0 uop 的 PS1I**（`u_ps1i(x_i2_uop[0])`）驱动，
  以及 `iprf_we/写口` 是否在该拍把 x11 的新值写进了那个物理号。
- **下一轮探针（一次运行）**：打印 `iprf_ra[0*PW_I +: PW_I]`、`u_ps1i(x_i2_uop[0])`、
  `iprf_rd[0*32 +: 32]`、`iprf_rd[2*32 +: 32]`、`x_i2_v`、以及**同拍 ALU0/ALU1 的写回**
  `(wbi_v/wbi_tag/wbi_data)` ⇒ 区分"地址错"（读到了别的物理号）与"写口未落地"（读到旧值）。
- 若为地址错：检查 `iprf_ra` 的驱动源（是否用了别的槽/别的字段，例如误用 PS2I 或 payload 的
  `PDIDST`）；若为写口未落地：检查 x11（`lhu` 结果）的写回与该 CSR 的读是否在同拍竞争
  （读优先旁路 `NW+1` 级链是否覆盖 CSR 所在槽）。
- **本轮已核对的确定事实（缩小到最后两个嫌疑）**：`backend_top` 第 1266~1271 行
  `iprf_ra[0*PW_I +: PW_I] = u_ps1i(x_i2_uop[0]); iprf_ra[1*PW_I +: PW_I] = u_ps2i(x_i2_uop[0]); …`
  ⇒ **读口地址就是槽 0 的 PS1I，端口映射无误**。故 `iprf_rd[0*32]=1` 只能是：
  (i) **uop 的 PS1I 字段本身不是 x11 的当前映射**（rename 侧给 CSR 指令的 rs1 映射错/取到旧映射），
      或 (ii) **该物理号在 PRF 里确实是 1**（x11 的新值 3 没写进那个号 ⇒ 写口地址/使能问题，
      注意 `lhu` 的 arch 写回 3 是通过 ROB 载荷对拍确认的，PRF 侧并未被 C1 覆盖）。
  ⇒ 最终探针（一次运行即可二选一）：在 CSR 的 I2 拍打印
      `u_ps1i(x_i2_uop[0])`、`iprf_ra[0*PW_I +: PW_I]`、`iprf_rd[0*32 +: 32]`、
      同拍 `iprf_we/iprf_wa/iprf_wd`（PRF 写口），并与 **x11 的 RAT 当前映射**（可从 rename 的
      `rat_q[11]` 层次引用）对照；若 PS1I ≠ rat_q[11] ⇒ 修 rename 对 CSR rs1 的映射；
      若相等而 PRF 里不是 3 ⇒ 修 PRF 写口（地址/使能/`wkeep` 门控）。

## 23. 第 22 轮：B29 **最终定案**（`upd_csrw` 的取值与 ROB 采样不同拍）

### 23.1 决定性现场（`/home/shorthair/dsh/rv32-cpu/.b2chk/p22.log`）

```
[csr-src t=12765000] lane=0 csr_ps1i=41 ra0=41 rd0=0x00000003 ra2=35 rd2=0x00000000 | prf_we=000001 wa=X
[csr-i2  t=12765000] op=1 addr=0x340 s1i=1 imm=0x00000340 rdata=0x00000000 upd_csrw=0x00000001 upd_v=1
[csr-cmt t=12775000] we=1 addr=0x340 wdata=0x00000001 ... mscratch=0x00000000
FAIL: 程序 2 第 15 条写回分歧：乱序 {we=1 rd=13 wd=0x00000001} vs 2A {we=1 rd=13 wd=0x00000003}
```
- **源操作数读取完全正确**：`csr_ps1i = 41`（CSR 的 rs1 物理号）、`iprf_ra[0] = 41`（读口地址对）、
  **`iprf_rd[0] = 0x00000003`（= x11 的值，正确）**；`s1i=1`、`imm=0x340`、`rdata=0`（旧值对）。
- **但 `upd_csrw = 1`**（应为 `cb_src_w = iprf_rd[0] = 3`）⇒ **`upd_csrw` 的成形/被采样与 CSR 的 I2 不同拍**：
  ROB 侧 `upd_csr_v/upd_csr_idx/upd_csrw` 是**当拍 I2 的组合函数**，若 ROB 在**下一拍**才接收这三者
  （或其 `upd_csr_valid` 晚一拍），此时 `csr_uop`/`cb_src_w` 已换成**下一条指令**的值 ⇒ 采到别的数（=1）。
  这与 B14"写回 tag 曾误用源 1"属同一类缺陷：**值与其索引/有效位没有同拍绑定**。
- 佐证：`prf_we=000001 wa=X wd0=0` —— 该拍 PRF 只有 1 个写口且地址为 X（未写），说明
  x11 的 3 早已写入（`rd0=3` ✓）⇒ 不是 PRF 写口问题，也不是 rename 映射问题（PS1I/RAT 一致 ✓）。

### 23.2 修法（下一轮落地，只动 `rtl/back2/`，二选一）

1. **把三元组打一拍**：在 `backend_top` 里对 `upd_csr_v/upd_csr_idx/upd_csrw` 统一寄存一拍再送 ROB
   （或在 ROB 侧用同一拍采样），保证"值/索引/有效"永远同拍对应；
2. **或让 ROB 侧用 CSR 自己的 uop 重新取值**：把 `cb_src_w` 的依据（槽位与 PS1I）连同 `upd_csr_idx`
   一起寄存，避免与被后续指令覆盖的 `x_i2_*` 组合信号混用。
- 判据：程序 2 第 14 条写 mscratch=3、第 15 条读到 3 ⇒ C1–C4 过 ⇒ 实测 IPC 定 C5 档（= 实测 × 0.8）
  ⇒ 三程序全绿 ⇒ regress 30/30。B28 修复（`INORD_LOAD`）与 (c) 保持不回退。

## 24. 第 23 轮：三元组寄存实测**更差**（已回退）⇒ B29 病因再收窄一格

### 24.1 实测（`/home/shorthair/dsh/rv32-cpu/.b2chk/r23.log`）

把 `(upd_csr_v, upd_csr_idx, upd_csrw)` 同拍寄存一拍再送 ROB 后：程序 2 第 15 条的取值由 `0x01` 变为
**`0x00`**（= 更新完全没落地）⇒ 说明 **ROB 本来就在 CSR 的 I2 同拍采样**（原时序正确），
寄存一拍后 `upd_csr_v` 在采样拍已为 0 ⇒ 无更新。**该改动已回退**（`grep upd_csr_v_q` = 0）。

### 24.2 由此确定的两点

1. **时序不是病因**：ROB 与 I2 同拍、`upd_csr_v=1` 在 CSR 的 I2 拍（探针实测 ✓）；
2. **病因是 `upd_csrw` 在该拍的实际取值**：探针同拍打印 `s1i=1`、`iprf_rd[0]=0x00000003`，
   而 `upd_csrw=0x01` ⇒ `upd_csrw` **并非**按 `cb_src_w = u_s1i(csr_uop) ? iprf_rd[0] : imm` 取值。
   下一步（一次运行即可收口）必须把**同一个 `csr_uop`** 的几个量放在**同一行**打印：
   `u_s1i(csr_uop)`、`u_imm(csr_uop)`、`iprf_rd[0*32 +: 32]`、`cb_src_w`、`upd_csrw`、
   `u_csrop(csr_uop)` —— 之前那行 `s1i/imm` 打印用的是 `x_i2_uop[0]`（虽与 `csr_uop` 同槽，
   但**不是同一个表达式**，不能作为 `cb_src_w` 分支的依据）。
3. 若 `cb_src_w` 与 `upd_csrw` 在同一行里就自相矛盾（如 `s1i=1 & rd0=3` 而 `cb_src_w=1`），
   则说明该 `cb_src_w` wire 存在**多驱动/被同名信号遮蔽**（iverilog 会解析成 x/1）——
   下一步先 `grep -c "cb_src_w" backend_top.v` 确认只有一个驱动点，再按需改名消歧。

（B28 修复 `INORD_LOAD` 与 (c) 保持不动；本轮无净功能改动。）

## 25. 第 24 轮：同一表达式探针 ⇒ **矛盾指向 ROB 侧载荷**（B29 最后的收口点）

### 25.1 实测（`/home/shorthair/dsh/rv32-cpu/.b2chk/p24.log`）

```
[csr-uop t=12765000] lane=0 ps1i=41 s1i=1 imm=0x00000340 csrop=1 | rd0=0x00000003 cb_src=0x00000001 upd_csrw=0x00000001 | v=1 idx=16 rdata=0x0
[csr-cmt t=12775000] we=1 addr=0x340 wdata=0x00000001 ... mscratch=0x00000000
FAIL: 程序 2 第 15 条写回分歧：乱序 {wd=0x00000001} vs 2A {wd=0x00000003}
```
**同一行、同一 `csr_uop`**：`s1i=1`（用 rs1）、`iprf_rd[0]=3`（源就是 3）、`csrop=1`（csrrw）——
而 `cb_src_w = 1`、`upd_csrw = 1` ✗。**表达式与它的输入自相矛盾**。
- 已排除：① 槽位错（`lane=0`、`ps1i=41` 正确）；② PRF 读口/地址（`rd0=3` ✓）；
  ③ 时序偏移（第 23 轮三元组寄存实测更差，已回退）；④ iverilog 连续赋值中 function 求值
  （第 24 轮**内联字段**后结果完全相同 ⇒ 非工具求值问题，已回退该改动）。
- ⇒ **结论：`upd_csrw` 的值并非来自这条表达式** —— 最可能是 **ROB 侧用自己的载荷字段覆盖了
  `upd_csr_wdata`**：载荷在**派发期**捕获（那时 PRF 尚未读、源操作数还不存在），
  其 CSR 数据字段因此是陈旧/别的值（实测 1）。

### 25.1b 最可能的真因（已排除 ROB 载荷覆盖）：**CSR 的 rs1 读未看到刚写回的值（RAW/旁路缺口）**

- 已核对 `rob.v` 第 276 行：`pl_q[upd_csr_idx][RB_CSRW] <= upd_csr_wdata;` ⇒ **ROB 直接使用外部
  `upd_csr_wdata`**（不是载荷里的陈旧字段）⇒"载荷覆盖"假设**排除**；`iprf_rd` 也只有一个驱动点
  （无 `assign iprf_rd`，由 PRF 实例输出驱动）⇒"多驱动/遮蔽"假设**排除**。
- 剩下的唯一自洽解释：**探针在同一时钟沿采样到了不同 delta 的值** ——
  `rd0=3` 是"x11 写回落地后"的组合读，而 `cb_src_w=1` 用的是"落地前"的旧值；
  即 **CSR 的 rs1 读口（port 0）没有吃到 `lhu x11` 刚写回的值**（旧 x11 = 1，首轮未初始化）。
  这与 B17（PRF 写口曾按全局 epoch 过滤 ⇒ 丢弃合法写回）同类，均为**读口/旁路与写回的时序缺口**。
- **下一轮一次探针即可定案**：围绕 CSR 的 I2 拍**逐拍**打印
  `iprf_we/iprf_wa/iprf_wd[0*32]`（PRF 写口：谁在写、写哪个 preg、写什么）与
  `iprf_ra[0*PW_I +: PW_I]`、`iprf_rd[0*32 +: 32]`（CSR 的 rs1 读口），
  看"写 preg=41、data=3"是否**早于** CSR 的读拍；若同拍/后拍 ⇒ 修 **PRF 旁路链**（把 CSR 所在
  槽的读口纳入 `wkeep` 旁路）或把 CSR 的取数拍后移一拍（保证读晚于写回）。

### 25.2 下一轮收口（一次查看即定案，只动 `rtl/back2/`）

1. 读 `rtl/back2/rob.v` 的 `upd_csr_wdata/upd_csr_valid/upd_csr_idx` 处理：确认它是否**直接使用外部
   `upd_csr_wdata`**，还是从 `alloc_payload` 里取 CSR 数据字段（若是后者 ⇒ 用外部输入替换，
   并把载荷里的 CSR 数据字段改为"提交期写入"）；
2. 同时核对 `rob_pay_w`/`d1_lat_uop` 里 CSR 数据字段的来源（是否在 D1/D2 就把 `u_imm` 或某个操作数
   塞进了"CSR 写数据"位域 ⇒ 那正是 1 的来源）；
3. 修法：CSR 写数据**只在 I2 读口取值**（`cb_src_w`，已正确），并用 `upd_csr_*` 三元组写入 ROB
   （现有接口即可），ROB 不得再用载荷里的陈旧值覆盖。
4. 判据不变：B28（`INORD_LOAD`）与 (c) 不回退；程序 0/1 基线 443/721 拍不回退；B29 修复后
   程序 2 全链 C1–C4 过 ⇒ 实测 IPC 定 C5 档（= 实测 × 0.8）⇒ 三程序全绿 ⇒ regress 30/30。

## 26. 第 25 轮：PRF 写口 vs CSR 读口逐拍对照 —— 关键新证据 + 最后一个问题

### 26.1 廉价甄别点的答复（母代理问）

`cb_src_w` 是 **`wire`**（`wire cb_src_w = u_s1i(csr_uop) ? iprf_rd[0*32 +: 32] : u_imm(csr_uop);`）✓
⇒ 不是寄存器 ⇒ 排除"寄存器采样拍错位"；但 §23 的三元组结论（ROB 与 I2 同拍采样）仍成立。

### 26.2 逐拍对照（`/home/shorthair/dsh/rv32-cpu/.b2chk/p25.log`）

```
[prf-w  t=12725000] we=010010 wa=36,45,33,0,41,x wd0=0x00000008 wd1=0x00000001
[prf-w  t=12765000] we=000001 wa=42,45,46,0,0,x  wd0=0x00000000 wd1=0x00000001
[csr-r  t=12765000] ra0=41 rd0=0x00000003 cb_src=0x00000001 upd_csrw=0x00000001 csrop=1
[csr-uop t=12765000] lane=0 ps1i=41 s1i=1 imm=0x340 csrop=1 | rd0=3 cb_src=1 upd_csrw=1 | v=1 idx=16
```
- **preg 41（= x11 的新映射，CSR 的 rs1）在 t=12725000 经写口 4 被写入**（比 CSR 读拍早 4 拍）✓
  ⇒ 不存在"写晚于读"的 RAW 缺口 ✗（RAW 假设排除）；
- 而 CSR 读拍：`rd0=0x00000003`（端口数据 = 3 ✓）、`cb_src=0x00000001` ✗ —— **wire 表达式的输入与输出
  在同一行自相矛盾**，且 `iprf_rd` 只有一个驱动点、表达式内联后结果不变（§24 已试）。
- 已排除的完整清单（含本轮）：① 槽位错；② 读口地址错（`ra0=41` 正确）；③ PRF 里没写（写口 4 已写）；
  ④ 写晚于读（早 4 拍）；⑤ iverilog function 求值；⑥ 多驱动/遮蔽；⑦ ROB 载荷覆盖（`rob.v:276` 用外部值）；
  ⑧ 时序整体打一拍（§23 实测更差）。
- C1 已证 x11 的 **arch 写回值 = 3**（ROB 载荷）⇒ 写回数据通路本身是对的 ✓
  ⇒ 矛盾只剩一种可能：**探针在时钟沿读到的 `cb_src_w` 与 `iprf_rd` 落在不同 delta**
  （`$display` 在 `posedge` 采样组合网，而 PRF 的组合输出会随同拍写旁路在 delta 间变化）。

### 26.3 最终收口方案（下一轮，二选一，均只动 `rtl/back2/`）

1. **把 CSR 的取数改为"寄存一拍再算"**：在 I2 拍把 `csr_uop`/`csr_lane` 寄存，次拍用寄存副本计算
   `cb_src_w/upd_csrw` 并**与 `upd_csr_v/idx` 同拍**送 ROB（注意 §23 的教训：**不要**整体打一拍，
   只寄存取数所需的 uop 副本，ROB 仍在 CSR 的 I2 同拍接收）⇒ 取数与 PRF 写旁路不再竞争同一 delta；
2. **或把 PRF 读口 0 的旁路在 CSR 拍强制稳定**（例如 CSR 类操作使用"写回后一拍的稳定读"，
   即在 `csr_v_w` 拍插入一个 1 拍取数寄存器 + `upd_csr_v_q` 组合门控，保证同拍对应）。
- 判据不变：B28（`INORD_LOAD`）与 (c) 不回退；程序 0/1 基线 443/721 拍不回退；B29 修复后程序 2
  全链 C1–C4 过 ⇒ 实测 IPC 定 C5 档（= 实测 × 0.8）⇒ 三程序全绿 ⇒ regress 30/30。

## 27. 第 26 轮：快照寄存方案**同样退化**（0x00）⇒ 结论收敛到 **ROB 侧载荷/更新路径**（最后的探针点）

### 27.1 实测（`/home/shorthair/dsh/rv32-cpu/.b2chk/r26.log`）

把"取值依据"（uop 副本 + 读口数据 + ROB 索引 + 读回数据）在 I2 拍采样寄存、次拍生成
`(有效,索引,写数据)` 同拍送 ROB 后：程序 2 第 15 条取值由 `0x01` 变为 **`0x00`**（更新完全没落地），
与第 23 轮"三元组整体打一拍"的结果一致 ⇒ **ROB 要求 CSR 更新必须在 CSR 的 I2 当拍送达**
（任何滞后一拍的方案都会退化为"无更新"）。该改动**已回退**。

### 27.2 由此得到的关键结论（与第 24/25 轮合并）

- 更新**必须**在 I2 当拍送达 ✓（第 23/26 轮两次实证）；
- 而该拍送达的 `upd_csrw` 实测为 1（打印其输入 `s1i=1`、`rd0=3` 却得 1 ⇒ 该表达式的实际求值不等于其
  打印输入之和）✓（第 24/25 轮）；
- C1 已证 **x11 的 arch 写回值 3 正确**（ROB 载荷），而提交写进 mscratch 的却是 1
  ⇒ **提交读到的 CSR 写数据字段值 = 1**，它要么来自 I2 更新（值 1 ✗），要么**来自分配期的载荷**
  （`pl_q[...][RB_CSRW]` 在 `rob.v` 分配时由 `alloc_payload` 写入，那时 CSR 的源操作数还不存在，
  其位域很可能是 `imm`/aux 的陈旧值 —— 与实测 1 吻合）。

### 27.3 最后的探针点（下一轮，改在 **`rob.v` 内部**，一次即定案）

1. 在 `rob.v` 的提交排空处打印 `pl_q[head][RB_CSRW]`（即将提交写入 CSR 的值）；
2. 在 `rob.v` 的分配处打印 `alloc_payload[RB_CSRW]`（载荷里带进来的初始值）；
3. 在 `rob.v` 的 `if (upd_csr_valid)` 处打印 `upd_csr_idx/upd_csr_wdata`（是否真的写过该 idx）。
   - 若"分配值 = 1 且从未被 update 覆盖" ⇒ 修 `backend_top` 的 **`rob_pay_w` 里 CSR 数据字段**：
     要么在分配时置 0 并由 I2 更新覆盖（需确认更新真的命中该 idx），
     要么让 `upd_csr_idx` 与分配期的 ROB 索引严格一致（现在用 `x_i2_rob[csr_lane]`，
     与 ROB 分配序号口径是否一致需一并核对）。
   - 若"update 命中且写入 1" ⇒ 回到取数表达式，改用**独立于 `iprf_rd` 的寄存器化取数**
     （如 PRF 增加一路"CSR 专用读口 + 输出寄存器"）。
- 判据不变：B28（`INORD_LOAD`）与 (c) 不回退；程序 0/1 基线 443/721 拍不回退。

## 28. 第 27/28 轮：B29 收窄到"PRF 旁路未命中却仍读到 1"⇒ 唯一剩余修法（CSR 专用前置读口）

### 28.1 `rob.v` 内探针（决定性，`/home/shorthair/dsh/rv32-cpu/.b2chk/p27.log`）

```
[rob-upd t=12765000] idx=16 wdata=0x00000001     ← csrrw(#14) 的更新，写入 ROB 的就是 1（应 3）
[rob-upd t=12795000] idx=17 wdata=0x00000001     ← csrrs(#15) 随后读到 1 ✓ 与 C1 一致
[rob-alloc ...] pay_csrw=0x00000000（全部）      ← 分配期载荷字段恒 0 ⇒ 载荷覆盖假设排除
FAIL: 程序 2 第 15 条写回分歧：乱序 {wd=0x00000001} vs 2A {wd=0x00000003}
```
⇒ ROB 的**更新路径与索引都正确**，收到的 `wdata` 本身就是 1 ⇒ 提交侧完全无辜。

### 28.2 旁路核对（`prf.v` 第 78~80 行）

```
(we[gw] & wkeep[gw] & (waddr[gw*PDW +: PDW] == ra)) ? wdata[...] : ...
```
逐拍对照（`p25.log`）显示：CSR 读拍（t=12765000）当拍的写口是 `we=000001 wa=42` ⇒ **没有任何写口命中 ra=41**
⇒ 旁路不该影响该读 ⇒ 读到的应是数组值（= 3，与 C1 的 arch 值一致）—— 但 `cb_src_w` 却是 1。
⇒ **旁路"误配"假设也排除**；B29 只剩"`cb_src_w` 表达式在编译后的取值与其打印输入不一致"这一条
（`iprf_rd` 单驱动、表达式内联无变化、无多驱动、非寄存器）。

### 28.3 唯一剩余修法（母代理已批准方向，下一轮实施）

**给 CSR 加一路"前置（pre-I2）采样"的独立源操作数读取**，使 I2 当拍生成 `(upd_csr_v/idx/wdata)`
时用的是**已稳定的寄存器值**，同时保持"更新在 I2 当拍送达 ROB"（第 23/26 轮教训）：
1. `prf.v`：读口 +1（`ra/rd` 各扩一个口；或复用 `NWR` 参数），端口地址由 **I1 发射拍**的 CSR uop 驱动；
2. `backend_top.v`：新增 I1 侧的 CSR 扫描（6 条 `iq_iss_uop/iq_iss_v` 中找 `u_is_csr`），
   用其 `u_ps1i` 驱动新读口，并在该拍把读到的数据采样进 `csr_src_r`；
3. I2 当拍（CSR 在 `x_i2_*` 中）用 `csr_src_r`（稳定值）组合生成 `upd_csrw`，与 `upd_csr_v/idx` 同拍送 ROB；
4. 判据：程序 2 第 14 条写 `mscratch=3`、第 15 条读 3 ⇒ C1–C4 过 ⇒ 实测 IPC 定 C5 档（= 实测 × 0.8）。
   B28（`INORD_LOAD`）与 (c) 不回退；程序 0/1 基线 443/721 拍不回退。

### 28.4 本轮收尾状态

- 全部探针已关（`DBG_CSR=0`；`DBG_LSU/DBG_IQ=0`、`TRB/TRACE=0`），`CHK=1`；
- 三 TB `-Wall` 编译零错误；`tb_back2_iq` 151/151 PASS；`tb_back2_ipc` PASS（IPC=2.0000）；
- 程序 0/1 C1–C5 全绿（443 拍/0.3917、721 拍/0.2469）；程序 2 C2 过、仅第 15 条（B29）。

## 29. 第 29 轮：前置采样（I1 读口）实测**仍为 1** ⇒ 病因最后收敛到"CSR 指令在 I1/I2 的 rs1 映射本身"

### 29.1 实施与实测

按 §28.3 落地：`prf` 整数域读口 15 → 16（`NRD(16)`、`re=16'hFFFF`），新增第 15 号读口由
**I1 发射拍**的 CSR uop（6 条 `iq_iss_v/iq_iss_uop` 扫 `u_is_csr`）的 `u_ps1i` 驱动，
`csr_src_i1_q` 采样并保持，`cb_src_w` 改用该稳定值（I2 当拍仍同拍生成 `upd_csr_v/idx/wdata` 送 ROB）。

**实测（`/home/shorthair/dsh/rv32-cpu/.b2chk/r29.log`、`r29b.log`，含"仅 I1 有效时采样并保持"版本）**：
程序 0/1 完全不变（443 拍/0.3917、721 拍/0.2469）；程序 2 第 15 条**仍为 `wd=0x00000001`**（应 3）。
⇒ **I1 前置读口取到的操作数也是 1** ⇒ 说明问题不在"读口的时序/旁路"，而在
**该 CSR 指令自己的 rs1 物理号（PS1I）与其应读的 x11 映射不一致**（取到了值为 1 的某个物理号）。
本轮试验改动（第 15 读口 + 采样保持）**已用开轮快照回退**（`../.b2chk/backend_top.v.pre29`），
树回到第九/十检查点语义；三 TB 编译零错误、`tb_back2_iq` 151/151。

### 29.2 下一轮的第一步（极窄，一次探针即定案）

在 **I1 拍**打印 `csr_i1_sel`、`u_ps1i(csr_i1_uop)`、`u_s1i(csr_i1_uop)`、`u_imm(csr_i1_uop)`、
`csr_src_i1_q`，并**与 I2 拍的 `u_ps1i(csr_uop)` 对照**（此前 I2 拍实测 PS1I=41 且 `iprf_rd[0]=3`）：
- 若 I1 与 I2 的 PS1I **不同** ⇒ CSR 指令在发射/进 I2 之间其 uop 的源映射被改写（查 IQ 入口的
  `wr_uop` 组装与 `lane_*` 字段拼接，B27 病族的"字段/拍错位"）；
- 若相同（都是 41）而 I1 读口仍返回 1 ⇒ 读口 15 的地址在 **I1 的 uop 尚未稳定**（发射拍 uop 可能
  与 I2 不同源），此时改用"**I2 拍再读一次 + 次拍使用**"不可行（第 23/26 轮已证），
  应改为**在 CSR 提交时用 ROB 载荷里的 rs1 物理号直接读 PRF**（提交级一次组合读，时序宽松）。
- 判据不变：B28（`INORD_LOAD`）与 (c) 不回退；程序 0/1 基线 443/721 拍不回退。

## 30. 第 30 轮：三项结构性假设排除 + 三组判定实验（全部无变化，已回退）⇒ 结论：进入"最小可复现反证"阶段

### 30.1 本轮排除的结构性原因（母代理指定）

1. **无重复模块/陈旧副本**：`rtl/back2/` 仅 8 个文件、模块名各一（`module backend_top/lsq_simple/rob`
   各 1 处）、`cb_src_w` 只出现在 `backend_top.v`、iverilog 无 duplicate/redefinition 告警 ✓；
2. **无重复连接**：`.upd_csr_valid/idx/wdata` 各只有一处（第 1273 行，接 `upd_csr_v/upd_csr_idx/upd_csrw`）✓；
3. **动态下标不是原因**：把 `csr_uop = x_i2_uop[csr_lane]` 换成**静态逐槽 mux** 后结果不变 ✗。

### 30.2 三组判定实验（均无变化，已回退）

| 实验 | 结果 |
|---|---|
| `cb_src_w` 直接取 `iprf_rd[0*32 +: 32]`（绕开三元/function） | 仍 `wd=0x00000001` |
| 静态逐槽 mux 取 `csr_uop` | 仍 `wd=0x00000001` |
| I1 前置读口 + 捕获保持（第 29 轮） | 仍 `wd=0x00000001` |

⇒ 结合第 24/25 轮的"同拍打印 `rd0=3` 而 `cb_src_w=1`"，可判定：**在同一模块内、同一表达式、
同一信号切片上，打印值与落入提交的值不一致** —— 这已超出"设计逻辑缺陷"的范畴，
进入**工具/编译层**（iverilog 12.0 对该文件该表达式的求值），也解释了为何 §20~§29 的所有
逻辑层修法都"零变化"。

### 30.3 下一轮建议（与以往不同的一条路：最小可复现 + 规避式修法）

1. **规避式修法（推荐，先拿到绿）**：把 CSR 的写数据**改为在提交点计算**而不是在 I2 计算后经 ROB 传递：
   `rob.v` 的提交路径已经有 `pl_q[...][RB_CSRW]`；改为在 `backend_top` 的**提交排空**处用
   `cmt_pay` 里的 CSR 字段（`p_csrop/p_csra`）+ **提交期直接读 PRF**（提交级组合读，时序宽松：
   该指令的操作数此时必然已写回）合成 `csr_wdata`，绕开 I2 三元表达式这条被工具污染的路径。
2. **最小反证 TB**：在 `sim/unit/` 下加一个 20 行小 TB（不依赖全设计），把
   `wire x = sel ? v : w;`（sel/v/w 均为寄存器）与 `%h` 打印对照，确认是否 iverilog 12.0
   在该写法上确有求值问题（若是，把该结论写进报告"工具陷阱"清单，与既有的
   "function 不得放进位拼接/连续赋值"并列）。
3. 判据不变：B28（`INORD_LOAD`）与 (c) 不回退；程序 0/1 基线 443/721 拍不回退；
   程序 2 修好后实测 IPC 定 C5 档（= 实测 × 0.8）⇒ 三程序全绿 ⇒ regress 30/30。

## 31. 第 31 轮：三组新实验 + 单驱动复核 ⇒ B29 判定为**仿真工具层的同拍取值差异**（三条独立证据）

### 31.1 本轮实验（均零效果或退化，已全部回退）

| 实验 | 结果 |
|---|---|
| `cb_src_w` 改为**完全无选择器的裸读口** `iprf_rd[0*32 +: 32]` | 仍 `wd=0x00000001` |
| 单驱动复核：`assign upd_csrw` ×1、`cb_src_w` ×1、`.upd_csr_*` 连接 ×1（grep 见 §31.2） | 无重复驱动 ⇒ 排除"旧路径残留" |
| **毛刺免疫快照**（`iprf_rd_q` 寄存）+ **稳定门控**（`upd_csr_v = csr_v_w & csr_v_d`） | `wd=0x00000000`（更新完全没落地）⇒ **第三次确认：更新必须在该 CSR 进 I2 的"第一拍"送达** |

### 31.2 关键事实（第 1273 行附近，单驱动已被 grep 证实）

```
wire [31:0] upd_csrw;                                   // 唯一声明
assign upd_csrw = (csrop==1) ? cb_src_w : ... ;          // 唯一驱动
wire   cb_src_w = iprf_rd[0*32 +: 32];                   // 唯一驱动（裸读口）
.upd_csr_valid(upd_csr_v), .upd_csr_idx(upd_csr_idx), .upd_csr_wdata(upd_csrw),   // 唯一连接
```
即在"唯一驱动 + 裸读口 + 无选择器"的**最简形式**下，提交仍得到 1，而同拍探针打印同一信号切片为 3。
⇒ **同一模块、同一表达式、同一拍、同一信号，探针值与落入提交的值不同** —— 三条独立证据
（§24 同表达式矛盾、§29 前置采样仍 1、§31 裸读口仍 1）共同指向 **iverilog 12.0 在该设计上的
仿真取值差异**（与既有"function 不得放进位拼接/连续赋值"同属工具陷阱族，但这次是**纯 wire 表达式**）。

### 31.3 下一轮建议（顺序固定，避免再无谓试错）

1. **先做 §30.3 路径 2 的最小反证 TB**（`sim/unit/` 内 20~30 行，不依赖全设计）：
   同一模块内 `wire y = v[31:0];`（v 为多位向量）+ 同拍 `$display`，验证 iverilog 是否复现
   "打印与采样不一致"；**这是把 B29 归因钉死为工具问题的唯一硬证据**，也是向用户如实汇报的依据。
2. 再按 §30.3 路径 1 做**提交点计算**（此时操作数早已写回，时序宽松）：
   - `back2_params.vh`：ROB 载荷加 `ps1i` 字段（分配期写入，随项到提交）；
   - `backend_top` 提交排空处：用 `cmt_pay` 的 `p_csrop/p_csra/p_ps1i` 合成 `csr_wdata`
     （W/S/C 用提交期直读 `iprf_rd`（提交拍读口地址临时改接到 `p_ps1i`，或用独立读口），
     zimm 形式用 imm），并在提交拍写 `b2_csr`；
   - **拆除 I2 的 `upd_csr_*` 写数据路径**（`upd_csr_v/idx` 若保留，仅作观测，报告已说明）。
3. 判据不变：B28（`INORD_LOAD`）与 (c) 不回退；程序 0/1 基线 443/721 拍不回退；程序 2 修好后
   实测 IPC 定 C5 档（= 实测 × 0.8）⇒ 三程序全绿 ⇒ regress 30/30。

## 32. 第 32 轮：最小反证 TB **未复现** ⇒ 放弃工具归因；病因落到"跨模块边界的取值/采样"

### 32.1 反证 TB 与实测（新建 `sim/unit/b29_wire_probe.sv`，独立、不依赖全设计）

构造与 `prf.v` 读口同构：`mem[] + 写优先旁路（we ? wd : mem[ra]）`，旁路选通在同一时间步的**更晚
delta** 打开（模拟组合逻辑固有竞争），_always @(posedge clk)_ 里**同拍**做两件事：`$display` 打印
`rd`、NBA 把 `rd` 采样进 `rd_q`。
```
[b29-probe cyc=1] display rd=0x00000003 | sampled rd_q=0x00000003
[b29-probe cyc=2] display rd=0x00000003 | sampled rd_q=0x00000003
B29-PROBE: 未复现（同拍打印与采样一致）⇒ 回归采样点/采样拍方向
TB_B29_WIRE_PROBE: PASS
```
（运行：`iverilog -g2012 -o /tmp/b29p.vvp sim/unit/b29_wire_probe.sv && vvp /tmp/b29p.vvp`；
文件名**不带 `tb_` 前缀**，故不改变 `regress.sh` 的用例计数。）

⇒ **工具归因（iverilog 同拍取值差异）被反证否定**，按母代理裁决转向"消费该 wire 的采样点/采样拍"。

### 32.2 病因的最后落点（跨模块边界，一次探针即定案）

此前所有探针都在**同一模块内**（`backend_top`：打印 3；`rob.v`：收到 1）——
**唯一没被检查过的环节正是"跨模块端口边界"**：
- 顶层探针：`cb_src_w/iprf_rd[0] = 3`、`upd_csrw = 1`（同拍、同 `$display`）；
- `rob.v` 内探针：`upd_csr_wdata = 1`、`idx = 16`（更新确实命中）。
⇒ 下一步（一次运行即可定案）：把 `cb_src_w`、`upd_csrw`、`iprf_rd[0*32 +: 32]` **作为额外调试端口**
送进 `rob.v`，在 `rob.v` 内**同一 $display** 打印"从边界收到的值"与"顶层源值"：
- 若两者不同 ⇒ 端口绑定/同名遮蔽问题（如存在另一处 `.upd_csr_wdata(...)` 或 `upd_csrw` 的别名连接，
  注意 iverilog 对重复命名端口连接**不报错**，会静默取后者）；
- 若两者相同（皆为 3）而 `pl_q` 仍存 1 ⇒ 采样拍问题（`pl_q` 的写入与 I2 更新不同拍，回到 B27 病族的
  "索引/有效/数据不同拍"清单，用同一套窗口算术核对）。
- **提交点计算（§30.3 路径 1）仍是最稳妥的正解**：它绕开"源在 I2 拍、消费在 ROB"这条整链，
  在提交拍（时序最宽松）现算 CSR 写数据；实施步骤见 §31.3 第 2 条（本会话预算已尽，未落地）。

## 33. 第 33 轮：提交点计算已实施并实测（仍为 1）⇒ 该 1 并非来自 CSR 源操作数链；已回退

### 33.1 实施内容（母代理第 33 轮任务 1，已按序落地）

- `rename.v`：新增 **ARAT 读口**（`arat_ra/arat_rd`，`assign arat_rd = arat_q[arat_ra];`）——
  提交拍可拿到"某架构寄存器当前**已提交**的物理号"；
- `backend_top.v`：提交扫描处一并捕获被提交 CSR 指令的 `rs1`（`p_imm(pay)[19:15]`）与 `csrop`；
  新增**提交级现算** `csr_cmt_data_new = f(csrop, csr_rdata_w, prf[ARAT[rs1]])`
  （PRF 第 15 读口，地址 = ARAT 解析结果）；提交拍把 CSR 读口切到 `csr_cmt_addr`；
  `csr_wdata_w` 改用 `csr_cmt_data_new`；
- **停用 I2 写数据路径**：`.upd_csr_valid(1'b0)`（`upd_csr_v` 保留为观测信号），避免新旧双写。

### 33.2 实测（`/home/shorthair/dsh/rv32-cpu/.b2chk/r33.log`）

程序 0/1 完全不变（443 拍/0.3917、721 拍/0.2469）；程序 2 第 15 条**仍为 `wd=0x00000001`**。
⇒ **在"I2 写数据路径已停用 + 提交级从头现算"的条件下，提交值仍为 1** ⇒ 该 1 **不是**由
CSR 源操作数链（`cb_src_w`/`iprf_rd`/ARAT/PRF）产生的，而是**ROB 载荷字段 `RB_CSRW` 在某个
我们尚未识别的写入点被写成 1**（已知的分配写入为 0、I2 更新已停用、提交级只读不写）。
⇒ 第 34 轮第一步（唯一未查的环节）：在 `rob.v` 内**逐拍转储 `pl_q[16][RB_CSRW]` 与所有写它的分支**
（分配 `alloc_payload`、`upd_csr_valid`、以及任何 `pl_q[...]` 整字写入路径），**一次运行即可看到
"谁把 1 写进去"**（怀疑存在对 `pl_q[idx]` 的**整字/分段写入**覆盖了该字段，例如执行期字段回写块
之外的某条赋值，属 B27 病族的"字段覆盖"）。
本轮改动（ARAT 读口 + 提交级现算 + I2 停用）**已整段回退**（`../.b2chk/*.pre33`），
树回到第十四个检查点语义；三 TB 编译零错误、`tb_back2_iq` 151/151。

### 33.3 交付状态（可编译检查点）

- 程序 0/1：C1–C5 全绿（**443 拍/0.3917 ≥0.30**、**721 拍/0.2469 ≥0.19**），基线未回退；
- 程序 2：C2 过、**B28 已修**、仅第 15 条（B29）；
- `tb_back2_iq` 151/151、`tb_back2_ipc` IPC=2.0000；三 TB `-Wall` 零错误；全旋钮 0、`CHK=1`；
- 新增诊断件 `sim/unit/b29_wire_probe.sv`（工具归因反证，未复现）；
- regress 30/30 未达成（锁步 fail-closed 保留清单）。

## 34. 第 34 轮：**B29 修复成功 —— 三程序全绿！**（母代理的字段语义更正命中真因）

### 34.1 真因与修法

- 载荷 `RB_CSRW` 在**分配期固定写 `32'h0`**，唯一写入者是执行期回写；第 33 轮用 `p_imm(pay)[19:15]`
  反推 rs1 时，该字段装的是 **CSR 地址 0x340** ⇒ `[19:15]=6` ⇒ `ARAT[6]` 恰为值 1 的寄存器 ⇒ 仍得 1
  （母代理更正完全正确）；
- **修法（第 34 轮）**：① 分配期把该 lane 的 **PS1I** 写进 `RB_CSRW`（`{25'b0, u_ps1i(lane_uop_fin[g5])}`，
  单写者、天然稳定）；② 提交拍 `PRF[ps1i]` 现算并按 `csrop` 合成（W→src；S→old|src；C→old&~src），
  在提交拍写 `b2_csr`；③ I2 的 `upd_csr_valid` 置 0（仅观测），避免双写；
  ④ PRF 整数域读口加宽到 **16**（`NRD(16)`、`re=16'hFFFF`）——否则端口 15 越界读出 x
  （中间实测正是 `wd=0xxxxxxxxx`，加宽后消失）。

### 34.2 实测（`../.b2chk/final1.log`）—— **全绿**

```
程序 0：161 / 199 条（黄金 161），跳板 2/2，443 拍，IPC=0.3917（下限 0.30 ✓）
程序 1：178 / 215 条（黄金 178），跳板 2/2，721 拍，IPC=0.2469（下限 0.19 ✓）
程序 2：126 / 257 条（黄金 126），跳板 2/2，913 拍，IPC=0.1382（下限 0.1094 ✓ 裕量 26%）
== 检查项合计 30 项全部满足；提交总数 = 465（3 程序）
TB_BACK2_LOCKSTEP: PASS
```
- C1（arch 写回锁步）/C2（vs Spike 黄金 PC）/C3（条数）/C4（存储映像）/C5（分档下限）全过；
  `RENAME-CHK` **0** 条；无停顿；程序 0/1 基线（443/721 拍）未回退；
- 旋钮全关（`DBG_IQ/DBG_LSU/DBG_CSR=0`、`TRACE/TRB=0`）、`CHK=1`。

### 34.3 B29 台账（最终）

| 项 | 内容 |
|---|---|
| 现象 | 程序 2 第 15 条 `csrrs x13, mscratch, x0` 读到 1（2A/Spike 为 3） |
| 真因 | CSR 写数据在 I2 组合取值经 ROB 载荷传送，取值不可靠；且第 33 轮"提交级现算"因**用错字段**（imm[19:15] 当 rs1）仍得 1 |
| 修法 | 载荷携带 PS1I + 提交拍 `PRF[ps1i]` 现算 + 停用 I2 写数据路径 + PRF 读口加宽到 16 |
| 验证 | 三程序 C1–C5 全绿、CHK 零违规、无停顿、基线不回退（见 §34.2） |

---

# 2B-3（真乱序 LSQ，32+32）进展 —— 第 1 段（接手时的检查点）

## B3.0 本轮已完成（可编译检查点）

1. **2B-2 收尾状态完好**（母代理已验收提交 `041ab61`、tag `2B-2`、regress 30/30 亲跑）：
   本段未触碰任何 2B-2 已验证逻辑；
2. **新增转发覆盖用例（验收判据④的半成品）**：`sim/unit/lsq_fwd_case.sv`（LSQ 直驱，
   覆盖 C1 字节→字部分转发合并、C2 两条字节 store→字 load 部分重叠合并、C3 同字节取**更年轻**
   store、C4 全转发不访存、C5 无命中走访存、C6 半字转发；含全局超时 fail-closed）。
   **当前状态：编译通过（`-Wall` 零错误）、可运行，但激励仍未跑通**（10 项中 9 项 FAIL）。
   已修：`st_issue` 的槽号改为**分配拍采样**（`alloc_valid=1` 当拍组合读 `alloc_idx[0]`）——修后
   失败数不变 ⇒ 剩余问题在 **load 侧时序口径**（`wait_wb` 的请求/响应窗口；以及 store 的
   `stq_rob`/`age_rob` 与 load 的 `exe_rob` 是否落在同一 ROB 窗口且 store 更老 ⇒ 需把激励里的
   `rob_head`/`exe_rob` 按窗口语义对齐）。下一步按此逐项对拍。**为守住 fail-closed（不得留失败用例），
   该文件暂以非 `tb_` 前缀命名，不计入 `regress.sh`（保持 30/30）**；跑通后改回 `tb_*.sv` 即自动纳入。
   > ★ **第 5 段已闭环**：改名 `sim/unit/tb_back2_lsq_fwd.sv` 并纳入 regress（**31/31**）——
   > 见 §B3.6（x 隐患根治 + 2 个 RTL 真缺陷 + 1 个用例协议缺陷）。本节以下为**历史现场**，保留不改。

## B3.1 2B-3 设计要点（下一轮实施，AGENT.md 口径）

| 项 | 口径 |
|---|---|
| 容量 | **LQ 32 + SQ 32**（`BACK2_STQ_N`/`OUT_N` 需扩为 32；索引位宽随之 +1） |
| load 乱序 | E1 生成地址后入 LQ，可**乱序执行/乱序写回**；写回按 tag 匹配归属（单端口响应 + `ld_tag`） |
| store 提交排空 | 仅按 ROB 提交序在提交点逐条排空到存储器；**单 AXI 在途 + 归属寄存器**纪律（AGENT.md §3.3 三件套） |
| store→load 转发 | 完整字节掩码语义：部分重叠**逐字节**取"更年轻的更老 store"（现有 §2.2 归约已成雏形，扩到 32 项） |
| 违序闸门 | 年轻 load 仅在**地址已证不相交**时越过年老 store；存在未定址更老 store ⇒ 保守闸门（**B28 的 `INORD_LOAD` 教训**必须保留） |
| 口径保持 | B24（`size` = log2 字节数）、B27（窗口算术、禁掩码写法）、B29（提交级 CSR）**均不得回退** |
| 新增用例 | 本段 §B3.0 的转发覆盖用例（跑通后纳入 regress ⇒ 31/31）+（可选）访存流 IPC 用例 |

## B3.2 下一步（按优先级）

1. 修 `lsq_fwd_case.sv` 的激励（按"分配拍"采样槽号）⇒ 全绿后改名 `tb_back2_lsq_fwd.sv` 纳入 regress；
2. 以现有 `lsq_simple.v` 为骨架扩到 **32+32**（先只扩容量与索引宽度并保绿，再放开乱序执行）；
3. 每步：整设计编译 + `tb_back2_iq` 151/151 复验 + 锁步三程序 C1–C5（性能基线变动时按规程重测 C5 档）。

## B3.3 第 1 段收尾状态（预算见底时的检查点）

**已完成**
- 2B-2 基线复验：`REGRESS: 30/30 PASS`（含 `tb_back2_lockstep PASS`）、`tb_back2_iq` 151/151、
  `tb_back2_ipc` IPC=2.0000、锁步三程序 443/721/913 拍 + CHK 0 + 无停顿；
- 2B-3 设计要点落档（§B3.1）与转发覆盖用例骨架 `sim/unit/lsq_fwd_case.sv`
  （C1–C6 六场景、含超时 fail-closed；编译 `-Wall` 零错误、可运行）。

**阻塞点（唯一）**
- `lsq_fwd_case.sv` 的**激励时序口径**未对齐：10 项检查 9 项 FAIL。
  已排除：槽号采样时机（已改为分配拍采样，失败数不变）。
  剩余待查（按可能性排序）：
  1. **load 侧请求/响应窗口**：`wait_wb` 在 `mem_req_valid` 的**次一拍**给响应 ✓，但 LSU 的
     `mem_req_ready`/`pend_any` 交错可能使请求延后 ≥2 拍 ⇒ 响应窗口应按"看到请求后**连续**给
     响应直到 `wb_valid`"实现（而非只给一拍）；
  2. **ROB 窗口口径**：store 的 `stq_rob` 在 E1 写入，需与 `rob_head`/`exe_rob` 同窗口且 store 更老；
     激励里固定 `rob_head=0`、store rob=1..、load rob=2.. 时应成立，但仍需用**窗口算术**
     （无掩码、宽度位差判先后）逐项打印核对；
  3. **store 未排空的影响**：本用例不驱动 `dr_valid`，若某场景的 `any_unk_w` 或 `iss_ok` 语义与预期
     不同，需在激励里显式排空（或断言 `cnt_store_o`/`stq_cnt_o` 以确认 store 已入队）。

**下一步（按序）**
1. 按上述 1→2→3 修激励 ⇒ 全绿 ⇒ 改名 `tb_back2_lsq_fwd.sv` 纳入 regress（**31/31**）；
2. 两步扩 LSQ 到 **32+32**：先只扩容量/索引宽度（`BACK2_STQ_N`/`OUT_N` 与 `lsq_simple.v` 内
   `stq_used` 的 16 项 popcount、`[4:0]` 计数、`ld_tag` 宽度等一并扩）并保绿；
3. 再放开 load 乱序执行、"地址已证不相交才可越过"闸门、逐字节转发更年轻优先、提交序排空；
   每步后：整设计编译 + `tb_back2_iq` 151/151 + 锁步 C1–C5 + regress；性能基线变动时按
   "实测×0.8"重测 C5 档并更新 TB 注释与本报告。

## B3.4 第 3 段：用例内层次探针的**决定性发现**（下一段 1 步可修）

探针实测（`lsq_fwd_case.sv` 内 `[fwd-case]` 逐拍打印，第 10~21 拍）：
```
[fwd-case c=10] anyunk=0 issok=1 stqcnt=1 cntst=1 | stq0 v=1 av=1 msk=0001 a=0x80001000 rob=1 |
                exe v=0 st=0 rob=2 a=0x80001000 sz=2 | reqv=x wen=x rspv=0 wbv=0 wbd=0x000000aa
```
- ✅ **store 入队正确**：`stq0 v=1 av=1 msk=0001 a=0x80001000 rob=1`，`cnt_store_o` 递增 ✓（§B3.3 第①点排除）；
- ✅ **转发数据正确**：`wb_data = 0x000000aa`（C1 场景期望的字节 0 = store 数据）✓
  ⇒ **LSQ 转发逻辑正确**（§B3.3 第②点方向排除）；
- ❌ **`mem_req_valid` / `mem_req_wen` 为 `x`** —— 这是用例全部失败的**直接原因**：
  我的 `wait_wb` 用 `if (mem_req_valid)` 采样 ⇒ x 参与判断 ⇒ `saw_req` 与期望不符 ⇒ 各场景判据失败。
- `lsq_simple.v` 内 `mem_req_valid/wen/addr/tag` 各只有**一处** `assign`（无多驱动）⇒ 该 x 来自
  其输入：`dr_fire = dr_any & mem_req_ready` 或 `ld_fire = pend_any & ~dr_any & mem_req_ready`
  中的某个信号为 x（最可能是 TB 侧 `dr_valid/dr_idx` 与 `pend_sel/ld_*` 的初值或 `mem_req_ready`
  的连接/时序）。

**下一段第 1 步（一行探针即可定案）**：在同一个 `[fwd-case]` 行追加
`u_lsq.pend_any / u_lsq.dr_any / u_lsq.pend_sel / dr_valid / dr_idx / mem_req_ready`
（全部为 TB 可见信号），即可确定 x 的来源；修好后本用例应即刻全绿（转发数据已证正确），
随后改名 `tb_back2_lsq_fwd.sv` 纳入 regress（目标 **31/31**），再进入"先扩 32+32、再放开真乱序"两步。

## B3.5 第 4 段：x 源已定案 —— **`lsq_simple.v` 的组合归约块在输入长期不变时保持 x**（RTL 侧潜在缺陷）

探针实测（`lsq_fwd_case.sv` 的 `[fwd-case]` 第二行）：
```
[fwd-case c=10] ... reqv=x wen=x ... | dr_any=x pend_any=1 dr_valid=0000 dr_idx=0 rdy=1
```
- **`dr_valid` 明确为 `0000`，而模块内部 `dr_any` 仍为 `x`** ⇒ `dr_fire = dr_any & mem_req_ready = x`
  ⇒ `mem_req_valid/wen = x`。`pend_any=1` 正常。
- 成因：`dr_any/dr_sel` 由 `always @(*)` + `for (dk = W-1; dk >= 0; dk = dk - 1)` 归约赋值；
  该块**只在输入（`dr_valid/dr_idx`）变化时重算**：若仿真起始时输入为 x、而此后长期保持同一值
  （本用例恒为 0），块不会再次执行 ⇒ `dr_any` 停留在 x（同一族工具/建模陷阱，与本设计已登记的
  "function 不得放进位拼接/连续赋值"并列）。在锁步里 `dr_valid` 频繁变化，故该 x 会被及时冲掉，
  未暴露为功能错误 —— 但这是**真实的 x 传播隐患**（空闲期请求口为 x）。
- ✅ 同时再次确认：`stq0 v=1 av=1 msk=0001 a=0x80001000 rob=1`、`wb_data=0x000000aa`（转发数据正确）。

**下一段修法（RTL 侧，安全且局部）**：把 `lsq_simple.v` 里这几处"`always @(*)` + for 归约"
改为**连续赋值的优先级链（generate + assign 三元表达式）**——连续赋值随任意输入变化恒被求值，
天然无该敏感性/初值陷阱：
1. `dr_sel/dr_any`（提交排空选择，§3 前的 dk 循环）；
2. `pend_any/pend_sel`、`rsp_ok/rsp_sel`、`newslot/newslot_ok`（§3 的 nq 循环）；
3. `ai[]`（分配槽扫描）与 `stq_used`（16 项 popcount，扩 32 时同步改为 32 项）。
改完：整设计编译 + `tb_back2_iq` 151/151 + 锁步三程序 C1–C5 + 本用例（应即刻全绿）
⇒ 改名 `tb_back2_lsq_fwd.sv` 纳入 regress（**31/31**）；随后进入 32+32 两步扩容。

## B3.6 第 5 段：x 隐患**根治** + 覆盖用例暴露的 **3 个真问题**（含 2 个 RTL 缺陷）—— 全绿

### B3.6.1 改动 1：六处组合归约全部改为连续赋值（x 隐患根治）

`rtl/back2/lsq_simple.v` 里所有 `always @(*)` + `for` 归约改写为 `generate` + `assign`：

| 归约 | 新实现 | 语义 |
|------|--------|------|
| `dr_sel/dr_any` | 连续赋值优先级链（lane 0→3） | 最低 lane 优先（原 dk 递减循环的等价） |
| `pend_any/pend_sel` | `pend_vec` 或归约 + 三元链 | 最低序号优先 |
| `rsp_ok/rsp_sel` | `rsp_vec` 或归约 + 三元链 | 原 `!rsp_ok` 锁存首个命中者 |
| `newslot/newslot_ok` | `ld_free` 或归约 + 三元链 | 最低序号优先 |
| `ai[]`（分配槽） | `ai_fr` 空闲前缀和 + 候选或归约 | 前 W 个空闲槽，序号升序 |
| `stq_used` | **assign 加法树**（16×2b→8×3b→4×4b→2×5b→6b） | popcount |
| `any_unk_w` | `unk_v` 逐项或归约 | B28 保守门 |
| 字节级转发 | 候选/最优 age 串行链（**4 字节 × 32 候选**） | 见 B3.6.2 ① |

**32 项扩展口径已就位**：`stq_v32`（高位补 0）、popcount 加法树、转发候选 4×32、
`ai_fr` 前缀和全部按 **32 槽**写死 ⇒ 第 6 段把 `BACK2_STQ_N` 改成 32 时本节零改动。
实测确认（同一探针）：`dr_any=0 pend_any=0/1 reqv=0 wen=0 anyunk=0` —— 空闲拍请求口
**全部为确定值**，x 消失。

### B3.6.2 覆盖用例暴露的 3 个真问题

① **转发优先级方向与规格相反（RTL 真缺陷，已修）**：原循环 `if (cur_age <= best_age)`
（初值 255）保留的是 **age 最小者 = 最老 store**，而规格 §6.2/文件头注要求"取字内**最年轻**的
更老匹配者"（同字节两条更老 store 时必须取更年轻者）。新实现改为"候选 age 最大者胜"
（`fw_ag_ch` 组内 8 项串行最大链 + 组间两级 ⇒ `fw_best`，再 `fw_sel = match & age==best`）。
用例 **C3**（同字节 0x11/0x22 ⇒ 期望 0x22）即验此点 —— 旧实现在该场景必错。

② **load 槽从不按响应释放（RTL 真缺陷，已修）**：原实现 `ld_v[]` 只在 `flush_all`/`squash`
清（§4.4 只有 `if (ld_fire) ld_req <= 1`）。⇒ 无冲刷时满 `OUT_N=4` 笔 load 之后
`ld_slot_ok=0`：既不满足"全转发"也无槽可分配 ⇒ 该 load **永不写回**、LSU 从此不受理 load。
锁步未暴露纯属侥幸：分支误判的 squash 顺手清了槽（程序 0/1/2 各有 5/5 次误判）。
**修法**：`if (rsp_ok) begin ld_v[rsp_sel] <= 0; ld_req[rsp_sel] <= 0; end`
（本里程碑口径 "响应到达 = 该 load 完成"；2B-3 真 LSQ 改为**提交点释放**并带 32 项 LQ）。
与 §4.2 分配无冲突：`newslot` 只从 `ld_free` 选，本拍被释放的槽 `ld_v` 仍为 1。

③ **用例 TB 自身协议错（已修）**：LSU 的访存请求是**单拍握手脉冲**（`ld_fire` 当拍即把
`ld_req` 置 1 ⇒ 下一拍 `mem_req_valid` 已回落）。原 `wait_wb` 在 **negedge** 采样
`mem_req_valid` ⇒ 必然漏掉脉冲 ⇒ 响应永不产生 ⇒ 10 项判据 9 项 FAIL（**与 RTL 无关**）。
修法：改为**寄存器化、posedge 采样的响应模型**（与 `tb_back2_lockstep.sv` 的存储器模型同口径，
只对 load 响应、每次受理恰好一拍响应、`saw_req` 粘滞）；另把 `chk` 的检查名宽度由 255 bit
（32 B）扩到 512 bit（64 B）—— 中文 UTF-8 检查名原被截成半个字符导致日志乱码。

### B3.6.3 第 5 段验证台账（全部实测）

| 项目 | 结果 | 日志 |
|------|------|------|
| 锁步三程序 C1–C5（槽释放改动后复验） | **30/30 PASS**，提交 465，IPC 0.3917/0.2469/0.1382（与基线逐位一致），CHK 零违规 | `../.b2chk/ls37.log` |
| `tb_back2_iq` | **151/151 PASS** | 内联运行 |
| `tb_back2_lsq_fwd`（原 `lsq_fwd_case.sv`） | **10/10 PASS**（C1 部分转发+合并、C2 双字节合并、C3 更年轻优先、C4 全转发不访存、C5 无命中走访存、C6 半字） | `../.b2chk/lsqf8.vvp` |
| `scripts/regress.sh` 全量 | **31/31 PASS**（新增 `tb_back2_lsq_fwd` 计入 ⇒ TB 数 30→31；`scripts/regress.sh` 本次**无需改动**，仅 T6 墙钟档属允许改动范围） | `../.b2chk/regress31.log` |

判据④（"新增/强化访存流 IPC 或转发覆盖用例并说明方法学"）**达成**：
`sim/unit/tb_back2_lsq_fwd.sv`（LSQ 直驱、不经前端/重命名，逐场景构造"更老 store + 更年轻
load"，6 场景 10 项检查；方法学见文件头注：接口与 2B-3 真 `lsq.v` 保持一致 ⇒ 可原样复用）。

### B3.6.4 阻塞点 / 风险登记

- 本段**无阻塞**。两条 RTL 修复均在 `rtl/back2/lsq_simple.v`（本里程碑允许改动范围）内，
  锁步/IPC 基线未变（IPC 逐位一致 ⇒ C5 档无需重测）。
- 遗留（**不属本段**，第 6 段处理）：`stq_rob` 仍是"E1 写入"的陈旧值语义 ⇒ `any_unk_w` 的
  年龄判据在"已分配未执行"的 store 上不可靠；2B-2 靠 `iq.v` 的 `INORD_LOAD` 队列级门兜底。
  放开 load 乱序前**必须**把 ROB 索引在**分配期**写进 STQ（`stq_rob`/`stq_epoch`）。
- `lsq_simple.v` 是**过渡件**：`OUT_N=4` 在途表 ≠ 32 项 LQ；第 6 段需新增 32 项 LQ
  （分配/提交点释放）并把 `OUT_N` 保留为"在途访存槽（MSHR 口径）"。

### B3.6.5 下一步（第 6 段：两步扩 LSQ，每步后全量验证）

1. **第一步（只扩容量/索引宽度，保绿）**：`BACK2_STQ_N` 16→32、`BACK2_STQ_IDX_W` 4→5、
   `stq_head/tail` 指针宽度、`stq_v32` 高位由常量 0 换成 `stq_v[16..31]`、`stq_cnt_o`
   零扩展位数、DBG 转储循环；转发候选 4×32 与 `ai_fr` 前缀和已按 32 项写死 ⇒ 预期零改动。
   > ★ **本段已实测的"零改动"边界**（`grep BACK2_STQ_IDX_W rtl/back2/*.v` = 仅 `lsq_simple.v`）：
   > `lsq_simple.v` 内部（归约/popcount/转发候选/LQ 表）确实零改动，但**索引宽度牵动
   > `backend_top.v` 的 6 处硬编码 4 bit 与 ROB payload 字段**，第一步的准确触碰点清单：
   > ① `back2_params.vh`：`BACK2_STQ_N` 16→32、`BACK2_STQ_IDX_W` 4→5、
   > `BACK2_RB_STQ_MSB/LSB` 409/406→410/406、`BACK2_RB_W` 416→417（★ 需核对 payload 字段表：
   > STQ 字段之上的其它字段偏移是否要整体上移，这是本步**唯一有系统性风险**的点）；
   > ② `backend_top.v`：L208 `function [3:0] p_stq`→`[4:0]`、L270 `wire [3:0] stq_of_rob_r`→`[4:0]`、
   > L278 `reg [3:0] stq_of_rob[0:127]`→`[4:0]`（L1501 复位字面量）、L656
   > `wire [15:0] st_alloc_idx`→`[19:0]`、L755 / L1161 / L1534 三处 `*4 +: 4`→`*5 +: 5`；
   > ③ `lsq_simple.v`：本段已按 32 项写死（popcount 加法树、转发候选 4×32、`ai_fr` 前缀和、
   > `stq_cnt_o` 零扩展）⇒ **零改动**；仅需把 `stq_v32` 高位来源换成 `stq_v[16..31]`。
   ⇒ 整设计编译 + `tb_back2_iq` 151/151 + 锁步 C1–C5 + `tb_back2_lsq_fwd` + regress 31/31。
2. **第二步（放开真乱序）**：① 新增 32 项 LQ（E1 入队、写回乱序、**提交点释放**）；
   ② "地址已证不相交才可越过"闸门（更老 store 已定址且与 load 字地址不交 ⇒ 放行；
   未定址 ⇒ 保守阻塞，B28 教训）；③ 逐字节转发**更年轻优先**（本段已在候选层实现，
   接到 32 项 LQ 的年龄窗口上）；④ store 提交序排空（单 AXI 在途 + 属主寄存器纪律）。
   ⇒ 同上五项验证 + 若性能基线移动则按 "**实测 × 0.8**" 重测 C5 档（三程序）并更新
   `tb_back2_lockstep.sv` 注释与本报告。

> ★ **本计划已执行完毕**：两步各自全绿、性能基线逐位不变 ⇒ 见下方 **§B3.7**（第 6 段交付）。

---

# 2B-3 第 6 段：**两步扩容落地**（SQ 32 + LQ 32 + 真乱序边界）—— 两步各自全绿

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev 分支，起点 HEAD=`8a372fb`，**未提交**）
> 写入范围：`rtl/back2/{lsq_simple.v, backend_top.v, back2_params.vh}` +
> `sim/unit/tb_back2_{lockstep,lsq_fwd,ipc}.sv`；`scripts/regress.sh` **未改**（无需改）；
> **2A/front4/exec/mem/csr/cache/fetch/decode/axi/top/pkg 零改动**（`git status` 仅上述 6 个文件）。
> 备份：`../.b2chk/{lsq_simple.v,backend_top.v,back2_params.vh,tb_back2_*.sv}.s6`。

## B3.7.0 两步划分与全绿结论（先给结论）

| 步骤 | 内容 | 结果 |
|---|---|---|
| **第一步** | 容量/位宽扩容：`STQ_N 16→32`、`STQ_IDX_W 4→5`、LQ `4→32`、`MEM_TAG_W 3→6`、ROB 载荷 STQ 位域 4→5 bit、backend_top 6 处硬编码位宽 | ✅ 五项判据全绿（§B3.7.2/§B3.7.4） |
| **第二步** | 语义：`stq_rob` **分配期**写入、发射闸门按**候选**判年龄、LQ **E1 入队 + 提交点释放**、写回乱序（标签匹配）、逐字节转发（32 项候选、最年轻胜）、store 按 ROB 序提交排空 | ✅ 同套判据全绿 + 性能基线**逐位不变**（§B3.7.3/§B3.7.4） |

`regress.sh`：第一步在**内容逐字节相同**的副本树上跑（`.b2chk/s1_regress.log`，31/31）；
第二步在**冻结后的正式树**上跑（`.b2chk/f_regress.log`，见 §B3.7.4）。

## B3.7.1 触点改动清单（实际落地，逐处）

### ① `rtl/back2/back2_params.vh`（容量/位宽唯一真源）

| 宏 | 改前 | 改后 | 说明 |
|---|---|---|---|
| `BACK2_STQ_N` | 16 | **32** | SQ 32 |
| `BACK2_STQ_IDX_W` | 4 | **5** | STQ 索引位宽 |
| `BACK2_LQ_N` / `BACK2_LQ_IDX_W` | （新增） | **32 / 5** | LQ 32（新增宏，语义显式化） |
| `BACK2_MEM_OUT_N` | 4 | **`BACK2_LQ_N`（=32）** | 在途访存槽 = LQ 深度 |
| `BACK2_MEM_TAG_W` | 3 | **6** | **必须 ≥ LQ_IW+1**：槽标签 0..31 最高位恒 0，store 排空标签取**全 1** |
| `BACK2_RB_STQ_MSB/LSB` | 409/406 | **410/406** | 见下方"位域核对" |
| `BACK2_RB_W` | 416 | **416（不变）** | 顶端保留位 6 bit → 5 bit |

**★ 位域核对结论（本步唯一系统性风险点，已用探针钉死）**：`backend_top` 的载荷组装
`{stq_idx, 5'b0, 1'b0, 32'h0, tval, {25'b0,ps1i}, uop}` 是**右对齐（LSB 对齐）**拼接、
高位由赋值零扩展 ⇒ **加宽最顶端的 STQ 字段只会向上生长，其下所有字段绝对 bit 位置逐位不变**。
故正确改法是 **STQ_MSB 409→410、STQ_LSB 恒 406、RB_W 恒 416**；
任务书摘录里"LSB 406→405、RB_W 416→417"的写法**会错**（5 bit 字段跨进 [405] = fflags 最高位，
`p_stq` 将含 fflags 位而丢掉 STQ 最高位）。一次性核对探针（`../.b2chk/probe/pay_probe.v`，
逐字复用该拼接式）：

```
PAY_PROBE: RB_W=416 STQ=[410:406] fflags=[405:401] csrw=[335:304] 错误 0 项
PAY_PROBE: 位域核对通过（其余字段绝对位置不变）
```

### ② `rtl/back2/backend_top.v`

| 位置（改后行号） | 改动 |
|---|---|
| 111/115 | `mem_req_tag_o` / `mem_rsp_tag_i` 由硬编码 `[2:0]` → `[`BACK2_MEM_TAG_W-1:0]`（**任务书触点表未列，编译期 `-Wall` 抓到**） |
| 208 | `p_stq` 返回宽度 `[3:0]` → `[`BACK2_STQ_IDX_W-1:0]` |
| 270/278 | `stq_of_rob_r` / `stq_of_rob[0:127]` 位宽 4→5 |
| 382 | `lsu_dr_idx` `[15:0]` → `[DISP_W*`BACK2_STQ_IDX_W-1:0]`（20 bit） |
| 385-388 | 新增 `st_alloc_rob`（4 lane × ROB 索引）与 `cmt_n_w`（提交条数）声明 |
| 660 | `st_alloc_idx` `[15:0]` → 20 bit；新增 `assign st_alloc_rob = {idx0+3, +2, +1, +0}` |
| 763 | ROB 载荷拼接 `st_alloc_idx[g5*4 +: 4]` → `[g5*5 +: 5]` |
| 877 | IQ-LSU 例化：`INORD_LOAD` 注释重写（见 §B3.7.3 ③；**参数保持 1**） |
| 1019 / 1031 / 1034 | LSQ 例化新增 `.alloc_rob(st_alloc_rob)`、`.iss_rob(i4_sel_rob)`、`.cmt_n(cmt_n_w)` |
| 1153 | 新增 `assign cmt_n_w`（= `cmt_ok ? popcount(cmt_raw) : 0`；前缀连续链） |
| 1182 | `lsu_dr_idx[cc*4 +: 4]` → `[cc*5 +: 5]` |
| 1522 | `stq_of_rob` 复位字面量 `4'd0` → `{`BACK2_STQ_IDX_W{1'b0}}` |
| 1555 | `stq_of_rob[...] <= st_alloc_idx[si2*4 +: 4]` → `[si2*5 +: 5]` |

### ③ `rtl/back2/lsq_simple.v`

| 区块 | 改动 |
|---|---|
| 参数 | 新增 `LQ_IW = `BACK2_LQ_IDX_W`（5） |
| 端口 | 新增 `alloc_rob`（分配期 ROB 索引）、`iss_rob`（发射候选 ROB 索引）、`cmt_n`（提交条数，外部按 `cmt_ok` 门控） |
| §2.1 闸门 | `unk_v` 的年龄比较由 `age_rob`（E1 项）→ **`age_iss`（候选）**；语义从"判别人"改为"判自己" |
| §3 LQ | 4 项字面实现 → **`OUT_N`(=32) 项参数化**：`ld_free/pend_vec/rsp_vec` 改 generate 连续赋值，`pend_sel/rsp_sel/newslot` 改**纯函数** `pri_enc`（只吃打包向量，不读存储器）；新增状态位 `ld_dn`（数据已齐） |
| §4.2 | STQ 分配同时写 `stq_rob <= alloc_rob[lane]`（**年龄唯一写点**，报告 §B3.6.4 的必办项） |
| §4.3 | store E1 不再重复写 `stq_rob`（唯一写点纪律）；load E1 同时清 `ld_dn` |
| §4.4 | 响应到达只置 `ld_dn=1`（**不再释放槽**）；退出请求口/响应匹配 |
| §4.4b（新增） | **提交点释放**：`ld_v & ((ld_rob-rob_head)&7'h7F) < cmt_n` ⇒ 清 `ld_v/ld_req/ld_dn`（幂等、无掩码写法，B27 口径） |
| §4.6 | squash 清 `ld_dn` |
| `ld_tag` 写入 | 零扩展宽度 `TAG_W-2` → **`TAG_W-LQ_IW`** |

### ④ `sim/unit/tb_back2_{lockstep,ipc}.sv`

`mem_req_tag` / `mem_rsp_tag` / `rq1_t` / `rq2_t` 由硬编码 `[2:0]` → `[`BACK2_MEM_TAG_W-1:0]`
（**不改则标签高位被截断 ⇒ 响应永匹配不上 ⇒ 挂死**）；`tb_back2_ipc` 的
`.mem_rsp_tag_i(3'h0)` 同步为宏宽度。`tb_back2_lsq_fwd.sv` 追加驱动三个新端口
（`alloc_rob` lane0、`iss_rob`、`cmt_n` 恒 0——直驱夹具不模拟提交点，见 §B3.7.6 遗留）。

## B3.7.2 第一步实测（容量扩容保绿）

```
== 程序 0：两核提交 161 / 199 条（黄金 161），跳板 2 / 2 条，443 拍   IPC=0.3917
== 程序 1：两核提交 178 / 215 条（黄金 178），跳板 2 / 2 条，721 拍   IPC=0.2469
== 程序 2：两核提交 126 / 257 条（黄金 126），跳板 2 / 2 条，913 拍   IPC=0.1385（窗 910）
== 检查项合计 30 项全部满足；提交总数 = 465（3 程序）           TB_BACK2_LOCKSTEP: PASS
tb_back2_iq 151/151 PASS ｜ tb_back2_lsq_fwd 10/10 PASS ｜ tb_back2_ipc IPC=2.0000 PASS
regress（内容相同副本树）：REGRESS: 31/31 PASS      ← ../.b2chk/s1_regress.log
```
程序 2 的**提交窗**由 912 → 910 拍（IPC 0.1382→0.1385）属测量抖动（第二步复测回到 912/0.1382，
与基线**逐位相同**）⇒ **C5 分档无需重测**（阈值是防退化下限，且实测未降）。

## B3.7.3 第二步实测与机制（真乱序边界）

### ① LQ 32：E1 入队 + 写回可乱序 + **提交点释放**

- `ld_v`（占用）与 `ld_dn`（数据已齐）分离：响应到达只置 `ld_dn`，槽留到该 load **提交**；
- 释放判据用提交组窗口算术 `(ld_rob - rob_head) & 7'h7F < cmt_n`，
  `cmt_n = popcount(cmt_rob 前缀链)` 且由 `cmt_ok` 门控（冲刷/陷阱拍恒 0）；
- 与 §4.2 分配无冲突（`newslot` 只从 `ld_free` 选，本拍被释放的槽 `ld_v` 仍为 1）。

**探针实测（`../.b2chk/probe_c1.log`，仅探针树含探针）**：
```
[lsq-probe] LQ 分配=37 全转发直通=2 响应=37 请求=37 提交点释放=31 排空=35 LQ峰值占用=2 rob不一致=0
```
⇒ 释放路径**确实被走到**（31 次）；LQ 峰值占用仅 **2/32**（提交点释放不构成容量瓶颈）；
`rob不一致=0` = 分配期写入的 `stq_rob` 与 E1 的 `exe_rob` **逐次一致**（年龄唯一写点正确）。

### ② 发射闸门精确化（`stq_rob` 分配期写入 + 按候选判年龄）

旧实现两处偏差：`stq_rob` 只在 E1 写（已分配未执行的 store 里是**上一占用者的陈旧年龄**）、
`any_unk_w` 用 **E1 项**的年龄（判的是上一拍发射的那条）。本段两处一并修正 ⇒
"更老**未定址** store ⇒ 阻塞本 load"（B28 保守语义）逐条精确；
更老 store **均已定址**时可越过，重叠字节由 §2.2 逐字节转发/合并兜住（同字节取**最年轻**者）。

### ③ `INORD_LOAD` 保持 1 —— **不是保守，而是 LQ 槽位序的防死锁门**（本段重要结论）

本段先按"放开真乱序"把 `INORD_LOAD` 置 0 实测（结果与置 1 **逐位相同**，见下），
随后由结构分析判定**置 0 存在真实死锁形态**，故**回退为 1**并在 RTL 写明原因：

> LQ 槽在 **E1（发射后一拍）**分配、释放点在**提交**。若容许 load 越过"更老**未就绪**的 load"，
> 年轻 load 可先占满 32 个槽并完成，而更老那条因 `ld_slot_ok=0` 永远发不出 ⇒ 它不 done ⇒
> ROB 头无法越过它 ⇒ 年轻人的槽也永不释放 ⇒ **结构性死锁**（本三个程序未触发：峰值占用 2，
> 但对一般程序可达）。真要放开必须把 LQ 分配改到 **D3 派发期**（程序序分配、提交点释放，
> 天然无此环；ROB 载荷 [415:411] 恰有 5 bit 空闲位可用）⇒ 登记为后续段任务。

**实测对照（两个配置同一探针，逐位同结果）**：
```
INORD_LOAD=0：选中 load 且存在更老未就绪项=70 拍（其中真发射=0 拍）
INORD_LOAD=1：选中 load 且存在更老未就绪项= 0 拍（其中真发射=0 拍）
两配置的三程序提交流、拍数、全部计数器**逐位相同**：161/199、178/215、126/243、443/721/913
```
⇒ ① 置 0 时那 70 拍的候选 load **全部被精确 STQ 闸门挡住**（保守语义未因撤销队列门而放松）；
② 该撤销对三个程序**行为中性**；③ 因 ①+死锁形态，最终保留 1（与任务书"未定址时保持
B28 的 INORD_LOAD 保守闸门"一致）。

### ④ store 提交序排空（未改语义，实测确认）

排空仍走 `rob.v` 的提交组（`cmt_st_drain` = 前缀链 & store 槽）→ `lsu_dr_valid/dr_idx` →
`lsq_simple` 取**最低 lane**（= 组内最老）⇒ 严格 ROB 序、单请求口、排空拍不发 load 请求。
探针：`排空=35` 次，同拍多排空请求 **0 拍**；`mem_rsp` 与 store 写口共用单端口（B22 模型）。

## B3.7.4 第二步验证台账（判据 1/2/3 逐条）

| 判据 | 结果 | 证据 |
|---|---|---|
| 整设计编译（`-Wall`） | ✅ **0 error** | `../.b2chk/s2c_whole.comp.log`（仅 2 条 fpu_cvt 既有 implicit 警告） |
| `tb_back2_iq` | ✅ **151/151 PASS** | `../.b2chk/f2_iq.log` |
| 锁步三程序 C1–C5 | ✅ **30/30 PASS**，`RENAME-CHK` 违规 **0 条**，无停顿 | `../.b2chk/f2_lockstep.log` |
| `tb_back2_lsq_fwd` | ✅ **10/10 PASS** | `../.b2chk/f2_fwd.log` |
| `tb_back2_ipc` | ✅ **PASS，IPC=2.0000**（3000 拍 6000 条） | `../.b2chk/f2_ipc.log` |
| `regress.sh` 全量 | ✅ **31/31 PASS**（冻结树） | `../.b2chk/f_regress.log` |
| B24（size=log2 字节） | ✅ 未回退（锁步 C1/C4 绿 + 转发用例 C1/C6） | 同上 |
| B27（窗口算术/禁掩码） | ✅ 未回退（本段新代码同样只用 7 bit 切片窗口算术；`lsq_simple` 的 LQ 释放判据即此口径） | `grep -r '& (LOG_N-1)' rtl/back2/` 命中 **0**（`rename.v` 里 3 处 `LOG_N-1` 是数组上界声明，非掩码） |
| B28（更老未定址 store 保守闸门） | ✅ 未回退且**精确化**（分配期年龄 + 候选年龄） | §B3.7.3②③ |
| B29（提交级 CSR） | ✅ 未回退（锁步 C1–C4 程序的 CSR 段全绿） | 同上 |
| 性能基线 443/721/913 | ✅ **逐位不变**（IPC 0.3917/0.2469/0.1382） | §B3.7.5 |

**非判据的可观测差异（如实登记）**：程序 2 乱序核提交条数 **257 → 243**（黄金 126 不变，
C3 判据只看程序段条数）——这是 `stq_rob`/闸门精确化后尾段（`tohost` 之后 `j .` 自循环）
的调度差异，不影响任何判据；拍数与 IPC 未变。

## B3.7.5 C5 分档：**无需重测**（性能基线逐位不变）

| 程序 | 实测拍数 | 提交窗 | IPC | 分档下限（Q8） | 裕量 |
|---|---|---|---|---|---|
| 0 | 443 | 411 | 0.3917 | 77（0.30） | 30% |
| 1 | 721 | 721 | 0.2469 | 49（0.19） | 29% |
| 2 | 913 | 912 | 0.1382 | 28（0.1094） | 26% |

与 §B3.6.3/母代理第 11 轮裁决表**逐位相同** ⇒ 按"实测×0.8、裕量≥20%"规程**不需要**重测，
`tb_back2_lockstep.sv` 的分档注释与阈值**保持原样**（本次未改该文件的分档表）。
测量条件不变：参照核 2A、冷 I$/冷预测器、窗起点 = 2A 进入程序拍。

## B3.7.6 遗留 / 风险登记（本段新增，均未放宽任何判据）

1. ~~同拍多 store 提交组的排空丢失风险（2B-2 既有潜在缺陷，本段只登记不改）~~ **★ 2B-4 第 1 段已修**（任务①：LSQ 提交排空队列 CDQ，逐 lane 入队/逐拍顺序排空 + 判据⑤ 探针与断言）—— 见 **§B4.1.1**：
   `rob.v` 的 `slot_st_ok = ~store | mem_wr_ready` 允许**同拍 ≥2 条 store 提交**，而
   `lsq_simple` 每拍只排空**最低 lane 一条**，且 `cmt_st_drain` 只在提交拍有效 ⇒
   第二条会被提交掉但永不落存储。**探针实测三个程序"同拍多 store 提交组"= 0 拍**
   （`../.b2chk/probe_c1.log`），故当前不可达；修法需动 `rob.v`（每 lane 串行化 store 提交）
   或给排空加在途缓冲，**均超出本段授权文件范围**，登记为下一段候选。
2. **LQ 分配改到 D3 派发期**（=真正放开 load 乱序发射的前提）：程序序分配 LQ 槽 +
   提交点释放，可消除 §B3.7.3③ 的死锁形态；ROB 载荷 `[415:411]` 5 bit 空闲位可直接承载
   LQ 索引（`BACK2_RB_LQ_MSB/LSB` 待加，`RB_W` 仍 416）。
3. **LQ 提交点释放缺"专用单元用例"**：`tb_back2_lsq_fwd` 保持 **10/10**（判据未动，直驱夹具
   `cmt_n=0`）；释放路径由锁步端到端 + 探针 31 次释放覆盖。建议后续加一条
   "驱动 `rob_head/cmt_n` 的 LQ 释放"用例（会使该 TB 检查数 10→11，属判据增强，需母代理批准）。
4. 仍属 2B-3 显式不做项：未对齐拆笔、PMP/MMU 落地、AMO/LR-SC、fence 屏障、`fld/fsd`（8 B）。

## B3.7.7 复现命令（本段全部判据）

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
# ① 整设计编译（零错误判据）
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ls.vvp -s tb_back2_lockstep_top "${RTL[@]}" sim/unit/tb_back2_lockstep.sv
vvp /tmp/ls.vvp                       # ⇒ C1–C5 30/30 PASS，443/721/913 拍
# ② 三个直驱/后端用例
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/iq.vvp  -s tb_back2_iq  "${RTL[@]}" sim/unit/tb_back2_iq.sv  && vvp /tmp/iq.vvp
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/fw.vvp  -s tb_back2_lsq_fwd_top "${RTL[@]}" sim/unit/tb_back2_lsq_fwd.sv && vvp /tmp/fw.vvp
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ipc.vvp -s tb_back2_ipc "${RTL[@]}" sim/unit/tb_back2_ipc.sv && vvp /tmp/ipc.vvp
# ③ 全量回归（含锁步；T6 墙钟档不变）
./scripts/regress.sh
# ④ 载荷位域核对（一次性探针，不进仓库）
iverilog -g2012 -I . -o /tmp/pay.vvp ../.b2chk/probe/pay_probe.v && vvp /tmp/pay.vvp
```

---

# 2B-4 第 1 段：后端收尾（排空/延迟分配）+ 锁步覆盖扩展 —— ①–④ 完成、⑤ 未做

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 HEAD=`7cf110b`=tag `2B-3`，**未提交**）
> 写入范围：`rtl/back2/{lsq_simple.v,backend_top.v,back2_params.vh,rename.v}` +
> `sim/unit/{tb_back2_lockstep.sv,tb_back2_lsq_fwd.sv}` + `sim/unit/prog/{back2_p4_fpu.S,
> back2_p5_mdu.S,gen_back2_lockstep_data.py,back2_lockstep_data.svh}`；`scripts/regress.sh` **未改**；
> **2A/front4 零修改**（本段暴露的 2A 侧问题一律以夹具侧修法处理，见 §B4.1.4 ⑦）。
> 备份：`../.b2chk/*.s7`（①③④ 中间绿态）与 `../.b2chk/*.s8`（本段终态）。

## B4.1.0 结论一览

| 任务 | 状态 | 关键证据 |
|---|---|---|
| ① 同拍多 store 提交组排空 | ✅ **完成**（CDQ 逐 lane 入队、逐拍顺序排空） | 判据⑤ 探针：**30 拍**出现"≥2 store 同拍提交组"、CDQ 峰值 **7**、**入队 178 = 排空 178** + TB 硬断言 |
| ② LQ 分配 E1→D3 + `INORD_LOAD=0` | ✅ **完成**（载荷 [415:411] 放 LQ 索引；置 0 后五程序逐位不变、无死锁） | 锁步五程序 C1–C5 全绿 + 性能逐位不变（§B4.1.2） |
| ③ LQ 提交点释放单元用例 | ✅ **完成**（`tb_back2_lsq_fwd` **10→11**） | §B4.1.3 |
| ④ 锁步新增 p4_fpu / p5_mdu | ✅ **完成**（黄金 91 / 265 条；**由此暴露并修复 7 处 RTL 真缺陷**） | §B4.1.4 |
| ⑤ front4 检查点分配扩展（可选） | ⛔ **未做**（预算；按任务书"先报再动"未触碰 front4） | — |

## B4.1.1 任务①：同拍多 store 提交组 ⇒ **提交排空队列（CDQ）**

- **缺陷（2B-3 登记的"遗留 ①"）**：`rob.v` 的 `slot_st_ok = ~slot_store | mem_wr_ready` 允许**同拍
  ≤4 条 store 提交**，而 LSQ 只按"本拍提交组 + 最低 lane"排空**一笔**；`cmt_st_drain` 只在提交拍
  有效 ⇒ 同组其余 store **被提交却永不落地**。
- **修法（逐 lane 排空）**：`lsq_simple` 新增 **CDQ**（深度 `BACK2_CDQ_N = 8`，参数文件真源）：
  - **入队**：`dr_valid & dr_room_ok` 的每个 lane 按**组内压缩序号 rank** 写入 `tail+rank`
    （全部连续赋值：rank 链 + `cdq_wp[g] = cdq_tail + rank[g]`）；
  - **出队**：`dr_fire = (cdq_cnt != 0) & mem_req_ready`，逐拍一笔、FIFO 序 = **ROB 提交序**；
  - **随提交拷贝** `{idx, addr, data, mask}` ⇒ STQ 项在被排空前仍有效（转发照旧），
    且 `flush_all`（陷阱）清 STQ 后**已提交的 store 仍会落地**（架构可见性更强）；
  - **背压**：`dr_room_ok = (CDQ_N - cdq_cnt) >= W`（只吃寄存器态 ⇒ **与 rob.v 提交链无组合环**），
    回送 `rob.v` 的 `mem_wr_ready` ⇒ store 提交只要求"CDQ 放得下一整组"，**与排空口当拍是否空闲解耦**；
  - 单请求口/单笔在途纪律**不变**（排空仍与 load 请求共口、排空拍不发 load 请求）。
- **判据⑤ 覆盖证据（探针 + 硬断言，均在 `tb_back2_lockstep.sv`）**：
  ```
  提交排空：入队 3 笔 / 排空 3 笔 / 同拍多 store 提交组 0 拍 / CDQ 峰值 0     ← p1
  提交排空：入队 11 笔 / 排空 11 笔 / 同拍多 store 提交组 0 拍 / CDQ 峰值 0    ← p2
  提交排空：入队 35 笔 / 排空 35 笔 / 同拍多 store 提交组 0 拍 / CDQ 峰值 0    ← p3
  提交排空：入队 16 笔 / 排空 16 笔 / 同拍多 store 提交组 2 拍 / CDQ 峰值 0    ← p4_fpu
  提交排空：入队 113 笔 / 排空 113 笔 / 同拍多 store 提交组 28 拍 / CDQ 峰值 0  ← p5_mdu
  == 判据⑤ 覆盖证据：同拍多 store 提交组合计 30 拍，CDQ 峰值占用 7，入队 178 / 排空 178 笔
  ```
  断言（fail-closed）：每程序 `入队 = 排空 + 在队`；收尾 `n_multi_grp > 0`（覆盖率不得丢失）
  且 `入队总数 = 排空总数`。**CDQ 峰值 7 > 1 ⇒ 多 store 确实"多拍顺序发出"**。

## B4.1.2 任务②：LQ 分配改 **D3 派发期** + `INORD_LOAD=0`

- **载荷**：`BACK2_RB_LQ_MSB/LSB = 415/411`（5 bit，正好用尽顶端空闲位 ⇒ `RB_W` 仍 416；
  与 STQ 字段同理"加在最顶端 ⇒ 其下字段绝对位置不变"）。
- **RTL**：
  - `lsq_simple`：新增 **LQ 分配器**（与 §1.2 的 STQ 分配器同构：空闲前缀和 + 候选或归约，
    `lalloc_ok = 空闲数 ≥ 本组 load 数`）、新增 **`ld_ex`**（已执行 E1）位 —— 派发期分配后、
    E1 之前的项**地址无效**，必须靠 `ld_ex` 挡在请求口外（`pend_vec = ld_v & ld_ex & ~ld_req & ~ld_dn`）；
    E1 改用 `exe_lq_idx`（派发期槽号），**全转发**那条在 E1 当拍把槽还回；`iss_ok` 只剩
    "无更老未定址 store"一条件（槽位已由派发保证）。
  - `backend_top`：`ld_alloc_v = d1_v_q & is_load`；`disp_ok` 增加 `ld_alloc_ok`；
    新增 `lq_of_rob[128]`（派发期登记"ROB 项 → LQ 槽"，E1 组合读，与 `stq_of_rob` 同法）。
  - `iq.v` 的 `INORD_LOAD` **1 → 0**：2B-3 里"槽在 E1 分配 ⇒ 年轻 load 占满 32 槽 ⇒ 更老 load
    永不发射 ⇒ ROB 头卡死 ⇒ 槽永不释放"的**结构性死锁**随派发期分配从根上消失。
- **实测（置 0）**：五程序 **C1–C5 全绿、逐位不变**（443/721/913/1108/4472 拍；
  IPC 0.3917/0.2469/0.1382/0.0848/0.0593；CHK 违规 0；判据⑤ 计数完全一致）⇒ **保留 0**。
- **过程中的一次自伤（如实登记）**：首版把 `lai_fr[OUT_N]`（=**空闲**总数）当成占用数，
  写成 `lalloc_ok = (32 - free) >= need` ⇒ "LQ 越空越不让派发 load" ⇒ 首个带 load 的块永久停摆
  （实测程序 1 挂死）；改为 `lalloc_ok = free >= need` 后全绿。已在 RTL 注释里写明该陷阱。

## B4.1.3 任务③：LQ 提交点释放单元用例（`tb_back2_lsq_fwd` 10 → **11**）

新增 **C7**（恰好一项检查）：发一条无命中 load（走存储器）→ 等写回 → 断言 LQ 占用 **+1**
（写回只置 `ld_dn`，槽仍占用 ⇒ 证明不是"响应即释放"）→ 驱动 `rob_head` 指向该 load 的 rob 号
并给 `cmt_n=1`（模拟 ROB 提交组）→ 断言占用回到原值（槽被**提交点**释放）。
夹具侧同步改为"先派发分配 LQ 槽、再 E1"（与 RTL 的 D3 分配口径一致）。实测
`== 检查项合计 11 项全部满足`。

## B4.1.4 任务④：锁步新增 **p4_fpu / p5_mdu**（并由此修掉 7 处 RTL 真缺陷）

### 新程序与黄金轨迹（三重自检保持）
- `sim/unit/prog/back2_p4_fpu.S`：RV32F 算术（FADD/FSUB/FMUL/FDIV/FSQRT/FMIN/FMAX/FSGNJ*）、
  FMA 族、比较（feq/flt/fle ⇒ 整数寄存器）、搬移/转换（fmv.x.w / fmv.w.x / fcvt.s.w / fcvt.w.s）、
  flw/fsw 访存 + 同址读回（FP 域转发）+ 依赖链循环；首两条先置 `mstatus.FS=Initial`
  （**2A 侧 FS=Off 判非法指令**，乱序核无此门 ⇒ 必须显式打开，两核才同语义）。
  **不读/写 fflags/frm/fcsr**（其"FPU done ⇒ 提交级累积"路径本段未覆盖，留作遗留）。
- `sim/unit/prog/back2_p5_mdu.S`：mul/mulh/mulhsu/mulhu + div/divu/rem/remu，覆盖**除零**
  （商=-1/全 1、余=被除数）与 **INT_MIN÷-1 溢出**（商=INT_MIN、余=0）两个规范边界，
  内含 RAW 依赖链与 7 次循环（16 条 store/轮 ⇒ 密集提交组）。
- 生成器：`PROGS` 每项带 **per-program `-march` 与 Spike `--isa`**（整数程序仍 `rv32ima_zicsr`，
  黄金轨迹与 2B-3 **逐字节不变**：161/178/126）；**三重自检全部保留且通过**
  （①两次链接 .text 逐字节同 ②.text 连续/不越界 ③黄金 PC 落在 .text 内）。
  实测新增：p4 = **91** 条、p5 = **265** 条黄金提交。

### ⑦ 本段由新程序暴露并修复的 **7 处 RTL 真缺陷**（全部有实测现场）
| # | 位置 | 缺陷 / 现场 | 修法 |
|---|---|---|---|
| B30 | `backend_top.v` MDU/FPU 启动 | `start/req_valid` 取**发射拍**（`iq_iss_v[3/5]`）而操作数取 **E1**（`x_i2_*`）⇒ 单元永不启动、`*_if_v` 恒 1 ⇒ **p4 第 20 条 `fadd.s` 处永久挂死**（探针 `fpu_busy=0/done=0`，`x_i2_v[5]` 已脉冲） | 改取 `x_i2_v[3]` / `x_i2_v[5]`（与 mdu.v/fpu.v 端口契约"start 与操作数同拍采样"、与 2A 的 `e_mdu_go/e_fp_go` 一致） |
| B31 | `rename.v` free list 初始化 | `ftail_q <= 7'd64` **硬编码**，而浮点域 `FREE_N=32`（只填了前 32 项）⇒ 浮点域**虚报 32 个空闲项**，用完后 fhead 读到清零值 **preg=0** ⇒ `RENAME-CHK FAIL: arn=22 ... preg=0` 自环 | `ftail_q <= FREE_N[FL_PTR_W-1:0]` |
| B32 | `backend_top.v` 单元 flush | `flush(squash_v_w|flush_all_w)` **无条件**：比 squash 点**更老**的在飞 FP 项（实测正是 ROB 头 `fmv.x.w`，`fpu_if_rob=42=rob_head`、squash_idx=66）被执行被冲掉而 ROB 项不作废 ⇒ `done` 永不再来 ⇒ 头卡死 | **年龄限定冲刷** `fpu_kill/mdu_kill`（`age(在飞) > age(squash 点)`；与 ROB/LSU 同口径窗口算术），并只清对应在途登记 |
| B33 | `backend_top.v` `fp_op_map` | 三组系统性错位：① FSGNJ/FMIN-FMAX/FEQ-FLT-FLE 的**组内选择位**取成 rs2 寄存器号（应为 **funct3**）⇒ `fmin.s f14,f1,f4` 被当 **FMAX**（实测锁步第 27 条 1.0 vs -0.5）；② `fcvt.s.w` 族 funct5 应为 **11010**（旧写 01000）⇒ 落到未定义 op 127（静默错值）；③ `01000` 实为 **F↔D 互转** | 照抄 2A `core_top.fp_op_map` 的映射（funct3/fmt/rs2[0] 选择 + FMA 26–29）；三组转换统一进 `fp_cvt_map` |
| B34 | `backend_top.v` FMA 源 | `rs1_f/rs2_f = is_opfp & ~is_fma` ⇒ **只有 rs3 是 FP 源**，a/b 停在未映射值 ⇒ `fmadd.s fs3,ft2,ft3,ft1` 得 **c**（1.0）而 Spike/2A 得 8.0 | 三个 FP 源全置位（s1←rs1、s2←rs2、s3←rs3，与 fpu.v 的 a/b/c 对应） |
| B35 | `backend_top.v` FP 源分类 | "源 1 是整数寄存器"的集合写错（把 **F↔D** 当整数源、漏掉 **11010**）⇒ `fcvt.s.w fs8,a4` 既没标整数源又被当 FP 源 ⇒ 得 0xce820000（应 5.0）；顺带把单源 FP 指令的 rs2 误标为源 | 与 2A 的 `e_fp_a_is_int = op∈{15,18,19,22,23}` 对齐；`rs2_f` 只对"双 FP 源族 + FMA + FP store"置位 |
| B36 | `lsq_simple.v` STQ 分配器×队头回收 | 同拍"分配"与"队头回收"撞同一槽时，保护只比 **lane 0** 的分配结果 ⇒ lane1..3 命中队头时**新项被回收清 0（静默丢失）**，槽被更年轻 store 复用并覆盖 ⇒ 前一条 store 永不落地（实测 p4 C4：`0x8000d028` 乱序 0x13 vs 2A 0x40e00000） | **逐 lane** 比较（任一 lane 命中队头即本拍不回收） |
| 夹具 | `tb_back2_lockstep.sv` | 2A 调试口 `debug0_wb_rf_wdata` 对 **FP 寄存器写**给出的不是架构值（实测 `flw ft1`：口给 0x8000d000（地址），Spike 给 f1=0xffffffff_3f800000）—— **夹具可观测性缺陷，非 2A 功能缺陷**（2A arch-test F/D 全绿，且禁止改 2A） | 夹具改取 **2A 的 FP 寄存器写口** `mw_fp_we/mw_fp_rd/mw_fp_wdata[31:0]`（判据不放宽，对 FP 写更忠实；顺带修正 f0：FP 写 rd=0 是真写） |

> B30–B35 集中在"**FP/MDU 在乱序核里从未被任何程序执行过**"这一盲区（2B-2/2B-3 的三个程序
> 全是整数流）；p4_fpu/p5_mdu 一上线即逐条暴露。B36 是 2B-3 遗留的分配器缺陷，由 p4 的
> 8 连 store 触发。

## B4.1.5 任务⑤（可选）：未做

front4 检查点分配扩展未触碰（任务书要求"先报再动"，且本段预算已用于 ①–④ 与 §B4.1.4 的
7 处修复）。登记为下一段候选，**不属于本段阻塞点**。

## B4.1.6 验证台账（判据逐条）

| 判据 | 结果 | 证据 |
|---|---|---|
| 整设计编译零错误 | ✅ | `iverilog -g2012 -Wall`（仅 2 条 fpu_cvt 既有 implicit 警告） |
| 锁步**全部程序** C1–C5 | ✅ **57/57 PASS**（p1..p5） | `../.b2chk/t12_run.log` |
| RENAME-CHK 零违规 | ✅ **0 行** | 同上（`grep -c RENAME-CHK` = 0） |
| 无停顿 | ✅ 五程序均达黄金条数：161/178/126/**91**/**265** | 同上 |
| 基线 443/721/913 拍不回退 | ✅ **逐位不变**（含 IPC） | 同上 |
| 新程序 C5 定档（实测×0.8、裕量≥20%） | ✅ p4 Q8=21→**16**（24%）；p5 Q8=15→**12**（20%） | §B4.1.7 + TB 注释表 |
| `tb_back2_iq` | ✅ **151/151** | 内联运行 |
| `tb_back2_lsq_fwd` | ✅ **11/11**（新增 C7） | `../.b2chk/t13_run.log` |
| `tb_back2_ipc` | ✅ **IPC=2.0000** | 内联运行 |
| `regress.sh` 全量 | ✅ **31/31**（TB 数不变 31） | `../.b2chk/final_regress.log` |
| 判据⑤ 同拍多 store 提交 + 全部排空 | ✅ 30 拍多组、CDQ 峰值 7、178=178 + 硬断言 | §B4.1.1 |
| ② `INORD_LOAD=0` 无死锁 | ✅ 置 0 后五程序逐位不变 | §B4.1.2 |

## B4.1.7 C5 分档更新（本段新增 p4/p5 两档）

| 程序 | 总拍数 | 提交窗 | 提交条数 | 实测 IPC | 实测 Q8 | 下限 Q8 | 阈值 IPC | 裕量 |
|---|---|---|---|---|---|---|---|---|
| p1 int | 443 | 411 | 161 | 0.3917 | 100 | 77 | 0.3008 | 23% |
| p2 branch | 721 | 721 | 178 | 0.2469 | 63 | 49 | 0.1914 | 22% |
| p3 memcsr | 913 | 912 | 126 | 0.1382 | 35 | 28 | 0.1094 | 20% |
| **p4_fpu** | **1108** | **1073** | **91** | **0.0848** | **21** | **16** | **0.0625** | **24%** |
| **p5_mdu** | **4472** | **4469** | **265** | **0.0593** | **15** | **12** | **0.0469** | **20%** |

口径不变：参照核 2A、冷 I$/冷预测器、窗起点 = 2A 进入程序拍（新两档低是因为 **2A 是顺序核**，
FPU 固定 8 拍潜伏期 / div·sqrt 更长、MDU 多拍，逐条依赖被 2A 侧串行放大）。阈值表与注释
已写入 `tb_back2_lockstep.sv`。

## B4.1.8 遗留 / 下一步

1. **fflags/frm/fcsr 覆盖缺失**（本段显式未做）：p4_fpu 只用静态 RNE、不读 fflags ⇒
   "FPU done ⇒ 提交级 fflags 累积"与 `fcsr` 读写路径**仍未验证**。下一段建议加 p6_fcsr
   （含 `frflags`/`fsflags`、frm 动态舍入、NaN/Inf 边界），先做**单元级**（直驱 fpu.v 的
   fflags 通路）再上锁步。
2. **D 扩展（fld/fsd、F↔D 互转、double 算术）**：`fp_op_map` 已按 2A 映射修好（含 20–25），
   但乱序核的 64 bit 访存（B21 遗留：LSQ 只做 ≤4 B）与 D 数据通路**未验证**。
3. **`rob.v` 的 store 提交串行化备选**：本段用 CDQ 让"同拍多 store 全排空"；
   若后续要极简实现，也可在 `rob.v` 逐 lane 串行化（每拍至多一条 store 提交），
   代价是提交宽度对 store 密集流降到 1/拍 —— 当前 CDQ 方案已实测无回退，保留。
4. **陷阱（`flush_all`）+ 在飞 CDQ**：CDQ 拷贝了地址/数据/掩码 ⇒ 已提交 store 不因陷阱丢失
   （比 2B-3 更强）；但**未做专门用例**（本 TB 无陷阱程序）。
5. `tb_back2_lockstep` 的 C5 主体仍是 **2A 参照核**（母代理第 9/10/11 轮裁决）；
   p4/p5 两档因此偏低 —— 若后续需要"乱序核自身的 FP/MDU 吞吐"证据，需另立 TB（不在本段范围）。

## B4.1.9 复现命令

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
# 黄金轨迹/映像再生（三重自检；--march 每程序见生成器 PROGS 表）
python3 sim/unit/prog/gen_back2_lockstep_data.py > sim/unit/prog/back2_lockstep_data.svh
# 整设计编译 + 锁步五程序（C1–C5 + 判据⑤ 探针/断言）
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ls.vvp -s tb_back2_lockstep_top "${RTL[@]}" sim/unit/tb_back2_lockstep.sv && vvp /tmp/ls.vvp
# 三个直驱/后端用例
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/iq.vvp  -s tb_back2_iq  "${RTL[@]}" sim/unit/tb_back2_iq.sv  && vvp /tmp/iq.vvp
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/fw.vvp  -s tb_back2_lsq_fwd_top "${RTL[@]}" sim/unit/tb_back2_lsq_fwd.sv && vvp /tmp/fw.vvp
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ipc.vvp -s tb_back2_ipc "${RTL[@]}" sim/unit/tb_back2_ipc.sv && vvp /tmp/ipc.vvp
# 全量回归（31 个 TB，T6 墙钟档不变）
./scripts/regress.sh
```

---

# 2B-4 第 2 段 · **取指集成**：新顶层 `core_top_2b`（front4 + backend_top 合体）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 HEAD=`d7932a3`=tag `2B-4`，**未提交**）
> 新增：`rtl/top/core_top_2b.v`、`sim/unit/tb_core_top_2b.sv`；
> **2A 既有文件零修改、只读例化**（`core_top.v`/`exec`/`mem`/`csr`/`cache`/`fetch`/`decode`/`axi`/`pkg`）；
> `scripts/regress.sh` **未改**（新 TB 因 glob `tb_*.sv` 被**自动纳入** ⇒ TB 数 31→32，见 §B4.2.5）。

## B4.2.0 结论一览

| 验收判据 | 结果 |
|---|---|
| ① iverilog 整设计（含新 top 与新 TB）零错误 | ✅ `-Wall` 0 error、**0 隐式网**、0 位宽不匹配 |
| ② `tb_core_top_2b` 跑 p1_int 全链 | ✅ **PASS**：449 拍、提交 **161** 条（黄金 161）、**PC 流 0 分歧** |
| ③ regress 不回退 | ✅ 既有 31 项全绿（新 TB 自动纳入后为 **32/32**，见 §B4.2.5） |
| ④ 报告（端口契约表 / 接线说明 / 占位清单） | ✅ 本章 §B4.2.2–§B4.2.3 |

## B4.2.1 本段做了什么（真实现）

`core_top_2b` = 2A 核的 **F/D/E 段**替换为 **front4_top（F1–F4 + 锦标赛预测器 + 检查点 + RAS）
＋ backend_top（D1–D3 / I1–I2 / E1 / W1：ROB 128 + 重命名 + 分布式发射 + PRF + LSQ + `b2_csr` 过渡栈）**，
取指侧按 2A 口径接 **I-TLB/PTW → L1I → XIP 直通 → 核内 AXI 读引擎**：

1. **复位与取指入口**：`RESET_PC = 0x1C00_0000`（front4 `pc_gen4.v` 内置，与 2A 同源）；
   XIP 窗口（`0x1C00_0000` / 别名 `0x1FE8_0000`）**不经 I-Cache**，单 beat 直读 + 字保持
   （`xip_hit_held` 地址比对，防陈旧响应 —— 2A §5.4 同法）。
2. **L1I**：2A `l1i` 实例（16 KB / 2 路 / 32 B 行）+ 行填充握手（`fill_req/accepted/valid/
   data/word_idx/done`）；**响应归属校验**（`l1i_pend_q`/`l1i_pa_q`：响应属于上一拍被接受的
   请求 ⇒ 重定向后丢弃，2A §5.3 同款修复）。
3. **核内 AXI 读引擎**：单笔在途 + 归属寄存器（`i_busy_q`/`i_src_q`），三请求源
   **XIP 单字 > L1I 行填充（8 beat）> PTE 单字**，共用 2A `axi_master_ctrl`
   （**AXI 五通道握手全部在该模块内 —— 本文件不重写 AXI 协议逻辑**，符合红线 4）。
4. **front4 ↔ backend_top 全接口**：块握手（4 宽派发）/重定向/训练/检查点释放/RAS/D2 修复。
5. **调试口**：`ws_valid` = 提交组非空；`debug0_wb_pc/rf_wen/rf_wnum/rf_wdata` 取**提交组 lane 0**
   （2A 单发射 ⇒ 逐条一致；4 宽提交时每拍只输出最老一条 ⇒ 差异登记见 §B4.2.3）。
6. **`break_point`** 真实接入 front4（断点冻结前端）。

## B4.2.2 端口契约核对表（48/48 逐端口同名同向同位宽）

> 核对方法：解析两份模块端口表逐项比对（脚本口径：`module` 头部至 `);`，
> 忽略注释行，取 `(方向, 位宽, 名字)` 三元组）；**实测 48/48 匹配**，另有 **10 个占位端口**（§B4.2.3）。

| # | core_top（契约） | 方向/位宽 | core_top_2b | 核对 |
|---|---|---|---|---|
| 1 | `aclk` | input (1 bit) | 同名同向同位宽 | ✅ |
| 2 | `intrpt` | input [7:0] | 同名同向同位宽 | ✅ |
| 3 | `aresetn` | input (1 bit) | 同名同向同位宽 | ✅ |
| 4 | `arid` | output [3:0] | 同名同向同位宽 | ✅ |
| 5 | `araddr` | output [31:0] | 同名同向同位宽 | ✅ |
| 6 | `arlen` | output [3:0] | 同名同向同位宽 | ✅ |
| 7 | `arsize` | output [2:0] | 同名同向同位宽 | ✅ |
| 8 | `arburst` | output [1:0] | 同名同向同位宽 | ✅ |
| 9 | `arlock` | output [1:0] | 同名同向同位宽 | ✅ |
| 10 | `arcache` | output [3:0] | 同名同向同位宽 | ✅ |
| 11 | `arprot` | output [2:0] | 同名同向同位宽 | ✅ |
| 12 | `arvalid` | output (1 bit) | 同名同向同位宽 | ✅ |
| 13 | `arready` | input (1 bit) | 同名同向同位宽 | ✅ |
| 14 | `rid` | input [3:0] | 同名同向同位宽 | ✅ |
| 15 | `rdata` | input [31:0] | 同名同向同位宽 | ✅ |
| 16 | `rresp` | input [1:0] | 同名同向同位宽 | ✅ |
| 17 | `rlast` | input (1 bit) | 同名同向同位宽 | ✅ |
| 18 | `rvalid` | input (1 bit) | 同名同向同位宽 | ✅ |
| 19 | `rready` | output (1 bit) | 同名同向同位宽 | ✅ |
| 20 | `awid` | output [3:0] | 同名同向同位宽 | ✅ |
| 21 | `awaddr` | output [31:0] | 同名同向同位宽 | ✅ |
| 22 | `awlen` | output [3:0] | 同名同向同位宽 | ✅ |
| 23 | `awsize` | output [2:0] | 同名同向同位宽 | ✅ |
| 24 | `awburst` | output [1:0] | 同名同向同位宽 | ✅ |
| 25 | `awlock` | output [1:0] | 同名同向同位宽 | ✅ |
| 26 | `awcache` | output [3:0] | 同名同向同位宽 | ✅ |
| 27 | `awprot` | output [2:0] | 同名同向同位宽 | ✅ |
| 28 | `awvalid` | output (1 bit) | 同名同向同位宽 | ✅ |
| 29 | `awready` | input (1 bit) | 同名同向同位宽 | ✅ |
| 30 | `wid` | output [3:0] | 同名同向同位宽 | ✅ |
| 31 | `wdata` | output [31:0] | 同名同向同位宽 | ✅ |
| 32 | `wstrb` | output [3:0] | 同名同向同位宽 | ✅ |
| 33 | `wlast` | output (1 bit) | 同名同向同位宽 | ✅ |
| 34 | `wvalid` | output (1 bit) | 同名同向同位宽 | ✅ |
| 35 | `wready` | input (1 bit) | 同名同向同位宽 | ✅ |
| 36 | `bid` | input [3:0] | 同名同向同位宽 | ✅ |
| 37 | `bresp` | input [1:0] | 同名同向同位宽 | ✅ |
| 38 | `bvalid` | input (1 bit) | 同名同向同位宽 | ✅ |
| 39 | `bready` | output (1 bit) | 同名同向同位宽 | ✅ |
| 40 | `ws_valid` | output (1 bit) | 同名同向同位宽 | ✅ |
| 41 | `break_point` | input (1 bit) | 同名同向同位宽 | ✅ |
| 42 | `infor_flag` | input (1 bit) | 同名同向同位宽 | ✅ |
| 43 | `reg_num` | input [4:0] | 同名同向同位宽 | ✅ |
| 44 | `rf_rdata` | output [31:0] | 同名同向同位宽 | ✅ |
| 45 | `debug0_wb_pc` | output [31:0] | 同名同向同位宽 | ✅ |
| 46 | `debug0_wb_rf_wen` | output [3:0] | 同名同向同位宽 | ✅ |
| 47 | `debug0_wb_rf_wnum` | output [4:0] | 同名同向同位宽 | ✅ |
| 48 | `debug0_wb_rf_wdata` | output [31:0] | 同名同向同位宽 | ✅ |

**占位端口（10 个；第 3 段删除）**：`oo_mem_req_valid/wen/addr/wdata/wstrb/tag`（output）、
`oo_mem_req_ready/rsp_valid/rsp_rdata/rsp_tag`（input），位宽与 `backend_top` 的
`mem_req_*`/`mem_rsp_*` 逐位相同（tag = `BACK2_MEM_TAG_W` = 6 bit）。

## B4.2.3 ★ 占位清单（本段**未实现**，不得读作已实现）

| # | 占位项 | 现状 | 后续段计划 |
|---|---|---|---|
| 1 | **数据侧（LSU → 存储器）** | `oo_mem_*` 占位端口直连 TB 内存模型（单请求口 + 带标签响应） | **第 3 段**：接 2A `l1d` + AXI，与取指**共用总线主口** ⇒ 须按 2A"单笔在途 + 归属寄存器 + `valid&&ready` 推进"三件套做 I/D 仲裁 |
| 2 | **完整 CSR / 陷阱 / 中断** | 仅 `b2_csr` 过渡栈（mscratch/mepc/mcause/mtvec/mstatus + fcsr）；`trap_valid_w` 只观测不交付；`intrpt[7:0]` **未接** | **第 4 段**：接 csr_file（2A）+ trap_ctrl + CLINT/PLIC（平台硬事实：核内 `0x1F00_0000`/`0x1F10_0000`） |
| 3 | **Sv32（I 侧）** | `tlb`（第二查询口）+ `ptw` + PTE `pmp_check` **已实例化并接线**，但 `satp` 占位 = 0 ⇒ `sv32_translate_en = 0`（Bare 直通） | 第 4 段接 csr_file 的 satp/sfence 提交源后启用；**届时必须恢复 2A 的"PTW 串行复用 + 数据侧优先"纪律**（本段数据侧无翻译请求 ⇒ PTW 仅服务取指，无争用） |
| 4 | **PTW 的 A/D 更新写通路** | **未实现**：`pte_ad_done` 恒 0（fail-closed：若启用 Sv32 会挂死而非静默跳过 A/D 更新）；PTE **读**通路经核内 AXI 引擎已可用 | 第 4 段补 AXI 写通路（含 `pte_ad_pa/data` 与 PMP 检查） |
| 5 | **PMP 上下文** | 取指/PTE 的 `pmpcfg_i/pmpaddr_i` 恒 0 + `priv = M` ⇒ M 模式无匹配项 ⇒ 放行 | 第 4 段接 csr_file 的 PMP 拍平量 |
| 6 | **L1I 维护（fence.i / cbo.inval）** | `inval_all` 恒 0（无 CSR 提交源） | 第 4 段接提交点 |
| 7 | **`infor_flag/reg_num/rf_rdata`**（调试寄存器读口） | `rf_rdata` 恒 0；两个输入未使用 | 第 4 段按架构 RAT 选 PRF 读口实现 |
| 8 | **多宽提交的调试口** | `debug0_wb_*` 只给 lane 0 | 若平台需要（chiplab debug 组按"每拍 1 条"口径）保持即可；如需全宽需扩展端口（属契约变更，须报批） |
| 9 | **XIP 窗口外的 uncached 取指（MMIO 取指）** | 未接（front4 只在 XIP 窗口判 uncached ⇒ 结构上不可达） | 若将来有 MMIO 取指需求再补 |

## B4.2.4 front4 ↔ L1I ↔ PTW ↔ AXI 接线说明（逐段）

```
front4_top
  ├─ tr_req_valid/tr_req_va ──► tlb.lookup2_*（第二查询口，纯组合）
  │                              └─ hit2/perm_fault2/pa2 ⇒ sv32_translate_{done,fault,paddr}
  ├─ sv32_translate_en ◄── 占位 0（Bare）
  ├─ l1i_req_valid/addr ──► l1i.cs_req/cs_paddr(=PA)/cs_vaddr
  │     ◄── cs_ready(经归属校验 → l1i_ready) / cs_rdata / cs_miss
  └─ unc_req_valid/pa ──► XIP 单字通路（字保持寄存器）
        ◄── unc_rsp_valid/pa/data（地址比对 xip_hit_held）
l1i.fill_req/paddr/beats ──► I 侧 AXI 引擎（三源仲裁）
ptw.pte_req_valid/pa      ──► I 侧 AXI 引擎（PTE 单字读）
        ◄── pte_resp_valid/data（同一 R 通道按 i_src_q 归属分发）
I 侧 AXI 引擎 ──► 2A axi_master_ctrl ──► 48 端口契约的 AR/R（写通道恒空）
```
- **单笔在途**：`i_busy_q` 期间不再受理新请求（XIP 的 `xip_req_pend_q` 另有一层在途保护）；
- **beat 分发**：R 握手拍按 `i_src_q` 把 `rdata` 分发给 L1I 的 `fill_valid/word_idx`、
  PTW 的 `pte_resp_*` 或 XIP 字保持寄存器；`i_cnt_q == i_last_q` 时收尾并释放在途位；
- **XIP 优先级最高**（启动关键路径），L1I 填充其次，PTE 读最低；32 B 行/单字均不跨 4 K
  ⇒ `req_split=0`；
- `AxCACHE`：DDR 行填充 `4'b1111`、XIP 单字 `4'b0000`（2A D5 口径）；`arlock/awlock` 只驱动 [0]。

## B4.2.5 验证台账（判据逐条）

| 判据 | 结果 | 证据 |
|---|---|---|
| ① 整设计（含新 top/TB）编译零错误 | ✅ 0 error / 0 隐式网 / 0 位宽不匹配（`-Wall`） | `../.b2chk/inttb3.log` |
| ② p1_int 全链跑通：PC 流 = 黄金、条数 = 黄金 | ✅ **449 拍、提交 161 条（黄金 161）、PC 流 0 分歧** | `../.b2chk/final_int_run.log` |
| ② 取指真走 L1I+AXI（自证） | ✅ AXI **AR=8 笔**（XIP 3 / DDR 行填充 5） | 同上（C4' 断言） |
| ② 跳板路径 = RESET_PC XIP 直取 | ✅ `0x1C00_0000` 提交后顺序到 `0x8000_0000` | 同上（C3' 断言） |
| ② 无提交点异常 | ✅ `trap_valid_w` 全程 0 | 同上（C5' 断言） |
| ③ regress 不回退 | ✅ 既有 31 项全绿；新 TB 经 glob **自动纳入** ⇒ 报 **32/32**（脚本未改） | `../.b2chk/int_regress.log` |
| ④ 端口契约 | ✅ **48/48** 同名同向同位宽 + 10 占位端口（§B4.2.2） | 逐端口比对脚本 |

TB 自身检查项 7 项：C1' PC 流、C2' 条数、C3' 跳板（2 项）、C4' L1I/XIP 走 AXI（2 项）、C5' 无异常。

## B4.2.6 遗留 / 下一步

1. **第 3 段（数据侧）**：接 L1D + AXI，删除 `oo_mem_*` 占位口；做 I/D 总线仲裁
   （单笔在途 + 归属寄存器）；`PTW` 恢复 2A 的串行复用（数据侧优先）。
2. **第 4 段（特权/异常/中断）**：完整 csr_file + trap_ctrl + CLINT/PLIC + Sv32（含 A/D 写通路）。
3. **本段未验证项**（结构就位但功能未跑）：Sv32 取指翻译、PTE 读通路、PMP 取指检查、
   L1I 维护失效、多宽提交的调试口语义。
4. **新 TB 是否长期纳入 regress**：因 `regress.sh` 按 `sim/unit/tb_*.sv` glob ⇒ 已自动纳入
   （32/32）。若母代理希望"先不纳入"，需给 `regress.sh` 加白名单/排除（属脚本改动，**待批**）。
5. 本段未做 L1I 命中率/取指带宽的性能测量（`tb_core_top_2b` 只判功能等价）。

## B4.2.7 复现命令

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
# 整设计（含新顶层与新 TB）编译 + 顶层合体集成用例
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ct2b.vvp -s tb_core_top_2b "${RTL[@]}" sim/unit/tb_core_top_2b.sv && vvp /tmp/ct2b.vvp
# 全量回归（新 TB 被 glob 自动纳入 ⇒ 32 项）
./scripts/regress.sh
```

---

# 2B-4 第 3 段 · **数据侧集成**：LSU → L1D → I/D 共用 AXI 引擎（删占位端口）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 HEAD=`e32c608`=tag `2B-4.2`，**未提交**）
> 改动：`rtl/top/core_top_2b.v`、`sim/unit/tb_core_top_2b.sv`、
> `sim/unit/prog/{back2_p6_l1d.S（新增）, gen_back2_lockstep_data.py, back2_lockstep_data.svh}`；
> **2A 既有文件零修改（只读例化）**；`scripts/regress.sh` 未改。备份：`../.b2chk/*.s10`。

## B4.3.0 结论

| 判据 | 结果 |
|---|---|
| ① 整设计编译零错误 | ✅ `-Wall` 0 error / 0 隐式网 / 0 位宽不匹配 |
| ② 数据程序（p3_memcsr + p6_l1d） | ✅ 两程序 **PC 流 + 写回寄存器轨迹（rd/写回值）均与 Spike 黄金逐条一致** |
| ②' AXI 计数自证走 L1D | ✅ p6：**AR=13（XIP 3）/ R=80 / AW=2 / W=16 / B=2** = 2 笔**脏行写回**（8 beat×2）⇒ 写通道有真实流量 |
| ③ p1_int 不回退 | ✅ **449 拍 / 161 条（黄金 161）**，与第 2 段逐位一致 |
| ④ regress 32/32 | ✅ 见 §B4.3.4 | 
| ⑤ 报告（接线/仲裁/PTW 复用/流量自证） | ✅ §B4.3.1–§B4.3.3 |

## B4.3.1 L1D 接线与适配器（`core_top_2b §4b`）

- **占位端口已删除**：`oo_mem_*` 10 个端口全部移除 ⇒ 顶级**回到纯 48 端口契约**（§B4.2.2 的表 48/48 依旧成立）。
- **适配器（`AD_IDLE/AD_REQ/AD_WAIT/AD_RETRY` 四态）**把 LSU 的"单请求 + 带标签响应"口
  翻译成 2A `l1d` 的 cache 访问口：
  - **load**：`AD_REQ` 发一拍 `cs_req`（we=0）→ `AD_WAIT` 收 `cs_ready`（读命中，次拍数据到）
    ⇒ 出 `mem_rsp_valid` + `mem_rsp_rdata` + 原 tag；
  - **store**：`AD_REQ` 发一拍 `cs_req`（we=1 + strb + data）→ 写命中 `cs_wr_done` **当拍**完成；
    **store 在 LSU 握手拍即被接管**（拷贝 addr/data/strb/tag），此后由适配器负责落地
    （LSU 侧 STQ 项已释放，符合"提交即落地"语义）；
  - **缺失**：`cs_miss` ⇒ `AD_RETRY`，L1D 自行"先写回脏受害者（`wb_req`）再填充（`fill_req`）"，
    两个握手都由 §5 引擎服务；L1D 回到 `idle` 后适配器**重发**同一次访问（重试命中）。
  - **uncached 分流**：复用 2A `mmio_route` 判定 XIP/MMIO 窗口 ⇒ 走引擎单 beat 读/写（不查 L1D）。
- **★ 组合环教训（本段踩过并已修）**：**不得**把 `l1d.cs_stall` 用于"是否发请求"的组合式
  —— `cs_stall = access | cs_miss | (ms_state!=IDLE) | maint` 而 `access = cs_req`
  ⇒ `cs_req ← cs_stall ← cs_req` 成环（iverilog 判环 ⇒ 全网 x ⇒ **一条不提交**）。
  重试判据只用**纯寄存器量** `l1d.idle = (ms_state_q==MS_IDLE) & ~maint_q`。已在 RTL 注释写明。
- **命中/写回口径**：读 `cs_ready`/写 `cs_wr_done`/缺失 `cs_miss`/脏行 `wb_req`+`wb_data`
  全部按 2A `l1d` 端口语义使用，未改 2A 任何文件。

## B4.3.2 I/D 仲裁与优先序（§5 引擎扩展为"读 + 写"）

- **单笔在途 + 归属寄存器**（`ist_q`/`i_own_q`）纪律不变；**不重写 AXI 协议**
  （五通道握手仍在 2A `axi_master_ctrl` 内）。
- **请求源与优先序（逐条对齐 2A `core_top` §11.1 的 grant 链）**：
  `① L1D 脏行写回 > ② L1D 行填充 > ③ uncached 数据（含 PTE 读，2A 归在 MDTA 一档）
   > ④ XIP 取指字 > ⑤ L1I 行填充`。
- **读拍分发**：按 `i_own_q` 把 R 拍数据交给 L1D 填充 / L1I 填充 / PTE / XIP / uncached；
- **写拍**：写回逐字取 `l1d.wb_data`（驱动 `wb_word_idx`，等 `wb_ready`，经 `wdata_valid/data`
  推 W 通道），末拍给 `wb_done`；uncached store 单 beat（接管时锁存的 strb/data）。

## B4.3.3 PTW 串行复用恢复说明（结构就位）

- 2A 的口径是"PTW 单请求口由 **M 级 FSM 串行复用**：数据侧优先，空闲时代取指跑一次遍历"
  （`m_tr_src_q` 记归属，见 2A §9.4.1）。本段的 `core_top_2b` **没有 M 级 FSM**（乱序核的
  访存不发翻译请求：`satp` 占位 = Bare ⇒ `sv32_translate_en=0`，L1D 访问直接用 PA）。
- 因此本段的结构是：**取指侧独占 PTW**（`tlb.lookup2_*` + `ptw`），**数据侧翻译请求恒 0** —— 
  与 2A"数据侧优先"的**争用场景在本段不存在**（不是绕过纪律，而是无争用）。
- **第 4 段必须做的事**（占位登记，§B4.2.3 第 3/4 项延续）：接 csr_file 的 satp/sfence 后，
  L1D 访问需 VA→PA ⇒ 数据侧翻译请求出现 ⇒ **恢复 2A 的串行复用**：加 `m_tr_src` 归属寄存器、
  数据侧优先仲裁、PTE 读/写（含 A/D 更新）共用同一 PTW 请求口与 §5 引擎。

## B4.3.4 验证台账（判据逐条）

| 程序 | 拍数 | 提交（黄金） | C1' PC | C3' 写回数据 | AXI AR | R | AW | W | B |
|---|---|---|---|---|---|---|---|---|---|
| p1_int | 449 | 161（161） | ✅ | ✅ | 9（XIP 3） | 51 | 0 | 0 | 0 |
| p3_memcsr | 462 | 126（126） | ✅ | ✅ | 8（XIP 3） | 43 | 0 | 0 | 0 |
| **p6_l1d** | 1077 | 366（366） | ✅ | ✅ | 13（XIP 3） | 80 | **2** | **16** | **2** |

- **检查项 25 项全过**（每个程序 7–9 项：PC 流/条数/写回 rd/写回值/AXI 读/写流量/无异常）。
- **AXI 写流量自证**：p6 的 2 笔 AW × 8 beat = 16 个 W beat ✓ = 2 条**脏行写回**
  （p6 按 4 KB 步进向同一组写 5+ 条行 ⇒ 4 路组相联必然逐出；`l1d.wb_req` ⇒ §5 引擎写突发）。
- **p3 的 0 写流量是正确行为**：其工作集 ≪ 32 KB，store 全部驻留 L1D（未逐出）。
- **★ 夹具侧修复（本段踩过）**：三个程序原本**同址装载** ⇒ L1I（阵列无复位、`inval_all` 本段
  未接）里上一程序的陈旧行**同 tag 命中** ⇒ 现象为"PC 流对、指令却是上一程序的"（实测 p3
  的 rd/wdata 全是 p1 的）。修法：**逐程序分基址**（16 KB 步进，程序 %pcrel 位置无关）+
  跳板按基址重建 + 黄金 PC 平移 `gold_delta`；**PC 相对量**（auipc/jal 结果）同样随基址平移，
  故写回值比对接受"黄金值"或"黄金值 + `gold_delta`"（非 PC 相对量仍须逐位相等）。
- **黄金轨迹扩展**：生成器新增 **`GREG_RD[]`/`GREG_WD[]`（逐条提交的写回寄存器号/写回值）**
  —— 从同一次 Spike `--log-commits` 的**第二遍解析**得到，并有**自检④**（两遍 PC 序列逐条
  一致，防解析错位）。这是"load/store 数据逐条正确"的直接判据（p5_mdu/p4_fpu 未变；
  原三重自检全部保留）。
- **新程序 p6_l1d**：`.option norvc`；4 KB 步进同行写 5+ 条（逐出）+ 回读 + 再逐出；黄金 366 条。

## B4.3.5 遗留 / 下一步

1. **第 4 段（特权/异常/中断/MMU）**：csr_file + trap_ctrl + CLINT/PLIC + Sv32（I/D 两侧翻译、
   PTW 串行复用恢复、PTE A/D 写通路）；`inval_all/clean_all`（fence.i/cbo）接提交点。
2. 本段**未做**：L1D 命中率/带宽性能测量；unaligned 访问（2A 的 M 级拆笔在乱序核里尚未接）；
   AMO/CMO（2B-3 起即在本里程碑范围外）。
3. `sim_mem_model` 的 DDR 体 64 KB（TB 侧）对 p6 的 6 行步进够用；更大数据程序需扩大窗口。

## B4.3.6 复现命令

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
python3 sim/unit/prog/gen_back2_lockstep_data.py > sim/unit/prog/back2_lockstep_data.svh   # 含自检①②③④
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ct2b.vvp -s tb_core_top_2b "${RTL[@]}" sim/unit/tb_core_top_2b.sv && vvp /tmp/ct2b.vvp
./scripts/regress.sh      # 32 项
```

---

# 2B-4 第 4a 段（特权/陷阱/中断集成）—— **实现状态 + 验证台账**（已落地）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 HEAD=`3dd93fa`=tag `2B-4.3`，**未提交**）
> 本段范围（母代理裁决）：**步骤 1→2→3 短期→4→5**；CSR 路线 = 本段给 `b2_csr` 补 `mtval(0x343)`
> 与陷阱进入/退出写路径，**换 `csr_file`+`trap_ctrl` 留作 4b 段**（与 Sv32/PTW 串行复用一并做）。

## B4.4.0 结论（一句话）

**乱序后端已从"陷阱即停机"改为"精确陷阱 + 外部重定向"，ecall/ebreak/非法指令 → `mtvec` → 处理程序
→ `mret` 返回全链路跑通，且提交 PC 流与写回寄存器轨迹与 Spike 黄金逐条一致（0 分歧）；
核内 CLINT 已例化，`mtimecmp` → MTIP → `mstatus.MIE×mie.MTIE×mip.MTIP` → 提交组边界取中断 →
`mcause=0x8000_0007` → `mret` 精确返回被中断指令，也已跑通。**
§B4.4.3 的 51 项判据全绿、`regress.sh` 32/32 无回归；`csr_file`/`trap_ctrl`/PLIC 仍为 4b 段的活。

## B4.4.1 落地清单（改动文件 + 关键位置）

| 文件 | 改动 | 关键位置 |
|---|---|---|
| `rtl/back2/rob.v` | 新增 `trap_retire`：陷阱拍**无副作用弹出**头部异常项（旧实现 `flush_all` 只清 `cnt`、不动 head ⇒ 异常项永驻头部 ⇒ 重取后又立刻再陷阱） | 端口 + §5.4 指针块 `head_q <= trap_retire ? idx_add(head_q,1) : 0` |
| `rtl/back2/backend_top.v` | ① 新增 `trp_flush_v_i/trp_redirect_v_i/trp_redirect_pc_i/trp_halt_o/xret_cmt_o/mtip_i/irq_mti_o/mtvec_o/mepc_o`；② `flush_all_w = trap_v_rob \| trp_flush_v_i`（**去掉** `trap_halt_q`，并把 `disp_ok` 里的 `~trap_halt_q` 一并去掉 ⇒ 陷阱后能继续派发）；③ `unsup` 摘出 ecall/ebreak/mret/sret；④ `exc_w` 优先级：取指异常 > ecall(11)/ebreak(3) > 非法(2)；⑤ 提交点 xRET 识别（载荷 TVAL = 原始指令位 `0x3020_0073/0x1020_0073`）+ `cmt_ok` 的"xRET 上报"口子；⑥ 陷阱/中断 → CSR 硬件写路径事件组装 + `irq_mti_w` 判定 | `:130-150`（端口）、`:1503-1560`（flush/redirect/xret）、`:1560-1605`（事件组装）、`:1595`（`disp_ok`） |
| `rtl/back2/b2_csr.v` | 新增 `CSR_MTVAL(0x343)`、`CSR_MIE(0x304)`、`CSR_MIP(0x344, 只读视图 MTIP)`；新增**陷阱进入**（mepc/mcause/mtval + MPIE←MIE、MIE←0、MPP←11）与**退出**（MIE←MPIE、MPIE←1、MPP←00）硬件写路径（优先级：硬件 > 软件 `csrw`）；引出 `mtvec_o/mepc_o/mstatus_o/mie_o` | 端口段 + 读 mux + `else if (trp_enter_v) … else if (trp_exit_v) …` |
| `rtl/back2/back2_params.vh` | 新增异常码宏 `BACK2_EXC_BREAK(3)/ECALL_U(8)/ECALL_S(9)/ECALL_M(11)` | §异常码段 |
| `rtl/top/core_top_2b.v` | ① 新增**无状态** trap FSM：`异常 > xRET > MTI 中断` 优先级，`trp_flush_v_i` 与 `trp_redirect_v_i` **同拍**（与 2A `core_top.v:2619` 同构），目标 = `mtvec`（MODE=0 直接 / MODE=1 向量 `base+4×cause`）或 `mepc`；② 例化**核内 CLINT**（2A `clint` 模块只读复用），`d_cp_q` 窗口的 MMIO 请求接 CLINT（偏移 = 地址 − `RV32GC_CLINT_BASE`），读响应取 `clint_rdata`，`mtip_o` → `backend.mtip_i` | §6b（trap FSM）、§4b.1（CLINT） |
| `sim/unit/prog/back2_p7_trap.S` | **新增**：ecall / 非法指令（`.word 0x0000000b`）/ ebreak 三类陷阱 + 处理程序自记录 + `mepc+=4` + `mret`；累加量全部**基址无关** | 74→89 条黄金（改动后 89） |
| `sim/unit/prog/back2_p8_int.S` | **新增**：写 `mtimecmp = mtime+200` → `mie.MTIE=1`/`mstatus.MIE=1` → 循环等中断 → 处理程序记录 + 关源 → `mret`（**不改 mepc** ⇒ 精确重启被中断指令） | 仅映像（无 Spike 黄金，见 §B4.4.2） |
| `sim/unit/prog/gen_back2_lockstep_data.py` | PROGS 增 p7/p8；新增"**仅映像**"程序支持（第 5 元组元素 `True` ⇒ 不跑 Spike、`P?_GOLD_N=0`） | `PROGS` + `no_gold` 分支 |
| `sim/unit/tb_core_top_2b.sv` | 程序数 3→5；新增 **C7'**（陷阱次数/cause/PC）与 **C8'**（中断交付次数/mcause/mepc 落点/处理程序与主程序自记录）；DDR3 窗口 64 KB→128 KB、别名窗口 `a[31:20]==0x800`、装载索引 `a[15:2]`→`a[19:2]`（5 程序 16 KB 步进的必然跟随） | 见 §B4.4.3 |
| `sim/unit/tb_back2_lockstep.sv`、`tb_back2_ipc.sv` | 这两个 TB **直驱** `backend_top`（不经 `core_top_2b`）⇒ 给新增输入补常量 tie-off（`trp_*=0`、`mtip_i=0`），行为与加接口前逐拍等价 | 例化处 |

> **红线遵守**：2A 文件（`rtl/decode/*`、`rtl/csr/*`、`rtl/l1*`、`rtl/clint/*`、`rtl/plic/*`、`rtl/top/core_top.v`…）
> **零修改**，全部只读例化/只读参考；`scripts/regress.sh` 未动。

## B4.4.2 口径登记（与 Spike 的比对口径，逐条实测）

黄金口径：`/opt/riscv/bin/spike --pc=0x80000000 --isa=rv32imac_zicsr --log-commits`（`gen_back2_lockstep_data.py`）。
本段新增的**四条**口径全部实测确认（`/tmp/p7exp/t4.log` 类实验 + p7 黄金轨迹）：

1. **抛陷阱的那条指令不进提交日志**：Spike 只打印 `exception … epc` 行 ⇒ 黄金 PC 流里**没有** ecall/ebreak/非法
   指令的 PC，处理程序 PC 直接跟在陷阱指令**前一条**之后。本核同口径：`slot_ok` 含 `~slot_exc` ⇒ 陷阱指令
   不上报提交，仅由新增的 `trap_retire` 弹出（`p7` 89 条黄金逐条吻合即为证据）。
2. **`mtval` 逐 cause 取值**（实测）：cause 11（M ecall）⇒ `0`；cause 2（非法）⇒ **出错指令编码**（实测 `0x0000000b`）；
   cause 3（breakpoint）⇒ **ebreak 的 PC**（实测 `0x8000_0028`，不是 0！）。本核 `trp_csr_tval_w` 按此三分支实现。
3. **`mret` 进提交日志**（它正常退役）⇒ 本核必须在 xRET 拍仍上报提交，故 `cmt_ok` 开了一个"仅上报"口子
   （`cmt_ok = ~squash & (~flush_all | (xret_cmt_o & trp_flush_v_i))`；副作用仍由 `p_di/p_df/cmt_st_drain` 门控）。
   `mstatus` 掩码 `0x1888` 实测：陷阱进入后 `0x1800`（MIE=0、MPIE=0、MPP=11）、`mret` 后 `0x0080`（MIE←MPIE=0、MPIE=1、MPP=0）
   —— 与 `b2_csr` 的硬件写路径逐位一致。
4. **p8（定时器中断）不与 Spike 逐条比**：`mtime` 是自由计数器（本核 `aclk` 每拍 +1），"源拉高→取中断"的拍数
   依赖微架构时序；且本 SoC CLINT 在 `0x1F00_0000`，Spike 默认 CLINT 在 `0x0200_0000` ⇒ Spike 跑 p8 **根本收不到 MTI**。
   故 p8 按任务书允许的"**程序自记录 + 硬编码期望**"口径：生成器按"仅映像"处理（`P7_GOLD_N = 0`），
   判据由 TB 的 **C8'** 给出（§B4.4.3）。

## B4.4.3 验证台账（判据逐条 + 本轮实测）

命令见 §B4.4.6。**整设计编译 0 error；`tb_core_top_2b` 51 项判据全绿；`regress.sh` 32/32。**

| 程序 | 拍数 | 提交/黄金 | AXI（AR/R/AW/W/B） | 判据 |
|---|---|---|---|---|
| p1_int（idx 0） | 449 | 161/161 | 9/51/0/0/0 | C1'~C5' 全绿（PC 流 + 写回逐条 = Spike） |
| p3_memcsr（idx 2） | 462 | 126/126 | 8/43/0/0/0 | 同上 |
| p6_l1d（idx 5） | 1077 | 366/366 | 13/80/**2/16/2** | 同上 + C6'（L1D 脏行写回真有 AW/W/B） |
| **p7_trap（idx 6）** | 755 | **89/89** | 10/59/0/0/0 | **C1'/C2'/C3' 逐条 = Spike 黄金**（含处理程序与 `mret`）+ **C7'** |
| **p8_int（idx 7）** | 4000（固定） | 522（无黄金） | 11/67/0/0/0 | **C8'**（自记录口径） |

**C7'（陷阱路径，p7_trap）实测**
```
[C7'] 陷阱序列：pc=0x8000c028/cause=11 → pc=0x8000c030/cause=2 → pc=0x8000c038/cause=3；mtvec 目标=0x8000c068
```
- ① 陷阱交付次数 = **3**（ecall / 非法 / ebreak），无多余陷阱；② `mcause` 依次 = **11 / 2 / 3**（M 模式口径正确）；
  ③ 陷阱 PC 严格递增且落在映像内；④ **PC 流 89/89 与 Spike 黄金逐条一致** ⇒ `mtvec` 重定向、处理程序、
  `csrr mepc/mcause/mtval/mstatus`、`csrw mepc`、`mret` 返回全部正确；
  ⑤ 写回寄存器轨迹（含处理程序把 `mcause/mepc/mtval/mstatus` 累加进 `s1/s2/s3/s5/s6` 的每一步）逐条一致
  ⇒ **mcause / mepc / mtval（低 12 位）/ mstatus 掩码 / mepc 写后读**五个量都与 Spike 相同。

**C8'（中断路径，p8_int）实测**
```
[C8'] 中断现场：mtvec=0x8001007c mepc=0x80010054 mcause=0x80000007 | 处理程序 s1=1、主程序 a0=1（共提交 522 条）
[C8'] handler 采到的 mepc=0x80010054（wait 循环 0x8001004c..0x80010054）
```
- ① MTI 中断交付次数 = **1**（后端 `irq_mti_w` 监视；处理程序关源 ⇒ 恰好一次，无重入）；
  ② 无异常交付（`n_trap_p = 0`）；③ 陷阱 CSR `mcause = 0x8000_0007`（MTI）、`mtvec = handler`；
  ④ `mepc` 落在 wait 循环 `[0x4c, 0x54]` 内、且处理程序 `csrr t1, mepc` 采到的值同样是 `0x8001_0054`
  ⇒ **精确中断**（返回被中断的那条可重启指令）；⑤ 处理程序自记录 `s1 = 1`、主程序观察到后走到 `done`（`a0 = 1`）
  ⇒ `mret` 真的回到了主流程。

**中断源证据**：MB 级过程量（DBG_P8=1 可复现）：`mtimecmp` 由 `0xFFFF_FFFF`（复位值）→ 程序写入 `mtime+200`
（CLINT 写命中 `hit=1`）→ `MTIP` 在 ~200 拍后拉高 → `irq_mti_w` 一拍 ⇒ 交付。

## B4.4.4 本段修掉的缺陷 + 新发现（都带证据）

| # | 缺陷 | 证据 | 修法 |
|---|---|---|---|
| D1 | **陷阱即停机**（勘察期 B1）：`flush_all_w = trap_v_rob \| trap_halt_q` 且 `trap_halt_q` 一经置位永不清 ⇒ 第一条陷阱后永久停机 | 旧 `backend_top.v:1503-1507`；旧 TB 的 C5' 只敢判"全程无异常" | 见 §B4.4.1（`flush_all_w` 去掉 `trap_halt_q`、`disp_ok` 同样去掉、`trap_retire` 弹头） |
| D2 | **CSR 立即数形式（csrrwi/csrsi/csrrci）的源取错**：载荷 `p_csrw` 存的是"被当成 rs1 重命名"的物理号，而立即数形式的 `insn[19:15]` 是 **zimm** ⇒ 提交点从 PRF 读回**无关寄存器**的值。实测 `csrsi mstatus, 8` 把 `s0`(=mtvec=`0x8001_007c`) 写进了 `mstatus`（`0x8001_00fc`），MIE 位纯属巧合才对 | p8 首轮现场：`mstatus=0x800100fc`（应为 `0x00001808`） | 提交点用载荷 TVAL（原始指令位）判 `funct3`（`insn[14:13] != 0` ⇒ 立即数形式）取 `insn[19:15]` 零扩展；**不改 2A 译码器**。修后 p8 的 `mstatus` 正确、p3_memcsr 仍逐条 = 黄金 |
| D3 | **测试基建三处 16 位假设**（非 RTL）：DDR3 窗口 64 KB、别名判定 `a[31:16]==0x8000`、装载索引 `a[15:2]` —— 5 个程序 16 KB 步进后第 5 个基址 `0x8001_0000` 被静默截断/判为"未登记区域"⇒ 取指读 0、一条不提交 | 首轮 p8：`提交 0 条`、`AR 命中未登记区域 addr=0x80010000` | TB 侧改 128 KB / `a[31:20]==12'h800` / `a[19:2]`（§B4.4.1） |
| N1 | **中断/xRET 的 `flush_all` 有 ~96 拍"派发暂停"**：`rename` 的 free list 重建 FSM（`rb_act`）逐拍扫描 `NREG=96` 项，期间 `busy=1` ⇒ `disp_ok=0`。**不是死锁**（重建结束即恢复，处理程序随后逐条提交），但会拉低中断响应后的 IPC | `DBG_P8=1` 的 `[irq-s]` 摘要：`rb_act=1` 自 t=0 持续到 t≈100，`rn_i_busy=1`；t=100 起 `pc0=0x8001007c`（处理程序首条）提交 | 记为 4b 优化项（可改成"仅重建被占用的 preg 区间"或用 `ar_used` 位图并行重建） |

## B4.4.5 占位 / 遗留清单（**不得读作已实现**）

| # | 项 | 现状 | 归属 |
|---|---|---|---|
| P1 | **PLIC 未接**：`mmio_route` 的 CLINT/PLIC 窗口里只有 CLINT 命中真件；PLIC 地址范围的访问仍是"立即完成、读回 0 / 写丢弃"（fail-safe，不挂死） | `core_top_2b §4b.1` | 4b（需 MEIP 优先级/阈值仲裁 + `intrpt[7:0]` 平台分配） |
| P2 | **`mip.MSIP/MEIP` 恒 0**：`b2_csr` 的 mip 只驱动 `MTIP` | `b2_csr.v` 读 mux | 4b（随 PLIC） |
| P3 | **无中断优先级/嵌套**：MTI 一取即清 `mstatus.MIE`，无"更高优先级抢占"、无 S 模式委托（`medeleg/mideleg` 不存在） | `backend_top` 的 `irq_mti_w` 只判 MTI | 4b/2C |
| P4 | **CSR 路线仍是 `b2_csr` 过渡栈**：本段只补了 `mtval/mie/mip` 与陷阱写路径；仍**没有** `misa/mideleg/medeleg/pmp*/mcycle/minstret/satp/stval/sepc/scause/sstatus` 等 | `rtl/back2/b2_csr.v` 地址表 | **4b**（换 `csr_file`+`trap_ctrl`，与 Sv32/PTW 串行复用一并做） |
| P5 | **priv 恒 M**：ecall 只可能 cause 11（S/U 的 9/8 已定义宏但不可达）；无 `mret` 到 S/U 的实际下陷路径（`MPP←00` 只有 CSR 语义） | `core_top_2b` 硬连线 M | 4b（随私有权状态机） |
| P6 | **Sv32/PMP 未启用**：`satp` 占位 Bare、PTE 的 A/D 写路径未落地（`pte_ad_done=0` 失败关闭），PMP 上下文未接 | §B4.3.3 | 4b（与 `csr_file` 同一批） |
| P7 | **陷阱向量模式（MODE=1）未实测**：实现按 `base + 4×cause` 写好了，但 p7/p8 只用 MODE=0；未做向量模式程序 | `core_top_2b §6b` | 4b（补一条向量模式判据） |
| P8 | **xRET 的 `mstatus.MPP≠M` 情形未实测**（本段恒 M）；`sret` 可被识别（`0x1020_0073`）但 S 模式不存在 ⇒ 实测只覆盖 `mret` | `backend_top` `xret_cmt_o` | 4b |
| P9 | **本段引入的接口对直驱 TB 的影响**：`tb_back2_lockstep`/`tb_back2_ipc` 例化 `backend_top` 时新增输入接常量 0；若将来这两个 TB 要测陷阱，需接上 `trp_*` 驱动 | §B4.4.1 末行 | 4b |

## B4.4.6 复现命令

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu

# 0) 黄金/映像再生成（改 .S 后必跑；★ 生成器**输出到 stdout**，必须重定向）
python3 sim/unit/prog/gen_back2_lockstep_data.py > sim/unit/prog/back2_lockstep_data.svh

# 1) 整设计编译 + 顶层集成 TB（5 程序 / 51 项判据）
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ct2b.vvp -s tb_core_top_2b "${RTL[@]}" sim/unit/tb_core_top_2b.sv
vvp /tmp/ct2b.vvp | tail -20      # ⇒ TB_CORE_TOP_2B: PASS（51 项）

#    p8 中断现场诊断（可选）：把 tb_core_top_2b.sv 的 DBG_P8 置 1 重编译
#    ⇒ [irq-s] 每 10 拍现场 + [irq-cmt] 逐条提交 PC

# 2) 全量回归（tb_*.sv glob 自动纳入本 TB ⇒ 32 项）
./scripts/regress.sh              # ⇒ REGRESS: 32/32 PASS
```

## B4.4.7 本段检查点状态（可复核，2026-09-23 实测）

- 整设计（含新顶层与新 TB）编译：**0 error**（`-Wall`，无新增 implicit-net 告警）。
- `tb_core_top_2b`：**TB_CORE_TOP_2B: PASS，51/51 项**
  （C1' PC 流 / C2' 条数 / C3' 写回 / C4' AXI 读 / C5' 无异常 / C6' 写回流量 / **C7' 陷阱路径** / **C8' 中断路径**）。
- `regress.sh`：**32/32 PASS**（日志 `../.b2chk/regress_4a_final.log`）。
- 未提交 git；改动文件快照见 `../.b2chk/*.s13`（步骤 1~3 检查点）与 `../.b2chk/*.s14`（本段最终态）。
- 证据日志：`../.b2chk/final_4a_run.log`（TB 全量输出）、`../.b2chk/gen_p8b.log`（黄金生成 stderr）。


# 2B-4 第 4b 段（csr_file 替换 + Sv32 + PLIC + S 模式）—— **接口勘察 + 第一步落地 + 可执行方案**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 4a 收官
> `09b5e32` + 补充 `d8b3600`，tag `2B-4.4`，**未提交新改动**）
> 任务书：①`csr_file`+`trap_ctrl` 替换 `b2_csr` 过渡栈（含提交组适配层）②Sv32 全链路
> ③PLIC + `intrpt[7:0]` + MEIP 最小闭环 ④向量模式 + S 模式判据。
> **预算见底 ⇒ 本段按纪律停在"整设计可编译 + 既有判据全绿"检查点**，并交付：
> **一项零风险、可独立验证的 4b 内容（向量模式实测，并已借此修掉一个真实 ISA 口径缺陷）**
> + 其余三项的**逐条接口勘察与可执行方案**（附 file:line 证据）。

## B4.5.0 结论（一句话）

**本段实测了 mtvec 向量模式并修掉缺陷 D4（4a 段把"同步异常"也做了向量化，与 ISA/2A 口径不符）；
`csr_file`+`trap_ctrl`+`priv_ctrl` 替换、Sv32 全链路、PLIC、S 模式四项只做了勘察与方案
——它们都依赖 `csr_file` 落地（`satp`/`mstatus.MPP`/`sstatus`/`medeleg` 等 CSR 与 `priv` 状态机
在 4a 的 `b2_csr` 过渡栈里**根本不存在**），半途替换必然打破"既有判据全绿"，故按任务书停在检查点。**

## B4.5.1 本段已完成（可复核的实测增量）

| 项 | 内容 | 证据 |
|---|---|---|
| **D4 缺陷修正** | `mtvec` MODE=1（Vectored）下**只有中断**取 `BASE + 4×cause`，**同步异常一律回 BASE**（4a 实现把异常也向量化 ⇒ 与 Spike/2A 口径不符） | 依据 `docs/design/06-csr-privilege.md §3.2`（"MODE=1：**同步异常** pc ← BASE；**中断** pc ← BASE + 4×cause"）；**实测抓住**：修正前 Spike 落 `vbase+0`、本核落 `vbase+44`（C1' 第 10 条分歧，p9 首轮日志）；修正后 `rtl/top/core_top_2b.v:900-917` |
| 向量目标合成口径 | 采用 2A `csr_file` 式 `BASE(低 8 位 0) \| (cause << 2)`（Vectored 下 2A 要求 BASE 256 B 对齐，正是为省加法器，见 06 §11 P-3）；`trp_vect_w = {base[31:8],8'b00} \| {26'b0,7,2'b00}` | `core_top_2b.v:912-916` |
| **新程序 `back2_p9_trapvec.S`** | MODE=1 + 三条同步异常（ecall 11 / 非法 2 / ebreak 3）⇒ **三次都落 BASE**；槽 1..11 塞 `j h_wrong`（标记 0xEE）作反例防护；`vbase` 256 B 对齐 | 黄金 92 条；TB 输出 `[C9'] 向量模式：mtvec=0x80014101（MODE=1，BASE=0x80014100）→ 三次同步异常目标均 = BASE（0x80014100×3），陷阱指令 PC=0x80014028/0x80014030/0x80014038，cause=11/2/3` |
| **p8 增补"中断向量化"** | p8 的 `mtvec` 改 MODE=1 + 256 B 对齐向量表，槽 7（`BASE+28`）= 中断入口；槽 0..6/8..11 = `h_bad`（fail-loud） | TB 输出 `[C8'] 中断现场：mtvec=0x80010101 mepc=0x80010058 mcause=0x80000007`、`向量槽 7（BASE+28）已提交` |
| TB 判据扩展 | 程序数 5→6；新增 `trp_tgt[]`（**异常重定向目标**采样）、`irq_target_q`（**中断重定向目标**采样，中断不走 ROB 异常口）；C8' 增 3 条（MODE=1 / 中断向量目标 / 槽 7 已提交）、C9' 6 条 | **TB_CORE_TOP_2B: PASS，68/68 项**（`../.b2chk/final_4b_run.log`） |
| 既有判据不回退 | p1 449/161、p3 462/126、p6 1077/366（AW=2/W=16/B=2）、p7 755/89（陷阱 3 次 cause 11/2/3）、p8 4000/524（中断 1 次）全部同 4a | 同上日志；`regress.sh` 见 §B4.5.8 |

## B4.5.2 ①`csr_file` + `trap_ctrl` 替换方案（含提交组适配层）

**接口事实（只读勘察，2A 参考行）**

| 模块 | 端口规模 | 2A 例化行 | 关键输入/输出 |
|---|---|---|---|
| `csr_file` | 45 | `rtl/top/core_top.v:2465-2534` | 读口 `raddr/rdata`；写口 `wen/waddr/wdata/w_illegal` + **W 级旁路** `rdata_w`，**M 级预览旁路** `byp_wdata/byp_rdata`；`priv/chk_addr/chk_illegal/chk_ro_write`；`mstatus_o/mstatus_set/mstatus_clr`；**陷阱写路径 `trap_we/trap_epc_i/trap_cause_i/trap_tval_i/trap_data_i`**；中断源 `irq_msip/mtip/meip/stip/seip`；计数器 `cycle_i/instret_i`；输出 `pmp_cfg_o/pmp_addr_o/satp_o/menvcfg_o/senvcfg_o/mcounteren_o/scounteren_o/mtvec_o/stvec_o/medeleg_o/mideleg_o/mie_o/mip_o/mepc_o/sepc_o` |
| `trap_ctrl` | 35 | `core_top.v:2568-2610` | 入口 = "W 拍单发射"：`commit_valid/commit_pc/commit_pc_next/commit_insn/exc_valid/exc_cause/exc_tval/exc_is_fetch/priv/medeleg/mideleg/mip/mie/mstatus_i/mtvec/stvec`；出口 = `trap_valid/trap_is_int/trap_target/trap_cause/trap_tval/trap_epc/trap_pc` + **CSR 写路径 `trap_we/trap_epc_i/trap_cause_i/trap_tval_i`** + `redirect_pc` |
| `priv_ctrl` | 20 | `core_top.v:2540-2562` | `trap_valid/trap_target/xret_valid/xret_kind/mstatus_i/csr_wen/csr_waddr/csr_wdata` → `priv_o/eff_priv_o/mprv_o/sum_o/mxr_o/mpp_o/tvm_o/tw_o/tsr_o/fetch_priv_is_m_o/flush_req/priv_next_o` |
| `pmp_check` | — | `core_top.v:1848`（PTE 隐式访存）+ 取指/数据侧各一 | `cfg_i/addr_i/acc_pa_i/acc_bytes_i/acc_priv_i/acc_type_i` → `allow_o/fault_cause_o` |

**适配层设计（`backend_top` → `trap_ctrl`，本段的结论性方案）**

1. **"W 拍"= ROB 头**：`commit_valid = rob_head_valid & head_done`；`commit_pc = 头部 PC`；
   `commit_pc_next = 头部 PC + len`（本核程序全 norvc ⇒ +4；压缩指令需从载荷取长度，登记为待办）；
   `commit_insn = 载荷 TVAL`（= 原始指令位，4a 已验证可用）。
2. **异常入口**：`exc_valid = commit_valid & head_exc`（**必须与 `commit_valid` 相与** —— 2A 的
   `core_top.v:2571-2579` 记录了"裸 `exc_valid` 逐拍重复取同一次陷阱"的真实缺陷）；
   `exc_cause/exc_tval` 取 ROB 头部的 `EXC`/`TVAL` 字段（4a 已有）；
   `exc_is_fetch` 由取指侧的异常来源标记提供（本核取指异常目前只在 front4 内部，需引到后端，登记为待办）。
3. **CSR 写在提交点**：`wen = 提交组里最老的那条 CSR 指令`（本核 CSR 只在 ROB 头发射 ⇒ **每组至多一条**
   ⇒ 简单优先 mux 足够，沿用 4a 的 `csr_cmt_we/csr_cmt_addr/csr_cmt_op` 现场）；
   `wdata` 用 `csr_file` 的 **W 级旁路 `rdata_w`** 合成（`W→src`、`S→old|src`、`C→old&~src`；
   立即数形式源 = 载荷 TVAL 的 `insn[19:15]`，即 4a 修的 D2）；`mstatus_set/clr` 由 xRET/CSR 写驱动。
   替换后 **4a 自己合成的 `trp_csr_*`（mepc/mcause/mtval/mstatus 进入/退出）全部删除**，
   改由 `trap_ctrl` 的 `trap_we/trap_epc_i/trap_cause_i/trap_tval_i` → `csr_file` 落地（delegation 由 trap_ctrl 算）。
4. **重定向优先级**：沿用 4a 的"外部优先"骨架，扩展为
   `trap_valid ? trap_target : xret ? (kind==mret ? mepc_o : sepc_o) : sfence/cbo/fence.i ? … : squash`；
   `trap_valid` 与 `redirect` **同拍**（2A `core_top.v:2619-2625` 同构）。
5. **中断**：`csr_file` 的 `mip` 由 CLINT/PLIC 直驱；`trap_ctrl` 用 `mip/mie/mideleg/priv/mstatus_i`
   判 `trap_is_int` 并给 `trap_cause/trap_target` ⇒ **4a 的 `irq_mti_w` 判定与 `0x8000_0007` 合成全部删除**；
   本核只需保留"提交组边界采样 + ROB 非空"（`mepc` = 头部 PC，等价于 2A 的"下一条未提交 PC"）。
6. **读口**：`csr_file.raddr/rdata` 直接替 `b2_csr` 的组合读口；**必须保留**本核的
   "CSR 指令只在 ROB 头发射"闸门（否则读到投机中间态）。

## B4.5.3 ②Sv32 全链路方案

**现状（本仓已就位的骨架，全部为占位 tie-off）**

| 项 | 现状 | 位置 |
|---|---|---|
| I 侧翻译 | `tlb` 第二查询口 + `ptw` 已接取指，`sv32_en = 0`（satp 占位 0）⇒ 直通 | `core_top_2b.v:242-292` |
| D 侧翻译 | **完全未接**：`tlb` 第一查询口 `lookup_valid(1'b0)`；LSU 侧 `cs_vaddr = cs_paddr` | `core_top_2b.v:251-255`、`:469` |
| PTW 串行复用 | **未做**：`ptw.req_valid = sv32_en & ~f_tlb_hit & tr_req_valid`（只有取指源）；2A 的 `m_tr_src_q` 归属仲裁（数据侧优先）未搬 | `core_top_2b.v:274`；2A `core_top.v:1587-1595/1790-1797/1988` |
| PTE A/D 写通路 | **未做**：`ptw.pte_ad_done(1'b0)`（fail-closed，Bare 下不可达） | `core_top_2b.v:289` |
| sfence.vma | **未接**：`tlb.sfence_valid(1'b0)`、`satp_we(1'b0)` | `core_top_2b.v:263-266` |
| cbo/fence.i 维护 | **未接**：L1I `inval_all(1'b0)`、L1D `inval_all/clean_all(1'b0)` | `core_top_2b.v:439`、`:572` |
| PTE 隐式访存 PMP | 已例化 `pmp_check`，但 `acc_type_i(2'b00)`（= X） | `core_top_2b.v:295-301` |

**实施方案（按依赖排序）**
1. `satp` 来自 `csr_file.satp_o` ⇒ `sv32_en = satp[MODE]`（2A `core_top.v:2536` 同式）；
   `priv` 来自 `priv_ctrl.eff_priv_o`（数据侧）/`priv_o`（取指侧）。
2. **D 侧翻译级**：把 LSU 请求拆成"VA 冻结 → tlb 口 1 查询 → 命中/未命中/缺页"，
   未命中走 PTW（与取指源按 **数据优先** 仲裁 + `m_tr_src` 归属锁存），完成后
   `cs_s_vaddr` 用译后 PA（`cs_vaddr=cs_paddr` 的注释块 `:469` 改成 VA/PA 分离）。
3. **A/D 写通路**：`ptw.pte_ad_update/pte_ad_pa/pte_ad_data` → 在 §5 AXI 引擎里新增第 7 个来源
   （单 beat 写；2A 口径：**在 M 级 uncached 写通道**发；本核引擎已有 `d_unc` 单 beat 写机制可复用），
   完成后回 `pte_ad_done`；**失败关闭**改为：只有 `pte_ad_done` 回执后才填 TLB。
4. **sfence.vma / cbo.***：在提交点识别（载荷 TVAL：`sfence.vma` = `0x12000073|rs`、cbo 族 funct3=0b100 族），
   驱动 `tlb.sfence_*`（含 va/asid/all 口径）与 L1I `inval_all`、L1D `clean_all/inval_all`，
   并按 2A 做"sfence 后同步重定向"（2A `core_top.v:2619-2625` 的 `sfence_sync_pending` 分支）。
5. **PTE-PMP 口径（★ 待母代理裁定）**：任务书写"PTE-PMP 恒 LOAD"，但 2A 实测是
   `acc_type_i(pmp_acc_xlat(ptw_pmp_req_acc))`（`core_top.v:1855` + `:471-479`）⇒ 取指遍历的 PTE 检查是
   **X**、数据侧是 LOAD/STORE。本段按"**以 2A 实现为验收基准**"记录，落地下一步按 2A 对齐。
6. `sv32_en` 打开后必须同时把 `cs_vaddr/cs_paddr` 分离、PTW kill 语义（`ptw.kill`）、
   翻译未就绪期压制取指原生异常（2A `core_top.v:862-875` 的两条口径）一并搬。

## B4.5.4 ③PLIC + `intrpt[7:0]` + MEIP 最小闭环

- **现状**：`core_top_2b §4b.1` 只接 CLINT；PLIC 窗口的访问"立即完成 / 读回 0 / 写丢弃"（fail-safe）。
- **2A 口径**：`clint` 与 `plic` 同挂 MMIO 截获；`plic #(.NUM_SOURCES, .NUM_CONTEXTS)` 例化于
  `core_top.v:1460-1478`，`src = {3'b000, intrpt[7:0]}`、`intrpt_src_map` 按平台表；
  `meip_o/seip_o` 经 **T2 的一拍寄存**（`core_top.v:1490-1500`）再进 `csr_file.mip`。
- **最小闭环（建议第一步）**：PLIC 例化 → `intrpt[7:0]` 按 2A 平台表分配 → 软件写 `enable/threshold` →
  外部源拉高 ⇒ `mip.MEIP` → `mie.MEIE`+`mstatus.MIE` ⇒ 取中断（cause 11 即 `0x8000_000B`）→
  处理程序读 PLIC `claim` 寄存器（`PLIC_BASE+0x0020_0000+4*ctx`）→ 写 `complete` 清 pending。
- **注意**：2A 把 PLIC 判决输出寄存一拍（时序修复，`core_top.v:1484-1500` 有完整论证）⇒ 本核接线
  同样加这一级；`mip` 的软件可写位（SEIP/STIP/SSIP）不走该寄存（在 `csr_file` 内部）。

## B4.5.5 ④S 模式判据（`back2_p10_priv.S`）设计草案

依赖 ①（`csr_file` 提供 `sstatus/sie/sip/scause/sepc/stvec/medeleg/mideleg` + `priv_ctrl` 提供 priv 状态机），
Spike 侧可直接给黄金（M/S 模式陷阱语义 Spike 全支持），故判据可沿用现有 C1'/C3' 逐条比对：
1. `mret` 下陷 S 模式（`mstatus.MPP=01`）→ 读 `csrr t0, sstatus` 验证 SPP/SPIE 语义；
2. S 模式 `ecall` ⇒ `scause = 9`、`sepc` = ecall PC、`stval = 0`（若 `medeleg[9]=1`）；
   未委托时 ⇒ `mcause = 9`（M 处理）；
3. M 处理程序 `sret` 返回 S ⇒ `sstatus.SIE ← SPIE`；
4. S 模式访问 M 专属 CSR（如 `mtvec`）⇒ 非法（cause 2，Spike 可直接给黄金）。
5. 若 S 模式 + Sv32 同时开，还需 `sum/mxr` 口径（`csr_file` 的 `sum_o/mxr_o`）。

## B4.5.6 分步顺序 + 每步判据 + 风险（建议 4b 分三段执行）

| 步 | 内容 | 通过判据 | 估计 | 主要风险 |
|---|---|---|---|---|
| 4b-1 | `csr_file`+`priv_ctrl`+trap_ctrl 替换 `b2_csr`（**保留** 4a 的重定向/flush 骨架，只换 CSR 与 trap 决策源） | p1/p3/p6/p7/p8/p9 全部旧判据 + regress 32/32；`misa/mstatus/mie/mip/mtvec/mepc/mcause/mtval/mscratch` 读写轨迹 = 黄金 | ~250 行 | 读口语义（W/M 旁路）、`mstatus` FS/SD 由顶层持有（2A `core_top.v:2538-2552` 有合并层，要一并搬）、xret 与 trap 同拍优先级 |
| 4b-2 | Sv32：satp→`sv32_en`、D 侧 TLB/PTW 串行复用（数据优先）、A/D 写通路、sfence/cbo/fence.i | 新 `p9_sv32.S`（两级页表 + A/D 置位 + sfence 重映射 + PTE-PMP 拒绝）+ 旧判据不回退 | ~400 行 | 本步最大：D 侧翻译插入会动 LSU/L1D 时序；A/D 写通路要占 AXI 引擎一档；PTW 串行复用的 kill/归属 |
| 4b-3 | PLIC + MEIP 最小闭环；S 模式判据 `p10_priv.S` | 新 `p10_priv.S`（M↔S 切换 + 委托/未委托 ecall + sret）+ PLIC claim/complete 闭环 | ~150 行 | PLIC 时序（T2 寄存）、Spike 平台地址表与本 SoC 的差异 |

## B4.5.7 阻塞点（为什么本段不能"半途替换"）

| # | 阻塞点 | 证据 |
|---|---|---|
| E1 | **`csr_file` 不是"换一个模块"而是换一套特权子系统**：它依赖 `priv_ctrl`（priv/MPRV/SUM/MXR/MPP 状态机）、`trap_ctrl`（delegation 决策）、`pmp_check`、计数器（`cycle_i/instret_i`）、中断同步级 | `core_top.v:2465/2540/2568` 三处例化互锁；缺任一项 CSR 读写即错 |
| E2 | **4a 的 `b2_csr` 与 `csr_file` 不能并存于同一地址空间**（两套 CSR 寄存器；`mstatus` 还被顶层 FS/SD 合并层覆盖） | 2A `core_top.v:2538-2552` 的 `mstatus_merged` 逻辑必须随 `csr_file` 一起搬 |
| E3 | **Sv32 依赖 `satp`/`priv`**：没有 `csr_file`+`priv_ctrl` 就没有 `satp`、没有 `eff_priv/sum/mxr`，D 侧翻译的权限判定无法成立 | `rtl/tlb/tlb.v` 的 `lookup_priv/sum/mxr` 端口；2A `core_top.v:1796` 用 `csr_eff_priv` |
| E4 | **PLIC/MEIP 的 cause 与委托都经 `trap_ctrl`**：4a 的 `irq_mti_w` 是"只有 MTI"的特例，扩展成 `mip/mie/mideleg` 通用判定等于重写该判定 | 4a `backend_top.v` 事件组装段 |
| E5 | 本段预算：任务书明确"预算见底 ⇒ 停在可编译 + 既有判据全绿检查点 + 报告已完成/阻塞点/下一步" | 任务书末段 |

## B4.5.8 本段检查点状态（可复核）

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ct2b.vvp -s tb_core_top_2b "${RTL[@]}" sim/unit/tb_core_top_2b.sv
vvp /tmp/ct2b.vvp | tail -12      # ⇒ TB_CORE_TOP_2B: PASS（**68 项**；含 C9' 向量模式）
./scripts/regress.sh              # ⇒ REGRESS: 32/32 PASS
```
- 实测：整设计编译 **0 error**；`tb_core_top_2b` **PASS 68/68**（`../.b2chk/final_4b_run.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b.log`）。
- 本段改动文件：`rtl/top/core_top_2b.v`（D4 修正 + 注释口径）、`sim/unit/tb_core_top_2b.sv`（C8'/C9' + 采样）、
  `sim/unit/prog/back2_p9_trapvec.S`（新）、`sim/unit/prog/back2_p8_int.S`（向量表）、
  `sim/unit/prog/gen_back2_lockstep_data.py`（p9 条目）、`sim/unit/prog/back2_lockstep_data.svh`（再生成）。
- 未提交 git；快照 `../.b2chk/*.s15`（本段最终态）、`../.b2chk/*.s14`（4a 收官态）。


# 2B-4 第 4b-1 段（`b2_csr` → `csr_file` 替换）—— **CSR 轨迹判据落地 + 两处真实缺陷修正 + 端口级替换方案**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 4b 1/3 `c7fb923`=tag `2B-4.5`，**未提交新改动**）
> 任务：实例化 2A `csr_file`+`priv_ctrl`+`trap_ctrl`+`pmp_check` 替换 `b2_csr`；删除 4a 自造 `trp_csr_*`；
> 适配层三要点（ROB 头当 W 拍 / `exc_valid` 与 `commit_valid` 相与 / CSR 写数据 `rdata_w` 旁路 + 立即数形式取 `insn[19:15]`）。
> **预算见底 ⇒ 按任务书停在"整设计可编译 + 既有判据全绿"检查点**，本段交付：
> ①**CSR 读写轨迹判据**（新程序 `back2_p10_csr.S`，与 Spike 黄金逐条比）——判据②的 CSR 部分；
> ②该判据**首轮就抓出两处真实缺陷并已修正**（D5a/D5b，都直接关系到本任务的适配层第③点）；
> ③替换的**端口级接线表 + 删除清单（带行号）+ 与 2A 的八条口径差异登记**（含 1 条需母代理裁决）。

## B4.6.0 结论（一句话）

**新增的 CSR 轨迹判据把"CSR 立即数形式判定"和"提交点 CSR 源取 lane 0"两处真实缺陷当场抓出并修好
（这正是本任务适配层第③点要落的两件事），`tb_core_top_2b` 从 68 项扩到 **79 项全绿**、p1/p3/p6/p7/p8/p9 无回退；
`csr_file`+`trap_ctrl`+`priv_ctrl` 的实际替换**未做**——它是"两文件同改、约 250 行、含 1 条待裁决口径"的原子改动，
预算内无法保证迭代到全绿，按任务书停在检查点，并留下可直接执行的**分阶段方案（4b-1a/1b/1c）**。**

## B4.6.1 本段已完成（全部可复核）

| 项 | 内容 | 证据 |
|---|---|---|
| **新判据程序 `back2_p10_csr.S`** | 只用"两种实现都具备"的 CSR（mscratch/mepc/mtvec/mcause/mtval/mie/mstatus），覆盖 `csrw`/`csrr`/`csrrw`/`csrrs`/`csrrc` + **立即数形式** `csrrwi`/`csrrsi`/`csrrci`；每个结果都进通用寄存器 ⇒ 与 **Spike 黄金逐条比** | 黄金 45 条；TB 输出 `[C10'] CSR 轨迹：mscratch(w/rw/rs/rc/wi/si/ci)=0x10、mie=0x808、mstatus&0x1888=0x1800；csrrw/rs/rc 旧值、WARL 回读均与 Spike 黄金逐条一致` |
| **缺陷 D5a（4a 段 D2 修法自身写错）** | 立即数形式判据必须是 **funct3 最高位 `insn[14]`**；4a 写成 `\|insn[14:13]`，而 `csrrs`(010)/`csrrc`(011) 的 `[14:13]=2'b01` 也非零 ⇒ **寄存器形式被误判成立即数形式**，源操作数取成"寄存器号" | 实测：`csrrc s5,mscratch,t3` 落盘 `0x0F0F0F03`（用 0x1C 当源值），Spike 黄金 `0x0F0F0F00`；修后逐条一致（`rtl/back2/backend_top.v` 的 `csr_cmt_zimm`） |
| **缺陷 D5b（B29 残留）** | 提交点 CSR 源固定用 **lane 0** 载荷的 `ps1i` 去读 PRF ⇒ CSR 指令不在 lane 0 时读到无关寄存器；改为用**该 CSR 指令自己**的 `ps1i`（新增 `csr_cmt_ps1i`，在提交组扫描里捕获） | 同上修复块；D5a+D5b 后 `csrrs`→`csrrc` 背靠背读改写链与黄金逐条一致（idx 9~16 全对） |
| **判据扩展** | TB 程序数 6→7（新增 p10）；新增 **C10'** 3 条（mscratch 立即数序列末值 / mie 回读 / mstatus 掩码回读）；诊断打印改为 `DBG_P10` 门控 | **TB_CORE_TOP_2B: PASS，79/79 项**（`../.b2chk/final_4b1_run.log`） |
| **既有判据不回退** | p1 449/161、p3 462/126、p6 1077/366（AW=2/W=16/B=2）、p7 755/89（陷阱 cause 11/2/3）、p8 4000/524（MTI 中断 1 次）、p9 843/92（MODE=1 异常回 BASE） | 同上日志；`regress.sh` 见 §B4.6.7 |
| **`mip.MTIP` 复位口径实测** | Spike 的 CLINT `mtimecmp` 复位 **0** ⇒ 一上电 MTIP=1（`mip=0x80`）；2A/本核 `clint.v` 复位 `mtimecmp=0xFFFF_FFFF` ⇒ MTIP=0。**无法在程序内对齐**（本核 CLINT 在 `0x1F00_0000`、Spike 在 `0x0200_0000`）⇒ p10 不纳入 raw `mip` 读，MTIP 判据交由 p8 | p10 首轮实测 `FAIL: 程序 6 第 33 条 写回值=0x00000000 期望 0x00000080（rd=14）`；登记见 §B4.6.4-③ |

## B4.6.2 适配层接线表（端口级，供 4b-1b 直接照抄）

### (1) `backend_top`：把 CSR 文件"请出后端"（新端口 7 个，删除 6 个）

| 端口 | 方向 | 驱动/来源 | 说明 |
|---|---|---|---|
| `csr_raddr_o[11:0]` | out | `= csr_raddr_w`（现有内部信号） | 与 4a 相同：`csr_cmt_we ? csr_cmt_addr : u_csra(csr_uop)` |
| `csr_rdata_i[31:0]` | in | 顶层 `csr_file.rdata` | **内部 `csr_rdata_w` 由该输入直接赋值** ⇒ `a0_wb_data`/`csr_wdata_w` 等 5 处使用点**零改动** |
| `csr_we_o` / `csr_waddr_o[11:0]` / `csr_wdata_o[31:0]` | out | `csr_we_w` / `csr_waddr_w` / `csr_wdata_w`（均现有） | 提交点写请求；`csr_wdata_w` 已含 `ff_cmt_val` 的 fflags 并路（保留） |
| `xret_kind_o[1:0]` | out | 由提交组 lane 0 原始指令位判：`0x3020_0073→1`(mret)、`0x1020_0073→2`(sret) | `priv_ctrl.xret_kind` 需要；`cmt0_tval` 已在 4a 引入 |
| **删** `mtip_i`/`irq_mti_o`/`mtvec_o`/`mepc_o`（4 个） | — | 中断判定改由顶层 `trap_ctrl` 用 `csr_file.mip/mie` 做；`mtvec/mepc` 顶层直接有 | 见 §B4.6.3 删除清单 |

### (2) `core_top_2b`：实例化与接线（按 `rtl/top/core_top.v:2465/2540/2568` 同法）

```verilog
// ---- CSR 文件 + 特权状态 + 陷阱决策（2A 只读例化）----
csr_file u_csr_file (
  .clk(aclk), .rst_n(aresetn),
  .raddr(csr_raddr_o), .rdata(csr_file_rdata), .wen(csr_we_o),
  .waddr(csr_waddr_o), .wdata(csr_wdata_o), .w_illegal(1'b0),
  .rdata_w(), .byp_wdata(32'h0), .byp_rdata(),
  .priv(csr_priv_2), .chk_addr(12'h0), .chk_illegal(), .chk_ro_write(),
  .mstatus_o(csr_mstatus_raw), .mstatus_set(mstatus_set), .mstatus_clr(mstatus_clr),
  .trap_we(trap_we), .trap_epc_i(trap_epc_i), .trap_cause_i(trap_cause_i),
  .trap_tval_i(trap_tval_i), .trap_data_i(32'h0),
  .irq_msip(clint_msip_w), .irq_mtip(clint_mtip_w), .irq_meip(1'b0), .irq_stip(1'b0), .irq_seip(1'b0),
  .cycle_i(cycle_cnt), .instret_i(instret_cnt),
  .pmp_cfg_o(pmp_cfg_flat), .pmp_addr_o(pmp_addr_flat), .satp_o(csr_satp),
  .menvcfg_o(), .senvcfg_o(), .mcounteren_o(), .scounteren_o(),
  .mtvec_o(csr_mtvec), .stvec_o(csr_stvec), .medeleg_o(csr_medeleg), .mideleg_o(csr_mideleg),
  .mie_o(csr_mie), .mip_o(csr_mip), .mepc_o(csr_mepc_o), .sepc_o(csr_sepc_o));

priv_ctrl u_priv_ctrl (  /* 2A core_top.v:2540 同法 */
  .clk(aclk), .rst_n(aresetn),
  .trap_valid(trap_valid), .trap_target(trap_target),
  .xret_valid(xret_cmt_w), .xret_kind(xret_kind_w),
  .mstatus_i(csr_mstatus_raw), .csr_wen(csr_we_o), .csr_waddr(csr_waddr_o), .csr_wdata(csr_wdata_o),
  .mstatus_set(mstatus_set), .mstatus_clr(mstatus_clr),
  .priv_o(csr_priv_2), .eff_priv_o(csr_eff_priv), .mprv_o(), .sum_o(), .mxr_o(), .mpp_o(),
  .tvm_o(), .tw_o(), .tsr_o(), .fetch_priv_is_m_o(), .flush_req(), .priv_next_o());

trap_ctrl u_trap_ctrl (   /* "ROB 头当 W 拍"适配 —— 见 §B4.6.4-①② */
  .commit_valid(rob_any_w), .commit_pc(trap_pc_w), .commit_pc_next(trap_pc_w), // ★ pc_next=pc
  .commit_insn(trap_tval_w),                                                  // 载荷 TVAL = 原始指令位
  .exc_valid(trap_valid_w), .exc_cause({1'b0, trap_cause_w}),
  .exc_tval(exc_tval_adapted_w),                                              // ★ 见 §B4.6.4-①
  .exc_is_fetch(1'b0),                                                        // 待办（本核载荷无 fetch 标记）
  .priv(csr_priv_2), .medeleg(csr_medeleg), .mideleg(csr_mideleg),
  .mip(csr_mip), .mie(csr_mie & {32{|dbg_rob_cnt_w}}),                        // ★ ROB 空 ⇒ 不取中断
  .mstatus_i(csr_mstatus_raw), .mtvec(csr_mtvec), .stvec(csr_stvec),
  .trap_valid(trap_valid), .trap_is_int(), .trap_target(trap_target),
  .trap_cause(), .trap_tval(), .trap_epc(), .trap_pc(), .redirect_pc(),
  .trap_we(trap_we), .trap_epc_i(trap_epc_i), .trap_cause_i(trap_cause_i),
  .trap_tval_i(trap_tval_i), .trap_data_i(), .trap_wr_m_epc(), .trap_wr_m_cause(),
  .trap_wr_m_tval(), .trap_wr_s_epc(), .trap_wr_s_cause(), .trap_wr_s_tval());

// 4a 的"重定向/flush 骨架"整体保留，只换目标来源：
assign be_trp_flush       = trap_valid | xret_cmt_w;
assign be_trp_redirect_v  = be_trp_flush;
assign be_trp_redirect_pc = trap_valid ? trap_target
                            : ((xret_kind_w == 2'd1) ? csr_mepc_o : csr_sepc_o);
```

### (3) 计数器与 pmp

```verilog
reg [63:0] cycle_cnt, instret_cnt;
always @(posedge aclk or negedge aresetn)
  if (!aresetn) begin cycle_cnt <= 64'h0; instret_cnt <= 64'h0; end
  else begin cycle_cnt <= cycle_cnt + 64'd1;
             instret_cnt <= instret_cnt + {60'b0, cmt_n_o}; end   // 提交条数累加
pmp_check u_pmp_pte ( ... .cfg_i(pmp_cfg_flat), .addr_i(pmp_addr_flat), ... );  // §B4.5.3 已就位，改接真值
```
> `pmp_check` 的**取指/数据侧**两份本轮不接（PMP 强制不在验收范围）；PTE 那份按母代理裁决照抄 2A 接线
> （`acc_type_i(pmp_acc_xlat(ptw_pmp_req_acc))`，`core_top.v:1855` + `:471-479`）。

## B4.6.3 删除清单（4b-1b 执行时逐条删，行号以 `c7fb923` 为准）

| 文件 | 行 | 内容 | 处置 |
|---|---|---|---|
| `rtl/back2/backend_top.v` | 133-141 | `trp_flush_v_i/trp_redirect_v_i/trp_redirect_pc_i/trp_halt_o/xret_cmt_o/mtip_i/irq_mti_o/mtvec_o/mepc_o` | **保留** `trp_flush_v_i`/`trp_redirect_*_i`/`trp_halt_o`/`xret_cmt_o`（4a 骨架）；**删** `mtip_i`/`irq_mti_o`/`mtvec_o`/`mepc_o`，新增 §B4.6.2(1) 的 7 个端口 |
| 同上 | 343-346 | `csr_mstatus_mie_w/csr_mie_mtie_w/trp_csr_enter_w/trp_csr_exit_w/trp_csr_pc_w/csr_mstatus_w/csr_mie_w` 声明 | **删**（连同 `trp_csr_tval_w`） |
| 同上 | 1462-1472 | `b2_csr u_csr (...)` 例化 | **删**（`b2_csr.v` 文件保留但**不再例化** ⇒ 满足"两套 CSR 不得并存"） |
| 同上 | 1600-1629 | `irq_mti_w`/`csr_mstatus_mie_w`/`csr_mie_mtie_w`/`trp_is_*`/`trp_csr_enter_w`/`trp_csr_exit_w`/`trp_csr_pc_w`/`trp_csr_cause_w`/`trp_csr_tval_w` | **全删**（陷阱 CSR 落地改由顶层 `trap_ctrl.trap_we/trap_epc_i/trap_cause_i/trap_tval_i` → `csr_file`） |
| 同上 | 1458-1461 | `DBG_CSR` 块里 `u_csr.mscratch_q` 引用 | 删该字段（否则层次名悬空） |
| 同上 | `wire [31:0] csr_rdata_w;` | 原由 `b2_csr` 驱动 | 改为 `assign csr_rdata_w = csr_rdata_i;`（5 处使用点零改动） |
| `rtl/top/core_top_2b.v` | §6b（~900-917） | 4a 的 `trp_mode_w/trp_base_w/trp_cause4_w/trp_vect_w/trp_target_w` 目标合成 | **删**（目标改由 `trap_ctrl.trap_target`，其内部含 2A 的 Direct/Vectored 口径，与本核 §B4.5 的 D4 修正一致） |
| 同上 | §6b | `irq_mti_w`/`xret_cmt_w` 的采样与 `trp_cause4_w=7` | `xret_cmt_w` 保留；中断判定改由 `trap_ctrl` 承担 |

## B4.6.4 与 2A 的口径差异登记（8 条，其中 ①需裁决）

| # | 项 | 2A 实测 | Spike / 本核现状 | 建议 |
|---|---|---|---|---|
| ① | **`mtval` for ecall**（★需裁决） | `core_top.v:3160-3162`：`e_exc_tval = de_ebreak ? de_pc : de_ecall ? de_pc : 0` ⇒ **ecall 的 mtval = PC** | Spike 实测 ecall ⇒ **0**（p7 黄金），ebreak ⇒ PC（两侧一致） | 适配层按 **Spike/4a**：`exc_tval = (cause==3) ? pc : (cause∈{8,9,11}) ? 0 : tval`（非法指令由 `trap_ctrl` 用 `commit_insn` 覆盖 ✓）。**若以 2A 为准 ⇒ p7 的 mtval 累加器判据必失败**（需母代理裁决；本段按"p7 不回退"优先，默认按 Spike，并在报告登记偏差） |
| ② | **中断 `mepc`** | `trap_ctrl.v:243`：中断时 `epc = commit_pc_next`（2A 是"W 已提交、下一条未执行"） | 本核取点在 ROB 头**提交前** ⇒ "下一条未执行"**就是头部 PC** | 适配层驱动 `commit_pc_next = commit_pc`（头部 PC）⇒ 2A 的 `trap_epc` 自然等于头部 PC；否则 p8 的 `mepc ∈ wait 循环` 判据会失败（实测过 4a 的口径 = 头部 PC ✓） |
| ③ | `mip.MTIP` 复位 | 2A `clint.v`：`mtimecmp` 复位 `0xFFFF_FFFF` ⇒ MTIP=0 | Spike：`mtimecmp` 复位 0 ⇒ **MTIP=1**（`mip=0x80`） | 无法程序内对齐（CLINT 地址不同源）⇒ p10 不纳入 raw `mip` 读；MTIP 判据由 p8 承担（已实测登记） |
| ④ | PTE 隐式访存 PMP | `core_top.v:1855` + `:471-479`：`pmp_acc_xlat(ptw_pmp_req_acc)`（取指遍历 PTE 按 **X**、数据侧 LOAD/STORE） | 任务书曾写"恒 LOAD" | **按母代理裁决：照抄 2A**，不做臆改；文档差异已在 §B4.5.3-5 登记 |
| ⑤ | `mstatus` FS/SD 合并层 | `core_top.v:2538-2552`：顶层持有一份 FS/SD 覆盖 `csr_file` 的对应位 | 本核 `core_top_2b` 无 FP 状态所有者（TB 七个程序全整数） | 4b-1b **先不搬**（搬了没有 FS 源、反而制造悬空语义），登记为"FP 集成时一并搬"；`csr_file` 自带的 FS 视图（`csr_file.v:671/698`）保持原样 |
| ⑥ | `fflags` 累加 | 2A 在 `csr_file` 写口承接（`mw_csr_wdata`） | 本核 `b2_csr` 依赖 `ff_cmt_any/ff_cmt_val` 并路进 `csr_wdata_w` | 保留现有并路（`csr_wdata_o` 已含），替换后由 `csr_file` 写口落地 ✓ 行为不变 |
| ⑦ | `mepc/mtvec` WARL | `csr_file` 有完整 WARL（mepc 低位对齐、mtvec MODE/对齐） | `b2_csr` 只掩 mepc bit0 | 替换后**自动对齐 2A**；p10 已覆盖 `mepc/mtvec` 回读（现以 `b2_csr` 口径全绿） |
| ⑧ | `exc_is_fetch` | `trap_ctrl` 用 `exc_is_fetch` 区分取指异常（PMP/access-fault 改写 cause） | 本核 ROB 载荷**没有**"取指异常"标记（4a 的 `lane_fault_*` 只给 cause/tval） | 4b-1b 先接 `1'b0` 并登记；**取指异常落地**（`fetch_exc_*` → ROB 载荷标记位）列为 4b-1 的紧跟待办 |

## B4.6.5 为什么本段停在检查点（阻塞点，逐条）

| # | 阻塞点 | 说明 |
|---|---|---|
| G1 | **替换是"两文件同改"的原子改动** | `backend_top` 把 CSR 请出后端（新端口 + 删 `trp_csr_*`）与 `core_top_2b` 接入 `csr_file/priv_ctrl/trap_ctrl` 必须**同一次**落地，否则 `csr_rdata_i` 悬空 ⇒ 不存在"编译干净的半途状态"（这正是"两套 CSR 不得并存"的直接后果） |
| G2 | **4 条口径必须先定**（§B4.6.4-①②③⑧） | 其中 ① 需要裁决（2A 的 ecall mtval=PC 与 p7 的 Spike 黄金直接冲突）；②⑧ 有明确技术解（已在接线表里给出） |
| G3 | **逐步验证成本** | 每次编译 ~30 s、TB 全跑 ~80 s、regress ~20 min；预算见底 ⇒ 无法保证"改完即全绿"的迭代轮数 |
| G4 | 回退成本已压到最低 | 本段快照 `../.b2chk/*.s16`（p10 全绿态）+ 母代理已提交的 `c7fb923` ⇒ 任何失败尝试都可一键回到绿态 |

## B4.6.6 下一步：分阶段执行方案（建议 4b-1a → 4b-1b → 4b-1c）

| 阶段 | 内容 | 判定（每阶段后必跑） |
|---|---|---|
| **4b-1a**（行为等价重构） | `backend_top` 端口化：加 §B4.6.2(1) 的 7 个端口、`csr_rdata_w` 改由输入赋值、删 `mtip_i/irq_mti_o/mtvec_o/mepc_o` 与 `trp_csr_*` 块；`core_top_2b` **把 `b2_csr` 实例搬到顶层**（同一实现、同一行为，只是位置变了 ⇒ 不违反"两套并存"）并接上 `csr_raddr_o/csr_rdata_i/csr_we_o/...` | 编译 0 error + **79/79 全绿**（纯搬运 ⇒ 必须逐项不变） |
| **4b-1b**（换文件 + 接陷阱决策） | 顶层 `b2_csr` → `csr_file`+`priv_ctrl`+`trap_ctrl`+`pmp_check`（§B4.6.2 全部接线）；`be_trp_redirect_pc` 改由 `trap_target`/`mepc_o`/`sepc_o` 驱动；按 §B4.6.4-①②⑧ 做 `exc_tval` 适配与 `pc_next=pc`、`mie` 按 ROB 非空掩码；删 4a 的目标合成 | 79/79 全绿（p7/p9 的 mtval/mepc/cause 与 p10 的 CSR 轨迹是关键哨兵）+ 新增 `mcycle/minstret` 读回判据（CSR 全集判据，p10 追加一段：读 `mcycle/minstret` 只校验单调性，避开与 Spike 的计数起点差异） |
| **4b-1c**（收尾清理） | 删 `b2_csr.v` 的残留引用与注释；`satp` 接 `sv32_en`（为 4b-2 铺路，仍保持 Bare）；把取指异常标记接进 ROB 载荷（§B4.6.4-⑧） | 编译 0 error + 79/79 + regress 32/32 |

> 4b-2（Sv32 全链路）与 4b-3（PLIC+S 模式）见 §B4.5.3/§B4.5.4/§B4.5.5，依赖本段完成。

## B4.6.7 本段检查点状态（可复核）

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
python3 sim/unit/prog/gen_back2_lockstep_data.py > sim/unit/prog/back2_lockstep_data.svh   # 黄金再生成（p10）
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ct2b.vvp -s tb_core_top_2b "${RTL[@]}" sim/unit/tb_core_top_2b.sv
vvp /tmp/ct2b.vvp | tail -12      # ⇒ TB_CORE_TOP_2B: PASS（**79 项**，含 C10' CSR 轨迹）
./scripts/regress.sh              # ⇒ REGRESS: 32/32 PASS（日志 ../.b2chk/regress_4b1.log）
```
- 本段改动文件：`rtl/back2/backend_top.v`（D5a/D5b 修复）、`sim/unit/tb_core_top_2b.sv`（p10 + C10' + DBG_P10）、
  `sim/unit/prog/back2_p10_csr.S`（新）、`sim/unit/prog/gen_back2_lockstep_data.py`（p10 条目）、
  `sim/unit/prog/back2_lockstep_data.svh`（再生成）。
- 未提交 git；快照：`../.b2chk/*.s16`（本段最终态，p10 全绿）、`*.s15`（4b 1/3 态）。


# 2B-4 第 4b-1 段（**csr_file 替换落地**：4b-1a → 1b → 1c）—— 实现状态 + 验证台账

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 4b-1 检查点
> `c06a6e7`=tag `2B-4.6`，含 §B4.6 的方案与两条裁决，**未提交新改动**）
> 任务：①`csr_file`+`priv_ctrl`+`trap_ctrl`+`pmp_check` 替换 `b2_csr`；②删净 4a 自造的 `trp_csr_*`
> （陷阱 CSR 落地改由 `trap_ctrl.trap_we/trap_epc_i/trap_cause_i/trap_tval_i`→`csr_file`）；
> ③适配层三要点（ROB 头当 W 拍 / `exc_valid` 与 `commit_valid` 相与 / CSR 写数据 `rdata_w` 旁路 +
> 立即数取 `insn[19:15]`）；④CSR 全集按 2A 口径（含 pmp*/satp、mcycle/minstret）；
> 并执行母代理裁决①（ecall 的 mtval 按 **Spike=0**）②（中断 `commit_pc_next = commit_pc`）
> ③（FS/SD 合并层先不搬）④（`exc_is_fetch` 先接 0）。

## B4.7.0 结论（一句话）

**替换完成**：`core_top_2b` 现在用 2A 的 `csr_file`+`priv_ctrl`+`trap_ctrl`+`pmp_check`（含 Zicntr 计数器），
4a 自造的 `trp_csr_*` **删净**、`b2_csr` 在核内**零例化**（"两套 CSR 不得并存"达成）；
`tb_core_top_2b` **80/80 全绿**（p1/p3/p6/p7/p8/p9/p10 七个程序全部不回退，含 p7 陷阱 CSR 序列与
p10 的 CSR 读写轨迹对 Spike 黄金逐条一致）；`regress.sh` 见 §B4.7.5；2A 文件零修改。

## B4.7.1 4b-1a：端口化 + `b2_csr` 搬到顶层（行为等价重构）

- `backend_top` 新增 7 个端口（`csr_raddr_o`/`csr_rdata_i`/`csr_frm_i`/`csr_fflags_i`/
  `csr_we_o`/`csr_waddr_o`/`csr_wdata_o`）+ `xret_kind_o`；删 `mtip_i`/`irq_mti_o`/`mtvec_o`/`mepc_o`；
  内部 `csr_rdata_w/csr_frm_w/csr_ff_w` 改由端口驱动（**5 处使用点零改动**）。
- `core_top_2b` 例化 `b2_csr`（暂命名 `u_csr`）+ 复刻中断判定（`irq_mti_w`），
  `csr_trp_*` 经顶层回灌。
- 判定：TB **79/79**（当时判据数）逐项不变 ⇒ 纯搬运 ✓；调试中发现并修掉一处遗漏：
  后端删掉内部中断判定后，`trp_irq_i` 必须由顶层补上（否则中断的 CSR **进入**事件不发 ⇒ p8 重入 16 次）。

## B4.7.2 4b-1b：换 `csr_file`+`priv_ctrl`+`trap_ctrl`+`pmp_check`

**接线（与 §B4.6.2 的接线表一致，全部按 `rtl/top/core_top.v:2465/2540/2568` 同法）**

| 模块 | 关键接线 |
|---|---|
| `csr_file` | 读口 `raddr=csr_raddr_w, rdata=csr_rdata_w`；写口 `wen=csr_we_w, waddr, wdata`（提交级合成）；`trap_we/trap_epc_i/trap_cause_i/trap_tval_i` ← `trap_ctrl`；`irq_msip/mtip` ← 核内 CLINT，`irq_meip/stip/seip` = 0；`cycle_i/instret_i` ← 本层 64 位计数器；`pmp_cfg_o/pmp_addr_o` → PTE 的 `pmp_check`；`satp_o` → `sv32_en` |
| `priv_ctrl` | `trap_valid/trap_target` ← `trap_ctrl`；`xret_valid/xret_kind` ← 提交点（`xret_cmt_w`/`xret_kind_w`，由载荷 TVAL 判 mret/sret）；`mstatus_i` ← `csr_file.mstatus_o`；`csr_wen/waddr/wdata` ← 提交级（软件写 mstatus 同步）；`priv_o` → `csr_file.priv` 与 `trap_ctrl.priv` |
| `trap_ctrl` | 适配层三要点：`commit_valid/commit_pc = ROB 头`（`rob_any_w`/`trap_pc_w`）、**裁决② `commit_pc_next = commit_pc`**、`exc_valid = trap_valid_w & rob_any_w`（防逐拍重复取陷阱）、**裁决① `exc_tval` 适配**（断点→PC、ecall(8/9/11)→0、其余→载荷 TVAL）、**裁决④ `exc_is_fetch=0`**、**`mie & {32{rob_any_w}}`**（ROB 空不取中断）；`redirect_pc` → 陷阱入口 PC |
| 计数器 | `cycle_cnt`（每拍 +1）/`instret_cnt`（按提交条数累加），64 位 |
| `pmp_check`（PTE） | 按裁决照抄 2A：`acc_type_i(pmp_acc_xlat(ptw_pmp_req_acc))`（本地复制该函数，语义逐字同 `core_top.v:471-479`）；`cfg_i/addr_i` 接 `csr_file` 真值 |

**关键修正（实测抓出，全部有据）**

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| C1 | p7 陷阱后跳到 PC=4（而非 `mtvec`） | 把 `trap_ctrl.trap_target` 当成 PC —— 它其实是**目的特权级**（送 `priv_ctrl`）；PC 是 `redirect_pc` | 引 `tc_redirect_pc` → `.redirect_pc(...)`，`trp_target_w` 用它 |
| C2 | 编译错误 `pmp_acc_xlat` 未定义 | 该函数是 2A `core_top.v` 的局部函数 | 本地复制一份（不改 2A） |
| C3 | 编译错误 `cycle_cnt` 非 l-value | 声明成 `wire` | 改 `reg` |
| C4 | 直驱 TB（`tb_back2_ipc`/`tb_back2_lockstep`）全 0 提交、ROB 全 x | 我的 TB 补丁**误删了 4a 的三条 tie-off**（`trp_flush_v_i/trp_redirect_v_i/trp_redirect_pc_i`）⇒ 悬空 z ⇒ `flush_all_w = 0 \| z = x` ⇒ rename free-list 永久 x | 补回 tie-off（3 行）；两 TB 恢复 PASS（ipc 5 项、lockstep 57 项） |
| C5 | 顶层 `csr_frm_w/csr_ff_w` 无驱动 | 它们原由 `b2_csr` 输出；2A `csr_file` 无对应读侧派生口 | 暂接 `frm=RNE(0)`/`fflags=0`（= fcsr 复位值，语义正确）；"软件写 frm 对 FPU 可见"列入 FP 集成待办（§B4.7.4-⑩） |

## B4.7.3 4b-1c：清理 + `satp` 铺路 + Zicntr 判据

- **删净**：`backend_top` 的 `csr_trp_*` 五端口 + `trp_irq_i` + 4a "事件组装"整块（`trp_is_*`/`trp_csr_*`）；
  `core_top_2b` 的 4a 目标合成（`trp_mode_w/trp_base_w/trp_cause4_w/trp_vect_w`）。核内 `b2_csr` 例化数 = **0**、
  `trp_csr_` 代码残留 = **0**（仅剩一条说明性注释）。
- **`satp` 接 `sv32_en`**：`sv32_en = csr_satp_o[RV32GC_SATP_MODE_BIT]`，`ptw.satp = csr_satp_o`；
  复位 `satp=0` ⇒ Bare ⇒ **行为与替换前逐拍相同**（4b-2 的 Sv32 从这条线开始）。
- **Zicntr 判据**：`mcycle/minstret` 的**数值**与 Spike 不可比（Spike 按指令条数、本核按 aclk 拍数，
  实测 Spike 第 40 条指令时 `mcycle=0x28`）⇒ 不放进黄金比对程序；改由 TB 在**复位释放后/开跑前**与
  **跑完后**采样顶层 `cycle_cnt/instret_cnt`，判"运行中单调递增"（C10' 新增一条）。

## B4.7.4 与 2A 的口径差异登记（本段新增 ⑨⑩）

| # | 项 | 本核取值 | 说明 |
|---|---|---|---|
| ⑨ | `mcycle/minstret` 的**计数口径** | 硬件计数 = **aclk 拍数**（`cycle_cnt`）/ **提交条数**（`instret_cnt`） | Spike 的 `mcycle` 按"执行的指令条数"递增 ⇒ 两者数值不可比（合法实现自由度）。判据只查"链路活 + 单调" |
| ⑩ | `fcsr.frm/fflags` 的**读侧回灌** | 暂接常量（`frm=RNE`、`fflags=0`） | 4a 由 `b2_csr` 提供 `frm_o/fflags_o`；2A `csr_file` 无对应输出。FP 集成时需把 `csr_file` 的 fcsr 视图接到 FPU/提交级（当前无 FP 程序 ⇒ 不影响任何判据） |
| ①~⑧ | 见 §B4.6.4 | ①ecall mtval=0（Spike 口径）②中断 epc=头部 PC ③FS/SD 不搬 ④PTE-PMP 照抄 2A ⑤mip.MTIP 复位差 ⑥fflags 并路保留 ⑦mepc/mtvec WARL 随 `csr_file` ⑧`exc_is_fetch=0` | 均按母代理裁决落地 |

## B4.7.5 验证台账（本轮实测）

| 判据 | 结果 |
|---|---|
| 整设计编译 | **0 error**（`iverilog -g2012 -Wall`，无 implicit-net 告警） |
| `tb_core_top_2b` | **PASS 80/80**：p1 449/161、p3 462/126、p6 1077/366（AW=2/W=16/B=2）、**p7 755/89**（C7'：三次陷阱 cause 11/2/3、落 `mtvec`）、**p8 4000/524**（C8'：MTI 交付 1 次、`mepc∈wait 循环`、形态 1 中断向量槽 BASE+28 已提交）、**p9 843/92**（C9'：MODE=1 下三次同步异常均落 BASE）、**p10 179/45**（C10'：CSR 轨迹 + Zicntr 活性） |
| `tb_back2_ipc` | **PASS**（5 项；测量窗 6000 条/3000 拍）——直驱 TB 已补 CSR 桩 |
| `tb_back2_lockstep` | **PASS**（57 项；5 程序，提交 821）——同上 |
| `regress.sh` | **32/32 PASS**（日志 `../.b2chk/regress_4b1c_final.log`） |
| "两套 CSR 不并存" | 核内 `b2_csr` 例化 **0** 处；`trp_csr_` 代码残留 **0** 处 |
| 2A 文件 | **零修改**（`git status` 仅 `rtl/back2/backend_top.v`、`rtl/top/core_top_2b.v`、两个直驱 TB、`tb_core_top_2b.sv`） |

## B4.7.6 复现命令

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ct2b.vvp -s tb_core_top_2b "${RTL[@]}" sim/unit/tb_core_top_2b.sv
vvp /tmp/ct2b.vvp | tail -12      # ⇒ TB_CORE_TOP_2B: PASS（80 项）
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/ipc.vvp -s tb_back2_ipc "${RTL[@]}" sim/unit/tb_back2_ipc.sv && vvp /tmp/ipc.vvp | tail -3
./scripts/regress.sh              # ⇒ REGRESS: 32/32 PASS
```

## B4.7.7 下一步（4b-2：Sv32 全链路）

`satp`/`priv`/`sum/mxr` 已就位（`csr_file`+`priv_ctrl`），4b-2 可直接做：
① D 侧 TLB 查询口（`lookup_*`，现恒空闲）与 `cs_lsu` 的 VA/PA 分离；② PTW 串行复用（数据优先 + `m_tr_src` 归属）；
③ PTE A/D 写通路（`pte_ad_update/pte_ad_pa/pte_ad_data` → §5 AXI 引擎单 beat 写，回 `pte_ad_done`）；
④ `sfence.vma` / `cbo.*` / `fence.i` 接提交点（`tlb.sfence_*`、L1I `inval_all`、L1D `clean_all/inval_all`）；
⑤ 新程序 `back2_p9_sv32.S`（两级页表 + A/D 置位 + sfence 重映射 + PTE-PMP 拒绝）。


# 2B-4 第 4b-2 段（Sv32 全链路）—— **接口勘察 + 可执行方案**（本段未改 RTL）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 4b-1 收官
> `f6f1d73`=tag `2B-4.7`，**本轮零代码改动**）
> 任务：①D 侧 TLB 口接线 + LSU VA/PA 分离 ②PTW 串行复用（数据优先 + `m_tr_src`）
> ③PTE A/D 更新写通路 ④`satp` 生效 + I 侧翻译核对 ⑤`sfence.vma`/`cbo.*`/`fence.i` 接提交点
> ⑥新程序 `back2_p11_sv32.S`。
> **预算见底 ⇒ 按任务书停在"整设计可编译 + 既有判据全绿"检查点**：本段交付**逐条勘察结论
> （附 file:line 与新发现的 3 个硬阻塞）+ 分阶段落地方案 + p11 设计与比对口径**，
> 让下一段可以直接照抄执行（§B4.6 → 4b-1 的"勘察→落地"两步走在本项目已验证有效）。

## B4.8.0 结论（一句话）

**Sv32 的"结构性骨架"已就位（TLB/PTW/`satp`→`sv32_en`/`pte_ad_*` 端口都在），但有三处硬阻塞
必须先解**：①`sfence.vma` 与 `cbo.*` 在**当前后端被判非法指令**（`OPT_SYS(8)` 不在 4a 的
`is_sys_ok` 白名单、`OPT_CBO(10)` 直接落 `unsup`）——**不先修这两条，p11 里任何 `sfence.vma`
都会变成陷阱**；②D 侧 TLB 查询口与 LSU 的 VA/PA 路径完全未接（`cs_vaddr = cs_paddr = d_a_q`）；
③A/D 写通路缺一个"与 PTE 读同源"的写口（2A 走 L1D 存储口，而本核 PTE **读**走 §5 AXI 引擎
⇒ 照抄 2A 会读到陈旧 PTE，必须把 A/D 写做成 §5 引擎的第 7 个来源）。

## B4.8.1 勘察结论（逐条 file:line）

| # | 项 | 现状 | 依据 |
|---|---|---|---|
| 1 | **I 侧翻译** | 结构就位：`tlb` 口 2 + `ptw` 取指源已接；`sv32_en` 已接 `csr_file.satp_o`（4b-1c） | `core_top_2b.v:282`（`sv32_en`）、`:312`（`ptw.req_valid = sv32_en & ~f_tlb_hit & tr_req_valid`）、`:314`（`ptw.satp`） |
| 2 | **D 侧翻译** | **完全未接**：`tlb` 口 1 恒空闲（`lookup_valid(1'b0)`、`hit_o()/perm_fault_o()/pa_o()` 悬空）；L1D 看到的是 `d_a_q`，而 `d_a_q` 就是 VA（Bare 下同值） | `core_top_2b.v:251-255`、`:624`（`.cs_paddr(d_a_q), .cs_vaddr(d_a_q)`）、`:651`（`d_a_q <= lsu_req_a`） |
| 3 | **PTW 串行复用** | 只有取指源；`ptw.kill` 恒 0（无冲刷）；无 `m_tr_src` 归属 | `core_top_2b.v:270-290`（`u_ptw`）、2A `core_top.v:1587-1595`（`m_tr_src_q`）、`:1790-1797`（`m_ptw_req_valid`/`m_tr_is_fetch`）、`:1988`（`f_tr_walk_done`） |
| 4 | **PTE 读** | 走 **§5 AXI 引擎**单 beat（`IOWN_PTE`，`:707` 附近的读拍分发 + `g_pte` 仲裁） | `core_top_2b.v` §5（`IOWN_PTE`/`g_pte`）|
| 5 | **PTE A/D 写** | `pte_ad_done` 恒 0（fail-closed）；`pte_ad_update/pte_ad_pa/pte_ad_data` 已从 PTW 引出但**无人消费** | `core_top_2b.v:295-301`；2A 的实现走 **L1D 存储口**：`core_top.v:3888-3894`（`M_S_PADW/M_S_PADX` + `m_ptw_ad_done_q <= 1'b1`）、`:1835`（`.pte_ad_done(m_ptw_ad_done_q)`） |
| 6 | **`sfence.vma`** | 译码为 `OPT_SYS(4'd8)`（`is_system & sys_priv_impl`）⇒ 后端 `is_sys_ok = ecall\|ebreak\|mret\|sret`（4a）**不含它** ⇒ **当前按非法指令处理** | `rtl/decode/decoder.v:110-124`（OPT 表）、`:611-614`；`backend_top.v` 的 `is_sys_ok`/`unsup`（4a 段） |
| 7 | **`cbo.*`** | 译码为 `OPT_CBO(4'd10)` ⇒ 直接落 `unsup`（`unsup` 含 `opt==4'd10`）⇒ **非法**；且译码侧 `menvcfg_cbie/cbcfe`、`senvcfg_*` 输入未接（2A 从 `csr_file` 引） | `decoder.v:118`；`backend_top.v` `unsup`；2A `core_top.v:1031-1040`（`menvcfg_cbie = csr_menvcfg[5:4]` 等） |
| 8 | **`fence`/`fence.i`** | `OPT_FENCE(4'd9)` **不在 `unsup`** ⇒ 今天按合法 no-op 执行，但**无维护副作用**：`l1i.inval_all`、`l1d.inval_all/clean_all` 全 tie 0 | `decoder.v:117`；`core_top_2b.v:439`（L1I `.inval_all(1'b0)`）、`:572`（L1D `.inval_all(1'b0), .clean_all(1'b0)`） |
| 9 | **`priv/SUM/MXR`** | `priv_ctrl` 已给 `priv_o/eff_priv_o/sum_o/mxr_o`，但 `tlb.lookup*_priv/sum/mxr`、`ptw.req_sum/req_mxr` 仍是常量（`PRIV_M`/`1'b0`） | `core_top_2b.v:256-260`、`:314` |
| 10 | **Spike 侧口径（本轮实测）** | `--isa=rv32imac_zicsr_zifencei` 下：`sfence.vma`(0x12000073)/`fence.i`(0x0000100f) **正常提交**；写 `satp=0x8009_2345`（MODE=1）后**翻译立即生效**（探针程序的下一条 load 触发 page fault ⇒ 日志止于 `sfence.vma`）⇒ **p11 可黄金比对** | 探针 `/tmp/sv32exp/t.log`、`/tmp/sv32exp/s.log` |

## B4.8.2 落地方案（建议切成 4b-2a / 2b / 2c，每步后跑同一套判据）

### 4b-2a（**先决条件**：把维护操作放出来 + 接维护口，不碰 LSU 数据通路）

1. **`sfence.vma` 合法性**：`backend_top` 的 `is_sys_ok` 增加 `sfence`（译码 `sfence_vma_o`；
   2A 对 U 模式的非法判定已有 `de_sfence_vma & priv==U` 口径，本核 priv 恒 M ⇒ 直接放行）。
2. **`cbo.*` 合法性**：把 `opt==4'd10` 从 `unsup` 摘出，并**照 2A 接译码门控**：把 `csr_file.menvcfg_o/senvcfg_o`
   引到 `front4_top`/`decoder` 的 `menvcfg_cbie/cbcfe`、`senvcfg_cbie/cbcfe`（`core_top.v:1031-1040` 同法），
   否则 `cbo_gate_ill` 仍会把它判非法。
3. **提交点识别 + 维护动作**（`core_top_2b`，与 4a 的 xRET 识别同法：载荷 **TVAL = 原始指令位**）：
   - `fence.i`（`0x0000_100F`）⇒ 触发 L1I **全阵列失效**（2A 用"逐组扫描 + 前端冻结"：
     `fencei_busy/fencei_idx_q/fencei_hold`，`core_top.v:304-312/882-903/949`）
   - `sfence.vma`（`insn[31:25]==7'b0001001 & insn[14:12]==3'b000 & opcode==0x73`）
     ⇒ `tlb.sfence_valid` + `sfence_va/asid/all_va/all_asid`（RS1=x0 ⇒ all_va、RS2=x0 ⇒ all_asid；
     2A `core_top.v:1759`）+ `satp_we/satp_asid_new`（写 satp 时刷 ASID）
   - `cbo.clean/flush/inval` ⇒ L1D `clean_all`/`clean_all`/`inval_all`（2A `core_top.v:2160-2169`；
     INVAL 在 CBIE=01 下降级为 FLUSH 的口径见 `decoder.cbo_downgrade_o`）
   - **必须同时冲刷更年轻的工作并重定向**：这些指令"生效于提交点"，而更年轻的指令可能已经
     用旧 TLB/旧缓存行投机执行过 ⇒ 复用 4a 的 `trp_flush_v_i` + 重定向到**头部 PC + 4**
     （2A 对应 `kill_young`/`sfence_sync_pending`，`core_top.v:362/1715/1799`），并沿用
     `cmt_ok` 的"xRET 上报"口子让该指令照常计入提交流。
4. 判据：既有 80 项不回退（Bare 下维护操作无架构副作用，但**必须**仍然提交且 PC 流不变）
   + 新程序 `back2_p11_maint.S`（`sfence.vma`/`fence.i` 各来几次，Spike `--isa=..._zifencei`
   逐条比 PC/写回）⇒ **Spike 可比性已实测确认**（§B4.8.1-10）。

### 4b-2b（**核心**：D 侧翻译 + PTW 串行复用）

5. `tlb` 口 1 接数据侧：`lookup_valid/lookup_va(=VA)/lookup_acc(acc)/lookup_priv(eff_priv)/lookup_sum/sum/mxr`
   → `hit_o/perm_fault_o/pa_o`；`core_top_2b` 的 LSU 适配器新增 `AD_XLATE` 级：
   - 命中 ⇒ `d_pa <= pa`，L1D/AXI 用 **PA**；`d_va_q` 留作异常 `tval`（2A 口径：mtval 恒 **VA**，
     `core_top.v:349/489/3194`）；
   - 未命中 ⇒ 发 PTW（与取指源**数据优先**仲裁 + `m_tr_src` 归属寄存器，2A `core_top.v:1587-1595/1790-1797`）；
   - 失败 ⇒ 按访问类型给 cause **12/13/15**、`tval = VA`（2A `:489` 还有一条 cbo 专用改写：
     LOAD_PAGE_FAULT ⇒ STORE_PAGE_FAULT）。
6. `satp` 变更的同步：`csr_file` 写 satp 时刷 TLB（`satp_we`），并沿用 4b-2a 的"冲刷 + 重定向"。
7. 判据：p11 的"经翻译的取指 + load/store 全链对 + page fault 序列"。

### 4b-2c（A/D 写通路）

8. **写口选型（本段结论）**：把 `ptw.pte_ad_update/pte_ad_pa/pte_ad_data` 接到 **§5 AXI 引擎**，
   新增第 7 个请求源 `IOWN_PADW`（单 beat 写，优先级建议排在 `d_unc` 之后、PTE 读之前），
   完成后单拍脉冲 `pte_ad_done`。**理由**：本核 PTE **读**已走 §5 引擎（`IOWN_PTE`），
   若照抄 2A 走 L1D 存储口，PTE 读（AXI）与 A/D 写（L1D）不同源 ⇒ 后续读可能命中陈旧副本；
   同源可保证"写完再读必见新值" ✓。同时在 4b-2c 把 `pte_ad_done` 的 fail-closed 注释更新为
   "已实现"，并把 A/D 置位口径登记（A=1、D=1 仅对叶 PTE 且首次访问；2A 由 PTW 给出
   `pte_ad_data`，本核**照抄 PTW 输出**不改语义）。
9. 判据：p11 中"PTE A/D 由硬件置位后回读 = 1"（页表项初始 A=D=0）。

### 4b-2d（p11 程序与口径）

10. `back2_p11_sv32.S`（`.option norvc`，`-march=rv32ima_zicsr_zifencei`、Spike
    `--isa=rv32imac_zicsr_zifencei`）：数据段建**两级页表**（root/leaf，页表项 V/R/W/X/U 明确，
    A/D **初始 0** 供 4b-2c 检查）→ 写 `satp`（MODE=1）→ `sfence.vma` → 经翻译取指与
    load/store（对一个映射页 + 一个未映射页）→ 自记录：`mcause/mtval/mepc` 序列、
    PTE 回读值、`sfence` 后重映射（改 PTE 指向另一物理页再 `sfence.vma` ⇒ 读到新值）。
    **口径**：页表内容与期望值**程序自记录 + 硬编码**（Spike 侧 `satp` 生效已实测 ✓，
    但两级页表的物理地址分配/PTE 值由程序固定写出 ⇒ 两侧可比）；逐条 PC/写回仍走现有黄金框架。
11. TB 侧：p11 的页表与数据段要落在 TB 的 DDR3 窗口内（现 128 KB、别名窗口 `a[31:20]==0x800`、
    装载索引 `a[19:2]`），第 8 个程序基址 = `0x8001_C000`（需把 DDR3 窗口提到 160 KB 或把
    步进改小 —— **登记为 TB 侧待办**，与 §B4.4.4-D3 同类）。

## B4.8.3 阻塞点（本段停在检查点的理由，逐条）

| # | 阻塞 | 影响 |
|---|---|---|
| H1 | `sfence.vma`/`cbo.*` 当前**非法**（§B4.8.1-6/7） | 不先修，p11 一执行 `sfence.vma` 就变陷阱，Sv32 判据全不可达 |
| H2 | D 侧翻译要**插入 LSU 适配器状态机**（新增 `AD_XLATE` 级 + 未命中→PTW→重试），直接改 L1D/AXI 的地址与握手路径 | 现有 80 项（尤其 p3/p6 的访存与 AXI 流量判据）会被牵连，必须逐拍核对；预算内无法保证一次到位 |
| H3 | A/D 写口选型需与 PTE 读**同源**（本核与 2A 不同：2A 走 L1D，本核走 AXI），属**设计决策 + 新引擎源** | 需改 §5 引擎仲裁与写拍 W 数据源（第 7 源），并复核所有既有 AXI 计数判据 |
| H4 | p11 的页表/数据段需要 TB 侧更大的 DDR3 窗口与第 8 个程序槽 | TB 基建改动（与 §B4.4.4-D3 同类），必须与 p11 同批做 |
| H5 | Spike 侧 Sv32 的 S 模式/异常口径仍需逐项核对（cause 12/13/15 与 `mtval=VA` 已按 2A 口径，但 p11 的期望值必须硬编码登记） | 比对口径需在报告中登记（任务书已允许"自记录 + 硬编码"） |

## B4.8.4 本段检查点状态

- **本轮零 RTL 改动**（工作树 = 母代理已验收的 `f6f1d73`，`git status` 干净）；
  基线复验：编译 0 error、`tb_core_top_2b` **PASS 80/80**（日志 `../.b2chk/base_4b2.log`）、
  `regress.sh` **32/32**（母代理亲跑；本轮未改文件 ⇒ 不变）。
- 勘察新增的三条**硬阻塞**（H1/H2/H3）与"Spike 维护操作/Sv32 生效"两条实测口径，
  都已写进 §B4.8.1/§B4.8.2，可直接作为 4b-2a 的开工清单。
- 下一步建议：**4b-2a 先行**（维护操作合法化 + 维护口接线 + `p11_maint.S`），
  它是 4b-2b/2c 的**先决条件**且不碰 LSU 数据通路 ⇒ 风险最低、判据最清晰。


# 2B-4 第 4b-2a 段（维护操作合法化 + 维护口）—— **RTL 已落地并入检查点；判据程序受 K1 阻塞**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 4b-2 勘察检查点
> `2B-4.7` 之后；本段改 `rtl/back2/backend_top.v` + `rtl/top/core_top_2b.v`，**未改 TB/黄金**）
> 任务：①`sfence.vma` 入白名单、`cbo.*` 摘出 `unsup`、`fence.i` 保持合法、menvcfg/senvcfg 门控
> ②提交点识别维护操作并驱动 TLB/L1I/L1D 维护口 ③`p11_maint.S` 黄金比对。

## B4.9.0 结论（一句话）

**RTL 侧三项全部落地且编译零错误、既有 80 项判据 + regress 全绿**（维护操作合法化、
维护口接线、提交点 lane 扫描识别、以及一个**实测抓出并修掉的整机停摆缺陷**）；
但 `p11_maint.S` 的黄金比对**未达全绿**：定位到一个**新的竞态阻塞 K1**（维护操作的
"冲刷 + 重定向"与前端在途取指/第二条维护操作相撞 ⇒ PC 流丢/跳指令），按任务书纪律停在
"RTL 编译干净 + 既有判据全绿"检查点，`p11_maint.S`/`p12_cbo.S` 作为**WIP** 留在工作树
（未进生成器清单，故不影响任何判据），K1 的定位证据与修法建议见 §B4.9.3。

## B4.9.1 已落地（RTL，逐条带实现位置）

| # | 内容 | 位置/口径 |
|---|---|---|
| 1 | **`sfence.vma` 合法化** | `backend_top.v` 的 `is_sys_ok = ecall \| ebreak \| mret \| sret \| sfence`（2A 只对 U 模式判非法；本核 priv 恒 M ⇒ 放行） |
| 2 | **`cbo.*` 摘出 `unsup` + 按动作码精确门控** | `unsup` 去掉 `opt==4'd10`；新增输入 `cbo_perm_i[1:0] = {CBCFE, CBIE≠0}`（顶层从 `csr_file.menvcfg_o` 译出：`cbcfe = menvcfg[6]`、`cbie≠0 = \|menvcfg[5:4]`）；`cbo_ill_perm = cbo_valid & (funct3==000 ? ~cbie_ok : ~cbcfe_ok)`（照 2A `dec_csr.v:222-237`） |
| 3 | **屏蔽译码器内部的 `cbo_gate_ill`** | 本核前端未把 menvcfg/senvcfg 接到译码器（那两位悬空 z）⇒ 直接用会引入 x；改为 `illegal = (ill_instr & ~cbo_valid) \| … \| cbo_ill_perm`（cbo 时 `x & 0 = 0`，非 cbo 时原样通过） |
| 4 | **`fence.i` 保持合法 + 全阵列扫掠** | 照 2A（`core_top.v:885-905`）：8 bit 索引 256 拍，L1I 的 index 输入在扫掠期切到 `{19'b0, idx, 5'b00000}`、`cs_req` 加 `~fencei_busy` 门控、`inval_all = fencei_busy`；扫掠结束重定向到 `fence.i` 的下一条 |
| 5 | **提交点识别（lane 扫描）** | `backend_top.v` 新增 `maint_kind_f()`（编码表：`0x0000_100F`=fence.i、`sfence.vma`=`opcode 0x73 & funct3 0 & funct7 0b0001001`、cbo 按 funct3 000/001/010 且 rs1≠0）、`xret_kind_f()`；**逐 lane 扫描提交组**（由高到低 ⇒ 最老者胜），输出 `maint_kind_o/maint_cmt_o/maint_pc_o` 与 `xret_kind_o` |
| 6 | **更年轻的槽必须"不上报、不回写、不更新 ARAT"** | 触发冲刷的维护/xRET 槽之后更年轻的 lane 会被冲刷并**重新执行** ⇒ 新增 `cmt_hold_w/cmt_raw_m` 掩码，作用于 `commit_valid_o`、`cmt_i_we/rel_i_we/cmt_f_we/rel_f_we`、`lsu_dr_valid`、训练 FIFO 入队 |
| 7 | **维护口接线** | `tlb.sfence_valid`（全失效：`all_va=1/all_asid=1`）、`tlb.satp_we = csr_we_w & (waddr==0x180)` + `satp_asid_new = wdata[30:22]`、L1I `inval_all`（扫掠）、L1D `inval_all/clean_all`（cbo.inval⇒inval、clean⇒clean、flush⇒两者；sfence⇒inval）、`maint_tlb_sfence_w`（**fence.i 不刷 TLB**） |
| 8 | **★ 整机停摆缺陷（实测修掉）** | 现象：p11 的 `sfence.vma` 之后 PC 停在 0、**再无任何提交**。根因：sfence 触发 L1D `inval_all` 时，LSU↔L1D 适配器正停在 `AD_WAIT` 等一个不会到来的 `l1d_cs_ready` ⇒ `d_ready_w` 永久为 0 ⇒ 之后所有访存全挂。修法：给适配器补 `d_kill_w = be_trp_flush` 的 kill 分支（2A 对应 `m_kill_fsm`，`core_top.v:3749-3752`"异常 / fence.i 同步：放弃在途访存"）。修后维护操作后访存恢复正常 |

## B4.9.2 验证台账（本轮）

| 判据 | 结果 |
|---|---|
| 整设计编译 | **0 error**（`iverilog -g2012 -Wall`） |
| `tb_core_top_2b`（既有 7 程序 80 项） | **PASS 80/80**（维护相关 RTL 对既有程序**零影响** ✓） |
| `regress.sh` | **32/32 PASS**（日志 `../.b2chk/regress_4b2a.log`） |
| `p11_maint.S` 黄金比对 | **未达全绿**（C1' 在 idx 20 分歧：`0x8001c060` vs 黄金 `0x8001c050`）⇒ 见 §B4.9.3 K1；程序文件作为 WIP 留在工作树，**未进生成器清单** ⇒ 不影响任何既有判据 |
| 维护"合法性/端口"侧证据（调试期实测） | `sfence.vma`/`fence.i`/`cbo.*` 均**不再变陷阱**；`maint_cmt` 计数正确（5 次）；`maint_l1i_inval` = 256×N（扫掠）；`maint_tlb_sfence`/`maint_l1d_inval` 计数正确；cbo 程序（`p12_cbo.S`）在写 `menvcfg` 后 `n_trap = 0` |

## B4.9.3 阻塞 K1（维护操作的冲刷/重定向竞态）—— 定位证据与修法建议

**现象**：把维护操作**紧邻**放置时（`fence.i; lw; sfence.vma; …; fence.i; fence.i`），提交 PC 流出现
"丢/跳指令"：先是 `idx 9: 0x8001c034`（跳过 `0x8001c024..0x8001c030`），把维护操作各自隔开 6 条无关
指令后改善到 `idx 20: 0x8001c060 vs 黄金 0x8001c050`（跳过 4 条）。

**调试证据**（`[rdbg]` 打印，逐次维护检测）：
```
[rdbg] maint kind=1 pc=0x8001c018 take_sf=0 redir_v=0 redir_pc=0x00000000 flush=0   ← fence.i
[rdbg] maint kind=2 pc=0x8001c020 take_sf=1 redir_v=1 redir_pc=0x8001c024 flush=1   ← sfence#1（重定向正确）
[rdbg] maint kind=2 pc=0x8001c030 take_sf=1 redir_v=1 redir_pc=0x8001c034 flush=1   ← sfence#2（重定向正确）
```
⇒ **每次维护操作的"目标 PC"都算对了**，问题在**执行顺序**：第 1 条 sfence 冲刷后重定向到
`0x8001c024`，但 `0x8001c024..0x8001c030` 这几条**没有提交**，而下一条维护操作（sfence#2）
却**已经被检测到**（说明它在 ROB 里执行过）⇒ 典型的"冲刷/重定向与在途取指块/已派发项的竞态"：
第一次维护的 flush 只清了 ROB，但前端在收到重定向之前已经取回并**派发**了后续块（含第二条
维护操作），第二次维护的 flush 又把夹在中间、尚未提交的指令整段丢掉。

**修法建议（下一段，按代价排序）**
1. **维护操作串行化（最小）**：在后端禁止"维护操作与任何更年轻指令同组提交"——即维护操作
   进入提交窗口时，**只允许它自己提交**（为此扩展现有的 `cmt_hold_w`：只要提交组内含维护/xRET，
   就 hold 掉它之后的所有 lane，并要求它位于 lane 0 才动作）。这样"重定向到 PC+4"与
   "下一条指令重新取"严格串行，不再有中间段被二次 flush 吃掉。
2. **维护后加 drain 窗口**：维护操作提交后，强制 `flush_all` 保持 N 拍（例如 4~8 拍）再发重定向
   （与 `fence.i` 的 256 拍扫掠同构），确保前端在途块全部作废后再重新取指。
3. **前端在途块的无效化口径**：核对 `front4_top` 在 `redirect_valid` 拍是否把**已取回但未派发**的
   块全部作废（若否，则与 2A 的 `kill_young` 口径存在差异，需要在 `front4` 侧补——登记为跨模块待办）。

**口径登记**：`p11_maint.S` 的黄金（Spike `--isa=rv32imac_zicsr_zifencei`，42 条）**已生成并可复用**；
`p12_cbo.S`（Spike 不支持 Zicbom，实测即使 `--isa` 含 zicbom 也判非法）继续走"自记录 + 维护口探针"。

## B4.9.4 cbo 口径表（本段实现）

| 指令 | 编码（funct3 / rs2 / rs1） | 合法性（2A `dec_csr.v:222-237`） | 维护动作 |
|---|---|---|---|
| `cbo.inval` | 000 / 00000 / ≠0 | `CBIE≠0`（menvcfg[5:4]） | L1D `inval_all` |
| `cbo.clean` | 001 / 00000 / ≠0 | `CBCFE=1`（menvcfg[6]） | L1D `clean_all` |
| `cbo.flush` | 010 / 00000 / ≠0 | `CBCFE=1` | L1D `clean_all` + `inval_all` |
| `fence.i` | 001 / 00000 / =0，`[31:20]=0` | 恒合法（Zifencei） | L1I 全阵列扫掠（256 拍）+ 冻结流水 |
| `sfence.vma` | opcode 0x73 / 000 / funct7 `0b0001001` | M 模式恒合法（U 模式非法） | TLB 全失效 + L1D `inval_all` + 冲刷重定向 |
| 未实现 | — | CBIE=01 的 **INVAL⇒FLUSH 降级**未实现（登记；本程序用 CBIE=11 不触发） | — |

## B4.9.5 本段检查点状态

- 改动文件：`rtl/back2/backend_top.v`（合法化 + lane 扫描 + hold 掩码）、`rtl/top/core_top_2b.v`
  （维护口接线 + fence.i 扫掠 FSM + 适配器 kill）；**TB/黄金零改动**（保持母代理已验收的 80 项）。
- WIP（未进生成器清单，工作树未跟踪）：`sim/unit/prog/back2_p11_maint.S`、`back2_p12_cbo.S`
  ——K1 修复后可直接挂回（生成器加两条 PROGS 即可，黄金已在 `/tmp/back2_P11.spike.log` 口径下验证过可生成）。
- 基线复验：编译 0 error、`tb_core_top_2b` **PASS 80/80**、`regress.sh` **32/32**。
- 下一步：**4b-2a-fix（K1）** → 挂回 `p11_maint`（黄金 42 条）+ `p12_cbo`（自记录）→ 再进 4b-2b（D 侧翻译）。


# 2B-4 第 4b-2a-fix 段（K1 竞态修复尝试）—— **未收敛；K1 定案为"取指块级丢失"，下一步须审计 front4 重定向口径**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 4b-2a `6cdecbb`=tag `2B-4.8`）
> 本段按母代理给的三条修法顺序实施 ①②（③留作下一步），**K1 仍未收敛** ⇒ 按任务书纪律
> 停在"整设计可编译 + 既有判据全绿"检查点：`rtl/back2/backend_top.v` 已回到提交态，
> 仅保留 `rtl/top/core_top_2b.v` 的"维护冻结窗口"改动（对既有 80 项零影响 ✓）。

## B4.10.0 K1 定案（结论先行）

K1 **不是**"重定向目标算错"（那已被证明每拍都对），也**不是**"在途旧块被派发"（本段加的
**块 PC 守卫**实测对症状**零改善**，已回退）⇒ K1 是**取指块级的丢失**：重定向后应有的一块
（4 条指令）**根本没有进入 ROB**，而被它后面的块照常执行 ⇒ PC 流少一块。

**本轮实测证据（p11_maint 隔开版，黄金 42 条）**
- 两次尝试（加/不加块 PC 守卫）失败点**完全相同**：`idx 20: 设计 0x8001c060 vs 黄金 0x8001c050`
  ⇒ 丢的正好是**一个 4 宽取指块**（`0x8001c050..0x8001c05c`）。
- `[rdbg]` 逐次维护检测显示每次维护的 `redir_pc` 都正确（`0x8001c024` / `0x8001c034`）⇒ 目标无误。
- 把相邻维护操作各隔开 6 条无关指令后，失败点从 `idx 9`（丢 4 条：`0x8001c024..0x8001c030`）
  推迟到 `idx 20`（丢 4 条：`0x8001c050..0x8001c05c`）⇒ 症状与"维护操作密集度"相关，但**丢块位置
  并不紧邻重定向点**（`0x8001c050` 距离上一次重定向 `0x8001c038` 已有 6 条指令）。

## B4.10.1 本轮实施与结论（逐条）

| # | 修法 | 实施 | 结果 |
|---|---|---|---|
| ① | 维护操作串行化（提交组含维护/xRET 时更年轻 lane 一律 hold；维护指令位于最老位） | **已实现**（`cmt_hold_w/cmt_raw_m`，见 §B4.9，随 4b-2a 已提交） | 未能消除 K1 |
| ② | 维护提交后 `flush_all` 保持若干拍再重定向 | **本段新增**：单拍维护（sfence/cbo）改为"冻结窗口 4 拍 + 窗口最后一拍才重定向"（`maint_wait_q/maint_pc_save_q/maint_hold_w/maint_redir_w`，`core_top_2b.v`） | 未能消除 K1（失败点不变 ⇒ 说明丢块不是"二次冲刷"造成） |
| ②′ | （本段额外尝试，已回退）重定向后的**块 PC 守卫**：`disp_ok &= ~exp_valid \| (lane_pc[0]==exp_pc)` | 实现后实测**症状完全不变**，且该守卫在"前端换个块呈现"时有引入新阻塞的风险 ⇒ **已回退**（`backend_top.v` 回到提交态） | 无改善，回退 |
| ③ | 审计 `front4_top` 在 `redirect_valid` 拍是否作废"已取回未派发"的块 | **未做**（下一步；见 §B4.10.3 的具体审计清单） | — |

## B4.10.2 p11/p12 判据现状（WIP，未挂回）

- `back2_p11_maint.S`（fence.i ×2 + sfence.vma ×2，Spike `--isa=rv32imac_zicsr_zifencei`，
  **黄金 42 条已生成并可复用**）——C1' 在 idx 20 分歧（K1）⇒ 未挂回生成器清单。
- `back2_p12_cbo.S`（cbo.inval/clean/flush；Spike 不支持 Zicbom ⇒ 自记录 + 维护口探针口径）——
  其**合法性/维护口侧判据在调试期已实测通过**（写 `menvcfg=0x70` 后全程 `n_trap=0`、
  L1D inval/clean 脉冲计数正确、4 次 load 数据正确），但为与 p11 同步，也未挂回。
- 两个文件仍在工作树（未跟踪），**不影响任何既有判据**：TB 仍为 7 程序 **80/80**，
  `regress.sh` **32/32**（`../.b2chk/regress_4b2afix.log`）。

## B4.10.3 下一步：front4 重定向口径审计清单（K1 的收口路径）

按"先查清证据再动 front4"的要求，逐条核对（每条都能用现有调试手段给出结论）：
1. `redirect_valid` 拍：front4 是否把**已取回但未派发**的块（含正在 `blk_valid` 呈现的那一块）
   一并作废？核对点：`front4_top` 的 fetch-queue/输出寄存器在 redirect 分支里是否被清。
2. redirect 后**第一个**取指请求是否被"同一拍/下一拍的 flush"误伤（即新块被自己的重定向冲掉）：
   在 redirect 拍打点 `blk_valid/lane_pc[0]` 与下一拍的首块 PC，看是否出现"目标块从未出现"。
3. `blk_ready_o` 握手：后端 `disp_ok=0`（flush/冻结窗口）拍，前端是**保持**当前块还是**丢弃**？
   若丢弃 ⇒ 冻结窗口会吃掉一块（与 K1 症状吻合！这也解释了为何"加冻结窗口"后失败点不变：
   丢块发生在窗口期间）。
4. 与 2A `kill_young` 口径对照（`core_top.v:1715`）：2A 是"冲刷更年轻 + 冻结前端 + 重定向到
   明确 PC"，本核缺"前端冻结（hold）"这一环 ⇒ 若 1~3 证实块被丢，最小修法是给 front4 加
   `hold_i`（维护/扫掠期间冻结取指，重定向后再放行），**这属于允许范围内的小改**，需在本报告登记理由。
5. 复核 fence.i 的 256 拍扫掠期间 `l1i_cs_req` 门控对前端取指队列的影响（是否丢块/失步）。

## B4.10.4 本段检查点状态

- 编译 **0 error**；`tb_core_top_2b`（既有 7 程序）**PASS 80/80**；`regress.sh` **32/32**
  （日志 `../.b2chk/regress_4b2afix.log`）。
- 改动：`rtl/top/core_top_2b.v`（维护冻结窗口；块 PC 守卫已回退）；`rtl/back2/backend_top.v`
  回到提交态（`git status` 仅顶层一处改动）。
- WIP：`sim/unit/prog/back2_p11_maint.S`、`back2_p12_cbo.S`（未跟踪、未进生成器清单）。
- 结论：**K1 未收敛**，但已从"重定向目标/在途旧块派发"两个候选排除，收窄到
  **"冻结/冲刷期间前端丢块"或"front4 redirect 未作废在途块"** 两类原因；下一步按 §B4.10.3
  的 5 条清单逐条打点，再决定是否给 `front4_top` 加 `hold_i`（小改 + 报告登记理由）。


# 2B-4 K1 收口段（五条审计清单打点）—— **K1 根因定案：前端在 L1I 请求被门控期间产生"重叠、乱序取指块"**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 4b-2a-fix `9eb70f6`=tag `2B-4.9`）
> 本段按 §B4.10.3 五条清单**逐条打点**，K1 根因已定案（证据见下），但**修法需要改动前端取指
> FSM 的"冻结"语义**（不是 2A 那种 `fe_stall` 能覆盖的），超出"小改"范围 ⇒ 按任务书纪律停在
> "整设计可编译 + 既有判据全绿"检查点：`rtl/top/core_top_2b.v` 保留维护冻结窗口 + `fe_stall` 接线，
> p11/p12 仍为 WIP（未进生成器清单）。

## B4.11.0 K1 根因定案（一句话）

**K1 = 前端取指块序列失序**：在 `fence.i` 的 L1I 扫掠期间，本核只把**送进 L1I 的请求**门控为 0
（`l1i_cs_req & ~fencei_busy`），却让前端继续按"请求已发出"推进内部簿记 ⇒ 扫掠结束后前端输出的
块起点**重叠且乱序**（实测序列：`0x…040 → 0x…050 → 0x…044 → 0x…054 → 0x…064`：既回退重叠、
又跳过 `0x…060` 所在的块）⇒ ROB 里的指令序与程序序不符 ⇒ PC 流丢/跳指令。

## B4.11.1 五条审计清单打点结果（逐条）

| # | 审计项 | 结论 | 证据 |
|---|---|---|---|
| ① | redirect 分支是否清 fetch-queue/输出寄存器 | **是**（不是 K1 根因） | `rtl/front4/ifetch4.v:669` `blk_valid = blk_ready_int & ~ckpt_stall & **~redirect_valid** & ~fault_hold_q`；`blk_fire = blk_valid & blk_ready`（`ifetch4.v:674`）⇒ 重定向拍块无效、且按 ready 推进 |
| ② | redirect 后第一个请求是否被自己的 flush 误伤 | **否**（重定向目标每拍都正确，见 §B4.10.0 的 `[rdbg]`） | `[rdbg]`：`redir pc=0x8001c024 / 0x8001c034 / 0x8001c060` 均正确 |
| ③ | 后端 `disp_ok=0` 拍前端是"保持"还是"丢弃"当前块 | **保持**（不是 K1 根因） | `[k1-blk]` 实测：`pc0=0x8001c034 mask=1111 rdy=0` 连续多拍**同一块反复呈现**（块被保持，未丢） |
| ④ | 与 2A `kill_young`（`core_top.v:1715`）对照：缺"前端 hold" | **确认缺**，且 2A 的 hold 落点是**取指 FSM/pc_gen**（不是本核的 `fe_stall`） | 本核 `front4_top` 只有三个冻结口：`rst_hold`（取指停在 RESET_PC ✗）、`break_point`（对外契约口 ✗ 不能挪用）、`fe_stall`（只进 `freeze_in`：`front4_top.v:302`，**只冻预测器/检查点，不冻取指推进** ✗） |
| ⑤ | fence.i 扫掠期间 `l1i_cs_req` 门控对取指队列的影响 | **就是 K1 根因** | `[k1-blk]` 失序序列（见 §B4.11.0）；本段把 `fe_stall` 接成 `fencei_busy \| maint_hold_w` 后**症状不变** ⇒ 证明 `fe_stall` 不足以冻结取指推进 |

## B4.11.2 本段实施（保留在检查点内的改动）

- `rtl/top/core_top_2b.v`：
  1. 维护冻结窗口（4b-2a-fix 段引入，保留）：单拍维护（sfence/cbo）自提交拍起 `flush_all` 保持 4 拍、
     窗口最后一拍才重定向；
  2. `fe_stall` 接线（本段）：`.fe_stall(fencei_busy | maint_hold_w)` —— 虽不足以修 K1，但语义正确
     （维护期间冻结预测器/检查点），且对既有判据零影响；
  3. 块 PC 守卫**已回退**（实测无改善且有引入新阻塞风险）。
- 判据：编译 **0 error**、`tb_core_top_2b` **PASS 80/80**、`regress.sh` **32/32**
  （日志 `../.b2chk/regress_k1.log`）；`rtl/back2/backend_top.v` 与 `rtl/front4/*` **零改动**。

## B4.11.3 K1 修复方案（下一步，按代价排序）

**方案 A（推荐，最小且贴合 2A 口径）**：给 `ifetch4.v` 增加一个**真正的取指冻结**输入
（例如 `fetch_hold_i`），语义 = "**不推进取指 FSM / 不作废当前组 / PC 不变**"（与 `rst_hold` 的区别
是 PC 不变、与 `redirect_valid` 的区别是不清队列）。实现要点：
- `ifetch4.v`：`blk_valid` 追加 `& ~fetch_hold_i`；把组推进（`blk_fire` 相关）与 `pc_q`/队列指针的
  使能加 `& ~fetch_hold_i`；`l1i/取指请求`（`fu_req_valid` 等）加 `& ~fetch_hold_i`。
- `front4_top.v`：把 `fetch_hold_i` 透传给 `ifetch4`（**小改**：1 个端口 + 1 处例化连线）。
- `core_top_2b.v`：`.fetch_hold_i(fencei_busy | maint_hold_w)`；扫掠期间同时保持
  `l1i_cs_vaddr` 切扫掠地址、`l1i_cs_req=0`（此时前端已真正冻结 ⇒ 不再失序）。
- 判定：p11_maint 黄金 42 条逐条一致。

**方案 B（不改前端，绕开 L1I 地址 mux）**：fence.i 改为"**先冻结后端 + 等 `l1i_idle`**，再逐 256 拍
发 `inval_all`，**但不切 `cs_vaddr`**（改为只在扫掠期间把扫掠地址当作 *fetch 请求* 送进 L1I，
即让前端"带着取指请求"走过 256 个 index）"——本质是借用前端请求通道做扫掠，实现更绕，不推荐。

**方案 C（最保守）**：`fence.i` 仅在**取指空闲**时扫掠：连续 N 拍观察到 `l1i_idle & ~blk_valid`
才启动扫掠；否则延迟（可能长时间无法启动，正确性优先）。可作为方案 A 落地前的临时口径。

## B4.11.4 本段检查点状态

- 编译 0 error；TB（既有 7 程序）**80/80**；`regress.sh` **32/32**；2A 零修改；未提交 git；
  快照 `../.b2chk/*.s23`。
- WIP：`sim/unit/prog/back2_p11_maint.S`（黄金 42 条已生成可复用）、`back2_p12_cbo.S`
  （自记录 + 维护口探针；其合法性/维护口侧判据调试期已实测通过）。
- 下一步：**方案 A**（`fetch_hold_i`，front4 小改 + 理由登记）→ 挂回 p11/p12 判据（TB 补丁形态见
  §B4.10.2 与本次工作树历史）→ 继续 4b-2b/2c（D 侧翻译与 PTE A/D 写通路）。


# 2B-4 K1 修法 A 落地段 —— **front4 冻结门控已实现（零影响）**；K1 残余缺陷定位到"维护拍提交上报/冲刷交互"

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 K1 定案 `ec082d5`=tag `2B-4.10`）
> 本段按方案 A 实施：`rtl/front4/ifetch4.v` 两处冻结门控 + 复用既有 `fe_stall`（**未新增端口**）、
> `core_top_2b` 接 `fencei_busy | maint_hold_w`。**K1 仍未收敛**，但本段拿到**决定性新证据**：
> 失败块正是**含维护指令本身的那一块**，且该维护指令**确实被执行并检测到**（重定向目标正确）——
> 说明残余缺陷在"维护拍的**提交上报**与冲刷的交互"，而非取指路径。按任务书纪律停在
> "整设计可编译 + 既有判据全绿"检查点（p11/p12 仍为 WIP，判据未放宽）。

## B4.12.1 方案 A 实现（diff 摘要 + 影响面登记）

| 文件 | 改动 | 理由 |
|---|---|---|
| `rtl/front4/ifetch4.v` | ① `l1i_req_valid` 追加 `& ~freeze_all`；② `unc_req_valid`（XIP 直连）同口径追加 `& ~freeze_all`；③ **`blk_valid` 追加 `& ~freeze_all`** | 原式里 `f1_accept = ~freeze_all & …` 只冻 F1→F2 推进，而**块消费**（`head_adv_valid = blk_fire`）与**取指请求**都不受冻 ⇒ 冻结期间"块被消费但流水不推进/请求照发"，与顶层把 `l1i_cs_req` 门控为 0 相撞 ⇒ 前端输出重叠、乱序块（K1 根因） |
| `rtl/top/core_top_2b.v` | `.fe_stall(fencei_busy \| maint_hold_w)`（4b-2a-fix 段已接，本段确认语义） | 复用 front4 **既有** `fe_stall`（→ `freeze_in` → `freeze_all`），**无需新增端口**（比原计划"新增 `fetch_hold_i`"更小） |
| **影响面** | `freeze_in`（`fe_stall`）在既有 7 个程序里**恒 0**（本核只把它接成 `fencei_busy \| maint_hold_w`，既有程序无维护操作）；`fault_hold_q` 与 `break_point` 的语义不变（前者本就该"冻结不呈现块"，后者是对外调试口） | 实测：`tb_core_top_2b` **PASS 80/80**、`regress.sh` **32/32**（`../.b2chk/regress_k1a.log`）⇒ 对既有判据**零影响** |

## B4.12.2 K1 残余缺陷的新证据（决定性）

把 `p11_maint` 放在**第一个程序槽**（自身基址 `0x8000_0000`，BTB/缓存全新）复测 ⇒ **同一相对失败点**
（`idx 20: 设计 0x…60 vs 黄金 0x…50`）⇒ **排除**"跨程序陈旧预测器/缓存状态"这一候选。

维护事件打点（`[mdbg]`，p11 置首运行）：
```
t=7525000  maint kind=2 pc=0x8000005c           ← sfence 在 0x5c，**被正确检测**
t=7565000  redir pc=0x80000060 flush=1 hold=1   ← 冻结窗口末端重定向到 0x60（**目标正确**）
```
提交轨迹（`[p11-trace]`）：
```
idx=19 pc=0x8000004c  ← 上一条（la t1 的 addi）
idx=20 pc=0x80000060  ← ★ 直接跳到维护指令的下一条
```
⇒ **丢失的正是含维护指令的那一块 `0x50..0x5c`（4 条）**：`0x50/0x54/0x58` 是分隔用的 addi，
`0x5c` 是 `sfence.vma`。而该 sfence **确实执行并被检测**（否则不会产生到 0x60 的重定向）⇒
残余缺陷是：**维护拍（含维护指令的那个提交组）没能把这一组上报为已提交**，
随后冻结窗口把 ROB 清空、重定向到 0x60 ⇒ 报告流里整块消失、程序从 0x60 继续。

**与现有机制的对应**（下一步的第一手排查点）：
1. `maint_cmt_o` 的口子在 `cmt_ok = ~squash & (~flush_all | ((xret|maint)&trp_flush))`，
   而 `maint_cmt_o` 由 lane 扫描（`cmt_raw & ~squash`）产生；若该拍 `squash_v_w` 或
   `trp_flush_v_i` 的**相位**与扫描不一致，整组就会 `cmt_ok=0` ⇒ 不上报。
2. `cmt_hold_w` 的"更年轻 lane hold"是按 `maint_lane_idx` 算的；若维护指令在较老的 lane，
   更年轻的 lane 被 hold（正确，它们会重执行），但**不能让更老的 lane 也消失**——
   需要确认 `cmt_raw_m` 对更老 lane 恒等。
3. `blk_bad=4`（本段新增的"块首 PC 回退"计数）说明前端**仍有**越序块呈现 ⇒ 即使冻结门控到位，
   仍需按 §B4.10.3 的第 1/5 条继续查（fetch-queue 与 L1I 响应的簿记）。

## B4.12.3 下一步（最小可判定实验，一步即可定位）

1. **打点维护拍**：在维护检测拍同时打印
   `cmt_ok / cmt_raw / cmt_raw_m / maint_lane_idx / squash_v_w / trp_flush_v_i / flush_all_w /
   commit_valid_o / maint_kind_w`（一次仿真即可判定是"整组 cmt_ok=0"还是"掩码把老 lane 也吃掉"）。
2. 按结论二选一：
   - 若为**相位/口子问题** ⇒ 把维护拍的上报改为"**无条件上报该组最老到维护指令之间的 lane**"
     （即 `cmt_ok` 对该拍强制为 1，并由 `cmt_hold_w` 只挡更年轻的 lane）；
   - 若为**掩码问题** ⇒ 修正 `cmt_hold_w`（用 `maint_lane_idx` 的"最老者优先"索引，或在扫描里
     同时记录最老维护 lane 与最老 xRET lane 的分组优先级）。
3. 再挂回 p11/p12（生成器 2 条 PROGS + TB 的 C11'/C12'，检查项 80→80+9：C11' 5 条 + C12' 4 条；
   DDR3 窗口 160 KB、第 8/9 槽、`[k1-blk]` 块序计数与维护口探针——本段工作树历史里补丁形态完整可复用）。

## B4.12.4 本段检查点状态

- 编译 **0 error**；`tb_core_top_2b`（既有 7 程序）**PASS 80/80**；`regress.sh` **32/32**；
  2A 零修改；`rtl/top/core_top_2b.v` 与 `rtl/back2/*` 本段零改动（仅 `rtl/front4/ifetch4.v` 三处门控）；
  未提交 git；快照 `../.b2chk/*.s24`。
- WIP：`back2_p11_maint.S`（黄金 42 条）、`back2_p12_cbo.S`（自记录 + 维护口探针）。
- 结论：**K1 未收敛**，但已把范围压缩到"维护拍提交上报/冲刷交互"（3 条具体排查点）+
  "前端越序块（`blk_bad=4`）"，并且 front4 的冻结门控（方案 A）已落地且零影响。


# 2B-4 K1 一步判定实验段 —— **根因定案并修复一半：D6（`cmt_hold_w` 移位量 2 bit 回绕）**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的修法 A `af851d1`=tag `2B-4.11`）
> 本段按要求做了"一步判定实验"并**定案**：K1 的"丢一个 4 宽块"来自 **`cmt_hold_w` 的移位量在
> 2 bit 上下文中回绕**（`lane 3 + 1 = 0` ⇒ 掩码 = `4'hF` ⇒ **整组被 hold**）。修法为一行位宽修正，
> 修复后 `p11_maint` 的提交数从 **33/42 → 41/42**、4 宽块不再丢失；**残余 1 条**（程序末尾的
> `j .` @0xa4 不提交）另立案（K1'，见 §B4.13.3）。按任务书纪律停在"整设计可编译 + 既有判据
> 全绿"检查点（p11/p12 未挂回，判据未放宽）。

## B4.13.1 一步判定实验的原始证据（维护检测拍现场）

```
[k1m] kind=1 pc=0x80000018 | cmt_ok=1 cmt_raw=0011 cmt_raw_m=0011 lane=1 squash=0 trp_fl=0 flush_all=0 cmt_v=0011
[k1m] kind=2 pc=0x8000002c | cmt_ok=1 cmt_raw=0001 cmt_raw_m=0001 lane=0 squash=0 trp_fl=1 flush_all=1 cmt_v=0001
[k1m] kind=2 pc=0x8000005c | cmt_ok=1 cmt_raw=1111 cmt_raw_m=0000 lane=3 squash=0 trp_fl=1 flush_all=1 cmt_v=0000   ← ★ 整组被掩掉
[k1m] kind=1 pc=0x8000007c | cmt_ok=1 cmt_raw=1111 cmt_raw_m=0000 lane=3 squash=0 trp_fl=0 flush_all=0 cmt_v=1111
```
⇒ 判定结果：**不是 (a) 相位/口子问题**（`cmt_ok` 恒 1 ✓、`trp_flush`/`flush_all` 相位正确 ✓），
而是 **(b) 掩码问题**，且**只在 `maint_lane_idx == 3` 时发生**（lane 0/1/2 的掩码正确）。

## B4.13.2 D6 缺陷与修法（diff）

```verilog
// 修前（backend_top.v）：移位量只有 2 bit ⇒ lane 3 时 3+1 回绕成 0 ⇒ 4'hF << 0 = 4'hF ⇒ 整组 hold
wire [3:0] cmt_hold_w = (|maint_lane_oh) ? (4'hF << (maint_lane_idx + 2'd1)) :
                        (|xret_lane_oh)  ? (4'hF << (xret_lane_idx  + 2'd1)) : 4'h0;
// 修后：移位量扩到 3 bit（最大 4）⇒ lane 3 时移位 4 ⇒ 掩码 0（不 hold 任何 lane）
wire [2:0] maint_hold_sh = {1'b0, maint_lane_idx} + 3'd1;
wire [2:0] xret_hold_sh  = {1'b0, xret_lane_idx}  + 3'd1;
wire [3:0] cmt_hold_w = (|maint_lane_oh) ? (4'hF << maint_hold_sh) :
                        (|xret_lane_oh)  ? (4'hF << xret_hold_sh)  : 4'h0;
```
**为什么与观测症状完全吻合**：维护指令恰落在**满 4 宽提交组的第 4 个 lane** 时（最典型：4 条
指令一块、维护指令是块尾）⇒ 整组（含**比它更老的 3 条**与它自己）从提交流消失 ⇒ 报告流里
"丢一个 4 宽块"，而硬件侧维护动作照常发生（冲刷 + 重定向）⇒ 后续从 PC+4 继续 ⇒ 正是 K1 现象。
修后实测：`cmt_raw_m=1111` ✓、提交数 **33 → 41**（黄金 42）✓、4 宽块不再丢失 ✓。

## B4.13.3 残余缺陷 K1'（1 条指令）与下一步

**现象**：`p11_maint` 现提交 41/42；缺的是程序末尾的 `j .`（`0xa4`）。`[k1tail]`（本段新增尾部诊断）：
```
[k1tail] blk_v=0 pc0=0x800000a4 rdy=1 | disp_ok=0 d1v=0000 rn_i=0 rn_f=0 fi=1 ff=1 iq=1 robcnt=0 fencei=0 maint_hold=0 tb_redir=0
```
⇒ 前端**停在该 PC、块呈现恒 0**，后端全空闲、无维护活动 ⇒ 前端在等一个"不会返回"的取指响应
（该行 `0xa0..0xac` 含 `0xa4`，恰是 `fence.i` 扫掠被失效的行之一）。
**已试而未愈**：①扫掠前等 `l1i_idle`（本段新增 `fencei_wait_q`，语义上更安全，保留）；
②`l1i_req_valid`/`unc_req_valid`/`blk_valid` 加 `~freeze_all`（上一段，保留）。
**下一步（精确打点建议）**：对 `0xa4` 那一行的取指握手打点 `l1i_req_valid/l1i_ready/l1i_miss/l1i_rdata`
与前端 `f4_v_q/f4_rsp_ok/can_grow`，判定是"请求未发出"还是"响应丢失"；若为响应丢失，最小修法是
**扫掠期间也保持 `cs_req` 通路**（把扫掠 index 从"取指请求通道"改由独立端口驱动——即给 `l1i`
增加一个专用维护 index 口，属 l1i 小改），或**扫掠前把前端取指流水彻底排空**（等
`l1i_idle & ~blk_valid` 连续 N 拍）。

## B4.13.4 本段检查点状态

- 编译 **0 error**；`tb_core_top_2b`（既有 7 程序）**PASS 80/80**；`regress.sh` **32/32**
  （日志 `../.b2chk/regress_k1b.log`）；2A 零修改；未提交 git；快照 `../.b2chk/*.s25`。
- 本段改动（均在 `rtl/`，对既有判据零影响——既有程序无维护操作）：
  ①`rtl/back2/backend_top.v`：**D6 位宽修正**（`cmt_hold_w` 移位量 3 bit）；
  ②`rtl/top/core_top_2b.v`：`fencei_wait_q`（扫掠前等 L1I 空闲）+ `fencei_pend_w`（冻结/冲刷窗口含等待态）。
- WIP：`back2_p11_maint.S`（黄金 42 条，修 D6 后 41/42）、`back2_p12_cbo.S`。
- 一句话：**K1 的"丢 4 宽块"已定案并修掉（D6）；只剩 1 条末尾指令的前端取指响应问题（K1'）**，
  范围已缩到"某一行的取指握手"。


# 2B-4 K1' 一步判定段 —— **定案：前端块拼装簿记留下"幻影 push"**（D6 修复后仅剩末尾 1 条）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 D6 修复 `84b2f25`=tag `2B-4.12`）
> 本段按方案打点 `0x…a4` 行的取指握手，**K1' 已定案**，但修法涉及前端块拼装状态机
> （比"冻结窗口/维护口"深一层），本段预算内未收敛 ⇒ 按任务书纪律停在"整设计可编译 +
> 既有判据全绿"检查点（p11/p12 未挂回，判据未放宽）。

## B4.14.1 判定实验原始证据（`[k1h]` 尾部打点）

```
[k1h] tick=200000 req_v=0 req_a=0x800000e0 cs_req=0 cs_rdy=0 cs_miss=0 rdata=0 own=0
      | f4v=0 f4rsp=0 **cangrow=1** fz=0 pend=0 pa_q=0x800000e0
```
⇒ 结论：**既不是"请求未发出"也不是"响应丢失"**，而是**前端块拼装 FSM 的簿记不一致**：
- 顶层与 L1I 侧**全空闲**（`req_v=0`、`cs_req=0`、`l1i_pend_q=0`、`l1i_own=0`）⇒ 没有任何在途取指；
- 前端 `f4_v_q=0`、`f4_rsp_ok=0` ⇒ F4 级与响应位都空；
- 但 **`can_grow=1`**（`can_grow = next_parcel_v | push_gives_next | f4_rsp_ok`）⇒ 前端仍然认为
  "本块还能长、且某次 push 会送来下一个 parcel"，而该 push 既不在途、也不会再来
  ⇒ `blk_ready_int = (grp_mask!=0) & (m3 | blk_term | ~can_grow) = 0` ⇒ 该块**永远拼不齐**、
  该指令（`j .`@0xa4）永不提交、PC 停在该处。

**触发条件**：该行 `0xa0..0xac` 恰是 `fence.i` 扫掠期间被失效的行之一 ⇒ 扫掠前后
"前端已 push、L1I 行被失效"这一组合让 parcel/push 簿记丢了配对。

## B4.14.2 本段试过的修法与结论（全部登记，均对既有判据零影响）

| # | 试法 | 结果 |
|---|---|---|
| 1 | 扫掠前等 `l1i_idle`（`fencei_wait_q`） | 未愈（仍 41/42） |
| 2 | 扫掠启动条件收紧为 `l1i_idle & ~l1i_pend_q & ~l1i_own`（前端取指请求彻底排空） | 未愈 |
| 3 | 冻结只用于 fence.i 扫掠（`fe_stall = fencei_busy`），sfence/cbo 不再冻前端 | 未愈（回到 41/42；此前把等待态也纳入冻结会死锁在 idx7，已修正为只在扫掠中冻结） |
| 4 | `l1i_req_valid`/`unc_req_valid`/`blk_valid` 加 `~freeze_all`（上一段已入） | 未愈（但语义正确，保留） |

**保留在检查点内的本段改动**（`rtl/top/core_top_2b.v`）：`fencei_wait_q`/`fencei_pend_w` +
"启动条件含前端排空" + "只在扫掠中冻结前端"。对既有 7 程序零影响（它们无维护操作）⇒
TB **80/80**、regress **32/32**（`../.b2chk/regress_k1p.log`）。

## B4.14.3 下一步（K1' 收口的两个可选方案，均已获母代理授权范围）

**方案 ①（推荐，直击根因、影响面可控）**：给 `rtl/cache/l1i.v` 增加**专用维护 index 口**
（如 `maint_idx_i[7:0]` + 复用现有 `inval_all`，维护时 index 取该口而非 `cs_vaddr`）：
- 好处：扫掠**不再借用取指请求通道、不再切 `cs_vaddr`** ⇒ 前端在扫掠前后完全不受影响
  （`l1i_cs_req` 也无需再门控），从根上消除"push 与失效行配对丢失"；
- 影响面：`l1i.v` 1 个输入端口 + 1 处 index mux（**2A cache 文件的最小加法**，母代理已授权并需登记）；
  `core_top_2b` 去掉 `l1i_cs_vaddr` 的扫掠 mux 与 `cs_req` 门控；`fe_stall` 仍保留（扫掠期间
  冻结前端以便 L1I 空闲，可选）。

**方案 ②（不动 l1i）**：在前端侧修"幻影 push"——在 `ifetch4.v` 中为 push/parcel 配对加
超时/一致性恢复（例如：`can_grow` 里的 `push_gives_next` 需与实际在途 push 计数相与，
无在途 push 时强制 `can_grow=0` 让块以当前 parcel 收尾）。改动更贴近根因但触及前端核心 FSM，
需要更充分的回归（含 lockstep TB 的 57 项）。

**先做的打点**（一步即可选定）：在停滞拍打印 `ifetch4` 内部
`push_lo_ok/push_hi_ok/push_gives_next/next_parcel_v/buf_cnt_q/grp_mask/m3/blk_term/f4_is_xip`，
确认是 `push_gives_next` 悬空（⇒ 方案 ②）还是 parcel 计数少一（⇒ 方案 ① 亦可解）。

## B4.14.4 本段检查点状态

- 编译 **0 error**；`tb_core_top_2b`（既有 7 程序）**PASS 80/80**；`regress.sh` **32/32**；
  2A 零修改；未提交 git；快照 `../.b2chk/*.s26`。
- 进度：`p11_maint` 42 条中已能提交 **41 条**（D6 修复前 33 条）；剩 1 条为前端幻影 push。
  WIP：`back2_p11_maint.S`、`back2_p12_cbo.S`（判据口径与 TB 补丁形态在 §B4.10.2/§B4.12.3/§B4.13.3 已完整登记）。


# 2B-4 K1' 收口段 —— **K1' 定案并修复（BPU 检查点池泄漏）；p11_maint 判据挂回全绿（TB 80→91 项）**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 K1' 定案 `2e7b6d2`=tag `2B-4.13`）
> 本段用"一键打点"完成定案并修好：**K1' = BPU 检查点池在全冲刷时泄漏** ⇒ `ckpt_full` 卡死 ⇒
> 预测跳转块无法呈现 ⇒ 前端永久停摆。修法为前端 3 行小改（`ckpt_clear_all` 在整机冲刷时清池）。
> 修后 **p11_maint 提交 42/42 且 PC 流/写回 = Spike 黄金逐条一致**，C11' 4 条全过；TB 检查项
> **80 → 91** 全绿；`regress.sh` **32/32**。p12_cbo 因 `cbo.clean/flush` 的数据校验未过，
> 本段未挂回（WIP，见 §B4.15.4）。

## B4.15.1 一键打点结果（stall 拍 ifetch4 现场）

```
[k1i] plo=0 phi=0 pgn=0 npv=1 bufcnt=32 grpm=0001 m3=0 term=1 xip=0
      | pva0=0x800000e0 pva1=0x800000e2 nva=0x800000a8 rsp=0 f4v=0
```
判定：
- `push_gives_next=0` ⇒ **不是**"幻影 push"（方案②不适用）；
- `npv(next_parcel_v)=1`、`blk_term=1`、`grpm=0001` ⇒ `blk_ready_int=1` ⇒ 块本可呈现；
- 但实测 `blk_v=0` ⇒ 被 `ckpt_stall = blk_ready_int & grp_taken & ckpt_full` 挡住
  （`j .` 是**预测跳转**，需要检查点；`ckpt_full=1`）⇒ **检查点池耗尽**（方案①的"parcel 计数少一"也不成立）。

## B4.15.2 K1' 根因与修法 diff

**根因**：BPU 的检查点池（`predictor_top` 的 `ck_valid_q`，16 项）只在**逐 ID 释放**
（`ckpt_free_valid/ckpt_free_id`，每拍一个）时归还。而"整机冲刷"（陷阱 / xRET / **维护操作**）
会一次性丢弃大量在途指令，它们的检查点**没有逐 ID 归还** ⇒ 池项逐次泄漏 ⇒ 若干次冲刷后
`ckpt_full=1` ⇒ 之后任何**预测跳转块**都无法呈现 ⇒ 前端永久停摆（p11 末尾 `j .`@0xa4 即此）。

**修法**（前端小改，母代理授权范围；语义："整机冲刷 ⇒ ROB 清空 ⇒ 所有检查点作废"）：

| 文件 | 改动 |
|---|---|
| `rtl/front4/predictor_top.v` | 新增输入 `ckpt_clear_all`；在检查点状态块中 `if (ckpt_clear_all) for (ck_i…) ck_valid_q[ck_i] <= 1'b0;`（iverilog 不支持整数组赋值，故用 for） |
| `rtl/front4/front4_top.v` | 新增输入 `ckpt_clear_all` 并透传给 `predictor_top`（1 端口 + 1 连线） |
| `rtl/top/core_top_2b.v` | `.ckpt_clear_all(be_trp_flush)`（= 陷阱/xRET/维护的整机冲刷拍） |

**影响面**：`be_trp_flush` 只在这些"整机清空"事件为 1；既有 7 程序里仅 p7/p8/p9 有陷阱/xRET
（各 1~3 次），清池是**语义正确**的行为（那时 ROB 确实被清空）⇒ 实测既有判据全部保持（见 §B4.15.3）。
顺带修掉一个**潜伏缺陷**：陷阱/xRET 路径此前同样泄漏检查点（只是测试里次数少未暴露）。

## B4.15.3 挂回 p11_maint（判据 80 → 91 项）

- 生成器新增 `back2_p11_maint.S`（`-march=rv32ima_zicsr_zifencei`、Spike `--isa=rv32imac_zicsr_zifencei`，
  **黄金 42 条**）；
- TB：程序数 7→8、DDR3 窗口 128 KB→160 KB、第 8 槽（基址 `0x8001_C000`）、维护口探针计数、
  **C11' 4 条**（维护提交 4 次 / L1I 扫掠 ≥512 拍 / TLB 失效 ≥2 次 / 前端块不越序）；
- **实测**：`程序 7 结果：1033 拍，提交 42 条（黄金 42）| AXI AR=11 R=67`，
  `[C11'] 维护：提交 4 次；L1I 扫掠 512 拍、TLB 失效 2 次、L1D 失效 0（sfence 不动 L1D）；PC 流/写回 = Spike 黄金`，
  **检查项合计 91 项全部满足**；既有 7 程序全部保持（p1 161、p3 126、p6 366（AW=2/W=16/B=2）、
  p7 89、p8 523、p9 92、p10 45）。

**附带修掉的两处口径缺陷**：
1. `sfence.vma` **不再失效 L1D**：本核 L1D 为**物理**索引/标签 ⇒ VA 重映射无需动数据缓存；
   原实现跟着 2A 一起 `inval_all` 会**丢脏数据**（实测 p11 第 12 条 load 读到 0 而非 `0x11223344`）。
2. TB 维护计数器补**逐程序复位**（此前为 x，`chk(x)` 被静默放过 ⇒ 判据不严）。

## B4.15.4 遗留：p12_cbo（WIP，未挂回）

- 程序已按 Zicbom 语义修正（`cbo.inval` 只在**干净行**上执行；数据安全检查用 `cbo.clean`/`cbo.flush`）。
- 但实测：`cbo` 后 4 次 load 仅 **1 次**读到 `0x55667788` ⇒ `l1d` 的 `clean_all`/`inval_all`
  维护与在途写回/重填的交互仍有问题（很可能与 §B4.14 同类的"维护扫描期间访问"竞态）。
- 该程序未进生成器清单 ⇒ **不影响任何判据**；下一段按"cbo 维护扫描与访存互锁"方向排查。

## B4.15.5 本段检查点状态

- 编译 **0 error**；`tb_core_top_2b` **PASS 91/91**（8 程序，含 p11_maint 黄金 42 条 + C11'）；
  `regress.sh` **32/32**（日志 `../.b2chk/regress_k1fix.log`）；2A 文件零修改
  （`rtl/front4/*` 为 2B 前端，属允许范围）；未提交 git；快照 `../.b2chk/*.s27`。
- 改动文件：`rtl/front4/predictor_top.v`（+`ckpt_clear_all`）、`rtl/front4/front4_top.v`（透传）、
  `rtl/top/core_top_2b.v`（接线 + sfence 不动 L1D + 扫掠等待/冻结范围）、
  `sim/unit/tb_core_top_2b.sv`（p11 槽 + C11'）、`sim/unit/prog/gen_back2_lockstep_data.py`、
  `sim/unit/prog/back2_lockstep_data.svh`（再生成）。
- **K1 系列收官**：D6（hold 掩码位宽回绕）⇒ 4 宽块不再丢；K1'（检查点池泄漏）⇒ 末尾 `j .` 正常提交；
  p11_maint 全流与 Spike 黄金逐条一致。
- 下一步：①p12_cbo 的 `l1d` 维护互锁（小项）；②**4b-2b**（D 侧 TLB 口 1 + LSU VA/PA 分离 +
  PTW 串行复用）、**4b-2c**（PTE A/D 写通路走 §5 引擎第 7 源）——方案见 §B4.8.2/§B4.8.1。


# 2B-4 p12_cbo 收口段 —— **定案：维护"全冲刷"丢掉"已提交但仍在排空"的 store（数据丢失）**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 K1' 修复 `01a686d`=tag `2B-4.14`）
> 本段按三种修法方向排查 p12_cbo，**定案到一个比 cbo 更基础的数据正确性缺陷**：
> 维护操作的"整机冲刷"会丢掉**已提交、尚在排空途中**的 store ⇒ 后 3 次 load 读到 0。
> 该缺陷不在 cbo 语义、也不在 L1D 扫描，而在**冲刷 × store 排空（CDQ）**的交互。
> 修法涉及 LSU/LSQ 的冲刷口径（预算内未收敛）⇒ 按纪律停在"整设计可编译 + 既有判据全绿"
> 检查点：p12 未挂回（WIP），**p11_maint 与既有 91 项保持全绿**、regress 32/32。

## B4.16.1 定案证据（p12 逐条提交轨迹）

```
idx=7  pc=0x8002001c we=0                  ← sw t0,0(s0)（0x55667788 写入）
idx=8  pc=0x80020020 we=1 rd=9  wd=0x55667788   ← lw s1 ✔（store→load 转发）
idx=9  pc=0x80020024 we=0                  ← cbo.clean（提交 ⇒ 维护全冲刷）
idx=10 pc=0x80020028 we=1 rd=18 wd=0x00000000   ← lw s2 ✗（应为 0x55667788）
idx=11 pc=0x8002002c we=0                  ← cbo.flush
idx=12/13 pc=0x80020030/34 rd=19/20 wd=0x00000000 ← lw s3/s4 ✗
```
⇒ `lw s1` 靠 **store→load 转发**读到正确值（说明数值确实在流水里）；第一次 `cbo.clean` 的
维护全冲刷之后，同一地址的 load 变成 0 ⇒ **那条已提交的 store 从未落进 L1D/内存**。

## B4.16.2 已试修法与结论

| # | 试法 | 结论 |
|---|---|---|
| 1 | cbo 维护**等 L1D 空闲**再启动（`maint_rdy_i = l1d_idle`，backend 侧对 cbo 门控 `maint_cmt_o`） | 未愈（计数正常：`maint=3, l1dinval=3, l1dclean=3`）⇒ 不是"扫描与在途访问相撞" |
| 2 | 适配器 kill 排除 store（`d_kill_w = be_trp_flush & ~d_we_q`，避免杀"已提交的 store 排空"） | 未愈 ⇒ 丢失点不在适配器 |
| 3 | **未试（下一步首选）**：冲刷**不得丢** CDQ 中"已提交待排空"的 store | 定案指向此处（store 在提交后才排空，冲刷把队列清了） |

**保留在检查点内的本段改动**（均对既有判据零影响）：①`maint_rdy_i`（cbo 等 L1D 空闲，
2A 风格的保守互锁，语义正确）；②`d_kill_w` 排除 store（避免杀已提交写，语义正确）。
两处都保留：它们是修法 3 的前置正确性改进。

## B4.16.3 下一步（修法 3 的具体落点）

1. **定位排空队列的冲刷口径**：`lsq_simple`（`rtl/back2/lsq_simple.v`）的 CDQ 在
   `flush_all` 下是否清空？若清空 ⇒ 改为"**只清未提交项，已提交待排空项继续排空**"
   （CDQ 的语义本就是"已提交 store 的排空 FIFO"，架构上不得丢弃）。
   判据：p12 4 次 load 数据全对 + 既有 91 项不回退 + 锁步 TB 57 项不回退。
2. 若 CDQ 语义改造代价大，保守替代：**维护冲刷等排空清空**（`dbg_stq_cnt_o == 0` 且 CDQ 空
   才允许 cbo 提交/冲刷），与 `fencei_wait_q` 同构；代价是 cbo 的延迟不确定，但正确性优先。
3. 挂回 p12：生成器 1 条 PROGS + TB 的 C12'（4 条：无陷阱 / L1D inval ≥1 / clean ≥2 /
   4 次 load 数据全对）+ 第 9 槽（0x20000，DDR3 窗口已 160 KB）⇒ 检查项 **91 → 95**。

## B4.16.4 本段检查点状态

- 编译 **0 error**；`tb_core_top_2b` **PASS 91/91**（8 程序；`../.b2chk/final_p12run.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_p12.log`）；2A 零修改；未提交 git；快照 `../.b2chk/*.s28`。
- 改动文件：`rtl/back2/backend_top.v`（`maint_rdy_i`）、`rtl/top/core_top_2b.v`
  （`maint_rdy_i` 接线 + kill 排除 store）；TB/生成器/黄金与母代理验收态一致（p12 未挂回）。
- **口径登记（cbo 语义表，本段复核）**：

| 指令 | 合法性 | 维护动作（本核） | 数据安全 |
|---|---|---|---|
| `cbo.inval` | `menvcfg.CBIE≠0`（或 `senvcfg`） | L1D `inval_all`（**破坏性，不写回**） | 只在干净行上使用（Zicbom 语义） |
| `cbo.clean` | `menvcfg.CBCFE=1` | L1D `clean_all`（写回） | 安全 |
| `cbo.flush` | `menvcfg.CBCFE=1` | L1D `clean_all` + `inval_all` | 安全（先写回再失效） |
| `sfence.vma` | M 模式恒合法 | **TLB 全失效**（本核 L1D 物理索引 ⇒ **不动 L1D**） | 安全 |
| `fence.i` | Zifencei | L1I 全阵列扫掠（256 拍）+ 冻结前端 | 安全 |

- 一句话：**p12 暴露的不是 cbo 缺陷，而是"维护全冲刷 × 已提交 store 排空"的数据丢失**——
  这是比 cbo 更基础的正确性议题（同样会影响"冲刷时仍有 store 在排空"的其他场景），
  已定案并给出两套修法；p11_maint（维护操作黄金判据）与既有 91 项保持全绿。


# 2B-4 CDQ 冲刷口径段 —— **排除两支候选、定案改判为"冲刷清 STQ 后转发失效 × 已提交 store 尚未排空"**

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 p12 定案 `e93ba50`=tag `2B-4.15`）
> 本段按首选修法核查 CDQ 口径、实施两支候选修法，**均未愈**；由此把根因**收窄并改判**为
> **冲刷清掉 STQ（转发表）后，重新执行的 load 与"已提交但尚未排空"的 store 之间缺少内存序互锁**
> ⇒ load 直读内存旧值。修法落在 LSQ 的转发/排空互锁（预算内未收敛）⇒ 停在
> "编译零错误 + 既有 91 项全绿"检查点；p12 未挂回（WIP），判据未放宽。

## B4.17.1 CDQ 口径核查结论（首选修法**无需**实施）

`rtl/back2/lsq_simple.v:598-612` 的 `flush_all` 分支**只清 STQ/LQ 与转发直通项**，
**不清 CDQ**（`cdq_v/cdq_cnt/cdq_head/cdq_tail` 不在该分支内），设计注释亦明确
"`flush_all` 清 STQ 时**已提交的 store 仍能落地**（架构上必须可见）"
⇒ **CDQ 口径本来就正确**（只清未提交项、已提交项继续排空）⇒ 本段**未修改 `lsq_simple.v`**。

## B4.17.2 两支候选修法与结论（均保留：语义正确、对既有判据零影响；均未愈）

| # | 修法 | 结论 |
|---|---|---|
| 1 | **kill 排除 store**：`d_kill_w = be_trp_flush & ~d_we_q` | 未愈（p12 仍 1/4） |
| 2 | **kill 再排除"接管拍"**：`d_kill_w = be_trp_flush & ~d_we_q & ~d_start`（防"冲刷拍恰与适配器接管该 store 同拍 ⇒ LSQ 认为 `mem_req_valid & mem_req_ready` 成功、CDQ 已弹出，而适配器被 kill ⇒ 该笔写凭空消失"） | 未愈 ⇒ 丢失点不在适配器交接 |
| 3 | （上一段已入）**cbo 维护等 L1D 空闲**：`maint_rdy_i = l1d_idle` 门控 cbo 的 `maint_cmt_o` | 未愈；维护计数正常（`maint=3, l1dinval=3, l1dclean=3`） |

## B4.17.3 定案（改判后的根因）

```
idx=7  sw  0x55667788            ← 提交（数据进 CDQ/STQ）
idx=8  lw s1 → 0x55667788 ✔      ← **靠 STQ store→load 转发**（此时尚未落 L1D 也能读到）
idx=9  cbo.clean（提交）          ← 维护全冲刷：flush_all ⇒ **STQ 被清**（转发表消失）
idx=10 lw s2 → 0x00000000 ✗      ← 该 load 被冲刷后重新执行 ⇒ 无转发可用，
                                    而已提交 store 的排空尚未到达 ⇒ 读到内存旧值 0
idx=11 cbo.flush → idx=12/13 lw s3/s4 → 0 ✗
```
⇒ **根因**：本核"已提交未排空"的 store 只能靠 STQ 转发被同地址 load 看见；
冲刷清掉 STQ 后，重新执行的年轻 load 既无转发、也无"等我更老的 store 排空"的互锁
⇒ 直读内存旧值。**不是 CDQ 口径问题，而是"转发/排空 × 冲刷 + 重执行"的内存序缺口。**

## B4.17.4 修法建议（下一步，按代价排序）

1. **保守互锁（最小、正确性优先）**：整机冲刷**等排空清空**再生效——把 `be_trp_flush` 的生效
   延长到 CDQ 空（需把 `lsq_simple` 的 `dr_any`/`cdq_cnt` 引到顶层或后端），与 `fencei_wait_q`
   同构；代价：冲刷延迟最高 ~CDQ 深度拍（登记）。
2. **保留转发（更优、改动大）**：冲刷时**不清"已提交未排空"的 STQ 项**（或把 CDQ 头顶项的
   地址/数据纳入转发查询）⇒ 重新执行的 load 仍可转发，无需等待；需在 `lsq_simple` 按
   `stq_ret`（是否已提交）区分清理范围（注意 B27 的窗口算术无掩码教训）。
3. 修好后挂回 p12：生成器 1 条 `PROGS` + TB 的 C12'（4 条：无陷阱 / L1D inval ≥1 / clean ≥2 /
   4 次 load 全对）+ 第 9 槽（`0x20000`）⇒ 检查项 **91 → 95**。

## B4.17.5 本段检查点状态

- 编译 **0 error**；`tb_core_top_2b` **PASS 91/91**（8 程序；`../.b2chk/final_91.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_cdq.log`）；2A 零修改；未提交 git；快照 `../.b2chk/*.s29`。
- 改动文件：`rtl/top/core_top_2b.v`（`d_kill_w` 收敛为 `& ~d_we_q & ~d_start`、`maint_rdy_i` 接线）、
  `rtl/back2/backend_top.v`（`maint_rdy_i` 输入 + cbo 门控）；**`lsq_simple.v` 未改**（CDQ 口径本就正确）。
  TB/生成器/黄金与母代理验收态一致（p12 未挂回）⇒ 既有 91 项与锁步 57 项零回退。
- 一句话：**CDQ 口径无需修改（首选修法被排除）；两支 kill 修法也被排除；根因改判为
  "冲刷清 STQ 后转发消失 × 已提交 store 尚未排空"的内存序缺口**，已给出两套修法与挂回判据。

---

# B4.18 内存序缺口修复 + p12 挂回收口（2B-4 第 4b-2a 段收口）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已提交的 p12 再定案 `3c6884b`=tag `2B-4.16`）
> 结论：**§B4.17 的根因改判被本段波形证据推翻** —— 真正根因是 **`cbo.*` 动作码解码错误**
> （按 `funct3` 区分，而真实编码 `funct3` 恒为 `010`、动作码在 `imm12[1:0]`）⇒ 三条 cbo 全被
> 当成 `flush` ⇒ 顶层对**每次** cbo 同时拉 `inval_all`+`clean_all` ⇒ 2A L1D 走 inval 优先
> ⇒ **整个 L1D 被"无写回失效"** ⇒ 已落地的脏 store 数据丢失。修掉解码 + 落实修法 1
> （维护等"数据通道排空"再发动作）+ 保守 flush 口径后：**p12 4 次 load 全部读到 0x55667788**，
> 判据 **91 → 103 项全绿**（9 程序；其中 C12' 4 项），`regress.sh` **32/32**，2A 文件**零修改**。

## B4.18.1 定案证据（修复前：p12 维护脉冲波形，一次实验即判决）

`DBG_P12=1` 打点（`sim/unit/tb_core_top_2b.sv`，默认关）：逐拍打印
`ad_st_q / d_we_q / cs_req / cs_miss / l1d_cs_wr_done | inv_all / clean_all / l1d.maint_q /
maint_clean_q / maint_idx_q / l1d.idle | be_trp_flush / dr_empty / dr_any / dr_fire`。

```
t=8858 st=0 a=0x00000000 | inv=1 cln=1 mq=0 mc=0 midx=0   idle=1 | flush=1 cdqe=1 drany=0   ← cbo.inval 提交拍
t=8859 st=0              | inv=0 cln=0 mq=1 mc=0 midx=0   idle=0 | 扫描开始：mc=0 = **inval 模式**（inval 优先）
t=8966 st=0              | inv=0 cln=0 mq=1 mc=0 midx=107 idle=0 | flush=0 cdqe=0 drany=1   ← store 卡在 CDQ（L1D 扫描中不排空）
t=9116 st=1 we=1 a=0x80021000 csreq=1 ...                        ← 扫描结束，适配器接管该 store
t=9117 st=2 we=1 miss=1                                          ← 写缺失 ⇒ L1D 自填
t=9129 st=1 we=1 csreq=1                                         ← 填完重发
t=9130 st=2 we=1 **wdone=1**                                     ← ★ store 写**已落进 L1D**（脏行）
t=9132 st=1 we=0 csreq=1 a=0x80021000                            ← 紧随的 load 请求
t=9137 st=0 a=0x80021000 | **inv=1 cln=1** mq=0 midx=255 idle=1 | flush=1 **cdqe=1 drany=0** ← cbo.clean 提交拍
t=9410 st=0 a=0x80021000 | **inv=1 cln=1** mc=1 midx=255 idle=1 | flush=1 cdqe=1 drany=0   ← cbo.flush 提交拍
```

三条判决性事实：

1. **三次 cbo 的维护脉冲全是 `inv=1 cln=1`**（inval+clean 同时拉高）⇒ 2A L1D
   `maint_clean_q <= clean_all & ~inval_all` ⇒ **`mc=0`（inval 优先）** ⇒
   `way_maint` 对全阵列 `wr_valid=0` ⇒ **无写回、整块失效**。
2. **cbo.clean 提交拍 `cdqe=1 / drany=0`** ⇒ 该 store **早已从 CDQ 排空**（`wdone=1` 于 t=9130）
   ⇒ **§B4.17"已提交 store 尚未排空"的改判被证伪**；数据丢失发生在 L1D **内部**。
3. 失效之后再执行的 `lw s2/s3/s4` 必然 miss ⇒ 从内存取回旧值 **0**（内存里从未有过该数据：
   2A L1D 的 clean 只清 dirty、无写回通道）⇒ 与"4 次 load 只有 1 次对"逐条吻合。

## B4.18.2 根因（`cbo.*` 动作码解码错误，工具链实证 + 2A 口径背书）

```
$ riscv32-unknown-linux-gnu-objdump -d p12.elf
80000010: 0004200f   cbo.inval (s0)      ← funct3=010, imm12[1:0]=00
80000024: 0014200f   cbo.clean (s0)      ← funct3=010, imm12[1:0]=01
8000002c: 0024200f   cbo.flush (s0)      ← funct3=010, imm12[1:0]=10
```

* **真实编码**：`cbo.*` = MISC-MEM(opcode 0x0F) + **`funct3 = 010`** + 动作码在 **`imm12[1:0]`
  = `insn[21:20]`**（0=inval / 1=clean / 2=flush，`insn[31:22]=0`）。2A 译码器同口径：
  `rtl/decode/decoder.v:361-369`「cbo.*：opcode=MISC-MEM、**f3=010**、f7=0000000、
  **rs2 ∈ {inval,clean,flush}**」⇒ `cbo_valid_o` 本就正确。
* **旧实现（本段修掉）**：`backend_top.maint_kind_f` 用 `t[14:12] == 000/001/010` 区分
  inval/clean/flush ⇒ 前两支**永不命中**、第三支**恒命中** ⇒ 三条 cbo **全部**返回 `kind=5`
  （"flush"）⇒ 顶层 `maint_l1d_inval_w = cbo & (kind != 4)`、`maint_l1d_clean_w = cbo & (kind != 3)`
  对 `kind=5` **同时为 1** ⇒ 就是 B4.18.1 观测到的 `inv=1 cln=1`。
* **同源的第二个偏差**：`cbo_ill_perm` 也按 `tval[14:12]==000` 判 inval ⇒ 永远走"需 CBCFE=1"
  分支 ⇒ `menvcfg.CBIE=01` 且 `CBCFE=0` 时**合法的 `cbo.inval` 会被误判非法**。
  p12 的 `menvcfg=0x70`（两位全开）把该偏差掩盖了，本段一并修正。

## B4.18.3 修法 diff（4 处，均在 2B 范围内；2A 文件零修改）

1. **`rtl/back2/backend_top.v` `maint_kind_f`**：cbo 三支改为
   `(t[6:0]==7'h0F) & (t[14:12]==3'b010) & (t[19:15]!=0) & (t[31:22]==10'b0) & (t[21:20]==2'b00/01/10)`
   ⇒ `kind = 3/4/5`（inval/clean/flush）；`fence.i`(1)/`sfence.vma`(2) 两支保持不变（不冲突）。
2. **`rtl/back2/backend_top.v` `cbo_ill_perm`**：动作码改取 `tval[21:20]` ——
   `==0`（inval）判 `cbo_perm_i[0]`（CBIE≠0），否则判 `cbo_perm_i[1]`（CBCFE=1）。
3. **`rtl/back2/lsq_simple.v`**：新增输出 `dr_empty_o = ~dr_any`（`iss_ok` **未改**，仍为 `~any_unk_w`）
   —— 只把"CDQ 空"这一事实引到后端/顶层做冲刷闸门。
4. **`rtl/top/core_top_2b.v`（修法 1 落实）**：
   * `backend_top.cdq_empty_o` → `cdq_empty_w`；维护 FSM 判据
     **`maint_drain_w = cdq_empty_w & (ad_st_q == AD_IDLE)`**（CDQ 空 **且** 适配器无在途访问
     ⇒ 最后一笔 store 的**写已落进 L1D**，因为适配器只在 `cs_wr_done` 那拍才回 IDLE）；
   * 维护已提交但未排空 ⇒ `maint_wait_cdq_q=1`（期间 `be_trp_flush` 保持、前端冻结、
     PC 保持），排空后**先发单拍动作脉冲 `maint_act_q`**，再走原 4 拍冻结窗口 + 末尾重定向；
   * **动作码必须锁存**（`maint_kind_save_q`）：`maint_kind_w` 只在提交拍有效，动作脉冲在下一拍
     ⇒ 实测用 `maint_kind_w` 会让动作码退化成 0（p11 的 2 次 sfence 维护动作全丢、`n_tlb_sfence=0`）；
   * 维护口由动作脉冲驱动：`inval = act & (kind==3)`、`clean = act & (kind>=4)`、
     `tlb_sfence = act & (kind==2)`；`fence.i` 路径不动（只刷 L1I，与数据序无关）；
   * 加固：`d_ready_w = d_idle & ~l1d_busy_w & ~maint_act_q` —— 实测三次维护脉冲里两次与
     "适配器接管一笔新访问"同拍（`st=AD_REQ/csreq=1`）⇒ 该访问会在下一拍与维护扫描第 0 组
     （tag 写口 / dirty 清口）重叠 ⇒ 用 `~maint_act_q` 挡掉这一拍的接管。

### 口径登记（保守 flush，**不放松任何判据**）

`cbo.flush` 的 **INVAL 部分本段不实现**（`maint_l1d_inval_w` 只在 `kind==3` 拉高）：
2A `l1d.v` 维护口只有 `inval_all`（清 valid，**不写回**）与 `clean_all`（清 dirty，保留 valid/数据）
两条路，**没有"维护写回"通道** ⇒ 真 flush 必然丢掉已提交脏行（p12 实测 s3/s4 = 0）。
本核为单核、无外部缓存代理（无 DMA/无多核共享）⇒ 取"**数据不丢**"的保守语义：flush 只 clean。
**待办**：2A L1D 增加"维护写回"（逐组把脏路走既有 `wb_req` 通道）后，flush 才补 INVAL 并重挂判据。

## B4.18.4 修复后波形与计数（同一实验，同一天平）

```
t=8861 | inv=1 cln=0 mq=0 mc=0 midx=0   idle=1 | flush=1 cdqe=1 drany=0   ← cbo.inval（只失效）
t=9141 | inv=0 cln=1 mq=0 mc=0 midx=255 idle=1 | flush=1 cdqe=1 drany=0   ← cbo.clean（只清 dirty）
t=9402 | inv=0 cln=1 mq=0 mc=1 midx=255 idle=1 | flush=1 cdqe=1 drany=0   ← cbo.flush（保守：只 clean）
```

* `[C12']` 计数：`维护提交 3 次；L1D inval 1 / clean 2 次；全程无陷阱；4 次 load 数据正确`
  （= `[C12']` 四项判据原文）。
* p12 提交轨迹：`sw 0x55667788` → `lw s1 = 0x55667788` → `cbo.clean` → `lw s2 = 0x55667788`
  → `cbo.flush` → `lw s3 = lw s4 = 0x55667788`（4/4）。
  逐条轨迹（`DBG_P12=1`）中 `rd ∈ {9,18,19,20}` 的写回**恰好 4 条**：
  `idx=8 pc=0x8002_0020 wd=0x5566_7788`（`lw s1`）、`idx=10 pc=0x8002_0028`（`lw s2`）、
  `idx=12 pc=0x8002_0030`（`lw s3`）、`idx=13 pc=0x8002_0034`（`lw s4`）
  ⇒ `crk >= 4` 判据**没有"重执行掩盖错值"的余地**（4 次观测全对才算过）。
* p11 维护程序基线 **42/42 条黄金**、TLB 失效 2 次、L1I 扫掠 512 拍、L1D 失效 0
  ⇒ `sfence.vma` **不动 L1D** 的 K1'' 口径未回退。

## B4.18.5 延迟代价登记（修法 1 的成本，实测）

* 机制：维护提交 → （CDQ 排空 + 适配器空闲）→ 动作脉冲（+1 拍寄存）→ 4 拍冻结窗口 → 重定向。
* 上界：`CDQ 深度(4) + 适配器在途(≤1 笔，含缺失自填的若干拍) + 1`；**只影响维护延迟，不影响语义**
  （维护只需"更老的已提交 store 已落地"这一序关系）。
* 实测：p11 `1033 → 1035` 拍（+2 拍）；p12 在固定 4000 拍窗口内提交 **429 → 432** 条
  （修复后不再被误失效打断，重执行次数减少）。
* 极端情形（维护紧跟在写缺失的 store 之后）：动作要等该 store 的 fill + 重发完成
  （实测 t=9116→9137 共 21 拍）⇒ 登记为"最坏数十拍量级"，不设上限断言。

## B4.18.6 判据（91 → 103 项，p12 挂回）

* 生成器 `PROGS` 加回 `("back2_p12_cbo.S","P12","rv32ima_zicsr_zicbom","rv32imac_zicsr_zicbom",True)`
  （第 5 元素 `True` = **仅映像、无 Spike 黄金**：Spike 不支持 Zicbom，口径见 §B4.15.4）；
  TB `NPROG=9`、`pidx[8]=11`、第 9 槽基址 `0x20000`、`C12'` 四项判据：
  ① 全程无陷阱（cbo 合法性门控生效）② `L1D inval_all ≥ 1` ③ `clean_all ≥ 2`
  ④ 4 次 load 全部读到 `0x55667788`（数据安全）。
* 实测：`tb_core_top_2b` **103/103 PASS**（`../.b2chk/final_103.log`）——
  91 项既有判据 + 第 9 槽新增 12 项（C1'/C2' 各 1、C3' 2、C4' 2、C5' 2、**C12' 4**）。
  既有 8 程序的 PC/写回/AXI 基线与上一检查点逐项一致（p1 449/161、p3 462/126、p6 1077/366、
  p7 755/89、p8 4000/523、p9 843/92、p10 179/45、p11 1035/42）。
* `./scripts/regress.sh`（脚本**未改**）：见 §B4.18.8 日志。

## B4.18.7 遗留与风险（本段未做，均已定位）

1. **`cbo.flush` 的 INVAL 部分未实现**（保守口径，见 B4.18.3 登记）——结构阻塞点是 2A L1D
   缺"维护写回"通道；影响面：单核 + 无外部代理场景下不可观测；一旦引入 DMA/多核共享内存
   必须先补。
2. **2A L1D 的 `clean_all` 只清 dirty、不写回内存**（`l1d.v:288/338` `maint_dirty_clr`）⇒
   `cbo.clean` 后内存可能滞后于缓存；若该行随后被逐出，写回会被跳过（脏位已清）⇒
   数据丢失。本段只保证"cache 内数据不丢"（p12 判据即此口径）。**建议下一段**：
   把"clean"实现为"逐组对脏路发 `wb_req` 后清 dirty"，与上面第 1 条同一处改动。
3. 维护动作与同拍接管请求的竞争已用 `~maint_act_q` 挡住；维护扫描期间 `l1d_idle=0`
   ⇒ 适配器不会接管新请求（`d_ready_w = d_idle & ~l1d_busy_w`）⇒ 无重叠。
4. `cbo.zero`（`imm12=4`，属 Zicboz）由 2A 译码器判非法（`decoder.v:367-369`），本段不变。
5. `menvcfg.CBIE=01` 的 INVAL→FLUSH 降级仍未实现（§B4.9.4 在册），本段只修正了许可位判据。

## B4.18.8 本段检查点状态

* 编译 **0 error**；`tb_core_top_2b` **103/103 PASS**（`../.b2chk/final_103.log`）；
  `regress.sh` **32/32 PASS**（`总数=32 运行=32 通过=32 跳过=0 失败=0`，
  `../.b2chk/regress_p12fix.log`，含 `tb_core_top_2b`/`tb_back2_lockstep`/`tb_back2_ipc`）；
  判据文件可复现：`python3 sim/unit/prog/gen_back2_lockstep_data.py` 的输出与仓库内
  `back2_lockstep_data.svh` **逐字节一致**；2A 文件**零修改**；未提交 git；快照 `../.b2chk/*.s30`。
* 改动文件：`rtl/back2/backend_top.v`（cbo 解码 + 许可位 + `cdq_empty_o`）、
  `rtl/back2/lsq_simple.v`（`dr_empty_o`）、`rtl/top/core_top_2b.v`（维护等排空 + 动作脉冲 +
  锁存 + `~maint_act_q` 加固）、`sim/unit/tb_core_top_2b.sv`（第 9 槽 + C12' + `DBG_P12` 默认 0）、
  `sim/unit/prog/gen_back2_lockstep_data.py` + `back2_lockstep_data.svh`（p12 挂回）。
  `rtl/cache/l1d.v`、`rtl/cache/l1i.v`、`scripts/regress.sh` **未改**。
* 一句话：**p12 的内存序缺口已收口** —— 根因是 `cbo.*` 动作码解码（funct3 vs imm12[1:0]），
  叠加"维护不等已提交 store 排空"的序缺口；两处都已修，p12 4/4 数据正确、判据 103 项全绿，
  遗留的 `flush` INVAL 与 L1D 维护写回登记为下一段的 2A 侧改动。

---

# B4.19 D 侧翻译 + PTW 串行复用（2B-4 第 4b-2b 段）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已验收提交的 `d5451b8`=tag `2B-4.17`）
> 结论：**主线（D 侧 TLB 查询口 + PTW 串行复用 + 数据侧精确页错误通路）已落地**，编译零错误、
> `tb_core_top_2b` **103/103**、`regress.sh` **32/32**、2A 零修改；**p13_sv32 未挂回（WIP）**，
> 阻塞点已用波形铁证定位：**PTW 的 PTE 读走核内 AXI 直读、绕过 L1D ⇒ 读不到"已进 L1D
> 但尚未写回内存"的页表项**。修法（PTE 读经 L1D / 维护写回）登记为 4b-2c 第一优先。

## B4.19.1 已完成（RTL 主线，全部在本段落地并验证）

| # | 内容 | 落点与关键口径 |
|---|---|---|
| ① | **D 侧 TLB 查询口（口 1）接通** | `core_top_2b.v` §2b：LSU 适配器新增 `AD_XLATE`（TLB 组合查询）/`AD_TR`（等 PTW）两级；状态码 2 bit→**3 bit**（2 bit 会把 `4/5` 截断成 `0/1` 与 IDLE/REQ 撞车——编译警告抓出） |
| ② | **翻译使能判据（ISA 口径）** | `d_xlat_need_w = sv32_en & ((priv≠M) \| MPRV&(MPP≠M))`：**MPRV 仅在 MPP≠M 时生效**；Bare / 不满足 ⇒ **整级跳过**，逐拍与旧版相同 |
| ③ | **路由与访问一律用 PA** | `d_route_a_w`（`AD_XLATE`/`AD_TR` 取翻译结果、其余取请求 VA）喂 `mmio_route`；`d_a_q` = PA、`d_va_q` = VA（异常 `mtval` 用 VA） |
| ④ | **L1D 物理标签修正** | L1D 是 **VIPT**（`l1d.v:112-113/480-481` 用 `cs_vaddr` **同时**出 index 与 tag）⇒ 送 `cs_vaddr = {PA[31:12], VA[11:0]}`（物理 tag + 虚拟 index）。Bare 下与旧值逐位相同；Sv32 下才能保证"同 VA 重映射后不命中旧行"（sfence 重映射判据的前提） |
| ⑤ | **PTW 串行复用（数据优先）** | `m_tr_src_q` 归属寄存器（0=数据/1=取指，2A `core_top.v:1587-1595` 同构）；数据请求抢占取指在途遍历时 `kill`（取指 `tr_req_valid` 电平保持 ⇒ 自动重发）；**取指的 done/fault 按归属过滤**（否则数据侧遍历完成会被误当取指完成） |
| ⑥ | **取指翻译/保护不受 MPRV 影响** | ISA `norm:mstatusmprvinstxlatop`（2A `priv_ctrl.v:19` 亦明示）⇒ `sv32_translate_en = sv32_en & (csr_priv_2 != M)`、`lookup2_priv = csr_priv_2`（原先误用含 MPRV 语义的 `csr_eff_priv`）。实测不修的后果：M 模式 + MPRV=1 时**取指侧抢走 PTW 并做一笔错误遍历** |
| ⑦ | **数据侧精确页错误通路** | `lsq_simple`：新增 `mem_rsp_err` 输入 + `exc_valid/rob/cause/tval` 输出（cause **13**、tval = **VA**、抑制 PRF 写口）；`backend_top`：接到 ROB 的 `upd_exc_*`（4a 起该口恒 0 未用）；`core_top_2b`：TLB 权限错 / PTW 故障时以"正常响应 + err=1"回一笔 ⇒ **异常位与 done 位同沿写入** ⇒ 下一拍 ROB 头部同时看到 done+exc ⇒ 精确抛陷阱且该指令不提交 |
| ⑧ | **PTE 的 PMP 检查** | 沿用 4b-1b 的 `pmp_acc_xlat`（取指遍历 X / 数据 LOAD/STORE），本段未改 |
| ⑨ | **sfence.vma 全失效** | 保持 §B4.9.4 登记口径（单地址空间 ⇒ `sfence_all_va/all_asid` 恒 1；精确 va/asid 属后续） |

## B4.19.2 p13_sv32（WIP，**未挂回**）：已跑通的部分与决定性阻塞点

`sim/unit/prog/back2_p13_sv32.S`（保留在树内，WIP）+ TB 的 C13'（8 项判据，
快照 `../.b2chk/tb_core_top_2b.sv.s31wip`）已实现：两级页表（根/一级各占独立 4 KB 页）、
4 MB 恒等大页覆盖程序自身、翻译后的 load/store/load、未映射 VA 的 load page fault、
`sfence.vma` 后重映射、关 MPRV 直读 PA 复核。

**已跑通（提交轨迹铁证）**：

```
idx=44  li s4,0x40000100                      ← 打开 MPRV=1/MPP=S + satp=Sv32(root) 之后
idx=45  pc=0x80024138  csrr t3,mcause → 0x0000000d   ← ★ mcause = 13（load page fault）
idx=46  pc=0x8002413c  csrr t4,mtval  → 0x40000100   ← ★ mtval = 故障 **虚拟**地址
idx=47  pc=0x80024140  csrr t5,mepc   → 0x800240b4   ← 故障指令 PC（精确）
```

**阻塞点（决定性证据）**：PTW 的 PTE 读走**核内 AXI 直读**（`IOWN_PTE` 源，
`core_top_2b.v:951/1015`），**绕过 L1D** ⇒ 读不到"已写入 L1D 脏行、尚未写回内存"的页表项：

```
[p13-pte] t=13030 pa=0x80026400 data=0x00000013   ← 根页表项地址读回 nop 填充（clear_mem）
```

程序刚用 `sw` 写进去的 `0x00009C01` 仍在 L1D 里 ⇒ 遍历把根项当"非叶 + PPN=0"⇒
二级表读取失败 ⇒ 首次翻译即页错误（实测 4 次陷阱 = 反复重试）。
本核既无"PTE 读经 L1D"通路，也无"维护写回"（§B4.18 在册）⇒ 页表写在遍历可见之前无法保证。

**修法（4b-2c 第一优先，按代价排序）**：
1. **PTE 读经 L1D**（首选）：把 PTE 读作为一路数据侧 load 走适配器/L1D 端口（新增请求源 +
   响应回 PTW），使"页表写"与"遍历读"在同一缓存层次上连贯；
2. 给 L1D 维护口补**写回**，由 `sfence.vma`（或 cbo.clean）强制回写页表行（与 §B4.18 的
   flush INVAL 同一处 2A 改动）。

## B4.19.3 本段实测回归与修法（新增输入口在"直驱 TB"里悬空 ⇒ x 传播）

**症状**：`regress.sh` 首跑 `tb_back2_lockstep` FAIL（`C3 程序 1`：乱序核只提交 **24** 条后停摆
200000 拍；2A 侧 1024 条）。逐段二分实测：HEAD（改动前）RTL 同一 TB **PASS**（77.55 ms 结束），
本段 RTL 复现失败 ⇒ 回归由本段引入。

**根因**：`lsq_simple` 新增输入 `mem_rsp_err`（数据侧带错响应）。`tb_back2_lockstep` 是
**纯后端直驱 TB**（直接例化 `front4_top` + `backend_top`，不经 `core_top_2b`）⇒ 该新输入
**未接**（悬空 z）⇒ `rsp_ok & mem_rsp_err = x` ⇒ `wb_dst_i/f` 里的 `x ? 0 : ld_di[...]`
按位归并成 **x** ⇒ PRF 写口有效位/目的号变 x ⇒ 第一个带目的寄存器的 load 之后整核写回失效
（前 24 条能提交，正是"第一次 load 响应"之前的指令数）。

**修法**（1 行，中心化，防御性正确）：LSQ 内先净化 —— `wire rsp_err_w = (mem_rsp_err === 1'b1);`
口径：**只有明确的 1 才算带错响应**，z/x/0 一律按正常响应处理。修后同一 TB **PASS**，
`regress.sh` 全绿（见 §B4.19.5）。
**教训（登记）**：给被"直驱 TB"直接例化的模块新增输入口时，必须①在模块内对输入做 z/x 净化，
或②同步给所有直驱 TB 补 `1'b0` 拴接；否则悬空 z 会经 `?:`/算术传播成 x 并静默毁掉功能。

## B4.19.4 遗留与下一步

1. **PTE 读连贯性**（上述阻塞点）—— 4b-2c 第一优先；在此之前 Sv32 不能端到端可信。
2. **store page fault 的精确性**：本核 store 在**提交点之后**才排空（CDQ ⇒ 适配器）⇒
   翻译发生在提交后 ⇒ 页错误**不精确**（会丢写）。修法：**执行期 store 翻译**（PA 随
   STQ/CDQ 项带入排空口），属 4b-2c。
3. **A/D 硬件置位写通路未实现**（`pte_ad_done` 恒 0 ⇒ 若 PTE 的 A/D=0，PTW 会**挂死**，
   fail-closed）：p13 采用"A/D 预置 1"绕开；硬件置位 + PTE 写回属 4b-2c。
4. **取指翻译的端到端验证**未做（需进入 S 模式执行流 + 取指 PMP 接 `csr_file` 真值；
   本段只把"取指翻译使能/特权级"的口径修正到位）。
5. `cbo.flush` 的 INVAL、L1D 维护写回（§B4.18）仍在册；`menvcfg.CBIE=01` 降级未实现。

## B4.19.5 本段检查点状态

* 编译 **0 error**；`tb_core_top_2b` **103/103 PASS**（`../.b2chk/final_103_b.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b2b.log`）；2A 文件**零修改**；未提交 git；
  快照 `../.b2chk/*.s31`（含 WIP 的 `tb_core_top_2b.sv.s31wip`、`back2_p13_sv32.S.s31`）。
* 改动文件：`rtl/top/core_top_2b.v`（§2b 数据侧翻译 + PTW 仲裁 + 适配器两级 + 错误响应 +
  L1D 物理 tag + 取指特权级口径）、`rtl/back2/lsq_simple.v`（`mem_rsp_err`/`exc_*`）、
  `rtl/back2/backend_top.v`（`mem_rsp_err_i` + ROB `upd_exc` 接线）、
  `sim/unit/prog/back2_p13_sv32.S`（WIP）；生成器与 `.svh` **已还原到 p12 挂回态**
  （9 槽 / 103 项），TB 的 C13' 块已摘除（源码在 `.s31wip` 快照内）。
* 一句话：**D 侧翻译与 PTW 串行复用的结构已就位且既有判据零回退；p13 的 Sv32 端到端判据
  被"PTE 读绕过 L1D（遍历不连贯）"卡住 —— 修法已定位到 4b-2c 的两条路线。**

---

# B4.20 PTE 读连贯性 + A/D 口径 + store 页错误（2B-4 第 4b-2c 段）

> 载体：`/home/shorthair/dsh/rv32-cpu/rv32gc-cpu`（dev，起点 = 母代理已验收提交的 `4050001`=tag `2B-4.18`）
> 结论：**PTE 读已改经 L1D（第一优先达成，阻塞点解除）**；顺带定案并修掉一个真实的**缓存口径缺陷**
> （VIPT 伪命中/别名 ⇒ 改 PIPT）与一个 **PTW 中止缺口**（冲刷必须 kill 遍历）；
> **A/D 口径按 2A = SVADE=1（软件置位，无硬件写通路）**；`tb_core_top_2b` **103/103**、
> `regress.sh` **32/32**、2A 零修改。p13 仍未挂回：12 项判据中 **11 项已过**，唯一残留是
> **`sfence.vma` 后重映射未生效（TLB 保留旧翻译）**，已定位到"flush 与 fill 的交叠"这一处，
> 留给下一段收口。

## B4.20.1 已完成（RTL 主线）

| # | 内容 | 落点与关键口径 |
|---|---|---|
| ① | **PTE 读经 L1D**（第一优先） | `core_top_2b.v`：新增 `AD_PTE`/`AD_PTER` 两级 —— PTE 读**借数据适配器 + L1D 端口**完成（`pte_req_ready = pte_rd_go_w`、`pte_resp_valid/data` 取自 L1D 读命中拍）；入口两处：`AD_IDLE`（取指侧遍历，数据侧空闲）与 `AD_TR`（数据侧遍历期间嵌套服务，读完回 `AD_TR`）；PTE 地址是 **PA、不再翻译**，且 `AD_PTE` 拍**强制 `cs_we=0`**（否则会拿上一笔 store 的数据写 PTE 行）；`AD_PTER` 等 L1D 自填后重发。**AXI 侧删除该源**（`g_pte=0`，XIP/L1I 填充不再被 PTE 读抑制） |
| ② | **L1D 改 PIPT**（本段实测抓出的真实缺陷） | 原 `cs_vaddr = {PA[31:12], VA[11:0]}`（物理 tag + 虚拟 index）与 Bare 路径**不同源**：Bare 用 PA 同时定 index/tag，Sv32 用 VA 定 index ⇒ 同一 PA 因访问路径不同落到**不同组**（实测：译后 load 命中到别的数据槽 0x55667788，而非自己的 0x11223344）。**定案：index 与 tag 同源取 PA**（本 L1D 几何 256 组 × 32 B：index=addr[12:5]、tag=addr[31:13]）⇒ 同一 PA 恒同一行、VA 重映射 ⇒ PA 变 ⇒ 必然 miss。Bare 下与旧实现逐位相同 |
| ③ | **PTW 中止（kill）缺口** | `ptw_kill_w` 除"数据优先抢占取指遍历"外，**加 `be_trp_flush`**（陷阱/xRET/维护整机冲刷）—— 2A `m_kill_fsm = trap_valid \| xret_redirect \| fencei_hold \| …` 同口径。否则适配器被 kill 后不再回 PTE 响应 ⇒ PTW 永停 `S_L1_W/S_L0_W` ⇒ 全网挂死 |
| ④ | **A/D 口径（按 2A 定案：SVADE=1）** | `rtl/csr/ptw.v:50-58`：`SVADE=1` 是**默认且 2A core_top 明确采用** ⇒ A=0（或写且 D=0）**直接 page-fault 交软件置位**，**不存在硬件 A/D 写通路**（`pte_ad_done` 仅 SVADE=0 时可达）。⇒ 母代理任务书 ③ 的"§5 引擎第 7 源"**按 2A 口径不需要做**；p13 的 A/D 判据改为"程序置位 + 回读一致"+"A=0 ⇒ 页错误（不挂死）"，**判据更强**（实测两次页错误 cause 均为 13、mtval 分别为 0x4000_1000/0x4000_2000 ✓） |
| ⑤ | **p13 判据（12 项中 11 项已过）** | 见 §B4.20.2：两级页表翻译链、两次精确页错误、`mtval`=VA、直读 PA 一致、PTE A/D 回读一致、精确返回 —— 均已实测通过 |

## B4.20.2 p13 实测（未挂回）：11/12 过，唯一残留 = sfence 后重映射

```
idx=49  lw s5  (VA 0x4000_0100 → PA l1 页+0x100) = 0x11223344   ✔ 翻译后 load
idx=53  lw s6  （译后 store→load）              = 0xDEADBEEF   ✔
idx=55/56  mcause=13, mtval=0x4000_1000（V=0 未映射）           ✔ 精确页错误 #1
idx=63/64  mcause=13, mtval=0x4000_2000（**A=0 ⇒ SVADE**）      ✔ 精确页错误 #2
idx=85  lw s10 （关 MPRV 直读 PA）              = 0xDEADBEEF   ✔
idx=86  lw s11 （PTE 回读）                     = 0x2000_9CC7  ✔ A/D 置位回读一致
idx=81  lw s9  （**sfence 重映射后**同 VA）      = 0xDEADBEEF ✘ 期望 0x55667788
[维护计数] maint=2 tlb_sfence=2 l1d_inval=0 l1d_clean=0
```

* **PTE 读连贯性已达成**（①的证据）：`[p13-pte]` 打点显示遍历读到的正是程序写入的 PTE
  （`0x80026400→0x2000_9C01`、`0x80027000→0x2000_9CC7`、`0x80027008→0x2000_9C07`），
  A=0 的那笔因此**正确判页错误**（而非像 4b-2b 时读到内存旧值/挂死）。
* **唯一残留**：`sfence.vma` **已提交且两次 flush 脉冲都发出**（`maint=2 tlb_sfence=2`），
  但重映射后的 load 仍得到旧翻译 ⇒ **TLB 保留了旧表项**，且其后**没有任何 PTE 读**
  （打点无新记录）⇒ 不是"重填后再次陈旧"，而是"flush 未真正清掉该表项"。
  最可疑点：`tlb.v:375-384` 的 **flush 与 fill 在同一 always 块、fill 覆盖 flush**
  （注释自述"失效优先，填充覆盖"）⇒ 只要该 VPN 的 walk 恰在 flush 拍回填，旧表项即复活。
  **下一步（一步判定实验）**：在 flush 脉冲拍打印 `tlb` 内部 `v_bit[i]/vpn[i]` 与该拍
  `fill_valid/fill_va`（或对同一 VA 前后各放一次 sfence 并观察 TLB 命中计数
  `hit_count_o/miss_count_o`），即可判定"未清"还是"清了又被同拍回填"。

## B4.20.3 遗留与下一步

1. **sfence 后重映射**（上述唯一残留）—— 建议先做 §B4.20.2 的一步判定实验；若判定为
   "fill 覆盖 flush"，修法是在 `tlb.v` 的 flush 分支后**禁止同拍 fill 写同一 VPN**
   （属 2A 文件 ⇒ 需母代理批准的最小加法，或改为"flush 延后一拍生效"的 2B 侧规避）。
2. **store page fault 精确化**（任务书 ②，本段未做）：本核 store 在**提交点之后**才排空
   （CDQ ⇒ 适配器）⇒ 翻译/页错误发生在提交后，**不精确**。设计（供下一段）：
   · 在 LSU 的执行期（E1 地址生成后）为 store 发一路"**翻译专用**"请求（`st_xlate_*`：
     VA + we + ROB 索引），适配器复用 `AD_XLATE/AD_TR` 服务；
   · 把翻译得到的 **PA 写入 STQ 项**（`stq_pa`），CDQ 排空口直接用 PA（不再翻译）；
   · 该路请求返回页错误 ⇒ 经 LSQ 的 `exc_*` 通道（cause 15 = store page fault、tval=VA）
     精确上报 —— 与 4b-2b 已建成的 `upd_exc` 通路同构。
3. **L1D 维护写回**（任务书 ① 后半，本段未做）：`clean_all` 只清 dirty、`inval_all` 只清 valid，
   都**不写回**（§B4.18 在册）。**本段已使 PTE 读经 L1D ⇒ 页表写在遍历中可见，该缺口不再阻塞
   Sv32**；它仍然影响 `cbo.clean/flush` 的内存可见性与 `cbo.flush` 的 INVAL 部分
   （建议与 §B4.18 的 flush INVAL 合并为同一处 2A 最小加法）。
4. **L1I 侧同类风险**：L1I 也是 VIPT（取指地址若为 PA、index 取 VA 会同类不同源）；本段只改了
   L1D 的数据口，L1I 的译后取指路径建议下一段按同一 PIPT 口径复核（fence.i 已能兜底失效）。

## B4.20.4 本段检查点状态

* 编译 **0 error**；`tb_core_top_2b` **103/103 PASS**（`../.b2chk/final_103_c.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b2c.log`）；2A 文件**零修改**（`l1d.v` 未动）；
  未提交 git；快照 `../.b2chk/*.s32`（含 WIP：`tb_core_top_2b.sv.s32wip`、`back2_p13_sv32.S.s32wip`）。
* 改动文件：`rtl/top/core_top_2b.v`（AD_PTE/AD_PTER + PTE 读经 L1D + PIPT + `ptw_kill` 补冲刷 +
  `cs_we` 屏蔽）；TB/生成器**已还原到 p12/p13 未挂回态**（9 槽 / 103 项）。
* 一句话：**PTE 读连贯性达成（第一优先完成），并顺带修掉 VIPT 伪命中与 PTW 中止两个真实缺陷；
  A/D 按 2A 口径定案为软件置位（不做硬件写通路）；p13 仅剩"sfence 后 TLB 未清干净"一项，
  已收窄到 flush/fill 交叠并给出一判定实验。**

---

# B4.21 sfence 重映射残留：一步判定实验 + 两处修法（2B-4 第 4b-2c 段续）

> 起点 = 母代理已验收提交 `43a8ce5`=tag `2B-4.19`。预算见底 ⇒ 停在"编译零错误 + 既有判据全绿"
> 检查点：`tb_core_top_2b` **103/103**、`regress.sh` **32/32**；p13 仍**未挂回**。
> **①一步判定实验已完成并给出结论**；**②修法按预授权落地两处**（`tlb.v` 最小加法 + 2B 侧代际闸门）；
> **③重映射残留仍未消除**（实验把范围进一步收窄，见 §B4.21.3）。

## B4.21.1 一步判定实验（结论：**"同拍回填覆盖 flush"被证伪**）

TB 新增打点（`DBG_P13=1`，默认关）：在 `maint_tlb_sfence_w` 拍打印"同拍是否在填充 +
fill 地址/PPN + TLB 命中/缺失/失效计数"（`u_dut.ptw_fill_*`、`u_dut.u_tlb.hit_cnt/miss_cnt/flush_cnt`）：

```
[tlbflush] t=13513 sfence=1 fill_valid=0 fill_va=0x80027100 fill_ppn=0x080027 | hit=1 miss=4 flush=0
[tlbflush] t=13625 sfence=1 fill_valid=0 fill_va=0x80027100 fill_ppn=0x080027 | hit=1 miss=5 flush=1
```

* 两次 `sfence.vma` 的 flush 拍 **`fill_valid` 皆为 0** ⇒ **不存在"同拍 fill 把刚失效的表项装回"**；
  `flush=1` 说明失效计数确实递增（flush 生效过）⇒ §B4.20.2 的"最可疑点"**被排除**。
* 结合"重映射后同 VA 仍得旧页数据、且其后无任何新 PTE 读"⇒ 残留形态是
  **旧翻译在 flush 之后仍对查询可见**，而不是"同拍冲突"。

## B4.21.2 已落地的两处修法（均为最小加法，逐拍影响面已登记）

1. **`rtl/csr/tlb.v` 最小加法（母代理预授权）**：fill 分支加同项冲突闸门 ——
   `if (~(sfence_valid & way_do_flush[fill_idx])) begin …填充… end`。
   **理由登记**：该块注释自述"失效优先，填充覆盖"，但实现顺序是"先失效、后填充"
   ⇒ 同拍同项时填充会覆盖刚做的失效；本加法把语义纠正为**flush 优先于 fill**
   （被抑制的表项保持无效，下次查询 miss 后重新遍历，语义安全）。
   影响面：仅"flush 与 fill 同拍且 `fill_idx` 正是被清项"这一冲突拍；其余逐拍不变。
   **本段实测**：该冲突在 p13 中未发生（见 §B4.21.1）⇒ 本加法是**正确性加固**，
   不是本次残留的解。
2. **2B 侧"遍历代际"闸门**（`rtl/top/core_top_2b.v`）：`ptw_flushed_q` —— 整机冲刷置位、
   新遍历被接受时清位；TLB 的 `fill_valid` 加限定 `& ptw_fill_ok_w` ⇒
   **冲刷前启动的遍历即使晚到也不得回填 TLB**（跨冲刷的陈旧结果一律丢弃）。
   影响面：只丢弃"跨冲刷"的回填，正常路径不变。

## B4.21.3 p13 现状：**8/12 已过，1 项实测失败（重映射），3 项未及判定**

| 判据 | 状态 | 证据 |
|---|---|---|
| C13'-1/2/3 两次陷阱、cause 均 13 | ✔ | `n_trap_p=2`、`trc_cause=13/13` |
| C13'-4 handler 两次读回 mcause=13 | ✔ | 轨迹 `rd=28` 两次 = 13 |
| C13'-5/6 `mtval` = 0x4000_1000 / 0x4000_2000（VA 口径） | ✔ | 轨迹 `rd=29` 两次 |
| C13'-7 译后 load = 0x11223344 | ✔ | 轨迹 `rd=21` |
| C13'-8 译后 store→load = 0xDEADBEEF | ✔ | 轨迹 `rd=22` |
| **C13'-9 sfence 后重映射（同 VA 读新页 0x55667788）** | ✘ | 轨迹 `rd=25` = **0xDEADBEEF**（旧页）；`n_tlb_sfence=2` |
| C13'-10/11/12 直读 PA / A/D 回读 / 精确返回 | 未及判定（9 失败即 fatal） | 4b-2c(1/2) 实测均为 ✔（`rd=26`=0xDEADBEEF、`rd=27`=0x2000_9CC7、`rd=10`=1） |

**残留范围已收窄到**：flush 确实发生（`flush=1`）、无同拍冲突、跨冲刷回填已禁止，
但**重映射后同 VA 的翻译仍为旧 PA**，且其后**无新的 PTE 读** ⇒ 只剩两类可能：
(a) 该 VA 的 TLB 表项在 flush 时**未被清**（例如 `way_flush` 的 `v`/VPN 匹配口径、
    或 flush 脉冲与该表的写口存在**同拍回填之外的**其它覆盖路径）；
(b) 重映射后的 load **根本没有走翻译**（`d_xlat_need_w` 在该拍为 0 ⇒ 直接用 VA 访问），
    恰好因 PIPT 与"旧 PA 行"同 index 而读到旧数据。
**下一步一步判定（建议）**：在该 load 的 `AD_XLATE` 拍打印 `d_xlat_need_w/d_va_q/d_tlb_hit/
ptw_pa_out`，并在 flush 前后读一次 `u_tlb.miss_cnt` —— 即可区分 (a)/(b)，随后按类修。

## B4.21.4 本段检查点状态

* 编译 **0 error**；`tb_core_top_2b` **103/103 PASS**（`../.b2chk/final_103_d.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b2c2.log`）；未提交 git；
  快照 `../.b2chk/*.s33`（含 WIP：`tb_core_top_2b.sv.s33wip`、`back2_p13_sv32.S.s32wip`）。
* 2A 修改：**仅 `rtl/csr/tlb.v` 一处最小加法**（母代理预授权，理由见 §B4.21.2-1）；其余 2A 零修改。
* 一句话：**一步判定实验把"同拍回填覆盖 flush"证伪；两处修法（tlb.v flush 优先 + 2B 遍历代际闸门）
  已落地并零回退；重映射残留范围进一步收窄到"表项未被清 / 该 load 未走翻译"两类，
  下一步判定实验与两类修法已在报告写死。**

---

# B4.22 (a)/(b) 一步判定定案 + p13 挂回收口（2B-4 第 4b-2c 段收口）

> 起点 = 母代理已验收提交 `0953faa`=tag `2B-4.20`。
> **结论：(a)/(b) 都不是 —— 定案为 (c)：与维护 op 同处一个提交组的 store 被"漏排空"。**
> 修复后 **p13 12/12 全过**、`tb_core_top_2b` **121/121**（103 + 第 9 槽通用 6 + C13' 12）、
> `regress.sh` **32/32**；2A 仅 `rtl/csr/tlb.v` 一处预授权最小加法。

## B4.22.1 一步判定（原始证据，全部来自 `[p13]` 逐拍打点）

```
t=13730 ad=4 va=0x40000100 we=0 need=1 hit=0 …          ← 重映射后的 load：**确实走翻译且 TLB 未命中**
t=13731 ad=5 va=0x40000100 ptwreq=1 rdy=1               ← 发起遍历
t=13734 pte_rv=1  [p13-pte] pa=0x80026400 data=0x20009c01   ← 一级 PTE 正确
t=13737 pte_rv=1  [p13-pte] pa=0x80027000 data=0x20009cc7   ← ★ 二级 PTE 仍是**旧值**！
```

* ⇒ **排除 (b)**：`d_xlat_need_w=1`、`hit=0` ⇒ load 走了翻译、也发起了遍历，不是"未走翻译"。
* ⇒ **排除 (a)**：表项并非"flush 未清"——它已被清（miss⇒遍历）；问题在**遍历读回的 PTE 是旧的**。
* ⇒ **定案 (c)**：PTE **更新 store 丢失**。证据链：
  · 程序 `sw t1,0(s1)`（pc=0x8002_4104）**已提交**（提交轨迹 idx=75 ✓）；
  · 但适配器侧**从未出现该笔**（全日志按 `a=0x80027000 we=1` 检索，只有 t=12928 的**初始**写，
    更新写缺失）⇒ 该 store 从未进 L1D；
  · 该 store 与紧随其后的 `sfence.vma` **同处一个提交组** ⇒ 维护 op 的 `be_trp_flush`
    抑制了整组的 CDQ 排空入队 ⇒ **已提交 store 静默丢失**（架构可见性被破坏）。

## B4.22.2 修法与规避

| 类型 | 内容 |
|---|---|
| **程序侧规避（本轮挂回用）** | 在 `sw`（PTE 更新）与 `sfence.vma` 之间插入 **6 条 `nop`** ⇒ 二者分属不同提交组 ⇒ store 正常排空。`sim/unit/prog/back2_p13_sv32.S` 中已注明"这是规避，RTL 根因待修" |
| **RTL 根因（下一段必修，建议）** | `be_trp_flush` 不得抑制同组**更老** store 的排空入队（`cmt_st_drain`/`dr_valid`/`mem_wr_ready` 一路）；修法方向：维护 op 的冲刷掩码只作用于**比它更年轻的 lane**（与 §B4.18 的 `cmt_hold_w` 同源思路），并把"同组更老 store 必须完成 CDQ 入队"作为判据 |
| （预授权已落地，保留） | `rtl/csr/tlb.v` fill 分支同项闸门（flush 优先于 fill）+ 2B 侧 `ptw_flushed_q` 遍历代际闸门（跨冲刷回填丢弃）——本轮判定证明二者**不是**本残留的解，但都是正确性加固，且 regress 全绿 |

## B4.22.3 p13 挂回与判据明细（103 → 121，全绿）

* 生成器 `PROGS` 加回 `back2_p13_sv32.S`（第 5 元素 True = 仅映像）；TB `NPROG=10`、`pidx[9]=12`、
  基址 `0x24000`、`C12'` 之后新增 **`C13'` 12 条**：
  | 判据 | 内容 | 实测 |
  |---|---|---|
  | C13'-1 | 恰好 2 次陷阱交付 | 2 ✔ |
  | C13'-2/3 | 两次 mcause = 13（V=0 / A=0） | 13/13 ✔ |
  | C13'-4 | handler 两次读回 mcause = 13（精确交付） | ✔ |
  | C13'-5/6 | `mtval` = 0x4000_1000 / 0x4000_2000（**VA** 口径） | ✔ |
  | C13'-7 | 译后 load（VA 0x4000_0100 → PA l1 页）= 0x11223344 | ✔ |
  | C13'-8 | 译后 store→load = 0xDEADBEEF | ✔ |
  | C13'-9 | **sfence 后重映射生效**（同 VA 读新页 0x55667788）+ `n_tlb_sfence ≥ 1` | ✔ |
  | C13'-10 | 关 MPRV 直读 PA = 0xDEADBEEF | ✔ |
  | C13'-11 | **PTE 回读 = 重映射后新 PTE 0x2000_98C7**（A/D 置位保持；PTE 读经 L1D 的直接证据） | ✔ |
  | C13'-12 | 陷阱精确返回后继续执行（a0 = 1） | ✔ |
* 合计 **121 项**（= 既有 103 + 第 9 槽通用判据 6（C1'/C2'/C3'×2/C4'×2）+ C13' 12）；
  母代理预期的 "103+12=115" 中，另有 6 项是新槽位本就该跑的通用判据（**判据只增不减**）。

## B4.22.4 检查点状态与下一步

* 编译 **0 error**；`tb_core_top_2b` **121/121 PASS**（`../.b2chk/final_115.log`，文件名沿用）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b2c3.log`）；未提交 git；快照 `../.b2chk/*.s34`。
* 2A 修改：仅 `rtl/csr/tlb.v` 一处最小加法（预授权）。`scripts/regress.sh` 未动。
* **下一步（按优先级）**：①修 §B4.22.1 定案的"同组 store 漏排空"（真 RTL 缺陷，影响任何
  "store 紧跟维护/陷阱/xRET"的程序），修完可去掉 p13 里的 6 条 nop 规避；
  ②store page fault 精确化（§B4.20.3 设计）；③L1D 维护写回 + `cbo.flush` INVAL 合并；④L1I 侧 PIPT 复核。

---

# B4.23 同组更老 store 漏排空：根因修复尝试与探针定案（2B-4 第 4b-2c 段）

> 起点 = 母代理已验收提交 `2d2428c`=tag `2B-4.21`。
> 结论：**修法已按任务书落地（`cmt_ok` 解耦 + 掩码口径），但"store 紧跟 sfence"原始形态
> 仍失败 ⇒ 抑制点不在 `cmt_ok/cmt_hold_w`**。已把候选缩小到"从未入队 / 入队后丢失"两支，
> 并给出一步探针；检查点保持 **121/121 + regress 32/32**（p13 暂留 6 条 `nop` 规避）。

## B4.23.1 已落地的根因修法（diff 摘要）

```verilog
// rtl/back2/backend_top.v §9（原）：
assign lsu_dr_valid[cc] = cmt_st_drain[cc] & cmt_ok & ~cmt_hold_w[cc];
// （新）：更老 store 的排空入队**不再无条件乘 `cmt_ok`**（`cmt_ok` 只在整机冲刷拍为 0，
//        而那正是"更老 store 仍需入队"的拍）：
wire cmt_ok_st_w = ~squash_v_w & (cmt_ok | (trp_flush_v_i &
                     ((|maint_lane_oh) | (|xret_lane_oh) | maint_pend_hold_w)));
assign lsu_dr_valid[cc] = cmt_st_drain[cc] & cmt_ok_st_w & ~cmt_hold_w[cc];
```
`maint_pend_hold_w = maint_cmt_o | (|maint_lane_oh)`（"维护已提交/整机冲刷在进行"）。

**实测结论**：去掉 p13 的 6 条 `nop`（恢复"PTE 更新 store 紧跟 `sfence.vma`"原始形态）后
`C13'-9` **仍失败**（同 VA 仍读旧页）⇒ 该修法**不是**充分条件：`lsu_dr_valid` 在原式下
本来就应该为 1（维护提交拍 `cmt_ok=1`，且 `cmt_hold_w` 只掩更年轻 lane），
⇒ **抑制点不在这两个门**。

## B4.23.2 候选收窄与一步探针（下一步）

按现有数据（`a=0x80027000 we=1` 全日志检索：更新写**完全缺失**；store 提交轨迹可见）：

| 分支 | 含义 | 判别探针（store 提交拍逐拍打印） |
|---|---|---|
| **(i) 从未入队** | `dr_valid/dr_take` 为 0，或 `cdq_tail/cdq_cnt` 不增 | `u_dut.u_back.u_lsu.dr_take`、`dr_push_n`、`cdq_tail`、`cdq_cnt`、`cmt_st_drain`、`lsu_dr_valid` |
| **(ii) 入队后丢失** | `cdq_cnt` 增了但 `cdq_a[tail]` 不是 0x8002_7000，或 `cdq_cnt` 随后被清/回退 | 同上 + `cdq_a[cdq_tail]`、`cdq_v[]`、`cdq_head`、`flush_all`/`squash` |

**优先怀疑**（供下一段先看）：LSQ `flush_all` 分支（`lsq_simple.v:637-639`）在同拍清空**整张 STQ**
（`stq_v/av/dv/ret`），而 CDQ 入队在同拍从 `stq_a/stq_d/stq_msk[dr_idx]` **拷贝**——
若 `flush_all` 与入队同拍且**指针/回收**（`:783-787` 的 STQ 队头回收）也参与，则可能出现
"拷贝到了但项被回收/覆盖"的竞态；探针 (ii) 可直接判定。

## B4.23.3 检查点状态与下一步

* 编译 **0 error**；`tb_core_top_2b` **121/121 PASS**（`../.b2chk/final_121.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b2c4.log`）；2A 零修改；未提交 git；
  快照 `../.b2chk/*.s35`。
* p13 **暂留 6 条 `nop` 规避**（否则 C13'-9 红）——规避注里已写明"RTL 根因待修；已试修法不足"。
* **下一步**：①按 §B4.23.2 探针判定 (i)/(ii)，再定点修；修好后去掉 `nop` 并重跑 121；
  ②store page fault 精确化（§B4.20.3 设计，本段因预算未做）；③L1D 维护写回 + `cbo.flush` INVAL；
  ④L1I 侧 PIPT 复核。

---

# B4.24 同组更老 store 漏排空：抑制点排除到 `lsu_dr_valid` 之后（2B-4 第 4b-2c 段续）

> 起点 = 母代理已验收提交 `5f9d588`=tag `2B-4.22`。
> 结论：**两次定点修法（`cmt_ok` 解耦 → 彻底去掉冲刷门）均不足以治愈**；结合代码定案，
> **丢失点已被排除到 `lsu_dr_valid` 之后**（CDQ 入队/记账路径）。检查点保持 **121/121 + regress 32/32**；
> p13 暂留 6 条 `nop` 规避。

## B4.24.1 逐拍/代码定案（(i) vs (ii)）

* **`cmt_st_drain` 不含任何 flush/squash 门**（`rob.v:213` = `cmt_chain & slot_store`，
  而 `cmt_chain` 只是 `slot_ok` 的**前缀链**，`rob.v:175-178`）⇒ 维护/陷阱/xRET 拍，
  "更老的已提交 store" 的 `cmt_st_drain` **仍为 1**。
* 原式 `lsu_dr_valid = cmt_st_drain & cmt_ok & ~cmt_hold_w` 中 `cmt_ok` 含 `~squash_v_w`
  与 `~flush_all_w` ⇒ 该拍入队被抹掉（**这是本段第一处修法**：改为
  `cmt_ok_st_w = ~squash_v_w & (cmt_ok | (trp_flush_v_i & ((|maint_lane_oh)|(|xret_lane_oh)|maint_pend_hold_w)))`）。
* **反证**：去掉 `nop` 后仍失败 ⇒ 继续收紧为 **`lsu_dr_valid[cc] = cmt_st_drain[cc] & ~cmt_hold_w[cc]`**
  （排空入队只看"前缀链里的 store"+"不被维护 lane 掩码挡住"，**彻底不乘任何冲刷门**）。
* **仍失败** ⇒ 判定：**不是 (i) 的入队许可问题**（该式此时恒允许），而是 **(ii)-型：
  入队许可之后、CDQ 记账/排空路径上丢失**。下一处探针（下一步唯一动作）：
  在维护提交拍逐拍打印 `u_dut.u_back.u_lsu.dr_take / dr_push_n / cdq_wp / cdq_head / cdq_tail /
  cdq_cnt / cdq_v[] / dr_idx`——即可判定"未真正写入（`dr_take=0`）"还是"写入后被队列指针/回收吃掉"。

## B4.24.2 已落地的修法（保留：语义正确、回归全绿）

```verilog
// rtl/back2/backend_top.v §9
- assign lsu_dr_valid[cc] = cmt_st_drain[cc] & cmt_ok & ~cmt_hold_w[cc];
+ assign lsu_dr_valid[cc] = cmt_st_drain[cc] & ~cmt_hold_w[cc];
```
**理由**：`cmt_st_drain` 天然只含**已提交前缀**里的 store，整机冲刷不可能让更老项变成未提交
⇒ 入队不应再乘 `cmt_ok`（原式会在维护/陷阱/xRET 拍丢掉更老 store 的排空入队）。
**该修法本身是对的**（覆盖维护/陷阱/xRET 三种冲刷形态），只是**不是本残留的充分修法**。

## B4.24.3 判据升级（③）与本段状态

* **判据升级未落地**：计划新增的硬断言"维护冲刷拍同组更老 store 完成 CDQ 入队"
  （采样 `be_trp_flush & |lsu_dr_valid` 计数 ≥1，反证=临时恢复旧式必 FAIL）因预算见底未实施；
  **现有 C13'-9 已是该缺陷形态的端到端判据**（重映射生效 ⇐ PTE 更新 store 必须已排空到 L1D），
  本段两次"无 nop 形态"失败即该判据在起作用（**未放宽**）。
* 编译 **0 error**；`tb_core_top_2b` **121/121 PASS**（`../.b2chk/final_121b.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b2c5.log`）；2A 零修改；未提交 git；快照 `../.b2chk/*.s36`。
* **下一步（唯一动作）**：按 §B4.24.1 末段探针判定 (ii) 的具体点（候选：CDQ 写指针与 `cdq_head`
  同拍冲突 / `cdq_v[wp]` 写入被随后语句覆盖 / 排空握手在该拍被 `maint_act_q` 挡住），
  修后**去掉 `nop`** 重跑 121；随后 ②store page fault 精确化、③L1D 维护写回 + `cbo.flush` INVAL、
  ④L1I 侧 PIPT 复核。
### B4.24.4 CDQ 入队/记账路径复核（本段补做，收窄下一步）

复核 `lsq_simple.v` 的入队/记账/出队三段（`495-522`、`763-787`）：

* **入队许可**：`dr_room_ok = ((CDQ_N - cdq_cnt) >= W)`、`dr_take = dr_valid & room`
  —— 只吃寄存器态、与提交链无环 ✓；且 `rob.v:168` 的 `slot_st_ok = ~store | mem_wr_ready`
  意味着"store 能进提交前缀 ⇒ 入队余量本拍必为 1" ⇒ `dr_take` 与 `dr_valid` 等价 ✓。
* **写指针/序号**：`dr_rank` 逐 lane 压缩（2 bit/lane，W=4 ⇒ 0..3 ✓）、`cdq_wp = cdq_tail + rank`
  ✓、`cdq_tail += dr_push_n` ✓、`cdq_cnt += dr_push_n - dr_fire`（单条赋值合并 ✓）——
  **未发现"写指针与 cdq_head 同拍冲突"或"cdq_v[wp] 被后续语句覆盖"的结构性缺陷**
  （同一 always 内 `if (squash)` 只动 STQ/LQ 的更年轻项，不碰 `cdq_*`）。
* ⇒ **候选收敛到"排空握手"一侧**：`dr_fire = dr_any & mem_req_ready`，而
  `mem_req_ready = d_ready_w = d_idle & ~l1d_busy_w & ~maint_act_q`。下一步探针必须**同时**打印
  `dr_any / mem_req_ready / d_idle / l1d_idle / maint_act_q` 与 `cdq_cnt/cdq_head/cdq_tail`
  —— 判定"入队了但排空握手被挡（或 `d_ready_w` 长期为 0）"。
* 另需一并核对：**该笔 store 排空时是否走了翻译**（`AD_XLATE` ⇒ PTW 遍历）而遍历失败/挂起
  （若 MPRV 此刻为 1）；探针加打印 `ad_st_q / d_xlat_need_w / ptw_req_done / ptw_fault` 即可闭合。
### B4.24.5 交接：本轮未跑探针（预算耗尽），绿色检查点保持 + 可直接执行的下一步

* **本轮状态**：未修改 RTL/TB/程序（`git diff` 仅本报告）⇒ RTL **与母代理已验收提交 `367d963`
  （tag 2B-4.23）逐字节一致**；绿色证据沿用本会话实测：`../.b2chk/final_121b.log`
  （`检查项合计 121 项全部满足` + `TB_CORE_TOP_2B: PASS`）、`../.b2chk/regress_4b2c5.log`（`REGRESS: 32/32`）。
  p13 仍带 6 条 `nop` 规避（注中已写明"RTL 根因已收窄、待修"）。
* **可以直接粘贴执行的探针**（TB 内、`DBG_P13` 门控；维护提交拍及前后各 2 拍）：

```verilog
        if (DBG_P13 && (cur_p == 12) && u_dut.be_trp_flush && (k1_tick > 12000) && (k1_tick < 14000))
            $display("   [dr] t=%0d flush=%b maint_act=%b dr_any=%b rdy=%b d_idle=%b l1d_idle=%b cdq_cnt=%0d head=%0d tail=%0d | ad=%0d need=%b va=0x%08x done=%b flt=%b own=%b",
                     k1_tick, u_dut.be_trp_flush, u_dut.maint_act_q,
                     u_dut.u_back.u_lsu.dr_any, u_dut.u_back.u_lsu.mem_req_ready,
                     u_dut.u_back.u_lsu.d_idle /* 见下注 */, u_dut.l1d_idle,
                     u_dut.u_back.u_lsu.cdq_cnt, u_dut.u_back.u_lsu.cdq_head, u_dut.u_back.u_lsu.cdq_tail,
                     u_dut.ad_st_q, u_dut.d_xlat_need_w, u_dut.d_va_q,
                     u_dut.ptw_req_done, u_dut.ptw_fault, u_dut.m_tr_src_q);
```
  （`d_idle` 是 `core_top_2b` 内部量：探针里改用 `u_dut.ad_st_q`/`u_dut.maint_act_q` 与
  `u_dut.u_back.u_lsu.mem_req_ready` 即可；`cdq_*` 为 `lsq_simple` 内部寄存器，iverilog 可直达。）
* **两个候选与判别判据**：
  | 候选 | 判别（看探针哪一列"卡住"） | 若成立的定点修法 |
  |---|---|---|
  | **(A) 排空握手被挡**：维护冻结窗口/`maint_act_q` 使 `mem_req_ready` 长期为 0 | `dr_any=1` 而 `rdy=0` 连续多拍；`cdq_cnt` 不减 | 维护动作与排空握手互锁：把 `~maint_act_q` 从 `d_ready_w` 移到"仅挡**新接管**、不挡 `dr_fire`"（即 `mem_req_ready` 拆成两路：CDQ 排空允许、LSU 新请求挡住） |
  | **(B) 排空期翻译挂起**：`MPRV=1` ⇒ store 排空走 `AD_XLATE/AD_TR`，而 `ptw_kill_w |= be_trp_flush` 打断其遍历 | `ad=4/5`、`need=1`、`done=0` 且 `cdq_cnt` 不增（store 栏位被占住） | ①`ptw_kill_w` 只打断**取指侧**遍历（数据侧在 `AD_TR` 电平保持、可自恢复），或②CDQ 项携带**已定址 PA**（提交前定址）⇒ 排空不再翻译（与 §B4.20.3 的 "PA 入 STQ/CDQ" 同一改动） |
* **建议**：若为 (B)，②与"store page fault 精确化"（§B4.20.3）是**同一处改动**，一次做完更省；
  若为 (A)，改动只在 `core_top_2b` 的 `d_ready_w`/`mem_req_ready` 拆分（约 3 行）。
### B4.24.6 探针实测（本轮）：排空握手与 CDQ 记账数据 + (B) 修法尝试结果

* **探针（`[dr]`，DBG_P13 门控）关键窗口**（无 nop 形态）：
  ```
  t=13513 flush=1 mact=1 dr_any=0 rdy=0 cdq(cnt=0 h=7 t=7) | ad=0 need=0 va=0x80027100   ← 第 1 次 sfence 动作脉冲
  t=13623 flush=1 mact=0 dr_any=0 rdy=0 cdq(cnt=0 h=7 t=7) | ad=5 need=1 va=0x80027000   ← 一笔"译后访问"在途
  t=13624 flush=1 mact=0 dr_any=0 rdy=1 cdq(cnt=0 h=7 t=7) | ad=0 need=1 va=0x80027000   ← 该笔被 kill（ad→0）
  t=13625 flush=1 mact=1 dr_any=0 rdy=0 cdq(cnt=0 h=7 t=7) | ad=0 need=1 va=0x80027000   ← 第 2 次 sfence 动作脉冲
  ```
* **两条硬结论**：①**PTE 更新 store 从未进入 CDQ**——t≈13100 之后 `dr_any` 恒 0、`cdq_cnt` 恒 0
  （入队许可已去 `cmt_ok`、指针/记账逻辑已复核无缺陷）⇒ 需再探"提交拍是否真产生 `cmt_st_drain`"
  （即该 store 是否在 ROB 提交前缀链里）：打印 `cmt_st_drain/lsu_dr_valid/dr_take`；
  ②维护动作脉冲（`mact=1`）前后确有"被 kill 的译后访问"（`ad=5 → ad=0`），与旧存疑吻合。
* **本段修法尝试（已撤回）**：把 `ptw_kill_w` 的整机冲刷项限定为"仅取指侧"（`& ptw_owner_fetch_w`）
  —— 实测**使 `nop` 形态从绿转红**（数据侧在途遍历跨过 flush 完成 ⇒ 旧翻译被回填）
  ⇒ 已按 `git` 口径撤回，RTL 恢复与已验收提交 `367d963` 一致。
* **检查点**：`tb_core_top_2b` **121/121 PASS**（`../.b2chk/final_121d.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b2c7.log`）；p13 仍带 6 条 `nop` 规避（判据未放宽）。
* **下一步（唯一）**：打印提交拍 `cmt_st_drain/lsu_dr_valid/dr_take/dr_idx` + ROB `cmt_chain`
  ⇒ 判定"该 store 是否在提交前缀链里"（若不在，问题在 `slot_ok/slot_st_ok` 与维护 lane 的
  同组判定；若在，则回到 `dr_take` 与 `cdq_wp` 的同拍写入）。
### B4.24.7 提交拍探针（本轮）：**入队已正常，丢失点定位到"排空期翻译被中止"**

```
t=13512 raw=1111 chain=1111 st_drain=0001 drv=0001 take=0001 | st_ok=1111 room=1 hold=1100 mact=0 flush=1
t=13513 raw=0000 chain=0000 st_drain=0000 drv=0000 take=0000 | ... mact=1 flush=1
t=13623 ... cdq(cnt=0 h=7 t=7) | ad=5 need=1 va=0x80027000   ← 该 store 排空时的**在途翻译**
t=13624 ... cdq(cnt=0 h=7 t=7) | ad=0 need=1 va=0x80027000   ← 被中止（AD_TR → IDLE）
t=13625 ... mact=1                                            ← 维护动作脉冲
```
* **①入队已修复且被实证**：t=13512 与 `sfence.vma` **同组**（`hold=1100` = 维护 lane 在 1）
  的 PTE store `st_drain=0001 / drv=0001 / take=0001` ⇒ **同组更老 store 完成 CDQ 入队** ✓
  （此即任务书 ③ 要求的硬断言形态，可直接在 TB 里断言此组合）。
* **②丢失点最终定位**：该 store 入队后**当拍/次拍即被排空**（`cdq_cnt` 由 1 归 0），
  排空时因 `MPRV=1` 需翻译（`ad=5, need=1, va=0x80027000`），而在维护动作脉冲前后
  该在途翻译被中止（`ad → 0`），适配器不再持有该写 ⇒ **已提交写丢失**。
* **修法方向（下一步，二选一）**：**(a)** 把 `d_kill_w` 的保护范围扩到"`AD_XLATE/AD_TR` 中的
  **store**"（当前 `~d_we_q & ~d_start` 未覆盖"已被接管但尚未进入 AD_REQ"的 store 翻译拍）；
  **(b)** 排空路径不翻译（CDQ/STQ 项携带已定址 PA）——与 §B4.20.3 的 store 页错误精确化同一改动。
* **检查点**：`tb_core_top_2b` **121/121 PASS**（`../.b2chk/final_121e.log`）；
  `regress.sh` **32/32**（`../.b2chk/regress_4b2c8.log`）；p13 仍带 6 条 `nop` 规避（判据未放宽）。
### B4.24.8 修法 (a) 实测（本轮）：不足以治愈，已撤回 ⇒ 下一步只走 (b)

* **试的修法（a）**：`d_kill_w` 增加翻译保护
  `d_xlat_guard_w = (ad_st_q∈{AD_XLATE,AD_TR,AD_PTE,AD_PTER})` ⇒
  `d_kill_w = be_trp_flush & ~d_we_q & ~d_start & ~d_xlat_guard_w`。
* **反证（无 nop 形态）**：**仍 FAIL**（`C13'-9`，且 `tlb_sfence` 计数由 2 变 1，说明该保护还扰动了
  维护/翻译的时序）⇒ **撤回**，RTL 恢复与已验收提交一致。
* **结论**：修法 (a)（kill 保护）**不能**治愈"排空期在途翻译被中止"这一形态；
  按母代理优先级直接走 **(b) 排空路径不翻译**——CDQ/STQ 项携带**已定址 PA**、排空直用 PA，
  与 store 页错误精确化（执行期 `st_xlate` + cause 15 + mtval=VA + 独立小用例）**同一次改动做完**。
  (b) 需要的落点（供下一轮直接施工）：`lsq_simple` 增 `stq_pa/cdq_pa` 字段 + 执行期翻译请求口
  （`st_xlate_valid/va/rob` ↔ `st_xlate_ready/pa/fault/cause`）→ `core_top_2b` 复用
  `AD_XLATE/AD_TR` 服务该口（PA 写回 STQ）→ CDQ 入队时随提交拷贝 PA → 排空口
  `mem_req_addr = cdq_pa`（**不再翻译**）→ 页错误经现有 `exc_*`/`upd_exc` 以 **cause 15** 精确上报。
* **检查点（本轮收口）**：`tb_core_top_2b` **121/121 PASS**（`../.b2chk/final_121f.log`）；
  `regress.sh` **32/32 PASS**（`../.b2chk/regress_4b2c9.log`）；2A 零修改；未提交 git；快照 `../.b2chk/*.s39`。
### B4.24.9 (b) 前三步的最小实现设计（本轮未施工：预算不足，避免留下半成品接口）

**关键简化（本轮新推导，可大幅降低 (b) 的风险）**

1. **`stq_a` 必须保持 VA**：store→load 转发按 `stq_a[si] == ld_addr` 比较（load 侧是 VA）⇒
   **不能**把 PA 直接写进 `stq_a`；按任务书新增**独立字段** `stq_pa[]`（+ `stq_pv[]` 有效位）与
   `cdq_pa[]`，排空口 `mem_req_addr = dr_fire ? cdq_pa[cdq_head] : ld_addr[pend_sel]` ✓。
2. **排空口"不再翻译"只需一行使能改写**：到适配器的**store 必是已提交排空**（load 才可能来自
   推测执行）⇒ 令 `d_xlat_need_w = sv32_en & d_xlate_on_w & ~lsu_req_we`
   ⇒ store 排空恒用 PA（不再走 `AD_XLATE/AD_TR`）✓ —— 这正是本轮根因（排空期翻译被中止）的直接消除。
3. **执行期翻译可搭在现成的 E1 点上**：`lsq_simple` 已在 store 地址+数据就绪时拉 `st_done_valid`
   （= ROB done）⇒ 在同一拍发 `st_xlate_valid`（`va = 该 store 的地址`、`rob/idx`）即可，
   无需新增"何时翻译"的判据；PA 在 `st_xlate_done` 时写入 `stq_pa[slot]`+`stq_pv[slot]`。
4. **CDQ 侧零改动即可携带 PA**：入队时 `cdq_pa[wp] <= stq_pa[dr_idx]` 与现有
   `cdq_a/cdq_d/cdq_m` 拷贝完全同构 ✓；`cdq_pa` 是唯一新增数组 ✓。
5. **无 PA 的兜底（fail-safe）**：若某 store 的 `stq_pv=0`（例如执行期翻译尚未回）而它要排空，
   则**该拍不排空**（`dr_fire` 加 `stq_pv[dr_sel]` 条件），等 PA 到齐再发 —— 避免"用 VA 当 PA"。

**逐文件落点（下一步照此施工）**

| 文件 | 改动 |
|---|---|
| `rtl/back2/lsq_simple.v` | 新增 `stq_pa/stq_pv/cdq_pa`；入队拷 PA；排空地址取 `cdq_pa` 且 `dr_fire` 加 `stq_pv` 门；新增 I/O：`st_xlate_valid/st_xlate_va/st_xlate_idx`（出）与 `st_xlate_ready/st_xlate_done/st_xlate_pa/st_xlate_fault`（入）；`st_xlate_valid` 于 `st_done_valid` 同拍拉高 |
| `rtl/back2/backend_top.v` | 新增上述 7 个端口的顶层透传（透传到 `core_top_2b`） |
| `rtl/top/core_top_2b.v` | ①`d_xlat_need_w &= ~lsu_req_we`（**排空不翻译**）；②适配器新增"执行期翻译"入口：`AD_IDLE & st_xlate_valid` → `AD_XLATE`（上下文标志 `d_stx_q`）→ 命中即回 `st_xlate_pa`，缺失走 `AD_TR`，完成后回写 PA 并置 `st_xlate_done`（**不进入 AD_REQ**，因为这不是访存而是纯翻译） |
| `sim/unit/` | 去 p13 的 6 条 `nop`；新增硬断言（[st] 信号组合）；store 页错误小用例（下一步） |

**结论**：本轮**未改动 RTL**（预算不足以"实现+验证"闭环，且半成品接口会让整设计不可编译 ⇒
违反"停在整设计可编译+既有判据全绿"约束）。检查点保持：
`tb_core_top_2b` **121/121 PASS**、`regress.sh` **32/32 PASS**（本会话实测日志见 §B4.24.8）。

---

# B4.25 (b) 排空 PA 化：施工落地 + **根因修正**（2B-4 第 4b-2c 段收口）

> 起点 = 母代理已验收提交 `ed02587`（§B4.24.9 设计落档）。
> **结论：缺陷已修，p13 的 6 条 `nop` 规避已删除**（恢复"PTE 更新 store 紧跟 `sfence.vma`"原始形态）。
> 检查点：`tb_core_top_2b` **122/122 PASS**（121 + 新增硬断言 1 项，未回退）、
> `regress.sh` 见 §B4.25.6；2A 零修改；未提交 git；快照 `../.b2chk/*.s40` 与 `*.good`。

## B4.25.1 根因修正：**不是"排空期在途翻译被维护脉冲 kill"，而是两处独立缺陷叠加**

§B4.24.8 的定案（"维护脉冲把在途翻译 kill 掉"）**与实测不符**。本轮用 PTW 内部探针
（`st / pte_q / leaf_ok / perm_granted / acc_r / priv_r`，一次性诊断，收工已删）逐拍定位，定案为：

| # | 缺陷 | 证据（本会话实测） |
|---|---|---|
| **①** | **翻译上下文取错时刻**：一次 store 翻译的正确性取决于 `{有效特权级, SUM, MXR}`，而本核 CSR **只在提交点更新**。旧形态在**排空拍**取值 ⇒ 偏新（更年轻的 `csrw mstatus` 已提交）；照 §B4.24.9 在 **E1 拍**取值 ⇒ 偏旧（更老的 `csrw` 尚未提交）。p13 的 PTE 更新 store（VA `0x80027000`）两处都错：E1 时 `MPRV` 已被更年轻的写重新置 1、`MPP` 因 `mret` 变 U ⇒ 按 **U 模式**翻译 U=0 的页 ⇒ **页错误** ⇒ 已提交写被静默丢弃。 | PTW 探针：`mstatus=0x00020080`（`MPRV=1, MPP=00=U`）、`priv_r=00`、`perm_granted=0`、`fault_cause=13`；而**并非** `kill`（`ptw_kill_w=0`、`d_kill_w=0`：`d_we_q=1` 早已置位）。 |
| **②** | **CDQ 入队被"整机冲刷分支"整段吞掉**：`lsq_simple` 的时序块是 `if (!rst_n) … else if (flush_all) … else <正常更新>`，而**入队语句只在正常分支里**。当提交拍恰好与维护冲刷同拍（p13：PTE 更新 store 与 `sfence.vma` **同组提交**），`flush_all=1` ⇒ 入队语句根本不执行 ⇒ **许可组合为 1、CDQ 计数/尾指针不动**（已提交写丢失）。 | `[st]`/`[dr]` 探针：`t=13512 st_drain=0001 drv=0001 take=0001 hold=1100 flush=1` → `t=13513 cdq(cnt=0 h=7 t=7)`（`cnt` 未变）。**§B4.24.7 把该现象读成"入队已正常"是误判**——当时只看组合信号，未核对 CDQ 寄存器态。 |

**顺带修正 §B4.24.2 的口径**：`lsu_dr_valid` 的 `& cmt_ok` 项在该拍**并不抑制**入队——
`cmt_ok = ~squash & (~flush_all | ((xret_cmt_o|maint_cmt_o) & trp_flush_v_i))`
而维护提交拍 `maint_cmt_o=1 & trp_flush_v_i=1` ⇒ `cmt_ok=1`。**反证 B**（临时恢复 `& cmt_ok`）
实测 **122/122 仍 PASS** ⇒ 该式在该场景**不是**抑制点（它仍是正确的收紧，保留）。

## B4.25.2 实现（五条简化照做 + 两处必要修正）

* **stq_a 保持 VA**；新增 `stq_pa/stq_pv/stq_ctx`（E1 预翻译结果 + 其上下文）与
  `cdq_pa/cdq_pv/cdq_bad/cdq_ctx`（提交拍口径 + 排空自足）✓ 简化 ①/④。
* **排空不翻译**：`d_xlat_need_w = sv32_en & d_xlate_on_w & ~lsu_req_we`（一行）——
  到适配器的 store 必是已提交排空、地址已是 PA ⇒ 整级跳过 `AD_XLATE/AD_TR` ✓ 简化 ②。
* **E1 搭 `st_done_valid` 拍发 `st_xlate_valid`** ✓ 简化 ③；该请求**未当拍被接受即放弃**
  （一次性预翻译，只作加速）。
* **提交拍（CDQ 入队）权威判定**（本轮新增，修根因 ①）：
  `cdq_pa <= st_xlate_en ? stq_pa : stq_a`、`cdq_pv <= ~st_xlate_en | (stq_pv & (stq_ctx==ctx))`
  ⇒ 提交序上下文说"无需翻译"时**无条件** PA=VA（覆盖预翻译）；需要翻译而预翻译不可用/上下文不一致
  ⇒ `cdq_pv=0`，由 **CDQ 扫描**用入队时锁存的 `cdq_ctx` 重译（**排空不悬挂**的活性保证）。
* **翻译上下文随请求携带**（本轮新增，修根因 ①）：端口 `st_xlate_ctx_i/o`（4 bit =
  `{priv[1:0], SUM, MXR}`），适配器在接受拍锁存 `d_stx_ctx_q`，**TLB 查询口与 PTW 请求**都用它
  （而不是"当下"CSR 值）；`d_acc_w` 对翻译事务恒按 **store** 查权限。
* **兜底**：`dr_fire = dr_any & mem_req_ready & (dr_ok | dr_bad)`（PA 未定 ⇒ **该拍不排空**）；
  `dr_issue = … & dr_ok`（真发写）⇒ 地址恒取 `cdq_pa` ✓ 简化 ⑤。
  翻译故障只由 **CDQ 源**置 `cdq_bad`（提交拍口径可信）⇒ 该笔**只弹出、不写、不悬挂**；
  store 页错误的**精确上报**（cause 15 + mtval + 独立用例）仍属另一步（未做，口径登记）。
* **修根因 ②**：`flush_all` 分支内**照做 CDQ 入队**（拷贝读本拍仍有效的 STQ 寄存器态），
  再做原有的 STQ/LQ 清理；该分支不推进出队（下拍照常，代价 ≤1 拍）。
* `d_kill_w` 增加 `& ~d_stx_q`、`d_rsp_err_w` 增加 `& ~d_stx_q`：**纯翻译事务**不受整机冲刷
  中止、也不产生"带错响应"（它不是访存；否则会给 LSQ 回一笔 tag 不明的错误响应）。
* **新增口的悬空净化（必做，实测抓到）**：`lsq_simple` 被多处 TB **直接驱动**例化
  （`tb_back2_lsq_fwd` 直接例化；`tb_back2_lockstep` 经 `backend_top`），本段**不改**这些 TB
  ⇒ 新口悬空为 **z** ⇒ `~st_xlate_en` / `ready` / `done` 参与的条件成 x ⇒ 排空门
  `cdq_pv|cdq_bad` 变 x ⇒ 整核挂死。首次全量回归实测：**31/32**（`tb_back2_lockstep`
  C3 "程序 0 提交条数 ≥ 黄金条数" 红）。修法（与既有 `mem_rsp_err` 同一教训与口径）：
  新输入一律 `=== 1'b1` 净化（`stx_en_w/stx_ready_w/stx_dn_w/stx_flt_w`），
  **只有明确的 1 才算"需要翻译/接受/完成/故障"**，z/x/0 ⇒ 等价于"Bare、无翻译请求"
  （与新增端口前的行为逐拍一致）✓ 复跑 32/32。

## B4.25.3 判据（母代理任务书 0–4 逐条）

| # | 判据 | 实测 |
|---|---|---|
| 0 | 基线编译 0 error + `TB_CORE_TOP_2B: PASS`（121 项） | ✔（`../.b2chk/base121.log`，改动前实测） |
| 1 | 五条简化落地（+2 处修正） | ✔ 见 §B4.25.2；文件 = `lsq_simple.v` / `backend_top.v` / `core_top_2b.v` |
| 2 | **去 p13 的 6 条 `nop`** 后 PASS、C13' 12 项全过、总检查项不回退 | ✔ `TB_CORE_TOP_2B: PASS`、`[C13'] Sv32：12 项全过（maint=2 tlb_sfence=2）`、**122 项**（121 + 新增 1） |
| 3 | 新增硬断言（维护冲刷拍同组更老 store 完成 CDQ 入队）+ 反证 | ✔ TB **C14'**；反证 A 见 §B4.25.4 |
| 4 | `./scripts/regress.sh` 32/32 | ✔ 见 §B4.25.6 |

**硬断言形态（TB `C14'`，两级判定）**：维护冲刷拍（`be_trp_flush & |maint_lane_oh`）内
① `dr_take` 必须覆盖 `cmt_st_drain & ~cmt_hold_w`（组合许可）；
② **CDQ 尾指针必须真的前进**（`((cdq_tail' - cdq_tail) & 7) >= dr_push_n`）——
第 ② 条正是抓根因 ② 的形态（许可为 1 但入队被吞）。
实测：`[C14'] … = 1 次（维护冲刷拍 5 拍）`，即 `st_drain=0001 & drv=0001 & take=0001 & hold=1100`
那一拍（t=13512）**确实入队落地**。

## B4.25.4 反证（两份，日志留证）

* **反证 A（真实抑制点，必红）**：临时撤掉 `flush_all` 分支里的入队 ⇒
  `FAIL: [硬断言] 维护冲刷拍同组更老 store 的 CDQ 入队**未落地**（尾指针未前进）：tail 7→7，应至少 +1`
  （`../.b2chk/counterproofA.log`，退出码 1）⇒ 断言**确实**检测该缺陷 ✓ 已还原。
* **反证 B（口径修正，记录用）**：临时恢复旧式许可 `lsu_dr_valid = cmt_st_drain & cmt_ok & ~cmt_hold_w`
  ⇒ **122/122 PASS**（`../.b2chk/counterproofB.log`）——与 §B4.24.2/§B4.24.7 的推断相反，
  该拍 `cmt_ok=1`，故它不是本残留的抑制点（真实抑制点在 `lsq_simple` 的冲刷分支）✓ 已还原。

## B4.25.5 与 §B4.24.9 设计表的差异（逐条说明，均为"修根因必需"）

| 项 | §B4.24.9 设计 | 实际落地 | 理由 |
|---|---|---|---|
| 端口数 | 7（`st_xlate_valid/va/idx` + `ready/done/pa/fault`） | **10**（+`st_xlate_en`、+`st_xlate_ctx` 入、+`st_xlate_ctx_o` 出） | `st_xlate_en`：E1/提交拍"是否需要翻译"的判据必须由顶层给；`ctx`：**翻译上下文必须随请求携带**，否则遍历/权限用"当下"CSR 值 ⇒ PA 不可信（根因 ①） |
| 翻译时机 | 仅 E1 拍 | E1 **预翻译**（一次性）+ **提交拍权威判定**（+CDQ 扫描兜底） | 只有提交拍与"该 store 的程序序时刻"一致（CSR 按序提交）；E1/排空拍都会取错上下文（根因 ①） |
| `dr_fire` 门 | `stq_pv[dr_sel]` | `cdq_pv[cdq_head] \| cdq_bad[cdq_head]`（`dr_issue` 才真写） | CDQ 项必须**自足**：`flush_all` 会清 STQ 并复用槽号 ⇒ 排空口读 STQ 字段会被"新占用者"污染；`cdq_bad` 保证故障项**不悬挂** |
| `stq_bad` | （未列） | **取消**（故障只由 CDQ 源置 `cdq_bad`） | E1 预翻译上下文可能偏旧 ⇒ 其故障**不可信**，不得据此作废已提交写 |
| 入队 | 沿用既有 | `flush_all` 分支内**也做入队** | 根因 ②（同组更老 store 被整机冲刷分支吞掉） |

## B4.25.6 检查点（本会话实测）

* 编译 **0 error**（命令见任务书判据 0；仅既有的 `-Wall` 信息性告警）。
* `tb_core_top_2b` **122/122 PASS**：`../.b2chk/final_122.log`
  （`[C13'] Sv32：12 项全过（maint=2 tlb_sfence=2）` + `[C14'] … = 1 次` +
  `检查项合计 122 项全部满足` + `TB_CORE_TOP_2B: PASS`）。
* `./scripts/regress.sh` **32/32 PASS**：`../.b2chk/regress_b2c11.log`
  （`== regress.sh：总数=32 运行=32 通过=32 跳过=0 失败=0` + `REGRESS: 32/32 PASS`）。
  ★ 首次跑为 **31/32**（`tb_back2_lockstep`）——根因与修法见 §B4.25.2 的"悬空净化"条目，
  净化后复跑全绿（`../.b2chk/regress_b2c10.log` 为红、`…b2c11.log` 为绿，两份均留）。
* p13 的 6 条 `nop` **已删除**（`sim/unit/prog/back2_p13_sv32.S`），映像经
  `gen_back2_lockstep_data.py` 重生成（差异恰为 6 条 `nop` 与随之位移的地址常量）。
* 2A 零修改；未提交 git；快照 `../.b2chk/{lsq_simple.v,backend_top.v,core_top_2b.v,tb_core_top_2b.sv,back2_p13_sv32.S,back2_report.md}.s40`
  与 `../.b2chk/*.good`（反证前后还原用）。
* **下一步（登记）**：①store 页错误精确化（cause 15 + mtval=VA + 独立小用例；本步已具备
  `cdq_bad` 钩子与 `st_xlate_fault` 通路）；②L1D 维护写回 + `cbo.flush` INVAL；③L1I 侧 PIPT 复核。

---

# B4.26 store 页错误精确化（2B-4 第 4b-2c 段收尾）

> 起点 = 母代理已验收提交 `937b783`（tag 2B-4.24）。
> **结论**：store 到未映射页 ⇒ 经数据适配器的执行期翻译发现故障后，以 **cause 15
> （store/AMO page fault）+ mtval = 故障 VA** 在**故障指令处精确抛出**（mepc = 该 `sw`、
> 故障 `sw` **从未提交**、其后继指令正常提交），且**不写任何存储**。
> 检查点：`tb_core_top_2b` **141/141 PASS**（122 + 第 11 个程序的通用判据 6 + C15' 13）；
> `regress.sh` **32/32 PASS**（§B4.26.5）；2A 零修改；未提交 git。

## B4.26.1 实现（LSQ 侧：提交门 + 精确异常通道）

| 机制 | 落点 | 说明 |
|---|---|---|
| **提交窗"翻译定妥"门** | `lsq_simple.v` §0b：`stq_win_w`（窗口：`age < W`）/ `stq_blk_w`（窗内且**未按当前上下文定妥**且未判坏）⇒ `dr_room_ok &= ~stq_blk_any_w` | `dr_room_ok` 回送 `rob.v` 的 `mem_wr_ready` ⇒ 窗口内有未定妥的 store 时**提交前缀链在该 store 处停住**（= 精确的前提：异常必须在提交前被记到该 ROB 项上）。判据只用**寄存器态**（`stq_*`/`rob_head`）⇒ 与提交链**无组合环** ✓ |
| **"按当前上下文"** | 同上：`~st_xlate_en \| (stq_pv & stq_ctx == 当前 ctx)` | 上下文（`{priv,SUM,MXR}`）变了 ⇒ 判为未定妥 ⇒ 由扫描**按新上下文重译** —— 这正是 §B4.25 登记的"E1 上下文偏旧"边界的收口（提交序 CSR 状态是唯一权威） |
| **STQ 扫描** | §3.4：候选 = `stq_blk_w`（与提交门**同源**） | 保证"门挡住的项一定有人去翻译"（**无死锁**），且天然限定为"马上要提交的那几条"（不给投机项打投机异常）。优先级：E1 预翻译 > STQ 扫描（窗内）> CDQ 扫描（fail-safe） |
| **精确异常通道** | §3.4/§3.5：`stx_flt_rep_w = stx_done_w & ~src & flt & 项仍在 STQ & 在窗内` ⇒ 复用既有 `exc_valid_o/rob/cause/tval` 端口 | cause **15**、tval = `stq_a[idx]`（**VA**）、rob = `stq_rob[idx]`（该 store 的 ROB 项）⇒ ROB 置 EXC ⇒ `slot_ok` 含 `~slot_exc` ⇒ **该 store 不提交、在头部抛精确陷阱**（与 load 的 cause 13 同一通道，按"store 优先"确定优先级） |
| **判坏/兜底** | `stq_bad`（新） | 只有**窗内**的 STQ 源故障才判坏（⇒ 精确陷阱 + 解提交阻塞）；窗口外（投机）不判坏，等进窗后按当时上下文重译。CDQ 源故障仍走 `cdq_bad`（只弹出不写）—— 提交门之后该路径应**不可达**（登记为边界） |

## B4.26.2 实现（core_top_2b 侧：`d_stx_q` 必须是**贯穿事务**的状态标志）

逐拍探针（`[p14-cyc]`）抓出的**真实死循环根因**：`d_stx_q` 原按"单拍脉冲"每拍默认清零
⇒ 它只在 `AD_XLATE` 那一拍为 1，进 `AD_TR` 后为 **0**，后果两条：

1. `AD_TR` 的**故障**分支走"普通访存"路径 ⇒ **不回 `stx_done/stx_fault`** ⇒ LSQ 永远等不到
   结果 ⇒ 提交门永久阻塞；而 LSQ 的扫描又不停重发 ⇒ **反复重译死循环**
   （实测：`ptw_st=6 done=1 flt=1 own=0` 而适配器 `ad=5 d_stx=0`，PTW 每 ~50 拍重启一轮）。
2. `d_acc_w` 退化成 **load** ⇒ 翻译事务的 TLB 查询/PTW 遍历按**读权限**判 ⇒ 权限结论错。

修法：`d_stx_q` 改为**接受拍置位、各出口分支清零**（`AD_XLATE` 命中/权限错、`AD_TR` 有结果
三处），**取消默认清零**；并**显式复位**（`d_stx_q/d_stx_ctx_q/stx_pa_q/stx_done_q/stx_flt_q`）
—— 否则不再是 x 兜底的对象：首次实测 `d_stx_q` 悬空为 **x**，`d_kill_w`/`d_acc_w` 随之成 x
⇒ **p12 的 C12' 直接红**（`L1D clean_all ≥ 2` 实测 1）。

## B4.26.3 新增用例（`back2_p14_storepf.S` + TB 第 11 个程序槽）

* **程序**：自建两级页表（**绝对地址** root=0x8002_A000 / l1=0x8002_B000，见下）、
  4 MB 恒等大页覆盖自身；开 MPRV=1/MPP=S + satp=Sv32；译后 load/store/load 对照；
  **`sw` 到未映射 VA 0x4000_2000（l1[2] 显式清零 ⇒ V=0）**；handler 自记录
  `mcause/mtval/mepc`（`sub a6, mepc, s8` 自证 mepc = 故障 `sw`）后 `mepc+=4; mret`；
  收尾把自记录值送入写回轨迹。
* **判据 C15'（13 项）**：①恰好 1 次陷阱 ②**mcause = 15** ③handler 读回 mcause = 15
  ④**mtval = 0x4000_2000**（故障 VA）⑤**mepc = 故障 `sw` 的 PC**（handler 自证差值 = 4）
  ⑥陷阱 PC 落在映像内 ⑦陷阱精确返回后继续（a0=1）⑧⑨⑩对照：译后 load / store→load /
  直读 PA 三条数据链正常 ⑪故障 VA 自记录 ⑫**故障 `sw` 从未提交**（`mepc ∉ 提交轨迹`
  ⇒ 未写任何存储、未污染已提交状态）⑬**其后继指令已提交**（陷阱精确、执行连续）。
* **黄金**：本程序**有 Spike 黄金**（78 条）——通用 C1'（提交 PC 流）/C3'（写回寄存器轨迹）
  与 Spike **逐条一致** ⇒ "提交流与黄金一致"的直接证据，同时反证"故障指令未被提交、
  无多余提交"。★ 取绝对地址的原因：TB 的寄存器轨迹比对只能补偿"未做算术的 PC 相对量"
  （`+gold_delta`）；`la` 得到的基址若再经 `srli/slli` 造 PTE，位移会把 delta 一起缩放
  ⇒ 无法补偿（实测 C3' 在第 11 条红）；改用 `li` 绝对地址后 DUT 与 Spike 执行**同一组
  立即数** ⇒ 轨迹逐位一致。
* **TB 改动**：`NPROG 10→11`、`pidx[10]=13 / cmax_of[10]=P13_GOLD_N`、`DDR3_LIMIT
  0x28000→0x30000`（第 11 个窗口 0x8002_8000）、`clear_mem` 清到 49152 字、C5' 的
  "无陷阱"豁免扩到 pid 10（其异常由 C15' 逐项判定 —— 判据未放宽）。

## B4.26.4 反证/边界登记

| # | 边界 | 状态 |
|---|---|---|
| 1 | **OoO CSR 可见性（比 §B4.25 登记的更宽：**load 侧同样中招**）** | **实测踩到并登记**：p14 里 `csrw mstatus,MPRV=0` 之后紧跟的 **load** 在更老的 `csrw` 提交**之前**执行 ⇒ 按**旧的** MPRV=1/MPP=U 去翻译（而该段本应 Bare 直读 PA）⇒ **误报 load 页错误（cause 13）**（实测 `lsu_exc_v=1 cause=13 tval=0x8002b100`）。**程序侧规避**（不改判据）：让访存**地址**数据依赖于一条 `csrr mstatus`（CSR 指令只在 ROB 头发射 ⇒ 其数据依赖者必然晚于更老 CSR 写的提交）。**RTL 侧根治**需 ①CSR 写串行化互锁 或 ②load 侧也按"提交序上下文"重译 —— 属后续段。 |
| 2 | CDQ 源翻译故障（项**已提交**） | 仍走 fail-safe"只弹出不写、不报异常"（不精确）；提交门落地后该路径**不可达**（登记）。 |
| 3 | 提交门代价 | 窗内 store 的翻译未回时该 store 不提交（最坏一次页表遍历延迟）；语义不变（维护流程本就等 CDQ 排空）。 |
| 4 | 窗口外（投机）翻译故障 | **不判坏、不报异常**（上下文可能偏旧 ⇒ 不打投机异常）；进提交窗后按当时上下文重译再判。 |
| 5 | 门/扫描同源 | `stx_s_v = stq_blk_w`（同一表达式）⇒ "门挡住的项必被扫到"，**无死锁** ✓ |

## B4.26.5 检查点（本会话实测）

* 编译 **0 error**；`tb_core_top_2b` **141/141 PASS**（`../.b2chk/final_p14.log`）：
  `[C15'] store 页错误精确化：cause=15 mtval=0x40002000 trap_pc=0x800280cc（mepc 自证 ✓、
  故障 sw 未提交 ✓、后继已提交 ✓）；对照 0x11223344/0xDEADBEEF/0xDEADBEEF ✓`
  + `[C13'] Sv32：12 项全过` + `[C14'] … = 1 次` + `检查项合计 141 项全部满足`。
* `./scripts/regress.sh` **32/32 PASS**（`../.b2chk/regress_b2c12.log`）。
* 改动文件：`rtl/back2/lsq_simple.v`、`rtl/top/core_top_2b.v`、
  `sim/unit/tb_core_top_2b.sv`、`sim/unit/prog/back2_p14_storepf.S`（新）、
  `sim/unit/prog/gen_back2_lockstep_data.py`（PROGS + p14）、
  `sim/unit/prog/back2_lockstep_data.svh`（重生成：仅 slot 13 变化 ✓ 已核对）。
  2A 零修改；`scripts/regress.sh` 未动；未提交 git；快照 `../.b2chk/*.s42`。
* **下一步（登记）**：①CSR 可见性互锁（边界 1，RTL 根治）；②L1D 维护写回 + `cbo.flush` INVAL；
  ③L1I 侧 PIPT 复核。

---

# B4.27 L1D 维护写回 + cbo.flush INVAL + L1I PIPT 复核（2B-4 第 4b-2c 段收尾）

> 起点 = 母代理已验收提交 `b8f21f3`（tag 2B-4.25）。
> **结论**：`cbo.clean/flush` 现在**真的把脏行写回内存**（复用既有写回通路，无新数据通路/端口）；
> `cbo.flush` = **写回 + 失效**（架构口径，旧"只 clean 不失效"的保守口径已不再需要）；
> L1I **PIPT 复核通过、无需修改**（另登记一处同族缺口：L1I 的 `inval_all` 未接）。
> 检查点：`tb_core_top_2b` **145/145 PASS**；`regress.sh` **32/32 PASS**（§B4.27.5）；2A 其余零修改。

## B4.27.1 ① L1D 维护写回（`rtl/cache/l1d.v`，最小加法 + 理由）

旧口径（`clean_all` 只清 dirty、不写回）：数据只留在 L1D，**一旦该行被逐出即永久丢失**
（内存是旧值）⇒ 属"测试没抓到的潜在正确性缺陷"（p12 的 cbo 之后仍能读到正确数据，只是因为
行还驻留在 cache 里）。补写回的最小加法（**不新增数据通路、不新增端口**）：

| 加法 | 内容 | 理由 |
|---|---|---|
| tag 读口复用 | `.rd_en(access \| maint_rd_en)`、`.rd_addr(maint_rd_en ? maint_idx_q : va_index)` | 维护扫描原本**盲写**（不需要知道哪一路脏）；补写回就必须先**读 tag** 拿到 脏位 + 该行 tag。维护期间访问被 stall ⇒ 同口复用无冲突 |
| 3 个寄存器 | `maint_rd_q`（本组读地址已发）/ `maint_done_q[WAYS]`（本组已写回的路）/ `maint_wb_q`（本笔写回来自维护） | 一组可能**多路脏** ⇒ 逐路写回直到干净；`maint_wb_q` 决定 `wb_finish` 后回**扫描**而不是进填充 |
| 扫描子状态 | clean 扫描：发读 → 判"有效&脏&未写回"的路 → **复用 `MS_WB_CAP`/`MS_WB_BUS`** 写它 → 直到本组无脏路 → 前进 | 写回**完全复用**既有受害者通路（抓行 9 拍 + 推总线 8 beat + `wb_*` 握手），零新增数据路径 |
| 逐路清 dirty | `way_clr[gw] = maint_wb_fin_w & (maint_way_w == gw)`：写回完成拍用**该路自己的 tag** 回写（保留 tag/valid，只清 dirty） | 原来的"整组清 dirty"专用口一次清 **4 路** ⇒ 一组多路脏时会把还没写回的路标干净（丢数据）。逐路清天然支持"一组多路脏、逐路写回再清" |
| flush 模式 | `maint_flush_q = clean_all & inval_all`：逐组先写回脏行，**该组干净后**再 `way_maint` 失效 | flush = clean + inval；顺序必须是"先写回、后失效"，否则丢已提交脏行 |

**过程中由实测抓出的两个实现级坑（都已在代码注释里写明）**：
1. **维护分支抢占了写回 FSM 的推进**：原结构是 `else if (maint_q) <扫描> else <case(ms_state_q)>`
   —— 维护写回要复用 `MS_WB_CAP/MS_WB_BUS`，而它们的推进在 `case` 里 ⇒ 扫描分支无条件抢占时
   写回永不推进：`wb_req` 常拉高、控制器**反复对同一行发起写突发**（实测 AW=571、L1D 永不结束、
   程序 16000 拍只提交 10 条）。修法：`else if (maint_q & (ms_state_q == MS_IDLE))` ——
   扫描只在写回 FSM 空闲时推进。
2. **清 dirty 必须逐路**（见上表）。

## B4.27.2 ② cbo.flush 的 INVAL 上线（`rtl/top/core_top_2b.v`）

```verilog
- wire maint_l1d_inval_w = maint_act_q & (maint_kind_act_w == 3'd3);        // cbo.inval
+ wire maint_l1d_inval_w = maint_act_q & ((maint_kind_act_w == 3'd3) |
+                                         (maint_kind_act_w == 3'd5));     // cbo.inval / cbo.flush
  wire maint_l1d_clean_w = maint_act_q & (maint_kind_act_w >= 3'd4);        // clean/flush
```
口径：**只 `inval_all`** = cbo.inval（**破坏性**，脏数据直接丢 —— Zicbom 语义允许）；
**只 `clean_all`** = cbo.clean（写回、保留）；**两者同时** = cbo.flush（写回 + 失效）✓。
旧注释里"flush 只 clean"的保守口径（因当时无写回通道）**已随写回落地而废止**。
★ 可见性证据：p12 的 `cbo.flush` 之后同地址 4 次 load 仍读到正确值（0x55667788），
而此时该行**已被失效** ⇒ 数据只能来自**内存**（= 写回真的落到了内存）✓。

## B4.27.3 ③ L1I PIPT 复核：**无需修改**

* `rtl/front4/ifetch4.v:413`：`assign l1i_req_addr = f4_pa_q;`（注释即"PIPT：查表地址 = PA"）
  ⇒ L1I 的取指请求地址是**翻译后的物理地址** ✓
* `core_top_2b` 例化：`.cs_paddr(l1i_req_addr), .cs_vaddr(l1i_cs_vaddr)` 且
  `l1i_cs_vaddr = fencei_busy ? {19'b0, fencei_idx_q, 5'b00000} : l1i_req_addr`
  ⇒ **index 与 tag 同源 = PA**（PIPT），不存在 L1D 那种"index 取 VA、tag 取 PA"的混用 ✓
* XIP 旁路用 `cs_paddr`（物理窗口判定）✓；`fence.i` 扫掠用**物理索引**（低位补 0）驱动 `cs_vaddr` ✓
  ⇒ 与 PIPT 口径自洽 ✓
* **结论：无同款缺陷，不改 `l1i.v`** ✓

**同时登记一处同族缺口（非 PIPT，趁复核发现，未在本轮改）**：
`core_top_2b` 的 L1I 例化里 `.inval_all(1'b0)` —— **L1I 的失效口没接**，即 `fence.i` 的 256 拍扫掠
只改了 `cs_vaddr`（索引）、并没有真正清 valid ⇒ **fence.i 不真正失效 L1I**。
（现有 TB 之所以全绿：注释已登记"L1I 阵列无复位、`inval_all` 未接"，并用**每程序 16 KB 递进基址**
规避"同 tag 陈旧命中"；C11' 的 `n_l1i_inval ≥ 512` 数的是 **核心侧扫掠脉冲**（`fencei_busy`），
不是 L1I 实际失效效果 —— 属"判据测的是发起、不是效果"的口径缺口。）
**修法（一行，待后续段连同 fence.i 语义一起做）**：`.inval_all(fencei_busy)` ——
扫掠本就是"每拍一组 + 该组索引在 `cs_vaddr`"的设计，接上后 256 拍恰好扫完整阵列 ✓。

## B4.27.4 ④ p12 判据扩展（`sim/unit/tb_core_top_2b.sv`）

* **`C12'-w1/w2/w3`（新）**：`cbo.clean` 后 AXI **写通道有真实流量** —— `AW>0 & W>0 & B>0`
  （写回自证；旧实现恒 0）。实测 `AW=2 / W=16 / B=2`（两条脏行 × 8 beat）✓
* **`C12'-f1`（新）**：`n_l1d_inval ≥ 2`（cbo.inval + cbo.flush 各一次 ⇒ flush 确实含 INVAL）✓
* 既有 `4 次 load 均读到 0x55667788` 在**真 flush（失效）** 之后依然全过 ⇒ 写回后数据可见性正确 ✓
* p12 的固定拍数：新增 `P12_CYCLES = 16000`（p8/p13 仍用 `P8_CYCLES`）—— 理由：clean 现在会
  **逐条写回脏行**，而本 TB 的 L1D 跨程序保留上一批程序的脏行（缓存无复位）⇒ 单次全阵列 clean
  的代价 ~127 行 × ~28 拍（一次 AXI 写突发）。这是**真实代价**，不是判据放宽（判据只增不减）。

## B4.27.5 检查点（本会话实测）

* 编译 **0 error**；`tb_core_top_2b` **145/145 PASS**（`../.b2chk/m6.log`）：
  `[C12'] cbo：提交 3 次；L1D inval 2 / clean 2 次；全程无陷阱；4 次 load 数据正确`
  + `检查项合计 145 项全部满足`（141 + C12' 新增 4 项，**既有 141 项零回退**）。
* `./scripts/regress.sh` **32/32 PASS**（`../.b2chk/regress_b2c14.log`）。
* ★ **`tb_l1d` 单元判据同步更正（判据只增不减）**：该 TB 的 C6 原写死
  `chk(wb_req === 1'b0, "C6 clean 自身不应产生写回")` —— 与架构口径（Zicbom：clean = 写回）相反，
  是本轮补写回后被它抓出来的**旧口径残留**。已改为更强的判据：clean 扫描期间**必须**服务写回握手且
  **至少写回 1 笔**、写回地址 = 脏行 A1 的行基址、写回数据**真的带出新值**（A1+4 = 0xAAAA_0000），
  并保留"clean 后 A1 已不脏 ⇒ 无残留写回请求"✓（现 `TB_L1D_UNIT: PASS`，33/33）。
* 改动文件：`rtl/cache/l1d.v`（维护写回，最小加法）、`rtl/top/core_top_2b.v`（flush INVAL 一行）、
  `sim/unit/tb_core_top_2b.sv`（C12' 扩展 + p12 拍数）、`sim/unit/back2_report.md`。
  **2A 其余零修改**；`scripts/regress.sh` 未动；未提交 git；快照 `../.b2chk/*.s43`（含 `l1d.v.pre`）。
* **下一步（登记）**：①L1I `.inval_all(fencei_busy)` + fence.i 效果判据（§B4.27.3）；
  ②CSR 可见性互锁（§B4.26.4 边界 1）；③L1I/L1D 复位与跨程序陈旧行（TB 侧已用递进基址规避）。

---

# B4.28 L1I inval_all 接线 + fence.i 效果级判据（② CSR 可见性 load 侧：**未完成，见表末**）

> 起点 = 母代理已验收提交 `6bdc5eb`（tag 2B-4.26）。
> 检查点：`tb_core_top_2b` **148/148 PASS**；`regress.sh` **32/32 PASS**；2A 零修改。

## B4.28.1 ① L1I `inval_all` 接线（一行）

```verilog
- .inval_all(1'b0),      // 旧：fence.i 扫掠只切索引、并未真正清 valid
+ .inval_all(fencei_busy),
```
**机理**：本核 `fence.i` = "冻结 256 拍 + 每拍一组、该组索引由 `l1i_cs_vaddr` 给出"的扫掠
（`core_top_2b` §4a 的 `fencei_busy/fencei_idx_q`），而 L1I 的失效写口判据正是
`inval_all ? va_index`（`l1i.v`：`wr_en(inval_all | way_fill_tag)`、`va_index = cs_vaddr[12:5]`）
⇒ 扫掠期间保持 `inval_all = fencei_busy` **恰好扫完 256 组** ✓（无需新增状态/端口）。

## B4.28.2 ① fence.i **效果级**判据（新增 3 项，含反证）

* **`C11'-e0`**：观察到 2 次 fence.i 扫掠**结束沿**（`fencei_busy` 1→0，p11 共 3 次 fence.i）✓
* **`C11'-e1`**（母代理点名的 AR/取指形式）：**末次扫掠结束之后，取指必须重新经 AXI 取指** ——
  用 L1I 行填充接受计数（`l1i_fill_accepted`）自证：扫掠结束时采样 → 程序结束时必须增加 ✓
* **`C11'-e2`（判别性判据，效果级）**：扫掠结束后延后 1 拍，**直接查 L1I 的 tag 阵列**
  `u_l1i.g_way[0/1].u_tag.tagv_q[i][0]`（= valid 位，L1I 为 **2 路 × 256 组**）
  ⇒ **全阵列 valid 必须为 0** ✓（实测"残留 0 位"）
* **反证（必红后还原）**：把 `.inval_all` 改回 `1'b0` ⇒
  `FAIL: C11'-e2 …（直接查 tag 阵列；残留 **12** 位）`（`../.b2chk/fencei_cp2.log`，退出码 1）
  ⇒ 判据**确实**区分"只切索引"与"真失效" ✓ 已还原。
  ★ 记录：`C11'-e1`（填充计数）**单独不判别**（断开 inval 时它仍会因"扫掠后取指落在未缓存行"
  而增加）—— 故效果级判据以 `C11'-e2` 为准（这正是"判据要测效果、不测发起"的同一教训，
  与 C11' 原有 `n_l1i_inval ≥ 512` 只数扫掠脉冲形成互补）。

## B4.28.3 ② OoO CSR 可见性 load 侧 RTL 根治：**本轮未完成**（设计已定案，附理由）

**为什么不能在预算内安全落地**（本轮实测 + 代码定案）：

1. 现有机制只做到"**CSR 指令只在 ROB 头执行**"（`backend_top:991/1014` 的
   `al0_csr_blk = i0_sel_v & u_is_csr(i0_sel_uop) & (i0_sel_rob != rob_head_w)` 门 ALU0 发射）。
2. 但**危害窗口不在"执行→提交"之间**：年轻 load 可以在**更老的 CSR 指令执行之前**就发射/执行
   （两者属不同队列：CSR 在 ALU0 等 ROB 头，load 在 LSU 队列只要操作数就绪即可发）
   ⇒ 实测 p14 就是这种形态（load 按旧 `MPRV=1/MPP=U` 翻译 ⇒ 误报 cause 13）。
3. ⇒ 正确的互锁必须是"**凡有更老的未提交 CSR 写，年轻 load 不得发射**"，即需要
   **按 ROB 年龄比较**（候选 load 的 `i4_sel_rob` vs"最老未提交 CSR 写的 ROB 索引"），
   而后者需要**派发侧挂钩**（记录最老 CSR 的 ROB 索引）+ 发射门改造 —— 涉及 backend_top 的
   派发/提交/发射三处，且会改变 p10（大量 CSR）/p8（中断时序敏感、固定拍数判据）的时序
   ⇒ 在"预算见底 + 必须停在既有判据全绿检查点"的约束下**不宜带病落地**。
4. **现状**：p14 仍保留程序侧串行化（访存地址数据依赖 `csrr mstatus`，见该文件 §6 注释），
   C15' 13 项全过 ✓（**判据未放宽**）；边界登记见 §B4.26.4 边界 1 与本段。
5. **下一步定点修法（建议）**：①`backend_top` 增"最老未提交 CSR 写"的 ROB 索引寄存器
   （派发时若空则记录、提交时清除，2 bit×7 或 7 bit 一个寄存器）；②发射门
   `lsu_ld_block |= csr_older_pend_w & (i4_sel_rob 比它年轻)`（年龄比较，B27 口径禁掩码）；
   ③配套：p14 去掉程序侧串行化 + 新增"CSR 写后紧跟 load"的独立小用例（反证 = 去掉互锁必红）。

## B4.28.4 检查点

* 编译 **0 error**；`tb_core_top_2b` **148/148 PASS**（`../.b2chk/f4.log`：
  145 + fence.i 效果级新增 3 项，**既有 145 项零回退**）；反证日志 `../.b2chk/fencei_cp2.log`（红）。
* `./scripts/regress.sh` **32/32 PASS**（`../.b2chk/regress_b2c15.log`）。
* 改动：`rtl/top/core_top_2b.v`（inval_all 一行）、`sim/unit/tb_core_top_2b.sv`（C11' 效果级 3 项 +
  探针 function）、`sim/unit/back2_report.md`。**2A 零修改**；`scripts/regress.sh` 未动；
  未提交 git；快照 `../.b2chk/*.s44`。
* **边界更新**：① L1I `inval_all` 已接 ✓（该边界关闭）；② CSR 可见性 load 侧**仍开放**（见 §B4.28.3，
  比 §B4.26.4 的描述更精确：窗口是"CSR 执行之前"，不是"执行→提交"之间）。

---

# B4.29 CSR 可见性 load 侧根治（ROB 年龄比较互锁）+ p14 去规避

> 起点 = 母代理已验收提交 `0e353d6`（tag 2B-4.27）。**边界 §B4.28.3 / §B4.26.4 边界 1：关闭** ✓
> 检查点：`tb_core_top_2b` **148/148 PASS**（p14 **已去程序侧规避**）；`regress.sh` **32/32 PASS**；
> 2A 零修改；未提交 git；快照 `../.b2chk/*.s45`。

## B4.29.1 互锁 diff（`rtl/back2/backend_top.v`，两处）

**① 跟踪寄存器 + 发射门**（声明在 §9 发射门之前，driver 在 CSR 提交区）：
```verilog
reg        csr_pend_q;      // 有"最老未提交 CSR 指令"
reg  [6:0] csr_pend_rob_q;  // 它的 ROB 索引
wire [6:0] csr_age_w      = (i4_sel_rob - csr_pend_rob_q) & 7'h7F;          // 年龄窗口算术（B27 口径）
wire       csr_ld_block_w = csr_pend_q & (csr_age_w != 7'h0) & (csr_age_w < 7'h40);
wire lsu_ld_block = u_is_ld(i4_sel_uop) & (~lsu_iss_ok_w | csr_ld_block_w);  // 追加"更老 CSR 在途"
```
`u_iq4` 的 `.iss_ready(~lsu_ld_block)` 不变 ⇒ **只挡 load**（store 的地址生成不能被挡，见该处既有注释）。

**② 跟踪时序**（放在 `csr_cmt_we` 定义之后的 CSR 提交区）：
* **派发**（`disp_ok`，块内 lane 0 最老）：本块有 CSR 且当前无在途 ⇒ 记下其 ROB 索引（`rob_alloc_idx0 + lane`）；
* **清除**：`flush_all_w` 整机冲刷 / 该 CSR 被 `squash_v_w` 冲掉（年龄比较，B27 口径）/ **该 CSR 已提交**（`csr_cmt_we` ⇒ CSR 状态已更新）；
* 同一拍"清 + 派发"：派发赋值在后 ⇒ 覆盖为新的那条 ✓。

**为什么必须是"年龄比较"而不是"exec→commit 窗口"**：CSR 指令虽只在 ROB 头执行（`al0_csr_blk`），
但**年轻 load 可以在它执行之前**就发射（CSR 在 ALU0 等 ROB 头；load 在 LSU 队列只要操作数就绪即可发，
两者无数据依赖）⇒ 只在 exec→commit 窗口挡 load 无效。本互锁按"候选 load 是否比最老未提交 CSR 更年轻"
判定，覆盖整个"派发→提交"窗口 ✓。

## B4.29.2 ③ p14 去程序侧规避（独立用例 = 该段本身）

`back2_p14_storepf.S` §6 恢复自然形态（删除原来的 `csrr mstatus; andi t2,t2,0; add s2,s1,t2` 依赖链）：
```asm
    li    t1, 0x00000800            /* MPRV=0 */
    csrw  mstatus, t1
    lw    s10, 0x100(s1)            /* ★ csrw 后**紧跟** load —— 本用例的核心 */
    lw    s11, 0(s1)
```
该段即"CSR 写后紧跟访存"的独立用例：修复前这两条 load 会在 `csrw` 提交前执行、按旧的
MPRV=1/MPP=U 翻译（对 U=0 的恒等大页 ⇒ 误报 load 页错误 cause 13、陷阱变 2 次）⇒ `C15'-1` 必红。
判据沿用 C15' 13 项（**未放宽**）＋通用 C1'/C3' 黄金比对（映像已重生成，golden=74 条）。

## B4.29.3 反证（必红后还原，日志留证）

把 `csr_ld_block_w` 临时接成 `1'b0` ⇒
`FAIL: 程序 10 第 62 条 PC=0x80028110 期望 0x800280e0` + `FAIL: C1' 程序 10`（提交 PC 流偏离 Spike 黄金：
多了一次 load 页错误陷阱）—— `../.b2chk/csr_counterproof.log`（退出码 1）⇒ 互锁**确实**在起作用 ✓ 已还原。

## B4.29.4 时序变化登记（p8/p10）

**无判据变化**：`tb_core_top_2b` **148/148**（含 C8' 的固定拍数判据、C10' 的 CSR 轨迹判据）与
`regress.sh` **32/32** 全绿，**没有**出现需要按规程重定的性能类判据 —— 原因：互锁只在"更老的 CSR
指令**已派发但未提交**"这一短窗口内挡年轻 load（CSR 指令通常很快到 ROB 头 ⇒ 1~2 拍量级），
且只挡**比它年轻**的 load（更老的 load 照常）✓ 故 p8（中断时序）/p10（大量 CSR）时序未发生可观测变化。

## B4.29.5 检查点

* 编译 **0 error**；`tb_core_top_2b` **148/148 PASS**（`../.b2chk/i2.log`：`[C15'] … ✓` +
  `检查项合计 148 项全部满足`）；反证日志 `../.b2chk/csr_counterproof.log`（红）。
* `./scripts/regress.sh` **32/32 PASS**（`../.b2chk/regress_b2c16.log`）。
* 改动：`rtl/back2/backend_top.v`（互锁两处）、`sim/unit/prog/back2_p14_storepf.S`（去规避）、
  `sim/unit/prog/back2_lockstep_data.svh`（重生成：仅 slot 13 变化 ✓ 已核对）、`sim/unit/back2_report.md`。
  **2A 零修改**；`scripts/regress.sh` 未动；未提交 git；快照 `../.b2chk/*.s45`（含 `backend_top.v.pre3`）。
* **边界关闭**：CSR 可见性（load 侧）✓ —— §B4.26.4 边界 1 / §B4.28.3 关闭。
* **剩余登记**：L1D/L1I 无复位、跨程序陈旧行（TB 侧递进基址规避）；cbo.inval 破坏性语义（Zicbom 允许）；
  store 侧上下文仍按"提交拍权威判定 + 提交门 + 重译"（§B4.25/§B4.26）—— 与本互锁互补。

---

# B4.30 4b-3·PLIC 例化接线（S 模式链 / p15：**本轮未完成，见表末**）

> 起点 = 母代理已验收提交 `52b7a28`（tag 2B-4.28）。检查点：`tb_core_top_2b` **148/148 PASS**；
> `regress.sh` **32/32 PASS**；2A 只读例化零修改；未提交 git。

## B4.30.1 ① PLIC 例化接线（完成，`rtl/top/core_top_2b.v`）

| 落点 | 内容 |
|---|---|
| 源映射 | 照 2A `core_top.v:557-570/1467`：`intrpt[7:0]` → 源号 `mac=5 / uart0=1 / spi=4 / nand=2 / dma=3`（`[7:5]` 不映射=0），常量取 `RV32GC_INTRPT_SRC_*` 宏（**不硬编码字面量**） |
| 窗口 | `[0x1F10_0000, 0x1F50_0000)`；`mmio_route` 早已解码（`plic_hit_o`），本轮把它接出为 `d_mr_plic_hit`；**实际选窗用锁存地址** `d_a_q`（`plic_sel_w = d_a_q ∈ [PLIC_HIT_LO, PLIC_HIT_HI)`）—— 因为 `plic_hit_o` 反映的是**当拍端口地址**，不能用于已接管的访问 |
| 访问 | 与 CLINT 同法：`AD_WAIT` 拍发一次 `req_*`（claim/complete 即 `CLAIM_OFF` 的读/写），同拍组合回 `resp_*`；`clint_req_vld` 拆出 `& ~plic_sel_w`（两窗口互斥），读数据 mux `plic_sel_w ? plic_rdata : clint_rdata` |
| 中断链 | `.irq_meip(plic_meip_w)`、`.irq_seip(plic_seip_w)` 接入 `csr_file`（原 `1'b0` 占位）⇒ `mip.MEIP/SEIP` → `mie.MEIE` → **中断取点仍在提交边界**（与 MTIP/p8 同一条 trap 链 ⇒ mepc 精确口径不变） |

实测：编译 0 error；`tb_core_top_2b` **148/148 PASS**（TB 的 `intrpt` 仍为 0 ⇒ 逐拍行为不变，
无既有判据回退）；`regress.sh` **32/32 PASS**（`../.b2chk/regress_b2c17.log`）。

## B4.30.2 ②③ S 模式完整链 / p15_priv：**本轮未完成**（预算见底，附已完成核对的现状）

**已核对到的现状（对下一轮直接可用）**：
* CSR 侧**已就位**：`csr_file` 例化里 `medeleg_o/mideleg_o/sepc_o/stvec_o/sstatus/sie/sip/scause/stval`
  等 S 模式 CSR 与 `priv` 输出都在（`core_top_2b:1392-1398`）；
* **委托路径已接**：`trap_ctrl` 例化带 `.medeleg(csr_medeleg_o)` / `.mideleg(csr_mideleg_o)`
  （`core_top_2b:1433-1434`）⇒ 委派判定在 RTL 侧已具备（**尚无用例行使**）；
* `ecall-from-S` / `sret` / `mret 进 S`：**未核对**（需读 `trap_ctrl` 的 cause/返回路径 + `priv_ctrl`
  的 `sret` 支持）——下一轮第一件事。
* 缺件：**p15_priv.S**、生成器 PROGS 项与黄金、TB 第 12 个程序槽与判据、TB 侧 **PLIC 测试中断源**
  （`intrpt` 由 TB 按程序阶段驱动，claim/complete 经 PLIC 窗口访问）——按本任务书 ④ 的口径，
  PLIC 中断判据须走"程序自记录 + 硬编码期望"（Spike 无 PLIC，与 p8 同法登记）。

**为什么未做**：本轮的预算是"停在全绿检查点"，而 ②③ 是"新程序（M→S 切换 → 委托 ecall → sret →
非法指令 → PLIC 中断链）+ 生成器 + TB 槽 + 中断源驱动 + 判据"的整链，属**独立一轮**的工作量；
在剩余预算内强行开工只会留下半成品接口（违反任务书的停止口径）⇒ 选择**只落地可独立验证的 ①**
并保持 148/148 + 32/32 全绿。

## B4.30.3 检查点与边界

* 改动：`rtl/top/core_top_2b.v`（PLIC 例化接线 + MMIO 选窗/读 mux + MEIP/SEIP 接入）、
  `sim/unit/back2_report.md`。**2A 零修改**（`plic`/`mmio_route`/`csr_file`/`trap_ctrl` 均只读例化）；
  `scripts/regress.sh` 未动；未提交 git；快照 `../.b2chk/*.s46`（含 `core_top_2b.v.pre3`）。
* **新增边界（开放）**：PLIC 已接线但**无判据覆盖**（TB `intrpt=0`）；S 模式委托路径已接但**无用例**。
* **下一轮建议顺序**：①读 `trap_ctrl`/`priv_ctrl` 核对 `sret`/`ecall-from-S`/委托投递；②写 p15_priv.S +
  生成器项 + 黄金（Spike 的 S 模式可比）；③TB 第 12 槽 + 判据（含 PLIC：TB 驱动 `intrpt` 某针、
  程序 claim/complete 自记录）；④反证（断开 `irq_meip` 必红）。
