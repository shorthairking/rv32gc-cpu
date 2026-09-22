# 2B-2 影子树交接（并发写者冲突 → 移交 8009c161）—— 2026-09-21 20:2x

> **本文件的性质**：本会话（2B-2 收尾子代理）按母代理裁定**停手移交**。全部成果在
> `/tmp` 影子树里，**仓库除本文件外零改动**（未 `git checkout/stash/reset`、未提交）。
> 承接人：`8009c161`（`rtl/back2/` 既有作者）。本文件只写事实与可直接套用的补丁。
>
> 影子树路径（可直接读/复制，属于工作区可见文件系统）：
> - **`/tmp/b2work/`** —— 仓库 `rtl/ + sim/unit/ + sim/tb/` 的完整副本（20:10 快照），
>   其中 `/tmp/b2work/rtl/back2/rename.v` = **本会话重写版（575 行，已编译通过）**。
> - `/tmp/b2w/rename.v.bak_pre_bitmap` —— 重写前的仓库版 rename.v（20:06 的 511 行版）。
> - `/tmp/b2w/conc/` —— 20:10 时刻的仓库快照：`backend_top.v` / `prf.v` /
>   `tb_back2_lockstep.sv` / `back2_report.md` / `rename.v.20h06`（用于与后续版本 diff）。
> - `/tmp/b2w/tb_ls_new2.vvp` 等 —— 影子树编译产物（无价值，可弃）。
> 复现命令见 §5。

---

## 0. 并发时间线（事实，用于证据归属）

| 时刻 | 事件 |
|---|---|
| ~19:58:46 | 前任子代理写完 `sim/unit/back2_report.md`（会话交接） |
| 20:05 | 本会话开工：`wc -l rtl/back2/rename.v` = **489 行**（环形表版），读全文 |
| 20:06:33 | rename.v → **511 行**（新增 §3.0 注释块 + 提交侧释放），非本会话所写 |
| 20:08:10 | `backend_top.v`、`prf.v` 同秒被改（非本会话所写） |
| 20:09:39 | `tb_back2_lockstep.sv` 被改（非本会话所写） |
| 20:09:55 | 本会话发出并发告警，母代理裁定：8009c161 为唯一仓库写者，本会话停手 |
| 20:10 | 本会话把仓库快照进 `/tmp/b2work/`、`/tmp/b2w/conc/`（此后仓库仍在被 8009c161 修改） |

⇒ 因此 §3 的实测结论基于"8009c161 在 20:08–20:10 的在飞版本（prf.v `wkeep` 版 +
backend_top.v 对应版）+ 本会话重写的 rename.v"。仓库此后又变过（`backend_top.v`
与本会话 20:10 快照已不同），请以承接人当前版本为准。

---

## 1. 交付物 A：`rename.v` 空闲物理号 → 96 bit 位图（§4.3(b)）

**文件**：`/tmp/b2work/rtl/back2/rename.v`（575 行，`iverilog -g2012 -Wall` 对
`rename.v` **零 warning**；可直接 `cp` 覆盖仓库同名文件）。

### 1.1 核心表示（与仓库现版 rename.v 的根本差异）

```
free_bm[i] == 1  ⟺  物理号 i 既不被 RAT 引用、也不被 ARAT 引用
free_bm        =  ~( rat_ref_bm | ar_used_q )
rat_ref_bm     =  96 位：逐位与 32 项 rat_q 比较后或树（96×32 = 3072 个 7 bit 比较）
```

- 删除：`flist_q[0:255]`、`fhead_q`、`ftail_q`、`ck_fhead[]`、`rb_fhead[]`、
  `rb_act/rb_cnt/rb_head`（全冲刷重建 FSM）、`ord_r`、`rel_n_w` 的使用。
- 分配：逐 lane 最低置位（`bm & (-bm)`）+ `lowidx()` 低位优先编码；同拍把该位从后续
  lane 的可用集掩掉（`av_bm[g] = av_bm[g-1] & ~pk_bm[g-1]`）⇒ **同块 4 lane 的物理号
  互不相同，由构造消除"重复 push"**。
- 释放：**不登记**。提交拍 `ARAT[arn] ← pd`（§3.0 每拍无条件执行）后旧映射自动离开
  `ar_used_q` ⇒ 下一拍 `free_bm` 自动置位；置位幂等。
- 回滚/冲刷：**无快照**。RAT 由变更日志恢复 / `flush_all` 时 `RAT ← ARAT`，
  `free_bm` 组合跟随。`busy = undo_act`（不再有 96 拍重建窗）。
- `rel_we/rel_preg` 端口保留但**只用于自检**（CHK-C：释放值不得等于本条新映射 = B14 形态）。
- 副作用（正向）：架构基线物理号 0..31 在其架构寄存器被首次覆写后也进入 `free_bm`
  ⇒ 可用物理号 96（旧环形表只回收 32..95）；整数域空闲数恒 ∈ [32,64]（**泄漏不可能**，
  也**不可能为 0**），浮点域 ∈ [0,32]（与 FREE_N=32 同下界）。
- 顺带修掉的真缺陷：`LOG_PTR_W` 默认值原为 `` `BACK2_RATLOG_N ``（=128 ⇒ 128 bit
  指针），改为 `` `BACK2_RATLOG_PTR_W ``（=8），与 params 注释一致，省 128 FF 且减法链变短。
- 新增自检（CHK=1 默认开，只在违规时打印 `RENAME-CHK FAIL(...)`）：
  A 自环（保留原有）、B 分配合法性（在 free_bm 内 / one-hot / 同块互异）、
  C 释放语义（`rel_preg != cmt_pd`）、D 稳态下 RAT/ARAT 内部互异（回滚 FSM 空闲拍才查）。
- 关键理由（为什么不用"检查点/回滚快照位图"）：快照恢复有一个**静默错值**反例 ——
  `A(x1←p)` 与 `W(x1←q)` 同在前端窗口内、快照点 s 落在 W 之后 ⇒ `p ∉ RAT_s` 且
  `p ∉ ARAT_s` ⇒ 快照把 p 记成空闲；若 A 在回滚**之后**才提交（A 比回滚点老，允许），
  `ARAT[x1] = p` 而 p 已被放出 ⇒ p 可被重新分配并覆写，之后任何"恢复出 x1→p"的回滚
  都读到错值。组合推导没有这个窗口（完整推导见文件头注释 §不变量 I）。

### 1.2 §3.0 提交侧无条件执行（与 8009c161 20:06 版 rename.v 的诊断一致，已并入）

仓库 20:06 版把"提交侧（`arat_q` / `ar_used_q` / free list 释放）"改到 `always` 块
**最前面、每拍无条件执行**，理由是"回滚 FSM 期间到达的提交不能丢"。本会话**独立确认
该诊断正确**，并在位图版里以同样方式实现（rename.v §3.0，第 503 行起）：

```verilog
// 3.0 提交侧（架构）更新：**每拍无条件执行**（缺陷 B17）
for (j2 = 0; j2 < W; j2 = j2 + 1) begin
    if (cmt_we[j2]) arat_q[cmt_arn[j2*ARN_W +: ARN_W]] <= cmt_pd[j2*PDW +: PDW];
end
ar_used_q <= ar_used_next;
// 3.1/3.2/3.3/3.4 的 FSM 只负责 RAT/日志/快照
```

位图版若**不修**这一处，症状不是"重复项"而是**静默错值**：回滚期间提交的
`ARAT[arn]=p_new` 丢失 ⇒ `ar_used_q` 里没有 p_new ⇒ `free_bm` 把仍被架构引用的号判为
空闲 ⇒ 该号被再分配。**这条修复对两条路线都必需。**
另外 `ar_used_next` 由 `always @(*)` 改为 W 级组合链 `au_st[]`（rename.v 第 350 行起），
消除 iverilog `-Wall` 的"@* 对整数组敏感"告警，与本文件风格一致。

---

## 2. 交付物 B：**新缺陷 B18**（R4 / 同块 WAW 前递优先级取反）—— 请务必合入仓库版

这是本会话在影子树里**新发现并修好**的缺陷，与 free list 无关，**环形表路线同样会踩**。

### 2.1 缺陷

`rename.v` 的"同块内前递"两处都按 **最老 lane 优先** 选，正确语义是 **最年轻 lane 优先**：

| 位置 | 旧（仓库版） | 新（影子树版） |
|---|---|---|
| 源物理号 R4（`ev_pd_s`） | `p0 ? pk_ix[0] : p1 ? … : p2 ? … : rat_q[sa]` | `p2 ? pk_ix[2] : p1 ? pk_ix[1] : p0 ? pk_ix[0] : rat_q[sa]` |
| 目的旧映射 WAW（`ev_pd_old`） | `s0 ? pk_ix[0] : s1 ? … : s2 ? … : rat_q[…]` | `s2 ? pk_ix[2] : s1 ? pk_ix[1] : s0 ? pk_ix[0] : rat_q[…]` |

`ev_pd_old` 那处还会污染**变更日志的 old 值** ⇒ 回滚后 RAT 恢复出错误映射。

### 2.2 实测证据（可复现）

程序 `back2_p1_int.S` 的循环体第 3 条是 4 级同块 WAW/RAW 链
`addi x8,x8,5`(lane0) / `xori x8,x8,0x11`(lane1) / `slli x8,x8,1`(lane2) / `srli x8,x8,1`(lane3)：

```
改前：FAIL: 程序 0 第 10 条写回分歧：乱序 {we=1 rd=8 wd=0x0000000c} vs 2A {… wd=0x0000002e}
      （0x0c = 6<<1 ⇒ 第 3 条读到第 1 条的物理号（值 6），而不是第 2 条的 23）
改后：第 10 条一致；分歧点后移到第 26 条（见 §3.3）
```

### 2.3 影子树版对应行号

`/tmp/b2work/rtl/back2/rename.v`：`ev_pd_old` 第 277–292 行、`ev_pd_s` 第 298–316 行。

---

## 3. 已完成的编译/验证结果（全部在影子树，仓库未跑）

### 3.1 编译

```bash
cd /tmp/b2work
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)   # 56 个
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/b2w/tb_ls_new2.vvp \
    -s tb_back2_lockstep_top -Ptb_back2_lockstep_top.CYC_LIMIT=4000 \
    "${RTL[@]}" sim/unit/tb_back2_lockstep.sv
# → rc=0；rename.v 零 warning（其余文件沿用仓库既有告警）
```

### 3.2 基线（仓库 20:06 版 rename.v + 20:08 版其余件）

```
$ vvp /tmp/b2w/tb_ls.vvp          # CYC_LIMIT=4000
RENAME-CHK FAIL: lane 3 src 0 arn=30 映射到自身新目的 preg=39（自环）
  | fhead=147 ftail=209 flist[fhead..+7]=39 39 10 40 40 40 41 35
real 4m38s（4000 拍 ⇒ ≈14 拍/s，停摆后吞吐崩掉，这正是 regress 300 s 墙钟被杀的原因）
```

### 3.3 影子树版（位图 + §3.0 + B18）

```
$ vvp /tmp/b2w/tb_ls_new2.vvp     # CYC_LIMIT=4000，real 0m0.24s（≈1800× 提速）
== 程序 0：黄金 161 条 ==
== 程序 0：两核提交 161 / 201 条（黄金 161），跳板 2 / 2 条，443 拍
FAIL: 程序 0 第 26 条写回分歧：乱序 {we=1 rd=8 wd=0x00000000} vs 2A {… wd=0x0000001c}
FAIL: C1 程序 0：arch 写回流锁步 0 分歧
```

要点：
- **无 RENAME-CHK 违规、无自环、无停摆**；PC 流 C2（两侧 vs Spike 黄金 161 条）全过，
  跳板 C3 全过；**前 26 条提交的 arch 写回全部与 2A 一致**（改前只能对到第 10 条）。
- 剩余分歧点已定位到"第一次循环回边误判/回滚之后"的第一条提交（DBG_CYCLES=1 原始日志
  `/tmp/b2w/dbg1.log`，225 行）：

```
[t=705000] lane1 pc=0x80000064 we=1 rd=29 wd=0x00000000 pdst=0 pdo=29   ← bne（循环回边，误判）
   …（11 拍无提交：重定向 + 回滚 + 重取）…
[t=815000] lane0 pc=0x80000020 we=1 rd=8 wd=0x00000000 pdst=34 pdo=9   ← 第 2 轮 addi x8,x8,5
[t=815000] lane1 pc=0x80000024 we=1 rd=8 wd=0x00000011 pdst=36 pdo=34
[t=825000] lane0 pc=0x80000028 we=1 rd=8 wd=0x00000022 pdst=38 pdo=36
[t=825000] lane1 pc=0x8000002c we=1 rd=8 wd=0x00000011 pdst=41 pdo=38
```

  第 1 轮里 `srli x8`（0x8000002c）曾以 **pdst=9 / wd=0x17** 提交，且第 1 轮第 18 条
  `and x10,x10,x8` 还能正确读回 0x17；到第 2 轮 `addi x8,x8,5` 时 `pdo=9`（源映射仍是
  preg 9）却读到 **0**（= PRF[9] 的值）⇒ 提交值 0x0（期望 0x1c=28）。
  ⇒ 症状形态 = **"回滚/冲刷之后，某些物理寄存器读回 0（陈旧值）"**，与 8009c161 在
  `prf.v` 第 45 行注释里记的"4 深 WAW 链的 `srli` 读到 0 而非 0x1a"属**同一类**：
  写回被写口判据（旧 `wepoch==epoch` / 新 `wkeep`）丢弃 ⇒ 消费者读陈旧值。
  本会话**未继续追**（按裁定停手），但可给承接人两条独立线索：
  ① 我的分歧点发生在**分支回滚之后**，而非"回滚前的在飞写回"⇒ 请确认 `wkeep`
     （`in_rob_win`）判据在"保留的更老在飞项"上确实为 1，且它在回滚拍附近不被清零；
  ② 请确认位图版的 free_bm 未把 preg 9 提前放出（若放出后被新指令覆写为别的值，
     也会看到"读到别的值"；本会话 CHK-B/D 全程未报，故先排除的是"重复分配"，
     但**不能**排除"提前释放"——建议给 rename.v 加一条 CHK：`free_bm` 里为 1 的位
     不得被 RAT 引用（组合式不变量断言），逐拍监控一次 C1 跑，即可判定）。

### 3.4 未完成项（承接人接手）

- `tb_back2_lockstep` 三程序 C1–C5 全绿（当前卡在程序 0 第 26 条，见 §3.3）；
- `tb_back2_ipc.sv` **未开始写**（本会话未创建该文件）；
- `scripts/regress.sh` 全量（29/30 TB）**未跑**（本会话只做了影子树单点验证）；
- `sim/unit/back2_report.md` 的"全绿收尾"更新**未做**（按裁定只写本文件）。

---

## 4. 与仓库现版 `rename.v` 的差异说明（给承接人决策用）

| 维度 | 仓库 20:06 版（511 行） | 影子树版（575 行） |
|---|---|---|
| 空闲表 | `flist_q[0:255]` 环形数组 + `fhead_q/ftail_q` | `free_bm[NREG]` 组合推导（`~rat_ref_bm & ~ar_used_q`） |
| 分配 | `flist_q[fhead + ord_d[g]]`（数组读，需 `free_cnt` 判据） | 逐 lane 最低置位 + 掩码（同块天然互异） |
| 释放 | 提交拍 push 到 `ftail` | 无（ARAT 更新后自动置位） |
| 回滚 | `fhead_q ← ck_fhead/rb_fhead`（只回退 head） | 无快照（RAT 恢复即 free_bm 跟随） |
| 全冲刷 | `RAT←ARAT` + `rb_act` 逐拍扫 96 项重建 free list | `RAT←ARAT`（1 拍），`busy` 不再含 `rb_act` |
| 提交侧 | 已提到 always 最前（20:06 版改动，正确） | 同上（§3.0），逐 lane 顺序一致 |
| 前递优先级 | `p0>p1>p2` / `s0>s1>s2`（**错**，见 B18） | `p2>p1>p0` / `s2>s1>s0`（**对**） |
| `LOG_PTR_W` | 默认 `` `BACK2_RATLOG_N ``=128（128 bit 指针） | 默认 `` `BACK2_RATLOG_PTR_W ``=8 |
| 自检 | CHK 自环（1 项） | CHK A/B/C/D（4 类，默认开） |
| 端口 | — | **端口完全不变**（`rel_we/rel_preg` 保留做自检）⇒ `backend_top.v` 零改动即可替换 |
| 规模/时序 | 96 FF + 256×7 bit 数组 + 双指针 | +3072 个 7 bit 比较 + 96 级 popcount 链（面积换正确性；仿真侧 0.24 s vs 4m38s） |

两道**必合**的改动（与路线无关）：**§1.2 的 §3.0 提交侧无条件执行**、**§2 的 B18
前递优先级**。位图路线可选：若承接人选择继续环形表，建议至少把 B18 与 §3.0 合入，
并考虑用"重复号检测"（分配后 `free_bm` 反查）替代快照方案。

---

## 5. 复现/交接命令（承接人可直接用）

```bash
# 影子树（含本会话重写版 rename.v）——只读，可直接 cp 到仓库
ls -l /tmp/b2work/rtl/back2/rename.v            # 575 行
diff -u /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/rtl/back2/rename.v \
        /tmp/b2work/rtl/back2/rename.v | less   # 与仓库现版差异

# 影子树编译 + 跑（不触碰仓库）
cd /tmp/b2work
mapfile -t RTL < <(find rtl -type f -name '*.v' | LC_ALL=C sort)
iverilog -g2012 -Wall -I rtl/pkg -I . -o /tmp/b2w/x.vvp \
    -s tb_back2_lockstep_top -Ptb_back2_lockstep_top.CYC_LIMIT=4000 "${RTL[@]}" \
    sim/unit/tb_back2_lockstep.sv && vvp /tmp/b2w/x.vvp
#   逐拍/逐条提交诊断：追加 -Ptb_back2_lockstep_top.DBG_CYCLES=1
#   rename 侧 preg 分配/释放轨迹：把 rename.v 的 TRACE 默认值改 1（-P 只对顶层生效）

# 仓库侧（承接人自己决定）：cp /tmp/b2work/rtl/back2/rename.v rtl/back2/rename.v
```

## 6. 纪律与边界（本会话遵守情况）

- 仓库改动：**仅本文件**（`sim/unit/back2_shadow_handoff.md`，新增 untracked）。
- 未 `git checkout/stash/reset`、未 `git add`、未提交；所有反证用 `cp` 备份（§0 路径）。
- 未改 `rtl/front4|exec|mem|csr|cache|fetch|decode|axi|top|pkg`、未改 `scripts/regress.sh`。
- 未创建 `tb_back2_ipc.sv`、未改 `back2_report.md`（按裁定移交）。
- 已知环境事实（对承接人有用）：`tb_back2_lockstep` 在**停摆态**吞吐 ≈14 拍/s（300 s
  墙钟必被杀）；修掉停摆后同一 TB 443 拍/程序、整轮 0.24 s ⇒ **修好后大概率不需要**
  T5 按名放宽档，届时按实测决定。
