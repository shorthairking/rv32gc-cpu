# privilege-memory 验证夹具（只读 DUT）

本目录只包含 TB/脚本/日志，**不修改** `rtl/`、`sim/tb/`、`sim/unit/`、golden、断言。

## 运行

```sh
./run_all.sh                 # 固定 11 例（p0..p5,b1..b3,l1..l2）；缺失先预检失败(0/11)
./negative/run_negative.sh   # 反证：空清单/坏 reference/坏入口均须被拒绝(4/4)
./run_p1.sh                  # backend 特权负例；exit 0 = 缺陷已复现
./run_b2.sh                  # CLINT 相等边界
./run_l1.sh                  # LSQ 回绕释放
```

## 判读

- `RESULT=DEFECT_REPRODUCED`：DUT 观测等于按当前 RTL 机理预测的错误值 ⇒ **缺陷复现成功**；
  DUT 语义本身是 FAIL。
- `RESULT=CONTROL_OK`：正向/反向控制，DUT 与规范一致。
- 三组证据等级均为模块级（见 `results.md`）；未做整核级复现。
- `ref_calc.py` 输出机器锚点 `REF_CHECK <tag>: OK value=0x........`，runner 校验 rc + 精确锚点。
