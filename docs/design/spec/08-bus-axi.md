# SPEC-08 总线子系统（AXI4 主设备、地址解码、非缓存通道与平台集成）

> 上游：`00-conventions.md`（握手/命名/参数/时钟复位）、`03-pipeline-regs.md` §2.7/§2.8（CSR 与 LSU↔Cache/AXI 接口）、`../06-bus-axi.md`（平台契约）、`../03-cache.md`（L1/L2/MSHR/Victim/非缓存）、`../07-fpga-timing.md`（时序预算）。
> 平台依据（**只读，不得修改 `chiplab/` 下任何文件**）：`chiplab/docs/Quick-Start.md:72-131`（`core_top` 端口）、`chip/soc_demo/loongson/soc_top.v:723-776`（CPU 例化）、`:779-989`（读 mux + 时钟桥）、`:992-1220`（`axi_slave_mux`）、`config.h`（`LID/Lawlen/Lwdata…`）、`IP/AMBA/axi_mux_syn.v:854-860,946-951`（平台译码）。
> 范围：`rtl/bus/addr_decode.v`、`rtl/bus/axi_master.v`（读引擎+写引擎+L2↔AXI 桥）、`rtl/bus/uncached_unit.v`、`core_top` 端口绑定与平台集成清单。需其他已发布文件配合处（新增宏、AXI 端口归属、非缓存策略）不直接改动它们，登记在 §9.5。

---

## 1. 平台 AXI 契约复核表
### 1.1 `core_top` 侧信号（与 `soc_top.v:723-776` 逐位一致）

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `aclk` / `aresetn` | I | 1 / 1 | CPU 时钟（现 50 MHz，本项目目标 100 MHz）；低有效复位，平台已 2 级同步（`soc_top.v:600-610`） |
| `intrpt` | I | **8** | `[0]`=MAC `[1]`=UART0 `[2]`=SPI `[3]`=NAND `[4]`=DMA，`[7:5]`=0 → 核内 PLIC 源 1~5 |
| `arid` / `araddr` / `arlen` | O | **4** / 32 / **4** | 读 ID / 物理地址 / 突发长度；**平台 `LID=4`、`Larlen=4`**，`arlen ≤ 4'd15` |
| `arsize` / `arburst` / `arlock` / `arcache` / `arprot` / `arvalid` | O | 3/2/2/4/3/1 | `size=3'b010`、`burst=2'b01`、`lock=2'b00`；`cache/prot` 平台**原样透传不解释**（§1.4） |
| `arready` | I | 1 | 读地址握手 |
| `rid` / `rdata` / `rresp` / `rlast` / `rvalid` | I | **4** / **32** / 2 / 1 / 1 | `rdata` 在 `` `AXI64 ``/`` `AXI128 `` 时为 64/128；平台所有从设备 `rresp` 恒 `2'b00` |
| `rready` | O | 1 | 本核恒 1（§3.5） |
| `awid` / `awaddr` / `awlen` | O | **4** / 32 / **4** | 同读侧；`awlen ≤ 4'd15` |
| `awsize` / `awburst` / `awlock` / `awcache` / `awprot` / `awvalid` | O | 3/2/2/4/3/1 | 同读侧 |
| `awready` / `wready` | I | 1 / 1 | 写地址 / 写数据握手 |
| `wid` / `wdata` / `wstrb` / `wlast` / `wvalid` | O | **4** / **32** / **4** / 1 / 1 | AXI3 风格 `wid`，**必须等于对应 `awid`**；64/128 配置下为 4/64/8、4/128/16 |
| `bid` / `bresp` / `bvalid` | I | **4** / 2 / 1 | `bresp` 平台恒 `2'b00` |
| `bready` | O | 1 | 本核恒 1（§4.4） |
| `ws_valid` / `rf_rdata` | O | 1 / 32 | 调试：提交级"写寄存器"脉冲 / 按 `reg_num` 读回的架构寄存器值 |
| `break_point` / `infor_flag` / `reg_num` | I | 1 / 1 / 5 | 断点请求 / 寄存器读请求 / 寄存器号 |
| `debug0_wb_pc` / `debug0_wb_rf_wnum` / `debug0_wb_rf_wdata` | O | 32 / 5 / 32 | 平台 difftest 与 TB 主观测点 |
| `debug0_wb_rf_wen` | O | **4** | 平台 FPGA 侧 wire 为 `[3:0]`（`soc_top.v:614`）→ 本核填 `{3'b0, wen}` |

> 未使用：`nmi`（各 SoC 均注释，`soc_top.v:726`）、`debug1_wb_*`（仅 `` `CPU_2CMT `` 时存在，本项目 `CPU_2CMT=n`）。`Quick-Start.md:80,98` 把 `arlen/awlen` 写作 `[7:0]`，但所有 SoC 连线与 `config.h` 均为 4 位 → **本设计声明 4 位**且保证 $\le 15$。

### 1.2 突发参数与数据宽度（`` `AXI_DATA_W ``/`` `AXI_STRB_W ``，`rv32gc_defs.vh:70-86`）

| 访问类型 | `len` | `size` | `burst` | beat × 每拍字节 |
|---|---|---|---|---|
| 32 B 行填充/写回（默认 AXI32 / `` `AXI64 `` / `` `AXI128 ``） | `4'd7` / `4'd3` / `4'd1` | `3'b010` / `3'b011` / `3'b100` | `2'b01` | 8×4 B / 4×8 B / 2×16 B |
| 非缓存设备访问（单拍） | `4'd0` | `3'b010` | `2'b01` | 1 × 4 B |

**硬约束**：① `arlen/awlen ≤ 4'd15`；② 突发不得跨 4 KB 边界——32 B 行天然 32 B 对齐、设备访问 4 B 对齐，均满足，仍按 §8.3 断言检查；③ 行访问 `len+1 == `AXI_BEATS_PER_LINE`。

### 1.3 平台侧拓扑与不变量（`soc_top.v:779-1220`）

```
core_top ──AR/R──► axi_2x1_mux ──m1_*──┐ （S01 = debug_sram：UART 在线调试加载器，与 CPU **争用读通道**）
   │ m0_*（S00 的 AW/W/B 全接 1'b0）    │
   └──AW/W/B──────────────────────────►┤
                                       ▼
        axi_clock_converter_0   cpu_clk(50/100 MHz) → aclk(33 MHz)   ← 平台负责 CDC
                                       │ m0_async_*
                                       ▼
        axi_slave_mux（axi_mux_syn.v，5 从设备，default→DDR）
  s0→MIG DDR3(0x0000_0000)  s1→SPI(0x1fe8/0x1c0)  s2→APB(UART 0x1fe0 / NAND 0x1fe7)
  s3→confreg(0x1fd0)        s4→MAC(0x1ff0)
```

1. **单主端口**：只有一组 AR/R/AW/W/B，没有第二路，没有分离 I/D 或 uncached 端口。
2. **读写路径不对称**：写通道**直连**时钟桥，读通道经 `axi_2x1_mux` 与调试加载器仲裁 → 不得假设 AW 与 AR 延迟/顺序一致。
3. 平台**不解释** `cache/prot`、**不产生 `resp≠00`** → 不能用错误响应探测未映射地址（必须核内解码，§2.3）；平台**不合成 ID**，`RID/BID` 原样回显。
4. `axi_2x1_mux.INTERCONNECT_ARESETN=resetn`（板级异步）而时钟桥用已同步的 `cpu_aresetn` → 核内仍自建 2 级同步。

### 1.4 属性位取值（平台不解释，但按 AXI 规范编码，便于 ILA 与复用）

| 访问 | `arcache/awcache` | `arprot/awprot` |
|---|---|---|
| 行填充 / 写回 | `4'b1111`（Write-back, R/W allocate） | `{1'b0, 1'b1, priv != PRV_U}` |
| 设备访问（强序非缓冲） | `4'b0000`（**Device Non-bufferable**） | 同上 |
| `arlock/awlock` | 恒 `2'b00`（不用总线锁定，避免与 DMA/MAC 主设备互锁） | — |

> 与 `../06-bus-axi.md` §2.1 的差异：该文设备访问写 `4'b0010`（= Normal Non-cacheable）；本规格按 AXI 编码改为 `4'b0000`。平台不解释该位，无功能影响（§9.5 R1）。

---

## 2. 地址解码 `addr_decode.v`
### 2.1 解码表（物理地址；宏见 `rv32gc_defs.vh:114-128`）

| 窗口 | 区间 | 属性 | 取指 | load/store | 去向 |
|---|---|---|---|---|---|
| DDR3 | `0x0000_0000`–`0x07FF_FFFF`（128 MiB） | **可缓存**（写回+写分配） | ✅ | ✅（含 AMO/LR/SC） | L2→AXI，ID 0/1/2 |
| SRAM / SPI-XIP | `0x1C00_0000`–`0x1C0F_FFFF`（1 MiB） | **可缓存** | ✅ | ✅ | L2→AXI，ID 0/1/2 |
| CONFREG（FPGA / 仿真） | `0x1FD0_0000`–`0x1FD0_FFFF` / `0x1FAF_0000`–`0x1FAF_FFFF`（各 64 KiB） | **非缓存/强序** | ❌ cause 1 | ✅ | uncached，ID 3 |
| UART0 / NAND | `0x1FE0_0000`–`0x1FE0_3FFF`（16 KiB，寄存器 `+0x1E0`）/ `0x1FE7_8000`–`0x1FE7_BFFF`（16 KiB，数据口 `+0x40`） | **非缓存/强序** | ❌ cause 1 | ✅ | uncached，ID 3 |
| SPI / MAC | `0x1FE8_0000`–`0x1FE8_FFFF`（64 KiB）/ `0x1FF0_0000`–`0x1FF0_FFFF`（64 KiB） | **非缓存/强序** | ❌ cause 1 | ✅ | uncached，ID 3 |
| **CLINT（核内）** | `0x1F00_0000`–`0x1F00_FFFF`（64 KiB） | 核内截获 | ❌ | 核内 CSR 通路 | **不下 AXI** |
| **PLIC（核内）** | `0x1F10_0000`–`0x1F1F_FFFF`（1 MiB） | 核内截获 | ❌ | 核内寄存器 | **不下 AXI** |
| 其它（未映射） | 全部剩余空间 | **不可访问** | ❌ cause 1 | ❌ cause 5/7 | **不下 AXI** |

- AMO/LR/SC 只允许落在**可缓存**窗口；设备窗口上的 `lr.w/sc.w/amo*.w` 由 PMA 检查判为访问错误（LR→cause 5，SC/AMO→cause 7），不发起 AXI（本平台无总线锁定能力，A 扩展要求可原子访问的 PMA）。
- 设备窗口**不允许取指**（读设备寄存器有副作用：16550 RBR/IIR 读清、NAND 数据口、MAC 描述符、仿真 `VIRTUAL_UART`）→ IF2 直接报 cause 1，`mtval`=取指 PC。
- 核内解码比平台**更窄**：平台按 `addr[31:16]` 粗译码（`0x1fe0/0x1fe7/0x1fd0` 整块）且 `default→DDR`；本核用上表精确窗口（`0x1FE0_4000-0x1FE0_FFFF` 在平台上也会落到 APB，本核**不承认**该别名）。

### 2.2 端口与伪代码

```verilog
module addr_decode (
  input  wire [31:0] paddr, input wire [2:0] mem_op,   // mem_op: MEM_LOAD/STORE/LR/SC/AMO
  output wire [2:0]  region,      // 0=DDR 1=SRAM/XIP 2=DEV 3=CLINT 4=PLIC 5=ILLEGAL
  output wire        cacheable, uncached, in_core, illegal, amo_ok, is_fetch
);
```

```text
region = 5 /*ILLEGAL*/;                      // 全部为前缀常量比较，深度 ≤2 级 LUT（与 TLB 并行）
if      (paddr[31:27]==5'b00000)                              region=0; // DDR 128 MiB
else if (paddr[31:20]==12'h1C0)                               region=1; // SRAM / SPI XIP
else if (paddr[31:16]==16'h1FD0 || paddr[31:16]==16'h1FAF)    region=2; // CONFREG（FPGA/仿真）
else if (paddr[31:16]==16'h1FE0 && paddr[19:14]==6'h00)       region=2; // UART 16 KiB
else if (paddr[31:16]==16'h1FE7 && paddr[19:14]!=6'h00)       region=2; // NAND 16 KiB
else if (paddr[31:16]==16'h1FE8 || paddr[31:16]==16'h1FF0)    region=2; // SPI / MAC
else if (paddr[31:16]==16'h1F00)                              region=3; // CLINT 核内
else if (paddr[31:20]==12'h1F1)                               region=4; // PLIC 核内
```

### 2.3 非法与越界访问的处理（**关键**）

平台 `axi_slave_mux` 只列出 5 个从设备，`default` 通路是 DDR（`axi_mux_syn.v:854-860`）：未映射地址（如 `0x8000_0000`）**不会被拒绝**，可能被 MIG 静默接受、回绕或永不响应。

| 情形 | 处理 | 上报 |
|---|---|---|
| 未映射地址（`region=5`） | 不下 AXI，LSU/PTW 直接产生响应 | 取指 cause 1 / load cause 5 / store·AMO cause 7，`mtval`=出错地址 |
| 设备窗口取指、CLINT/PLIC 取指 | IF2 拦截，不分配 MSHR | cause 1，`mtval`=取指 PC |
| 设备窗口 AMO/LR/SC | PMA 检查拦截 | cause 5（LR）/ cause 7（SC、AMO） |
| 突发跨 4 KB | 仿真断言失败；综合后不可能发生 | — |

---

## 3. AXI 读引擎 `axi_rd_engine.v`
### 3.1 端口

```verilog
module axi_rd_engine (
  input  wire clk, rst_n,
  // 请求（来自 L2 Refill Buffer / uncached_unit，仲裁见 §6.4）
  input  wire rd_req_valid, output wire rd_req_rdy,            // rdy = 读表有空项
  input  wire [31:0] rd_req_addr, input wire [3:0] rd_req_id,  // ID: 0/1/3（§6.3）
  input  wire rd_req_len_mode,                                 // 0=行(8/4/2 beat) 1=单拍
  input  wire [3:0] rd_req_tgt, input wire rd_req_tgt_is_uc,   // 目标 L2 Refill Buf / UC 索引
  // 回填（逐拍写 L2 行缓冲或 UC 数据寄存器）
  output wire fill_valid, output wire [3:0] fill_tgt, output wire fill_tgt_is_uc,
  output wire [4:0] fill_byte_off, output wire [`AXI_DATA_W-1:0] fill_data,
  output wire fill_last, fill_err,
  // 错误与状态
  output wire rd_err_valid, output wire [3:0] rd_err_tgt, output wire [1:0] rd_err_resp,
  output wire rd_idle,                                         // 读表全空
  // AXI 侧端口 = §1.1 的 arid/araddr/arlen/arsize/arburst/arlock/arcache/arprot/arvalid/arready
  //   + rid/rdata/rresp/rlast/rvalid/rready，位宽与方向逐位一致（`rready` 恒 1，§3.5）
);
```

### 3.2 状态机（每表项 `rd_state`，3 bit；通道由"存在 `RD_AR_ISSUE` 项"驱动）

```
   ┌──────────┐ 分配表项/有请求   ┌────────────┐ arvalid&&arready ┌───────────┐
   │ RD_IDLE  │──────────────────►│ RD_AR_ISSUE│─────────────────►│ RD_R_BEAT │
   │  3'd0    │                   │   3'd1     │  入 ID FIFO 尾   │   3'd2    │
   └──────────┘                   └────────────┘                  └─────┬─────┘
        ▲                                        收满 len+1 拍且 rlast 对 │
        │ 释放表项（出 ID FIFO）        ┌───────────┐                    │
        ├───────────────────────────────│ RD_R_DONE │◄───────────────────┘
        │                               │   3'd3    │
        │        ┌───────────┐ resp≠00 / rlast 错位 / 超时
        └────────│ RD_ERROR  │◄────────────────────────────────────────────
                 │   3'd4    │ 已上报；drop=1 时保持 ID FIFO 头直到 rlast
                 └───────────┘
```

- 同一时刻最多 1 项处于 `RD_AR_ISSUE`；多个表项可同时在 `RD_R_BEAT`，但**同一 ID 的数据按 AR 顺序返回**，故 R 通道只与各 ID 队头比较。
- `RD_R_DONE` 持续 1 拍：向目标发 `fill_last`，然后释放表项。

### 3.3 读表表项 `rd_entry_t`（`AXI_RD_TBL_DEPTH=8`）

| 字段 | 位宽 | 说明 |
|---|---|---|
| `valid` / `state` | 1 / 3 | 占用；§3.2 编码 |
| `id` / `addr` / `len` / `size` | 4 / 32 / 4 / 3 | 已发出的 AR 参数（`1<<size` = 每拍字节数） |
| `beat_cnt` | 4 | 已接收 beat 数（校验 `rlast`） |
| `byte_off` | 5 | 行内字节偏移 = 回填写指针 / UC 车道选择（每拍 `+= 1<<size`） |
| `tgt` / `tgt_is_uc` | 4 / 1 | 目标：L2 Refill Buffer 索引（4 项，`06-lsu-mem.md` §5.4）+ 源标记；或 UC 读队列索引（`tgt_is_uc=1`） |
| `src` | 2 | 0=I-fetch 1=D-refill 3=device（错误归因，§8.1） |
| `drop` / `err` / `resp` | 1 / 1 / 2 | flush·超时后丢弃（仍需吸收到 `rlast`）/ 错误 / AXI 响应码 |
| `tmo_cnt` | 16 | 无进展超时计数（§3.5） |

**ID FIFO**：每 ID 一个循环队列（8 项 × 3 bit 索引 + head/tail），入队序 = AR 发出序 → 保证同 ID 数据按序归属；只比较 4 个队头，不做全表搜索。
**容量关系**：`AXI_RD_TBL_DEPTH=8` 是**容量上限**（本规格要求"最多 8 个未完成突发"）。L2 侧已发布为 **Refill Buffer 4 项 + Victim Buffer 4 项**（`06-lsu-mem.md` §5.4），故稳态占用 ≤ 4（refill）+ 1（设备保留槽）+ 1（预取）= 6；8 项留作余量。若要把并发做满 8，L2 的 Refill Buffer 需扩到 8 并同步 `tgt` 位宽（§9.5 R2）。

### 3.4 按 `RID` 分发伪代码

```text
rready = 1'b1;                                    // 恒能接（L2 有专用回填端口，见 §3.5）
if (rvalid) begin
  if (id_fifo[rid] 非空) begin
    e = id_fifo[rid].head;
    if (!rd[e].drop) begin                        // drop：flush/超时后回来的数据直接丢
      fill_valid=1'b1; fill_tgt=rd[e].tgt; fill_tgt_is_uc=rd[e].tgt_is_uc;
      fill_byte_off=rd[e].byte_off; fill_data=rdata; fill_last=rlast;
      fill_err = (rresp != 2'b00);
    end
    rd[e].beat_cnt <= rd[e].beat_cnt + 1;
    rd[e].byte_off <= rd[e].byte_off + (1 << rd[e].size);
    if (rresp != 2'b00) rd[e].err <= 1'b1;
    if (rlast) begin
      if (rd[e].beat_cnt != rd[e].len) protocol_err(rid);   // 早到/晚到
      rd[e].state <= rd[e].err ? RD_ERROR : RD_R_DONE;
      id_fifo[rid].pop();
    end
  end else protocol_err_unexpected_beat(rid);     // 无对应表项：吸收并报错
end
```

### 3.5 `rlast` 校验、错误与超时

| 事件 | 判定 | 动作 |
|---|---|---|
| `rlast` 早到（`beat_cnt < len`） | 收到 `rlast` 时比较 | 转 `RD_ERROR`，`resp` 记 `2'b11`；已收数据仍送回填缓冲（该行标无效） |
| `rlast` 缺失（`beat_cnt > len`） | 第 `len+1` 拍后仍无 `rlast` | 断言报错；继续吸收到 `rlast`（`drop=1`）以免总线失步 |
| `resp ≠ 2'b00` | 每拍检查 | `err=1`；**AXI 要求 `rlast` 前不能中断**，故吸收完本突发后在 `RD_ERROR` 上报 |
| 超时（无进展） | `tmo_cnt` 在 AR 接收时清零、每收到该 ID 的 beat 清零；达 `AXI_TIMEOUT_CYCLES`（默认 4096 ≈ 41 µs @100 MHz） | 转 `RD_ERROR`+`drop=1`，报访问错误；表项在 `rlast` 后释放。**不得用该计数推断平台频率**（§7） |
| flush 期间的在途突发 | `flush_all` 广播 | 该 ID 表项置 `drop=1`：**AXI 无取消机制**，必须吸收完再释放（前端 MSHR 已丢弃，二者解耦） |

`rready` 恒 1 的前提：L2 为回填提供**专用写端口**，UC 读数据只需 1 个寄存器（单 R 通道每拍最多 1 拍数据）。若 L2 无法保证，则加 2 项 R skid buffer，`rready = !skid_full`。

---

## 4. AXI 写引擎 `axi_wr_engine.v`
### 4.1 端口

```verilog
module axi_wr_engine (
  input  wire clk, rst_n,
  // 请求：victim 写回（数据在 L2 victim buffer）与设备写
  input  wire wr_req_valid, output wire wr_req_rdy,                // rdy = 写表有空项
  input  wire [31:0] wr_req_addr, input wire [3:0] wr_req_id,      // 2=writeback 3=device
  input  wire [1:0] wr_req_buf_idx,                                // victim buffer / UC 索引
  input  wire [3:0] wr_req_wstrb, input wire wr_req_last,          // 仅设备写用
  // victim buffer 读端口（32 B 行 → wb_stage_q[255:0]）
  output wire [1:0] wb_rd_idx, output wire wb_rd_req, input wire [`CACHE_LINE_BITS-1:0] wb_rd_data,
  // 完成 / 错误
  output wire wr_done_valid, output wire [1:0] wr_done_idx,
  output wire wr_err_valid, output wire [1:0] wr_err_idx, wr_err_resp, output wire wr_idle,
  // AXI 侧端口 = §1.1 的 awid/awaddr/awlen/awsize/awburst/awlock/awcache/awprot/awvalid/awready
  //   + wid/wdata/wstrb/wlast/wvalid/wready + bid/bresp/bvalid/bready，位宽方向逐位一致
);
```

### 4.2 状态机（每表项 `wr_state`；通道状态机同名）

```
   ┌──────────┐ 取最老 pending 项  ┌────────────┐ awvalid&&awready ┌───────────┐
   │ WR_IDLE  │──────────────────►│ WR_AW_ISSUE│─────────────────►│ WR_W_BEAT │
   │  3'd0    │                   │   3'd1     │   aw_done=1      │   3'd2    │
   └──────────┘                   └────────────┘                  └─────┬─────┘
        ▲                                       wlast&&wready → w_done=1 │
        │ 收到 B（bid 匹配、resp=00）                                     ▼
        │        ┌────────────┐                          ┌───────────────────┐
        └────────│ WR_B_WAIT  │◄─────────────────────────│ 入 b_wait FIFO[bid]│
                 │   3'd3     │ resp≠00 / 超时 → WR_ERROR └───────────────────┘
                 └────────────┘
```

- **流水重叠**：`WR_AW_ISSUE`（最老 pending 项）与 `WR_W_BEAT`（最老 `aw_done && !w_done` 项）**可同拍并存**（AW/W 通道独立），`WR_B_WAIT` 最多 4 项 → 这就是"最多 4 个未完成写"的来源。
- **W 数据所有权**：同一时刻只有 1 项在发 W beat（不做 AXI3 写数据交织），故 `wid = 当前 W owner 的 awid`，天然满足 `wid==awid`。

### 4.3 写表表项 `wr_entry_t`（`AXI_WR_TBL_DEPTH=4`）与写数据分片

| 字段 | 位宽 | 说明 |
|---|---|---|
| `valid` / `aw_done` / `w_done` / `state` | 1/1/1/3 | 占用 / AW 已接收 / W 已发完 / §4.2 编码 |
| `id` / `addr` / `len` / `size` | 4 / 32 / 4 / 3 | 2=writeback、3=device |
| `beat_cnt` / `buf_idx` | 4 / 2 | 已发出的 W beat 数（= 第 `beat_cnt` 片）/ victim buffer 或 UC 写索引 |
| `wstrb_mask` | 4 | 设备写字节掩码；行写回忽略（恒全 1） |
| `err` / `resp` / `tmo_cnt` | 1 / 2 / 16 | 错误 / 响应码 / 超时（同 §3.5） |

```text
// ① 行写回启动前：wb_rd_req 读 victim buffer → wb_stage_q[255:0]（BRAM 读 1 拍 + 寄存 1 拍）
// ② 每个 W beat（默认 AXI32 ⇒ 8 beat × 4 B）：
slice = beat_cnt * `AXI_STRB_W;                  // 4B:0..28  8B:0,8,16,24  16B:0,16
wdata = wb_stage_q[slice*8 +: `AXI_DATA_W];      // 行写回：整片，wstrb 全 1
wlast = (beat_cnt == len);
// 设备写（单拍、4 B 对齐）：
lane  = addr[1:0] % (`AXI_STRB_W/4);             // AXI32:a[1:0]  AXI64:a[2:0]  AXI128:a[3:0]
wdata = {`AXI_DATA_W{1'b0}}; wdata[lane*32 +: 32] = uc_wdata;
wstrb = uc_wstrb << (lane*4);
```

`awaddr` = 行访问 `{addr[31:5],5'b0}`、设备访问 `{addr[31:2],2'b0}`；8 beat × 4 B 天然 32 B 对齐，不跨 4 KB。

### 4.4 `B` 响应匹配与异常情形

| 情形 | 处理 |
|---|---|
| 正常 | `bready = 1'b1`（恒收，避免平台被挂住）。B 到达时匹配 **`b_wait_fifo[bid]` 队头**（入队序 = AW 发出序 → 满足"同一 ID 响应顺序 = AW 顺序"），释放表项并发 `wr_done_valid` |
| **B 早于本项 W 数据** | 对**同一事务**不可能（AXI 要求 `BVALID` 在该事务最后一拍 W 被接收后才可拉高）；但**跨事务**完全可能：AW(k+1) 已发出、W(k+1) 正在发送时 `B(k)` 已返回 → 故 B 只与 `b_wait_fifo` 头（仅在 `aw_done && w_done` 时入队）匹配，而非"最老表项" |
| B 无匹配表项 | 协议违规：吸收该 B（保持 `bready`），置 `protocol_err`，计入 `mberrstat`（§8.2） |
| `bresp ≠ 2'b00` | 写回（ID2）**数据已提交、丢失**：无法精确归因 → 只记机器级错误（§8.2）；设备写（ID3）→ 报 cause 7（提交门控保证尚未提交，§5.2） |
| 超时 / `flush_all` | 超时 → `WR_ERROR`，停发剩余 W beat，上报 §8 并释放表项。flush **不得**清空写表项（已发出的 AW/W 不可撤回，否则 B 无处匹配）；victim buffer 由 `wr_done_valid` 释放 |

---

## 5. 非缓存通道 `uncached_unit.v`
### 5.1 端口与请求队列

```verilog
module uncached_unit (
  input  wire clk, rst_n,
  // ── 来自 LSU（提交门控后，§5.2）──
  input  wire uc_req_valid, output wire uc_req_rdy,        // 命名与 `06-lsu-mem.md` §2 一致（*_rdy）
  input  wire uc_req_we, input wire [31:0] uc_req_addr, uc_req_wdata,
  input  wire [3:0] uc_req_wstrb, input wire [1:0] uc_req_size, input wire uc_req_unsigned,
  input  wire [4:0] uc_req_lsq_idx, input wire [6:0] uc_req_rob_idx,
  // ── 到 AXI 桥（单拍读写）──
  output wire uc_axi_req_valid, input wire uc_axi_req_rdy,
  output wire uc_axi_req_we, output wire [31:0] uc_axi_req_addr, uc_axi_req_wdata,
  output wire [3:0] uc_axi_req_wstrb,
  input  wire uc_axi_resp_valid, input wire [31:0] uc_axi_resp_rdata, input wire [1:0] uc_axi_resp_resp,
  // ── 回给 LSU / ROB ──
  output wire uc_resp_valid, output wire [31:0] uc_resp_rdata,
  output wire uc_resp_fault, output wire [3:0] uc_resp_cause,
  output wire [4:0] uc_resp_lsq_idx, output wire [6:0] uc_resp_rob_idx,
  output wire uc_idle                                             // 队列空且无在途（供 fence）
);
```

**队列**：`UC_Q_DEPTH=4`，FIFO，**严格串行**（`UC_OSTD=1`：前一个响应返回后才发起下一个）。由此：
- **同地址保序**自动成立（不存在同一时刻的两个设备事务）；**读写之间的保序**也成立（younger write 不会越过 older read 到达设备）；
- ID=3 最多 1 个未完成 → `RID/BID=3` 的分发只需 1 个寄存器，不需要 FIFO；
- 深度 4 的用途：① 一条非对齐访问按 `mem_size` 拆成最多 2 个单拍请求；② 反压期间吸收 LSU 侧请求。因提交门控，**稳态占用 ≤2**。
- **挂接点**：本文件按"UC 直接进 AXI 桥"给出 `uc_axi_*` 端口；若按 `06-lsu-mem.md` §5.3 把非缓存归入 L2 **源 3（非缓存/维护）**，则把该组端口换成 `l2_req_*` 的源 3 位（`l2_req_valid[3]`/`l2_req_rdy[3]`/`l2_rsp_*`），其余逻辑不变（见 §9.5 R11）。

### 5.2 "设备访问不投机"的明确定义（**提交门控**）

> **定义**：设备窗口的 load/store 在到达 **ROB 头部**（`lsq_entry.rob_idx == rob_head_idx && rob_entry.done && !excp && !flush`）之前，**不产生任何 AXI 事务**；`uc_req_valid` 只在该条件下拉高。ROB 在该指令提交前等 `uc_resp_valid`：设备访问的**执行**就发生在提交点，提交与副作用之间没有窗口。（与 `06-lsu-mem.md` §7 的差异与取舍见 §9.5 R10。）

| 理由 | 说明 |
|---|---|
| ① 设备读不幂等 | 16550 `RBR/IIR` 读清、NAND 数据口、MAC 描述符、仿真 `VIRTUAL_UART/IO_SIMU`、CONFREG `TIMER`：投机发起后被清空（误预测/trap/`fence.i`）**无法回滚**，会丢字节/丢中断/丢退出码 |
| ② 设备写不可撤回 | AXI4（本平台 AXI3 风格 + 时钟桥）**没有取消机制**，投机写会在设备上留下假写 |
| ③ 异常精确 | 门控天然给出 RT 级精确异常（`trap_valid/trap_cause/trap_tval`，`03-pipeline-regs.md` §2.7），不需要"悬挂异常 + 重放" |
| ④ 代价可接受 | 设备访问只在启动/轮询/调试路径；入队到 AXI 发起仅 1~2 拍；乱序核仍可**执行**更年轻的独立指令，只是不能提交 |

**明确拒绝的替代方案**：MEM 级投机发起 + 响应缓存；MEM 级发起 + 清空时丢弃响应；只对写做投机（读仍投机）——三者都无法满足 ①/②。**可缓存**窗口的 load/store 仍按常规投机执行（内存幂等）。

### 5.3 读数据对齐/拼接与写字节使能

```text
lane = uc_req_addr[1:0];                     // AXI32；AXI64 用 [2:0]，AXI128 用 [3:0]
case (uc_req_size)
  MSZ_BYTE: b = uc_axi_resp_rdata[lane*8 +: 8];
            uc_resp_rdata = uc_req_unsigned ? {24'b0,b} : {{24{b[7]}},b};
  MSZ_HALF: h = uc_axi_resp_rdata[lane*8 +: 16];
            uc_resp_rdata = uc_req_unsigned ? {16'b0,h} : {{16{h[15]}},h};
  MSZ_WORD: uc_resp_rdata = uc_axi_resp_rdata[lane*32 +: 32];
endcase
// 非对齐（如 LH 在 addr[1:0]==3）：LSU 拆成 2 个请求（跨 4 B 边界），本单元按序返回、由 LSU 拼接
// 写：wstrb 由 LSU 生成（BYTE:4'b0001<<a[1:0]  HALF:4'b0011<<a[1:0]  WORD:4'b1111），wdata 放 lane 车道（§4.3）
// 响应字段：uc_resp_rdata→LSU 的 WBP_LSU 写回口；uc_resp_fault/cause→RT 的 trap_valid（cause 5/7）
```

### 5.4 与 `fence`/`cbo` 的交互

| 指令 | 提交级动作 | 等待信号 |
|---|---|---|
| `fence`（含 `rw,rw`） | 等 ① 更老 store 写入 L1D/L2；② 无在途设备访问；③ 写表空 + victim 队列空（更老写全局可见） | `uc_idle && axi_wb_idle` |
| `fence.i` | 等 I-fetch 突发全部吸收完（前端可先丢 MSHR）→ 再清 L1I + 取指队列 | `rd_idle`（I 类） |
| `cbo.clean/flush` | 脏行写回由 victim 通路完成；保守等全部写回 | `axi_wb_idle` |
| `cbo.inval` | 无需等总线；若该行有在途 refill，先置 `drop` | `rd_idle` |
| `sfence.vma` | 与总线无关（TLB 维护） | — |

> `axi_wb_idle` 是保守判据（全清空而非按地址过滤）：省掉地址比较阵列，代价是少数额外等待；若实测影响 CoreMark，再按地址区间过滤优化。

---

## 6. L2 ↔ AXI 桥 `axi_bridge.v`
### 6.1 结构

```
 L1I 缺失 ─┐                                ┌─ refill_q (4) ─┐
 L1D 缺失 ─┼─► L2 (256KB PIPT 8way) ─ miss ─┤                ├─► 读引擎(8 表项) ─► AR/R
 设备访问 ─┘        │      ▲                └─ Refill Buf(4) ┘
                    │      └── 回填 fill_valid/tgt/byte_off/data
                    └─ victim ─► victim_q (4) ─► 写引擎(4 表项) ─► AW/W/B
                       （32 B 行 + 索引）        保留槽：读表项 7 / 写表项 3 归设备
```

- **Refill Buffer（L2 侧）**：4 项 `{tag, set, way, 源/ID, beat_cnt, data[255:0], err}`（`06-lsu-mem.md` §5.4）；`tgt` = 该缓冲索引 + 源标记。回填按 `byte_off` 把 4 B 片写入 `data`，`fill_last` 时整行写 L2 阵列并唤醒等待的 L1I/L1D。
- **Victim 队列**：4 项 `{valid, paddr[31:5], vbuf_idx[1:0]}`，数据留在 L2 Victim Buffer（4 × 32 B），写引擎用 `wb_rd_*` 读走整行后才释放。

### 6.2 对 L2 的反压信号

| 信号 | 方向 | 含义 |
|---|---|---|
| `l2_rf_valid/rdy` | L2→桥 / 桥→L2 | refill 请求；`rdy = !refill_q_full`（由读表空位驱动排空） |
| `l2_wb_valid/rdy` | L2→桥 / 桥→L2 | victim 写回；`rdy = !victim_q_full` |
| `l2_rf_full` / `l2_wb_full` | 桥→L2 | 队列将满告警（留 1 项余量），供 L2 提前反压 |
| `l2_rf_stall` / `l2_wb_stall` | 桥→L2 | 第 1 级流水判满 → L2 停在当前请求（不回退指针） |

**反压链**：读表满(8) → `refill_q` 满(4) → L2 Refill Buffer 满(4) → `l2_req_rdy[3:0]` 拉低（`06-lsu-mem.md` §5.2）→ L1I/L1D MSHR 分配失败 → 前端冻结/发射停顿；写表满(4) → `victim_q` 满(4) → L2 Victim Buffer 无空位 → 替换停顿 → store 提交停顿。链上每级都有容量上界，反压**必然终止**（无活锁）。

### 6.3 ID 分配表

| ID | 用途 | `len` | 读写 | 最大未完成 |
|---|---|---|---|---|
| `4'd0` | I-fetch refill（L1I 缺失经 L2） | 行 | 只读 | 受读表总容量约束 |
| `4'd1` | D-refill（L1D/L2 数据缺失） | 行 | 只读 | 同上 |
| `4'd2` | victim 写回（L1D/L2 脏行） | 行 | 只写 | ≤4 |
| `4'd3` | 非缓存设备访问 | `4'd0` | 读写 | **≤1**（§5.1） |

- ID 在请求入队时由**源**决定；`wid = awid`。
- 读表项 7 与写表项 3 为**设备保留槽**（refill/victim 最多用 7/3）：设备访问是**提交阻塞**的（§5.2），必须有界延迟；代价是 refill 并发降 1，实测无影响（32 B 行仅 8 beat）。
- `4'd4`–`4'd15` 保留：next-line 预取若按 `06-lsu-mem.md` §5.5 使用**独立 ID**，落在本保留区即可直接工作（读引擎按"每 ID 一个 FIFO"实现，不依赖 ID 取值）；也可把 Refill Buffer 索引高位编入 ID 以提高并发（平台不合成 ID，安全）。

### 6.4 读写并发仲裁与死锁避免

**优先级**（同拍竞争表项时）：`设备(3) > victim(2) > refill(1)`——设备卡在 ROB 头（直接停提交），victim 满会卡 store 提交，refill 只影响性能。读/写通道物理独立，**可同时**发起（无需互斥）。

**死锁避免**：① **无环依赖**——写数据只来自 L2 Victim Buffer 与 UC 写队列，**不来自任何读响应**，不存在"写等读"；② **设备路径解耦**——设备访问按 `06-lsu-mem.md` §5.3 走 L2 **源 3（非缓存/维护）**且不分配 Cache 行、持有保留槽，不会被 refill 流饿死；③ **每条已发事务必然终结**——正常由 `rlast`/`bvalid`，异常由 `AXI_TIMEOUT_CYCLES` 兜底，表项一定回收；④ **容量匹配**——`refill_q(4) ≤ 读表(8)`、`victim_q(4) ≤ 写表(4)`，队列不会无限积压；⑤ **不占总线锁定**——`lock=2'b00`，不与 `debug_sram`/DMA/MAC 主设备互锁；⑥ **核内截获**——CLINT/PLIC 不占 AXI 资源，总线卡住时仍能收中断并进 trap。

> 已知降级：若平台对某地址既不响应也不回 `rlast`，看门狗只能让核内路径继续（发 trap）；**若该 ID 的 FIFO 头被永久占用，同 ID 后续请求会排队**——可接受的降级（可打印错误并停机），不是静默错误。

### 6.5 桥对 L2 的接口清单

```verilog
// L2→桥：input l2_rf_valid, [31:0] l2_rf_addr, [2:0] l2_rf_idx, l2_rf_src;  output l2_rf_rdy
//        input l2_wb_valid, [31:0] l2_wb_addr, [1:0] l2_wb_idx;              output l2_wb_rdy
// 桥→L2：output l2_rf_fill_valid, [2:0] l2_rf_fill_idx, [4:0] l2_rf_fill_byte_off, l2_rf_fill_last,
//                [`AXI_DATA_W-1:0] l2_rf_fill_data, l2_rf_err_valid, [2:0] l2_rf_err_idx,
//                [1:0] l2_rf_err_resp, l2_wb_rd_req, [1:0] l2_wb_rd_idx, l2_wb_done_valid,
//                [1:0] l2_wb_done_idx, l2_wb_err_valid, [1:0] l2_wb_err_idx,
//                axi_rd_idle, axi_wb_idle, axi_idle, [3:0] l2_miss_pending
//        input [`CACHE_LINE_BITS-1:0] l2_wb_rd_data
```

> **接口层次说明**：本节信号是**桥的内部接口**（L2 的 Refill/Victim Buffer ↔ AXI 引擎）。L2 对上层（L1I/L1D/非缓存）的请求接口是 `06-lsu-mem.md` §5.2 的 `l2_req_valid/we/rdy[3:0]` + `l2_req_addr/wdata/wstrb/cbo/id` / `l2_rsp_*`——**反压位 `l2_req_rdy[3:0]` 已在该文件定义**，故 §9.5 R3 的缺口已闭合，只需 `04-frontend.md` §6 的取指侧视图与之对齐。

---

## 7. 时钟、复位与时序预算

| 时钟 | 频率 | 覆盖 | 核内是否关心 |
|---|---|---|---|
| `clk` = `aclk` = `cpu_clk` | **50 MHz（现）/ 100 MHz（目标）** | 核内全部逻辑 + CPU 侧 AXI | 是（唯一时钟） |
| `uncore_clk` = 平台 `aclk` | 33 MHz | DDR/UART/NAND/SPI/MAC/CONFREG | **否** |
| MIG `ui_clk` | 100 MHz | DDR 控制器内部 | 否 |

1. CPU 侧 AXI 的**所有**输出（`ar*`/`aw*`/`w*`）与 `rready`/`bready` 必须由 `clk` 域寄存器驱动；核内不做 CDC、不分频、不门控时钟（`axi_clock_converter_0` 负责 100↔33 MHz）。
2. **不得假设 uncore 频率**：核内唯一频率相关逻辑是 §3.5 的超时看门狗（4096 `clk` ≈ 41 µs @100 MHz，仅作"无进展"保护，**不代表**平台超时；仿真可设 `AXI_TIMEOUT_CYCLES=0` 关闭）。
3. 复位：`aresetn` 异步置位、同步释放（核内 2 级同步器）；释放后所有 `*valid` 保持低 ≥2 拍；读/写表、ID FIFO、握手状态机全部清零。
4. **输出寄存建议**：AR/AW 的 `valid+payload` 打一拍输出（表项头选择 → 寄存器 → 端口）；W 的 `wdata/wstrb/wlast/wid` 来自 `wb_stage_q`/UC 写寄存器（天然寄存）；R/B 在输入侧各加一级捕获（R 用 skid，B 用 `b_wait` 表项）。

| 路径（10 ns @100 MHz；取自 `01-pipeline.md` §7 "L2 仲裁 → AXI 6.0 ns"） | 预算 | 措施 |
|---|---|---|
| 读表头选择 → `araddr/arvalid` | 3.0 ns | 8:1 选择器两级；地址入表时已对齐 |
| victim 分片 → `wdata/wstrb` | 3.5 ns | 整行先入 `wb_stage_q[255:0]`，按 beat 做 4:1 片选 |
| `rid` 比较 + 表项/`byte_off` 更新 | 4.0 ns | 只比较 4 个 ID 队头；表项写为单点 |
| `bid` 匹配 + 表项回收 | 2.5 ns | 每 ID 一个 head 指针，不全表搜索 |
| 地址译码（L2/UC/非法） | 2.0 ns | `[31:20]`/`[31:16]` 常量比较，与 TLB 并行 |
| 反压组合链（`l2_*_rdy`） | 3.0 ns | 队列满标志寄存输出，不穿透组合链 |

---

## 8. 错误处理与调试
### 8.1 归因表（`resp ≠ 2'b00`、超时、未映射）

| 来源 | 检测点 | 归因（cause） | `mtval`/`stval` |
|---|---|---|---|
| 取指（ID0） | R 响应 / 超时 | **1 指令访问错误** | 触发缺失的取指 PC（MSHR 记录；多请求合并时取最老 PC） |
| load（ID1，L1D refill） | R 响应 / 超时 | **5 载入访问错误** | 出错 VA（LSQ `fault_va`） |
| store/AMO（ID1 填行） | R 响应 / 超时 | **7 存储/AMO 访问错误** | 出错 VA |
| 页表遍历（ID1） | R 响应 / 超时 | 按**原始访问类型**：取指 1 / load 5 / store 7 | PTE 地址 |
| 设备读（ID3） / 设备写（ID3） | `rresp`/`bresp`≠00、超时 | 5 / 7 | 设备地址 |
| 未映射地址（§2.3） | `addr_decode` | 1 / 5 / 7 | 出错地址 |
| **写回（ID2）** | `bresp≠00` / 超时 | **无法精确归因**（指令已提交） | 无 → §8.2 机器级记录 |
| 协议违规（`rlast` 错位、无匹配 beat/B） | R/B 通道 | 保守取对应来源的 5/7 | 表项地址 |

依据：`riscv-arch-test/coverpoints/norm/S.yaml:273-295`（access-fault/page-fault 写入出错虚拟地址）；PTW 访问错误按原始访问类型上报见 `riscv-isa-manual/src/priv/supervisor.adoc:1723-1854`（"raise an access-fault exception corresponding to the original access type"）。

### 8.2 上报路径

1. **精确路径（首选）**：LSU/前端在 RT 级通过 `trap_valid/trap_cause/trap_tval`（`03-pipeline-regs.md` §2.7）触发，CSR 侧按 `medeleg` 决定 M/S 委托（`04-csr-mmu.md` §4.2）。提交门控（§5.2）保证设备访问也走这条路。
2. **机器级错误寄存器（不可精确归因时，如 ID2 写回）**：建议新增 2 个自定义 M 模式 CSR（**本文件不改动 `rv32gc_defs.vh`/`07-priv-csr-mmu.md`，需登记后再实现**）：

| 地址 | 名称 | 属性 | 字段 |
|---|---|---|---|
| `0xBC0` | `mberrstat` | RW（W1C） | `[0]`valid `[2:1]`resp `[6:3]`src（0=I 1=D-refill 2=WB 3=dev 4=timeout 5=protocol） `[7]`we `[31:16]`饱和计数 |
| `0xBC1` | `mberraddr` | RO | 出错物理地址 |

3. **调试/仿真**：`perf_axi_err`（P0 错误计数）、`dbg_axi_err_pulse`、`dbg_axi_timeout`（ILA 触发源）；`mberrstat` 建议镜像到 `dbg_state[7:0]` 高位字节供数码管显示。

### 8.3 ILA 观测点与协议断言

**ILA 观测点**（深度建议 8192 ≈82 µs @100 MHz；`err_pulse` 触发时冻结 `mberrstat` 快照）：① AXI 边界 `ar*/r*/aw*/w*/b*` 及各 `valid&&ready`；② 读引擎 `rd_state`(打包)、`beat_cnt`、`byte_off`、`id_fifo_head[3:0]`；③ 写引擎 `wr_state`、`wr_beat_cnt`、`b_wait_fifo_head`；④ 非缓存 `uc_q_valid`、`uc_req_we/addr`、`uc_resp_valid/fault/cause`；⑤ 桥与反压 `l2_rf_valid/rdy`、`l2_wb_valid/rdy`、`l2_miss_pending`；⑥ 超时 `tmo_cnt`（最大者）、`timeout_hit/id/src`。触发条件：`err_pulse`、`timeout_hit`、`uc_resp_fault`、`l2_*_stall` 持续 >200 拍。

`` `ifdef SIM_ASSERT `` 断言清单：① `arvalid&&!arready` ⇒ `ar*` 不变（`aw*/w*` 同理）；② `arlen/awlen ≤ 4'd15`，行访问 `len+1 == `AXI_BEATS_PER_LINE`，设备访问 `len==0`；③ `arburst==awburst==2'b01`、`arlock==awlock==2'b00`、`arsize/awsize==3'b010`；④ `araddr[1:0]==0 && awaddr[1:0]==0`，且 `addr[11:0]+(len+1)*(1<<size) ≤ 4096`（不跨 4 KB）；⑤ `rvalid` 拍数 == `len+1` 且 `rlast` 恰在末拍，`rvalid&&!rready` ⇒ 载荷不变；⑥ `wid == 对应事务 awid`、`wstrb != 0`、`wlast` 恰在末拍；⑦ `bvalid` 数 == 已发 AW 数、`bid` ∈ 已分配 ID、无未匹配 B；⑧ 未映射/核内地址（`region==5/3/4`）**从不出现**在 AXI 上；⑨ 表项占用 ≤8（读）/≤4（写），在途设备读/写各 ≤1；⑩ 复位释放后 ≥2 拍内 `ar/aw/w/bvalid==0`、无 X 传播；⑪ `rd_err_valid`/`wr_err_valid` 每次错误只脉冲 1 拍，`drop` 表项在 `rlast`/`bvalid` 后释放。

---

## 9. 平台集成检查清单
### 9.1 与 `soc_top.v:723-776` 例化逐项核对

- [ ] 模块名 `core_top`，端口名与 §1.1 **逐字一致**（含 `ws_valid`、`break_point`、`infor_flag`、`reg_num`、`rf_rdata`、`debug0_wb_*`）。
- [ ] `intrpt[7:0]`：`[4:0]={dma,nand,spi,uart,mac}`（`soc_top.v:597,725`）→ 核内映射 PLIC 源 1~5，`[7:5]` 忽略。
- [ ] `debug0_wb_rf_wen` 声明 `[3:0]`（平台 `soc_top.v:614` 是 4 位 wire；仿真 SoC 只有 1 位 → 只取 bit0，本核填 `{3'b0, wen}`）。
- [ ] 无 `nmi`、无 `debug1_wb_*`（不定义 `` `CPU_2CMT ``）。
- [ ] 源文件放 `IP/myCPU/`（用 `scripts/install_cpu.sh` 软链/复制 `rtl/**`），不改 `chip/`、`IP/` 下任何文件。
- [ ] 读通道经 `axi_2x1_mux`（与调试加载器共享）→ 读延迟不可预测；写通道直连时钟桥 → **不假设读写对称**。

### 9.2 位宽核对（`config.h`：`LID=4`、`Lawlen=Larlen=4`、`Lawaddr=Laraddr=32`、`Lwdata=Lrdata=32`、`Lwstrb=4`）

| 端口 | 本设计 | 平台 | 结论 |
|---|---|---|---|
| `arlen/awlen` | 4 | 4（`config.h` 与所有 SoC wire） | ✅（文档 `Quick-Start.md` 写 8，以 4 为准） |
| `arid/awid/wid/rid/bid` | 4 | 4 | ✅ |
| `araddr/awaddr` | 32 | 32（FPGA SoC）；**仿真 SoC 为 64** | ✅ 零扩展兼容（仿真译码只看 `[28:16]`） |
| `rdata/wdata` / `wstrb` | 32/4（`` `AXI64 ``/`` `AXI128 `` 时 64/8、128/16） | 由同一组宏决定 | ✅ 引脚一致；仿真 128 bit 时必须定义 `` `AXI128 `` |
| `intrpt` / `debug0_wb_*` | 8 / 32·4·5·32 | 8 / 32·4·5·32 | ✅ |

### 9.3 Vivado tcl 生成工程需加入的文件

```tcl
# fpga/build_chiplab.tcl（在本项目目录内生成工程，不改 chiplab 源树）
add_files [concat [glob -nocomplain $PROJ/rtl/**/*.v] [glob -nocomplain $PROJ/rtl/**/*.vh]]
set_property include_dirs $PROJ/rtl/pkg [current_fileset]      ;# `include "rv32gc_defs.vh"
add_files -fileset constrs_1 $CHIPLAB_HOME/fpga/loongson/soc_up.xdc
set_property top soc_top [current_fileset]                     ;# part=xc7a200tfbg676-2
synth_design -top soc_top -part xc7a200tfbg676-2 -flatten_hierarchy rebuilt -retiming on
```

- [ ] `rtl/**/*.v` 全部加入（含 `rtl/bus/*.v`、`rtl/top/core_top.v`）；`rtl/pkg/rv32gc_defs.vh` 加入且 `include` 路径正确——**`../06-bus-axi.md` §5 第 2 步写的 `rtl/pkg/*.svh` 与实际文件名 `.vh` 不符，以本表为准**。
- [ ] `config-generator.mak` 的 `MYCPU_SRC` 指向 `IP/myCPU`；`AXI64/AXI128/CPU_2CMT` 保持 `n`。
- [ ] `report_timing_summary` WNS ≥ 0 @10 ns；不满足按 `07-fpga-timing.md` §2 降级（先 75 MHz，再 60 MHz）。

### 9.4 升频到 100 MHz 的步骤（**平台侧改动，本节只描述，不在本次交付中执行**）

1. `clk_pll_33`：把 `IP/xilinx_ip/<ver>/clk_pll_33/clk_pll_33.xci` 的 `CLKOUT1_REQUESTED_OUT_FREQ` 由 `50.000` 改为 `100.000`，重新生成 IP。派生值：`MMCM_DIVCLK_DIVIDE=2`、`MMCM_CLKFBOUT_MULT_F=33` → **VCO=1650 MHz**；`MMCM_CLKOUT0_DIVIDE_F` 由 `33` 改为 **`16.5`** 即得 100 MHz。`CLKOUT2`（`MMCM_CLKOUT1_DIVIDE=50`）**保持 33 MHz 不动**（uncore 必须维持 33 MHz）。
2. `chip/soc_demo/loongson/config.h:33`：`` `define FREQ 32'd33000000 `` → `32'd100000000`（否则 CONFREG `FREQ_ADDR` 与软件计时错误）；`software/bsp/drivers/confreg_time.c` 的 `CORE_CLOCKS_PER_SEC`（weak，33 MHz）与内核 `timebase-frequency` 同步改 100 MHz。
3. XDC：`set_clock_groups -asynchronous -group [get_clocks cpu_clk] -group [get_clocks uncore_clk]`（`soc_up.xdc` 只约束板级 100 MHz 输入，不能替代 `cpu_clk` 约束）。
4. `axi_clock_converter_0` 无需改配置（频率无关，内部 FIFO 自动反压）；但 100→33 MHz 带宽比约 3:1，DDR 侧成为瓶颈，`03-cache.md` §9 的命中率目标更重要。
5. ⚠️ **待确认（不在本次交付内验证）**：`MULT_F=33`+`DIVCLK_DIVIDE=2` 给出的 VCO=1650 MHz 超出 Artix-7 **-2** MMCM VCO 上限（数据手册约 1440 MHz），属平台既有疑点（当前 50 MHz 配置已是该值）。升频不改变 VCO，故不使该疑点恶化；但重新生成 IP 时若 Vivado 报 DRC，需先与平台侧确认。

### 9.4b 裁定记录（2026-09-13，上级决策）

| 编号 | 冲突 | **裁定** | 理由 |
|---|---|---|---|
| D-1 | 非缓存访问时机：`06-lsu-mem.md` §7（MEM 级执行 + 强序队列）vs 本文件 §5.2（提交门控） | **采用"ROB 头部门控（head-gated）"**：非缓存 load/store 只在 `rob_idx == rob_head` 时发往 `uncached_unit`；发出后**不得重放/重发**；其数据在写回后立即提交。**不是**"提交后才发"（那会死锁：ROB 头部指令永远无法置 `done`） | 平台设备存在读副作用（UART RBR/IIR 读清、NAND 数据口、仿真 VIRTUAL_UART）。头部门控保证：任何清空都只可能来自更年轻的指令（该 load 比它们老，因而**不会**被清掉），既不投机也不丢副作用；同时避免死锁 |
| D-2 | AXI 端口归属：`l2_cache.v` 暴露 AXI vs L2 经桥接 | **`l2_cache.v` 不直接暴露 AXI**；L2 通过 refill/victim 队列连到 `axi_bridge`；**非缓存单元直接连到 `axi_bridge`**（不经 L2、不分配 L2 行） | 非缓存访问必须强序且不能污染 L2；桥内两个客户端（L2、UC）+ 设备保留槽的仲裁更简单；`06-lsu-mem.md` §5.2 的 AXI 端口应删除，改由本文件 §5/§6 定义 |
| D-3 | 设备访问 `awcache/arcache` 编码 | 取 `4'b0000`（Device Non-bufferable） | AXI 规范；平台不解释该位（无功能影响，仅语义正确性） |

### 9.5 差异与风险清单（本次核查发现，需上游文件配合）

| # | 差异/风险 | 处置建议 |
|---|---|---|
| R1 | 设备访问 `cache` 编码：`../06-bus-axi.md` §2.1 与 `06-lsu-mem.md` §5.6/§7 都写 `4'b0010`（=Normal Non-cacheable）；本规格按 AXI 编码改为 `4'b0000`（Device Non-bufferable，符合 I/O 语义） | 以 §1.4 为准；平台不解释该位，无功能影响，但三份文档应统一 |
| R2 | 读并发容量：L2 已发布为 **Refill 4 项 + Victim 4 项**（`06-lsu-mem.md` §5.4/§5.5），而本规格按要求实现 **8 项读表** | 8 项作为上限、稳态占用 ≤6（4 refill + 1 设备保留 + 1 预取）；若要真正并发 8，需把 L2 Refill Buffer 扩到 8 并同步 `tgt` 位宽 |
| R3 | 反压：`04-frontend.md` §6 的取指侧 `l2_req_*` 无 ready/credit 位 | **已由 `06-lsu-mem.md` §5.2 的 `l2_req_rdy[3:0]` 闭合**；只需把取指侧视图与之对齐 |
| R4 | 本文件新增宏（`AXI_RD_TBL_DEPTH`/`AXI_WR_TBL_DEPTH`/`AXI_REFILL_Q_DEPTH`/`AXI_VICTIM_Q_DEPTH`/`UC_Q_DEPTH`/`UC_OSTD`/`AXI_TIMEOUT_CYCLES`/`AXI_ID_*`）与 2 个 CSR（`0xBC0/0xBC1`，经查 `07-priv-csr-mmu.md` 未占用该地址） | 需登记进 `rtl/pkg/rv32gc_defs.vh` 与 `07-priv-csr-mmu.md`；本文件未改动它们 |
| R5 | 平台 CONFREG 有 FPGA/仿真两套地址（`0x1FD0_0000`/`0x1FAF_0000`），**偏移也不同** | 软件用设备树/宏区分；核内两条窗口都按非缓存处理（§2.1） |
| R6 | 仿真 SoC 为 128 bit AXI + 64 bit 地址 wire、`debug0_wb_rf_wen` 仅 1 位，与 FPGA SoC 不同 | 仿真时定义 `` `AXI128 ``；`debug0_wb_rf_wen` 恒按 `[3:0]` 声明（bit0 有效） |
| R7 | 平台所有从设备恒 `resp=00`，未映射地址落 DDR 默认通路 | **必须**核内拒绝未映射地址（§2.3）+ 保留超时看门狗（§3.5），不能依赖平台报错 |
| R8 | 写通道绕过 `axi_2x1_mux` 直连时钟桥，读通道经该 mux 与调试加载器仲裁 | 读延迟/顺序不可预测：不得假设读写配对超时相等；建议读路径超时阈值单独放宽 |
| R9 | 平台 `axi_2x1_mux` 的 S00 只接 AR/R，调试加载器（`debug_sram`）是**另一个读主设备** | 读带宽会被调试通道分走；上板调试结束后建议在平台侧关闭该通道（不改本核） |
| R10 | **非缓存执行策略冲突**：`06-lsu-mem.md` §7 为"load 在 MEM 级执行、非缓存写走强序队列排空、写响应错误非精确记账"；本文档 §5.2 为**提交门控**（到达 ROB 头前不发 AXI 事务） | 必须二选一：① 采纳提交门控（本文件）——杜绝投机设备读的副作用（16550 RBR/IIR 读清、NAND 数据口、仿真 `VIRTUAL_UART`），代价是 ROB 头串行；② 采纳 06 方案——延迟更短，但需为"读有副作用"的窗口加白名单，否则清空/误预测会丢数据。建议 ①（与 `../03-cache.md` §5 的"不投机"意图一致） |
| R11 | **AXI 端口的归属切分**：本文档把 AXI 端口放在 `rtl/bus/axi_master.v`（读/写引擎 + 桥）；`06-lsu-mem.md` §5.2 把 `arid/araddr/…` 直接列在 `l2_cache.v` 端口上，而其 §1.1 框图又画 `l2_cache.v ─► axi_master.v` | 二者是同一逻辑的两种切分，必须冻结其一：推荐"`l2_cache.v` 只做阵列 + 4 源仲裁，AXI 端口在 `axi_master.v`"（与 `00-conventions.md` §6 的目录规划一致）；同理，非缓存单元是直接进桥还是经 L2 源 3（`06-lsu-mem.md` §5.3 取源 3）也需冻结——本文件 §5.1 的 `uc_axi_*` 按"直接进桥"给出，若改走源 3 只替换该组端口，其余逻辑不变 |
