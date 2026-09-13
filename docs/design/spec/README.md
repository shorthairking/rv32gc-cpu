# 微架构规格书（Microarchitecture Specification）

本目录把 `docs/design/` 的**方案级**设计细化为**可直接照着写 RTL 的规格**：接口 bundle、表项位域、状态机、算法伪代码、验证判据。

## 阅读顺序

| 顺序 | 文件 | 内容 | 依赖 |
|---|---|---|---|
| 1 | `00-conventions.md` | 全局约定：编码风格、时钟复位、握手/清空协议、参数、目录规划、调试接口 | — |
| 2 | `02-uop-and-decode.md` | **微指令（uop）控制位 72 位定义**、RV32IMAFDC+Zicsr/Zicbom 译码表、RVC 展开、立即数、译码期异常 | 00 |
| 3 | `03-pipeline-regs.md` | 流水级寄存器、**跨模块接口 bundle**、IQ/ROB/LSQ 表项格式、重命名结构、`core_top` 端口 | 00, 02 |
| 4 | `04-frontend.md` | PC 生成、锦标赛 BPU（表项与更新伪码）、I-Cache、取指队列、RVC 对齐 | 00, 02, 03 |
| 5 | `05-ooo-core.md` | 重命名/ROB/发射队列/唤醒选择/PRF/旁路/精确异常与恢复 | 00, 02, 03 |
| 6 | `06-lsu-mem.md` | AGU/LSU/LSQ/转发/重放/D-Cache/MSHR/L2/预取/原子/Cache 维护 | 00, 02, 03 |
| 7 | `07-priv-csr-mmu.md` | 逐 CSR 字段表、异常优先级、trap/`mret`/`sret`、TLB/PTW/PMP、CLINT/PLIC | 00, 02, 03 |
| 8 | `08-bus-axi.md` | AXI 读/写引擎状态机、非缓存通道、地址解码、错误处理、平台集成清单 | 00, 03 |
| 9 | `09-verification-interface.md` | 仿真环境、**提交级 trace 格式（与 Spike 对齐）**、断言清单、测试清单、覆盖率 | 00, 03 |

## 唯一真源（Single Source of Truth）

- **编码与宏**：`rtl/pkg/rv32gc_defs.vh` —— 与 `02-uop-and-decode.md` 的位域一一对应；已用 `iverilog -g2005` 与 `verilator --lint-only` 验证可编译。
- **平台契约**：`../06-bus-axi.md` + `../../kb/01-chiplab-platform.md`（端口、时钟、地址、CONFREG 两套地址）。
- **接口 bundle**：`03-pipeline-regs.md` §2；任何模块不得私自增减跨模块字段。

## 一致性规则（修改时必守）

1. 改 `rv32gc_defs.vh` 的位域 → 必须同步更新 `02-uop-and-decode.md` 的位段表；
2. 改接口 bundle → 必须同步更新 `03-pipeline-regs.md` 与所有消费该 bundle 的子系统规格；
3. 新增/修改异常或 CSR 行为 → 必须以 ISA 规范为依据（用 `kb_search` 查证），并在 `07-priv-csr-mmu.md` 中标注 `path:行号` 出处；
4. 每个子系统规格必须给出**验证判据**（可执行的判据，而非"充分测试"）。

## RTL 开发顺序（与 `00-conventions.md` §8 一致）

```
pkg → alu/mul/div → decoder/imm_gen → csr/trap/clint/plic/pmp
    → icache/dcache/l2/mshr/store_buffer → tlb/ptw → axi_master/uncached
    → pc_gen/bpu/fetch_queue → 【顺序 5 级集成 = 阶段 2A】
    → rat/freelist/rob/iq/prf/lsq/stld → 【4 发射乱序集成 = 阶段 2B】
```
