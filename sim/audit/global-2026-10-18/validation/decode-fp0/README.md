# decode-fp0 验证夹具（只读 DUT）

本目录只包含 TB/脚本/日志，**不修改** `rtl/`、`sim/tb/`、`sim/unit/`、golden、断言。

## 运行

```sh
./run_all.sh          # 固定 24 例清单；缺任一例先预检失败(0/24)；全绿才 24/24
./negative/run_negative.sh   # 反证：空目录/缺一例/坏 reference/坏入口均须被拒绝(5/5)
./run_c1.sh           # compressed_expand 单例（c0..c8）
./run_f1.sh           # decoder OP-FP 单例（f0..f10）
./run_b1.sh           # backend dst_fp 单例（b1..b4）
```

每个 `run_*.sh` 独立编译（iverilog 12.0）、独立 vvp、独立日志 `log_<kind><case>.log`、
独立退出码。`run_all.sh` 使用**硬编码 24 例清单**（`c0..c8,f0..f10,b1..b4`），
执行前逐文件存在性预检，不依赖 `ls`/通配；汇总恒为 `<pass>/24`。
`run_one.sh` 判定：kind/case/mode 白名单 + 参考计算的 python rc 与精确锚点
（`REF_CHECK <tag>: OK value=0x........`，kind=c 另需 `REF_CIN`）+ 唯一 `RESULT=` 行；
删除 vvp 前校验解析路径仍在本目录且文件名就是本例 `<kind><case>.vvp`。
`ref_calc.py <tag>` 独立重算期望编码（输出 `REF_*` 锚点）。

## 判读

- `RESULT=DEFECT_REPRODUCED`：DUT 观测等于"按当前 RTL 机理预测的错误值"，
  表示**缺陷复现成功**；DUT 语义本身是 FAIL。
- `RESULT=CONTROL_OK`：反向控制，DUT 与规范一致。
- 报告与行号见 `results.md`；独立 oracle 输出见 `oracle_objdump.log`、`oracle_assembler.log`。
