> ## ⚠️ 更正（2026-09-13 第 7 轮）
>
> **本报告的结论已被推翻。** `Zalrsc-sc.w-00` 的失败实际是本核 `rtl/top/rv32gc_core.v` 的
> **MEM 级转发缺陷**（访存结果在 MEM 级不转发，紧跟 `LA(x2,scratch)` 的消费者读到旧值，
> 导致签名指针寄存器被搬到 scratch 地址）。核修复后，**同一份生成的汇编、同一个参考签名**
> 即可通过；生成器并无缺陷。
>
> 归因证据：`4f0ad1e`（旧 RTL）+ 旧 slave → FAIL；`7040098`（含修复 RTL）+ 旧 slave → PASS。
>
> 本文下方内容保留作为**排查过程记录**，其中"框架缺陷"的判断以及"33 个同族文件"的结论
> **不再成立**（`arch_scan_sigreg_clobber.py` 的值模型基于"LA 之后寄存器即被覆盖"的错误假设）。
> 请勿据此报告向 upstream 提 issue。

# ACT4 生成器缺陷：签名指针寄存器被测试自身覆盖（`mv x<new>,x<old> # switch signature pointer`）

> 发现于 RV32GC 核 bring-up 阶段（2026-09-13），定位对象：`riscv-arch-test`（ACT4 框架）。
> 结论：这是**框架/生成器缺陷**，不是被测核的 RTL 缺陷；参考模型 Spike 的自校验路径同样会
> 走到错误数据上（下述证据 3 为实测）。

## 1. 现象

`tests/rv32i/Zalrsc/Zalrsc-sc.w-00.S` 在自校验模式下（`RVTEST_SELFCHECK`）运行，框架在执行
到第 172 个用例时报签名不符：

```
RVCP-SUMMARY: TEST FAILED - Test File "Zalrsc-sc.w-00.S"
RVCP: Test Info: test: 171; cg: Zalrsc_sc.w_cg; cp: cmp_rd_rs2; bin: b1
```

用例源码（节选，`cp_rs1_nx0` 的 bin b2）：

```asm
Zalrsc_sc_w_cg_cp_rs1_nx0_b2_success:
  RVTEST_SIGUPD(x17, x5, x4, x13, ...)   # 签名指针在 x17
  LA(x2, scratch)                        # rs1 = scratch 基址（x2）
  LREG x18, 0(x2)                        # 读回存储值
  RVTEST_SIGUPD(x17, x5, x4, x18, ...)
```

但生成器在 bin b1 结束处插入了：

```asm
mv x17, x2   # switch signature pointer register to avoid conflict with test
```

此处的 `x2` **已经不是签名指针**——b1 的 `LA(x1, scratch)`/b2 的 `LA(x2, scratch)` 等测试自身
代码早已把 x2 写成 scratch 地址。于是 x17 变成 **scratch 地址**，后续所有 SIGUPD 都去读写
scratch（被测数据区），而 `LREG` 读回的也是签名区内容。

## 2. 根因

`generators/testgen/src/testgen/data/registers.py::RegisterFile.consume_registers()`

```python
if sig_conflict:
    self._sig_reg = self.get_register(exclude_regs=[0, *self.link_temp_regs])
    lines.append(
        f"mv x{self._sig_reg}, x{old_sig_reg} # switch signature pointer register to avoid conflict with test"
    )
```

该搬运**假设 `old_sig_reg` 此刻仍持有当前签名指针**。而调用方（如 `cp_regs.py::make_rs1`）
是把这段 asm 通过 `tc.code.insert(0, asm_setup)` 插到用例最前面，紧接着用例自己的
`LA(x{rs1}, scratch)`；当 `rs1 == old_sig_reg` 时，`LA` 早于（或同段于）搬运执行，
`old_sig_reg` 里已经是 scratch 地址，搬运的是错值。

生成器对 `_sig_reg` 的记账是**寄存器名**而非**当前值**，因此无法察觉"该寄存器被测试代码
改写过"。

修复方向（供上游参考）：
* 让签名指针的搬运不依赖旧寄存器内容——例如把"当前签名指针"放在一个框架自留寄存器/固定
  位置（如相对 `signature_base` 的偏移），搬运时用 `LA` + `addi` 重新构造；
* 或在被复用的 `old_sig_reg` 被测试代码改写**之前**就完成搬运（需要把搬运插在测试 setup
  之前，并保证 setup 不使用新旧签名寄存器）；
* 或在 `consume_registers` 冲突消解时，选择**不是**本次请求寄存器的其它寄存器，并禁止
  把签名指针放到任何"本轮测试会被写"的寄存器上。

## 3. 证据（三条独立、可复现）

### 3.1 反汇编：`LREG x18, 0(x2)` 实际被编成读 x17 的 load

```
80002120: auipc  sp,0x12 / addi sp,sp,-288   # x2 = scratch = 0x80014000
80002144: lr.w   zero,(sp)                   # (b2 的 LR)
80002148: sc.w   a3,a1,(sp)
80002154: lw     tp,0(a7)                    # ← 源码是 LREG x18,0(x2)，这里读的是 a7(x17)
```

### 3.2 本核提交轨迹 + D 侧请求（RV32GC 平台）

`sim/log/Zalrsc-sc.w-00.rtl.log`（`tb_trace_mem` 观测）：

```
COMMIT cyc=2607 pc=800020fc x17=8001bdec        # mv x17, x2；x2 此时 = 0x8001bdec(=签名指针)
DREQ  cyc=2701 pc=80002154 we=0 addr=8001bdec   # ← 访问的是签名区，不是 scratch
DRSP  cyc=2706 pc=80002154 rdata=00000000       # 期望读到 scratch 里的 0x3a688fc5
```

核的行为与反汇编**完全一致**——它老老实实执行了生成器给出的错误代码。

### 3.3 参考模型 Spike 同样走错（实测提交轨迹）

```
core 0: 3 0x80002148 (0x18b126af) x13 0x00000000 mem 0x80014000 0x3a688fc5   # sc.w 正确写存储
core 0: 3 0x80002154 (0x00d8a023) mem 0x8001bdec 0x00000000                  # 同一条"错位"访问
core 0: 3 0x80002158 (0x00000863)                                            # 比较失败
```

Spike 在这条用例上同样会自校验失败。之所以 CI 里没暴露，是因为参考签名是在
`-DSIGNATURE`（非自校验）模式下由 Spike 生成的，跑签名时不会触发自校验比较。

## 4. 影响面（全语料静态扫描）

`rv32gc-cpu/scripts/tests/arch_scan_sigreg_clobber.py` 扫描
`riscv-arch-test/tests/rv32i/**/*.S`（641 个文件），**33 个文件**存在同类"签名指针搬运源
已被覆盖"：

```
D/D-fcvt.d.w-00.S          D/D-fcvt.d.wu-00.S        D/D-fld-00.S
F/F-fcvt.s.w-00.S          F/F-fcvt.s.wu-00.S        F/F-flw-00.S
F/F-fmv.w.x-00.S           MisalignZca/MisalignZca-c.lwsp-00.S
MisalignZca/MisalignZca-c.swsp-00.S                  Zca/Zca-c.addi16sp-00.S
Zca/Zca-c.addi4spn-00.S    Zca/Zca-c.lwsp-00.S       Zca/Zca-c.swsp-00.S
Zcd/Zcd-c.fldsp-00.S       Zcd/Zcd-c.fsdsp-00.S      Zcf/Zcf-c.flwsp-00.S
Zcf/Zcf-c.fswsp-00.S       ZfaD/ZfaD-fmvp.d.x-00.S   Zfbfmin/Zfbfmin-flh-00.S
Zfbfmin/Zfbfmin-fmv.h.x-00.S                         Zfh/Zfh-fcvt.h.w-00.S
Zfh/Zfh-fcvt.h.wu-00.S     Zfh/Zfh-flh-00.S          Zfh/Zfh-fmv.h.x-00.S
Zfhmin/Zfhmin-flh-00.S     Zfhmin/Zfhmin-fmv.h.x-00.S
Zicbom/Zicbom-cbo.clean-00.S                         Zicbom/Zicbom-cbo.flush-00.S
Zicbom/Zicbom-cbo.inval-00.S                         Zicbop/Zicbop-prefetch.i-00.S
Zicbop/Zicbop-prefetch.r-00.S                        Zicbop/Zicbop-prefetch.w-00.S
Zicboz/Zicboz-cbo.zero-00.S
```

共同特征：测试使用了 **x2（sp）** 类寄存器作为操作数（`c.lwsp/c.swsp/c.addi16sp/c.addi4spn`、
`c.flwsp/c.fldsp`、`flw/fld`、`fmv.*.x`、CBO 指令等），而生成器又把签名指针放在同一寄存器上。

## 5. 建议

1. 上游修复 `registers.py` 的签名指针搬运（见 §2 修复方向），并重新生成受影响的 33 个文件；
2. 上游在 CI 中增加"自校验模式"冒烟（例如对 1~2 个文件同时跑 `RVTEST_SELFCHECK`），
   否则这类缺陷只会在 DUT 侧暴露，且容易被误判为 DUT 缺陷；
3. 在下游使用方（如本项目）侧，把上述 33 个文件标记为"框架缺陷已知问题"，与核的
   RTL 缺陷分开记账。
