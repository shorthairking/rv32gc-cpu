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
