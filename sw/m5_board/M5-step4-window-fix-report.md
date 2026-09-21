# 步④ `cycles/iter` 窗口修正 —— 交付报告（2026-09-21，第五轮）

> **范围**：只改**上板程序**（`sw/m5_board/m5_board.S`）+ 构建脚本同步 + runbook。
> **RTL / bitstream / sim / arch-test / regress 判据一律未动**（`git status` 只列 3 个文件）。

## 1. 结论

| 项 | 结果 |
|---|---|
| `bash sw/m5_board/build.sh` | **rc=0**，53 条 PASS / 0 条 FAIL，`RESULT_M5_BUILD: OK` |
| `bash tb/ctrl/build_ctrl.sh` + `python3 tb/ctrl/diff_equiv.py` | **rc=0**；缩放副本与冻结程序差异 **4 字**，全部是 `DELAY_HB/SW_TICKS` 的 `li` 立即数对 |
| `bash tb/run_tb.sh`（保持型） | **`TB_M5_BOARD: PASS`**（C0–C6 全绿，4439635 拍，1167 字节，`RESULT: RV32GC-M5-OK`） |
| `bash tb/run_tb.sh`（非保持型 `DDR_R_NONHOLD=1`） | **`TB_M5_BOARD: PASS`**；UART 字节流与保持型轮**逐字节相同** |
| `bash sw/m5_board/verify_m5.sh` | **`V5: ALL CHECKS PASS`**（未改 V5b 基线；`rtl/**` md5 = `66e3225645b6f29375c786fe166448d6` 不变） |
| 反证（判据 A 容差强制 0） | 仿真该轮 **`RESULT: RV32GC-M5-BAD`**、`TB_M5_BOARD: FAIL C3`；恢复后 src md5 与镜像 md5 **逐字节一致** |
| bitstream | **未动**，仍 `md5 = 167dc9dfd487a9d6148ddee02d407726` |

## 2. 改了什么

### 2.1 `sw/m5_board/m5_board.S`

1. `CPI_SANITY_HI`：**300 → 20000**（注释注明**板级实测 4120** / **零延迟仿真 59** 两种口径，
   以及"原上界按仿真标定值 59 的量级定为 300 ⇒ 真实标定值被误判 BAD"）。
2. **窗口判据降级为信息性**：删除 `bltu s7,LO ⇒ tp_bad` / `bltu HI,s7 ⇒ tp_bad` 两条
   "把 s11 置 1"的路径；`cycles/iter` 仍然算出并打印，但**不参与 BAD 判定**。
   现在 BAD 只由 **① 判据 A**（`|Δtimer − Δcycle| ≤ max(256, Δcycle/128)`）
   与 **② 步⑤ FREQ 锚定**（`div1e6 == 33` ∧ `FREQ>>20 == 31`）+ 三个探针决定。
3. 步④ 打印合并为**一条字符串**（`str_tpiwin` 承载；删除 `li a0,XIP_CPI` + `str_tpical`）：
   ```
   step4 timer delta = <dec>, cycle delta = <dec>, cycles/iter = <dec> (informational only; window 20..20000; board-calib=4120, sim-calib=59 cycles/iter)
   ```
4. BUILD 标记 `2026-09-21c` → **`2026-09-21d`**（镜像换代可辨识；横幅第 2 行同时标注
   `CPI window informational`）。

### 2.2 `sw/m5_board/build.sh`（同步机器护栏）

- 判据⑧f4：窗口上界检查 `≤ 400` → **`≤ 1e6 且 > 下界`**。理由：窗口已不是判据，
  但它**仍必须是有界、有序的窗口**（fail-closed，禁止改成无界/必过样子货）；
  400 这个上限是"按仿真标定值 59 的窄窗口"的口径，与 20000 的真实标定值冲突。
- 判据⑫a/⑪h 的 BUILD 标记与横幅字节串同步为 `…-2026-09-21d` /
  `stack probes; CPI window informational)`。

### 2.3 `sw/M5-board-runbook.md`

- 步④ 一节：示例行改成仿真值（**首处用 `cycles/iter = 59`**，`build.sh` 判据⑨d 抽取它核对
  `XIP_CPI` —— 已写进手册，避免以后改文案踩坑）；上板实测行改为 4120；
  判据说明改为"判据 A + 步⑤ 锚定（窗口信息性）"，并给出"这不是放水"的论证。
- §5.2 BAD 行、§6 交付表（源码 md5 `ac51c14a…`、镜像 **2772 B** / md5 `a91f6f64…`、
  hex md5 `26b38763…`）、§6.1 重烧步骤（**本轮只烧程序、不动 bitstream**）、
  §6 第五轮交付说明，全部同步。

## 3. 新产物

| 文件 | 大小 | md5 |
|---|---|---|
| `sw/m5_board/out/m5_board.bin`（烧写镜像） | **2772 B** | **`a91f6f64630237cb1e0f76f2a32c40a9`** |
| `sw/m5_board/out/m5_diag.bin`（诊断版命名副本，逐字节相同） | **2772 B** | **`a91f6f64630237cb1e0f76f2a32c40a9`** |
| `sw/m5_board/out/m5_board.hex`（仿真加载） | 6237 B | `26b38763b7e02d8efe638817a04ab911` |
| `sw/m5_board/m5_board.S`（源码） | — | `ac51c14a823b6dbaf665aae13acc59f0` |

## 4. 可复现命令

```bash
cd rv32gc-cpu
bash sw/m5_board/build.sh                       # 期望 rc=0、53 PASS、RESULT_M5_BUILD: OK
bash sw/m5_board/tb/ctrl/build_ctrl.sh          # 期望 rc=0
python3 sw/m5_board/tb/ctrl/diff_equiv.py       # 期望 rc=0（差异 4 字，仅 li 立即数对）
# 仿真两轮（缩放副本；本轮 4M 拍预算不够，实测 4439635 拍 ⇒ 用 6M）
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_m5_scaled.hex RUN_TAG=diag_hold_d2 \
  EXPECT_EXTRA="R2FIX: yes" DDR_R_NONHOLD=0 TIMEOUT_CYCLES=6000000 bash sw/m5_board/tb/run_tb.sh
PROG_HEX=sw/m5_board/tb/ctrl/out/ct_m5_scaled.hex RUN_TAG=diag_nonhold_d2 \
  EXPECT_EXTRA="R2FIX: yes" DDR_R_NONHOLD=1 TIMEOUT_CYCLES=6000000 bash sw/m5_board/tb/run_tb.sh
bash sw/m5_board/verify_m5.sh                   # 期望 V5: ALL CHECKS PASS
```

## 5. 反证记录（fail-closed 证明）

1. **首次尝试无效（已记录现象）**：把判据 A 的"容差下限 `li t2,256`"改成 0 **不生效** ——
   `tol = max(256, Δcycle/128)` 里的 `Δcycle/128`（仿真里 Δcycle/128 ≈ 922，比 256 大 ⇒ 覆盖掉改小的下限）随后会覆盖它
   ⇒ 该轮仍打印 `-OK`。这说明"改常量"这条路径不是判据本体。
2. **有效反证**：把 `mv t2, t1`（容差 = max(...)）改成 `li t2, 0`（容差恒 0，结构不变）
   ⇒ 该轮打印
   `step4 … cycles/iter = 59 (informational only; …)` 之后 **`RESULT: RV32GC-M5-BAD`**，
   TB 判 `FAIL C3`（`结果行已出现且判定为**非 OK**`）⇒ **判据 A 确实还能把结果翻成 BAD**
   （且窗口不再参与 ⇒ 证明"信息性"没有削弱判据 A 的触发能力）。
3. **恢复**：`cp` 备份回源文件，`cmp` 空、源码 md5 回到 `ac51c14a823b6dbaf665aae13acc59f0`，
   重新 `build.sh` 后镜像/hex md5 与反证前**逐字节一致**（全程未用 git checkout/stash/reset）。

## 6. 用户重烧步骤（只烧程序，不动 bitstream）

1. **bitstream 不动**：`rv32gc_chiplab_soc.bit` md5 `167dc9dfd487a9d6148ddee02d407726`（与上一轮同一份）。
   若板子里已是这份（步2.5/2.6/2.7 都判过），跳过烧 bitstream。
2. **只烧程序**：按 runbook §3 方式 B（`programmer_by_uart.bit` + xmodem）把
   `rv32gc-cpu/sw/m5_board/out/m5_diag.bin`（**2772 B**，md5 `a91f6f64630237cb1e0f76f2a32c40a9`）
   写入 Flash 地址 0。
3. 复位后核对：横幅第 2 行 = `BUILD=m5_board-diag-2026-09-21d (stack-free prints; R2+MEXT+stack probes; CPI window informational)`；
   步④ 行 = `step4 timer delta = 8241325, cycle delta = 8240913, cycles/iter = 4120 (informational only; window 20..20000; board-calib=4120, sim-calib=59 cycles/iter)`；
   末行应为 **`RESULT: RV32GC-M5-OK`**。

## 7. 遗留 / 风险

1. **`sw/m5_board/tb/README-tb.md` 未同步**（不在本次授权范围）：
   §4.1 结果表仍是 `diag_hold`/`diag_nonhold`（旧 BUILD `…c` 轮）、§5.2 仍写
   `cycles/iter ∈ [20, 300]`。建议由母 Agent 决定是否补一条 `diag_hold_d2/diag_nonhold_d2` 记录。
2. **`sw/m5_board/tb/run_diag_matrix.sh` 里硬编码了旧 BUILD 标记** `BUILD=m5_board-diag-2026-09-21c`
   （未授权修改）⇒ 该矩阵脚本对新镜像会**判不到镜像标记**（fail-closed，不会假 PASS，但会报错）。建议同步。
3. **反证轮的第一个"无效尝试"值得留档**：`max(256, Δcycle/128)` 结构下，"改 256"只影响小窗口；
   以后要反证判据 A，必须改 `mv t2,t1` 这一条（或直接用更小的 Δcycle）。
4. 仿真两轮在 4M 拍预算下会 **C5 超时**（实测需 4439635 拍，收 1012/1167 字节）；
   用 `TIMEOUT_CYCLES=6000000` 复跑才 PASS。若以后加入更多打印，需再抬高预算。
5. 板上 `cycles/iter ≈ 4120` 只是**记录值**：它随 SPI Flash 型号/时序浮动，
   **不要**再把它当判据；主频锚定在步⑤ FREQ。
