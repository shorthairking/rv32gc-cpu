# 06 执行域静态审计

## 【结论】

基线 HEAD `b284df704e4b0984cef8fa8062ada01656eca287`，源码树摘要 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`。本轮仅静态读取，**未仿真、未构建、未运行向量**。未发现可据现有证据认定的当前两 top 集成算术确定错误；不能据“3441”测试数或同源金标差分认定全部 IEEE-754 正确。

本域独立条目：**P0=0、P1=3、P2=1**。P1 分别为参数功能失效、公开流水接口结果覆盖风险、关键测试断言缺口；均不提升为当前集成 P0。后端 f0 根因归 02 域，母 Agent 已报告另有动态验证，不重复计数。

## 【变更】

仅新建本报告；产品、测试和其他文档全部只读。

## 【证据】

### 实际读取覆盖

“全读”表示实际读取全文件，不代表形式证明；“抽查”明确未读完。

| 主责文件 | 覆盖 | 实际范围/重点 |
|---|---|---|
| [alu.v](../../../rtl/exec/alu.v) | 全读 | 1–143；回绕、低5位移位、有/无符号比较 |
| [bru.v](../../../rtl/exec/bru.v) | 全读 | 1–144；六比较、PC+imm、JALR清bit0 |
| [exe_ctrl.v](../../../rtl/exec/exe_ctrl.v) | 全读 | 1–167；M>W>RF、排除x0 |
| [mdu.v](../../../rtl/exec/mdu.v) | 全读 | 1–644；两分支、符号修正、状态机/flush |
| [fregfile.v](../../../rtl/exec/fregfile.v) | 全读 | 1–86；f0可写、三读口写优先 |
| [fpu.v](../../../rtl/exec/fpu.v) | 全读 | 1–572；格式/动态rm、派发、有效链、输出选择 |
| [fpu_cmp.v](../../../rtl/exec/fpu_cmp.v) | 全读 | 1–275；NaN、±0、分类、boxing |
| [fpu_cvt.v](../../../rtl/exec/fpu_cvt.v) | 全读 | 1–595；转换范围、先舍入后判域、NV压NX |
| [fpu_div_sqrt.v](../../../rtl/exec/fpu_div_sqrt.v) | 全读 | 1–597；特殊值、迭代、共享round收尾 |
| [fpu_fma_shared.v](../../../rtl/exec/fpu_fma_shared.v) | 全读 | 1–625；S/D注入、精确积、对阶、一次舍入 |
| [fpu_mul.v](../../../rtl/exec/fpu_mul.v) | 全读 | 1–258；保留金标，非当前FMUL路径 |
| [fpu_add.v](../../../rtl/exec/fpu_add.v) | 抽查 | 214–860、1491–1590；当前活跃delay/round/align辅助全读，保留add/FMA金标未读完 |

| 指定测试 | 覆盖 | 实际范围 |
|---|---|---|
| [tb_alu.sv](../../../sim/unit/tb_alu.sv) | 全读 | 1–188 |
| [tb_bru.sv](../../../sim/unit/tb_bru.sv) | 全读 | 1–258 |
| [tb_mdu.sv](../../../sim/unit/tb_mdu.sv) | 全读 | 1–429 |
| [tb_exe_ctrl.sv](../../../sim/unit/tb_exe_ctrl.sv) | 全读 | 1–333 |
| [tb_fregfile.sv](../../../sim/unit/tb_fregfile.sv) | 全读 | 1–298 |
| [tb_fpu.sv](../../../sim/unit/tb_fpu.sv) | 全读 | 1–739（长输出截断后补读690–739） |
| [tb_fpu_cmp_cvt.sv](../../../sim/unit/tb_fpu_cmp_cvt.sv) | 抽查 | 1–180、440–680 |
| [tb_fp_load_use.sv](../../../sim/unit/tb_fp_load_use.sv) | 抽查 | 1–220、470–905；未全读总线/例化部分 |

配套 [fp_load_use.S](../../../sim/unit/prog/fp_load_use.S) 全读；[n15s_fpstress_core.sv](../../../sim/unit/n15s_fpstress_core.sv) 抽查1–180、410–584。两 top/backend仅交叉抽查，不作全域覆盖声称。

### P1-06-01：除法/开方拍数参数实际失效（存量）

位置：[fpu_div_sqrt.v:163–174](../../../rtl/exec/fpu_div_sqrt.v#L163-L174)、[548–580](../../../rtl/exec/fpu_div_sqrt.v#L548-L580)。`SPC_DIV`作为for次数，但每次均读取同一旧寄存器，向同一寄存器非阻塞赋值；重复的是同一步，计数器每拍仍仅减1。`SPC_SQRT`未用于迭代循环。

触发：分别设`FDIV_CYCLES=4/32/128`执行S或D的1/3；`FSQRT_CYCLES`同样扫参执行sqrt(2)。静态推导均109次迭代，加打包/舍入收尾；默认32不能实现注释所称近32拍。**数值不因此改变**，影响参数契约、性能与超时预算，而非已证算术错。

漏测：[tb_fpu.sv:285–296](../../../sim/unit/tb_fpu.sv#L285-L296)只比第二实例结果，拍数打印不判差异；且第二实例计数在第一实例完成后才开始，不是独立完整测量。最小验证：每实例从接收沿独立记到done，断言扫参的规定延迟与相同result/flags。建议删除虚假可配置承诺，或用组合临时状态真正推进多步并正确选择sqrt参数。**修活前必须重审共享round仲裁**：[fpu_fma_shared.v:582–592](../../../rtl/exec/fpu_fma_shared.v#L582-L592)当前显式依赖参数失效所保证的长迭代窗口。

### P1-06-02：SC后接DS时，较早SC的done可能配到DS结果（接口风险）

位置：[fpu.v:286–289](../../../rtl/exec/fpu.v#L286-L289)、[555–569](../../../rtl/exec/fpu.v#L555-L569)。派发门只查DS，不查SC在途；DS派发后`ds_pend=1`，输出立即选DS总线，而`done`仍OR入`sc_done`。

最小触发：E0接收`FADD.S 1+2`，E1接收普通迭代`FDIV.S 1/3`，随后撤请求。第8级SC有效时DS仍在途，`done=1`却输出DS旧寄存结果/flags，而非boxed 3.0。特殊值DS还可能先于旧SC完成，接口亦无标签/队列承载乱序结果。

分层：这是模块允许接收序列下的风险；当前[core_top.v:1231–1233](../../../rtl/top/core_top.v#L1231-L1233)结合[1309–1313](../../../rtl/top/core_top.v#L1309-L1313)和issued位仅一条E指令在途；[backend_top.v:1727](../../../rtl/back2/backend_top.v#L1727)亦由在飞位限制单条FPU，因此**尚无当前集成可达证据**。现有背靠背测试只做SC→SC，DS测试串行等待。最小验证即上述两拍序列，逐条scoreboard比done/result/flags；建议加明确ready并在DS前排空SC，或提供真正结果仲裁/排队。不能仅修改sel优先级掩盖同时完成丢结果。

### P1-06-03：关键握手/动态rm/FMA源测试存在可静态确认的断言空洞

* [tb_mdu.sv:110–123](../../../sim/unit/tb_mdu.sv#L110-L123)仅在`lat+6`窗口内计一次done，不检查准确完成拍；[290–305](../../../sim/unit/tb_mdu.sv#L290-L305)所谓背靠背其实两次完整`run_op`，每次额外等完整窗口。延迟提前/晚数拍及done同拍重启缺陷可能不红。最小验证：逐沿断言done位置、在第一次done同拍重启不同操作数；flush扫S_MUL/S_DIV/S_FIN及结果拍。MDU没有ready，busy也不覆盖S_MUL/S_FIN，不能把busy=0独自当接受许可；当前调用者单在途规避。
* [tb_fpu.sv:177–198](../../../sim/unit/tb_fpu.sv#L177-L198)动态frm任务只检查done与flags，不检查result，且保持req_valid多拍；[721–722](../../../sim/unit/tb_fpu.sv#L721-L722)的1.5在RNE/RUP均为2、NX也相同，动态rm断路可漏测。建议用1.25的RNE=1/RUP=2、相同NX，单拍请求、全值断言并覆盖连续不同frm。
* [tb_fp_load_use.sv:590–594](../../../sim/unit/tb_fp_load_use.sv#L590-L594)的`tb_fpu_use_a`漏`op_fma`。若仅FMA rs1依赖未完成load、rs2/rs3独立，C7不检查a；现有FMA三源同号时b/c可能替代捕获，掩盖a覆盖空洞。最小验证：三源各单独依赖并逐口注错；补入FMA使能。默认`EMU_FETCH_BUFFER=0`且[842–845](../../../sim/unit/tb_fp_load_use.sv#L842-L845)仅在开关打开时强制场景非零，不能把默认PASS当互锁已触发证据。

### P2-06-04：IP分支说明与当前实现不一致

[fpu_div_sqrt.v:46–50](../../../rtl/exec/fpu_div_sqrt.v#L46-L50)及[fpu.v:123–130](../../../rtl/exec/fpu.v#L123-L130)声称综合例化Floating-Point IP，但当前除开方文件完整597行没有该宏分支或IP例化，实际走同一迭代RTL及外部共享round。触发条件为定义/不定义宏后核对层次；不是据旧注释认定综合算错。默认参数在FPU宏分支为1，但由于上条死参数数值行为仍不变。建议同步实现事实与注释，并由IP域核对实际综合层次；本轮没有运行综合。

### 已核查语义与边界（不等于全IEEE证明）

* MDU：32位绝对值保留INT_MIN幅值，MULHSU用64位补码修正；DIV/REM除0、INT_MIN/-1、余数随被除数在[335–375](../../../rtl/exec/mdu.v#L335-L375)统一修正，两分支共用。flush状态优先、done寄存脉冲；未实际验证IP复位最小脉宽/ready。
* ALU/BRU：显式signed比较，移位低5位，地址模32回绕，JALR清bit0；未见局部算术问题。整数RF不在exec目录，exe_ctrl只旁路；浮点f0不应排除，寄存器堆实现正确。backend f0问题归02，勿重复计根因。
* 当前FADD/FSUB/FMUL/FMA均走共享S/D FMA；53×53精确积、110位对阶窗口后一次round，S有效数低29位补0。**保留add/mul/FMA金标未例化不等于功能缺失**；但同文件delay/align/round辅助仍是活跃依赖，不能整体称死代码。
* 特殊值：共享FMA对sNaN置NV，Inf×0即使c为qNaN仍NV；精确抵消RDN给−0，FMUL注入积同号零。div/sqrt区分Inf/0无DZ、有限非零/0有DZ，sqrt(−0)保留负零，负非零NV。subnormal隐藏位为0，无显式flush-to-zero；溢出按方向选Inf/max，UF/NX与tiny逻辑未做独立oracle穷举。
* 非transfer S输入boxing检查、S结果补高32位1；FMV.X.W取原低32位不查box；FCVT.D.S使用检查后的S输入。F2I先舍入再判域，负小数转无符号可得到0+NX，越域/NaN/Inf为NV且压NX。
* rm=111取frm，101/110及保留frm回RNE是实现策略，**不单凭“不陷阱”报错**。本轮CLI取ISA chunk11008（F手册30–133）明确保留rm行为reserved；chunk10997（D手册24–93）确认transfer与非transfer boxing差异，未重建缓存。
* FPU flush清SC valid链、DS状态且组合屏蔽done；结果总线无效拍可陈旧，不单独当bug。2A done在M阻塞期间锁存结果，M浮点前递优先于RF内W写优先：[core_top.v:3318–3336](../../../rtl/top/core_top.v#L3318-L3336)。2B整数写回LSU>MDU>FPU，FPU被挤掉锁存数据；浮点目的有独立写口：[backend_top.v:1771–1786](../../../rtl/back2/backend_top.v#L1771-L1786)。只抽查，不声称全部访存/写回顺序证明。

## 【遗留/风险】

fflags粘滞/冲刷最终精确性跨域：2A在E累积并补年轻flags，2B将flags记录ROB后提交；本轮仅抽查相关代码，未证明所有较老访存异常、CSR写与FP done同拍组合。N15 stress提交比较仅32位，不能独自证明D高32位或完整fflags；存储字节检查只覆盖实际store出的结果。未运行任何已有脚本、变异、随机向量、独立SoftFloat/Spike差分，未核实注释历史“0失配”声称。

已执行的只读核对：`pwd`、`git rev-parse HEAD`；按BASELINE逐项SHA-256核对12个exec和8个指定TB，输出20/20 MATCH；上述路径`git diff --stat`为空。来源查询使用`node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search/get`，没有重建KB。未读完范围如覆盖表，不以全局“未发现”替代遗漏验证。
