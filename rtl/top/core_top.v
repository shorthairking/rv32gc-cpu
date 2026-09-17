//==============================================================================
// rtl/top/core_top.v —— RV32-GC 阶段二 2A：单发射顺序 5 级核顶层（48 端口）
//==============================================================================
// 项目  : rv32gc-cpu（2A = 单发射、顺序、F/D/E/M/W 五级，见
//         docs/design/08-baseline-5stage.md §1.1）
// 规格  : docs/design/08-baseline-5stage.md §4（48 端口逐字契约）/§5（每级规格）/
//         §5.5（M 级抉择）/§5.6（W 级统一异常入口）/§6（CSR·特权）/§7（总线与实现）；
//         docs/design/01-overview-datapath.md §5（端口表与位宽真源）；
//         NEXT_SESSION.md §1.5（接线要点 1–8）。
// 位宽真源: rtl/pkg/rv32_defs.vh + rtl/pkg/core_params.vh（本文件只读，不新增编码）
//
//------------------------------------------------------------------------------
// 一、例化清单（全部已交付模块）
//------------------------------------------------------------------------------
//   fetch/ : fetch_unit（内含 pc_gen / parcel_align）
//   decode/: decoder（内含 compressed_expand / dec_imm / dec_csr）
//   exec/  : alu / bru / mdu / fpu / fregfile / exe_ctrl
//   mem/   : lsu（内含 pmp_check×2 / mmio_route / amo_unit / cmo_unit）
//   csr/   : csr_file / priv_ctrl / trap_ctrl / tlb / ptw
//   clint/ : clint        plic/ : plic
//   cache/ : l1i / l1d（内含 cache_array_bram / cache_tag_array）/ mshr_simple
//   axi/   : axi_req_desc / axi_master_ctrl
//   另有 3 个"核内需求件"（已交付模块未覆盖，职责由顶层承担）：
//     ① GPR 32×32（exe_ctrl.v 头注："寄存器堆读口本体在 core_top"）；
//     ② FP CSR `fflags`/`frm`/`fcsr`（csr_file.v:665 明示"本模块不持有"）；
//     ③ `mstatus.FS` 推进（08 §5.3 ③：CSR 侧落地）+ XIP 直连取指 + AXI 请求仲裁。
//
//------------------------------------------------------------------------------
// 二、流水线口径（2A 关键裁决，全部在此显式表达）
//------------------------------------------------------------------------------
//   (a) **前端整体推进**：F/D/E 共用一个推进条件 `pipe_adv = e_done & ~m_busy`；
//       不满足则 F/D/E 全部冻结（08 §5.0「任何停顿都冻结 F/D/E 并插入气泡」）。
//   (b) **BRU 重定向冲刷集合**：BRU 在 E 级解析，重定向同拍送 pc_gen。
//       需作废的是**比分支更年轻**的已取指令，它们恰在 D 槽（FD 寄存器）与
//       即将进入 E 的槽（DE 寄存器）⇒ 重定向拍同时清 FD/DE 的 valid。
//       ★ 08 §5.3 的「冲刷 D/M/W 中已取指令」按**指令年龄**理解：M/W 持的是
//         比分支更**老**的指令（分支自身的链接写回就在其中），冲刷它们会丢提交。
//         本实现严格保证"分支之后（更年轻）的已取指令全部作废"。
//   (c) **load-use 停顿**：M 级的 load/AMO/LR/SC 结果要到访存**完成拍**才可用
//       （L1D/MMIO 均为"发请求拍 + 结果下一拍"的两拍口径）；紧随其后要用该 rd
//       的 E 级指令保持停顿，完成拍由 exe_ctrl 的 **M 旁路**取回 load 数据并随
//       em_go 锁存进 E→M 寄存器（不造组合提前转发路径）。停顿判据含"访存已完成"
//       的锁存态 ⇒ 完成即解除、**无自保持死锁**（见 §12 load_use_stall 注释）。
//   (d) **W 级统一异常入口**：所有同步异常随指令携带异常标记进入 W，
//       由 trap_ctrl 唯一入口写 *epc/*cause/*tval；core_top 不在别处写陷阱 CSR。
//   (e) **中断取点**：trap_ctrl 内部已用 `commit_valid` 限定"指令边界之后"（T6）；
//       core_top 送 `commit_valid = mw_valid`。
//   (f) **精确异常**：`trap_valid`（W 拍）必须同拍压制 M 级（更年轻指令）的存储器
//       副作用并清掉 M/E/D 槽位 —— 见 `kill_young`。
//   (g) **中断与异常的提交差异**：同步异常 ⇒ W 的该指令**不提交**；
//       中断 ⇒ 在提交边界之后取，W 的该指令**照常提交**（只清更年轻的）。
//   (h) **EM 访存单次启动**：任一 EM 槽的访存指令只启动一次（`m_issued_q` 记账：
//       启动置位，em_go/kill 清 0）。完成脉冲 `m_done_q` 只维持一拍，**不能**
//       用作启动判据（完成拍若 pipe_adv=0，下一拍会重复启动同一笔访问）。
//   (i) **M 级访存"已完成"锁存口径**：`m_mem_done = ~m_is_mem | m_done_q |
//       (m_issued_q & FSM 空闲)`，是 load-use 解除、M→W 放行、M 级旁路有效的
//       唯一判据；在途期间 m_issued_q 已置位但 FSM 非空闲 ⇒ **不算**完成
//       （否则会用陈旧 m_rd_data_q 提前提交/旁路）。
//   (j) **冲刷口径（2026-09-15 修复"陷阱/fence.i 冲刷洞"）**：`kill_young`
//       （= trap_valid | fencei_busy）拍必须**同时**做到三件事，否则比陷阱指令/
//       fence.i **更年轻**的已取指令会漏进 W 并提交（实测：ebreak 拍 E 槽指令在
//       下一拍进 M、再下一拍提交；fence.i 拍 M 槽指令在窗口内提交一次、窗口后
//       重取又提交一次）：
//         ① §13(4) EM 槽：kill_young 拍清 `em_valid`（E 槽的更年轻指令不得进 M）；
//         ② §12.3 `mw_cap`：kill_young 拍关闭 M→W 放行（M 槽的更年轻指令不得进 W）；
//         ③ fence.i 的**同步启动拍**（W 槽是即将开始扫描的 fence.i）也要关闭 M→W 放行
//            —— 那一拍 kill_young 尚未拉高（窗口从下一拍起），漏的正是 fence.i+4。
//       ★ `~bru_redirect` **不属于**冲刷口径：分支在 E 解析时，M/W 槽持的是比分支
//         **更老**的指令（见 (b)），必须照常提交；旧式 `mw_cap` 把它一并丢掉，会
//         造成"紧邻取即重定向指令之前那条指令的提交/写回丢失"（本任务一并修复）。
//       ★ 在途记账：被冲刷指令**刚进 M 槽**（trap 拍：M 槽在上一拍还是陷阱指令；
//         fence.i 拍：M 槽同上），正常路径下尚未发起任何访存（`m_l1d_go`/
//         `m_axi_want` 均被 `m_kill_fsm` 门控）；若确已在途，kill 路径把 FSM 强制
//         回 IDLE 并清 `m_issued_q`（放弃结果），事务本身由 axi_master_ctrl 的
//         "单笔在途三件套"自行收尾（§11.6 的 done owner 记账不受影响）。
//       ★ （2026-09-15 修复 R2）**xRET（mret/sret）并入同一冲刷口径**：xRET 也是
//         "W 级提交即改写执行流"的指令（取指重定向到 *epc），比它更年轻的 M/E/D
//         槽指令同样是错路径 ⇒ `kill_young` 与 `m_kill_fsm` 都含 xRET。重定向目标
//         与优先级见 §9 的 xRET 修复块与 §10 的 `redirect_exc_*` 选择式。
//
//------------------------------------------------------------------------------
// 三、已知遗留（如实登记，不静默跳过）
//------------------------------------------------------------------------------
//   L1. **取指侧 Sv32 翻译未接**：`fetch_unit.sv32_translate_en` 恒 0（Bare 直通）。
//       原因：tlb.v / ptw.v 各只有**一个**请求口，数据侧（M 级）已占用；取指侧
//       需要"取指/数据共享 PTW 的仲裁器"或第二套 TLB 端口，属 M2 的独立设计点。
//       复位后 satp.MODE=Bare（08 §7.2）⇒ 不影响 M1/M2 早期的 XIP 引导取指。
//   L2. `sfence.vma` 未译码（decoder 未覆盖），tlb 的 sfence 端口接常量。
//------------------------------------------------------------------------------
// 四、组合逻辑风格 / IP / 原语（红线 1/2/3 合规声明）
//------------------------------------------------------------------------------
//   · 组合逻辑全部用 `assign` / 条件表达式 / `function`；`always` 块只用于
//     ① 流水寄存器与状态机（时序元件）；② GPR/FP-CSR 存储体（存储元件）。
//     不存在"给多个 reg 赋值的 always @(*)"。
//   · **未例化任何 FPGA 原语**（无 RAMB*/BUFG/MMCME2/DSP48 原语）：存储走
//     cache_array_bram/cache_tag_array（内部 BRAM + `ifdef RV32GC_USE_VIVADO_IP`
//     双分支），乘法/除法 IP 在 mdu/fpu 子部件内。
//   · 本文件**不写 AXI 协议逻辑**：五通道握手在 axi_master_ctrl.v，地址窗口
//     译码在 axi_req_desc.v；本文件只做"请求仲裁 + beat 记账 + 数据搬运"。
//   · 本文件内不出现旧项目标识（旧项目 RTL/脚本一律不得复制，见 AGENT.md 抬头）。
//==============================================================================

`timescale 1ns / 1ps

`include "rv32_defs.vh"
`include "core_params.vh"

module core_top (
    //--------------------------------------------------------------------------
    // 时钟 / 复位 / 中断（08 §4.1 #1–#3）
    //--------------------------------------------------------------------------
    input  wire        aclk,               // = cpu_clk（= uncore_clk = 33 MHz，同域）
    input  wire [7:0]  intrpt,             // {3'b0, int_out[4:0]}；高 3 位恒 0
    input  wire        aresetn,            // 低有效复位

    //--------------------------------------------------------------------------
    // AXI4 读地址通道 AR（#4–#13）
    //--------------------------------------------------------------------------
    output wire [3:0]  arid,
    output wire [31:0] araddr,
    output wire [3:0]  arlen,
    output wire [2:0]  arsize,
    output wire [1:0]  arburst,
    output wire [1:0]  arlock,             // ★ 只驱动 [0]，[1] 显式置 0
    output wire [3:0]  arcache,
    output wire [2:0]  arprot,
    output wire        arvalid,
    input  wire        arready,

    //--------------------------------------------------------------------------
    // AXI4 读数据通道 R（#14–#19）
    //--------------------------------------------------------------------------
    input  wire [3:0]  rid,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,

    //--------------------------------------------------------------------------
    // AXI4 写地址通道 AW（#20–#29）
    //--------------------------------------------------------------------------
    output wire [3:0]  awid,
    output wire [31:0] awaddr,
    output wire [3:0]  awlen,
    output wire [2:0]  awsize,
    output wire [1:0]  awburst,
    output wire [1:0]  awlock,             // ★ 只驱动 [0]，[1] 显式置 0
    output wire [3:0]  awcache,
    output wire [2:0]  awprot,
    output wire        awvalid,
    input  wire        awready,

    //--------------------------------------------------------------------------
    // AXI4 写数据通道 W（#30–#35）
    //--------------------------------------------------------------------------
    output wire [3:0]  wid,
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,

    //--------------------------------------------------------------------------
    // AXI4 写响应通道 B（#36–#39）
    //--------------------------------------------------------------------------
    input  wire [3:0]  bid,
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready,

    //--------------------------------------------------------------------------
    // 调试组（#40–#48；口径 08 §4.4）
    //--------------------------------------------------------------------------
    output wire        ws_valid,           // W 级有指令提交（架构状态更新）
    input  wire        break_point,        // 平台断点探针（F 级生效）
    input  wire        infor_flag,         // 请求读某架构寄存器
    input  wire [4:0]  reg_num,            // 架构寄存器号（0–31）
    output wire [31:0] rf_rdata,           // 由 infor_flag/reg_num 选出的寄存器值
    output wire [31:0] debug0_wb_pc,       // 提交指令 PC
    output wire [3:0]  debug0_wb_rf_wen,   // ★ 必须 [3:0]；2A 只驱动 [0]
    output wire [4:0]  debug0_wb_rf_wnum,  // 目的架构寄存器号
    output wire [31:0] debug0_wb_rf_wdata  // 写回数据
);

    //==========================================================================
    // 0. 编码常量（值取自 rtl/pkg/*.vh 与各模块头注；本文件不新增编码含义）
    //==========================================================================
    localparam [3:0] OPT_ALU   = 4'd0;
    localparam [3:0] OPT_BRU   = 4'd1;
    localparam [3:0] OPT_JAL   = 4'd2;
    localparam [3:0] OPT_JALR  = 4'd3;
    localparam [3:0] OPT_LSU   = 4'd4;
    localparam [3:0] OPT_AMO   = 4'd5;
    localparam [3:0] OPT_MDU   = 4'd6;
    localparam [3:0] OPT_CSR   = 4'd7;
    localparam [3:0] OPT_SYS   = 4'd8;
    localparam [3:0] OPT_FENCE = 4'd9;
    localparam [3:0] OPT_CBO   = 4'd10;
    localparam [3:0] OPT_FP    = 4'd11;
    localparam [3:0] OPT_FPLD  = 4'd12;
    localparam [3:0] OPT_ILL   = 4'd15;

    localparam [3:0] MEM_NONE   = 4'd0;
    localparam [3:0] MEM_LOAD   = 4'd1;
    localparam [3:0] MEM_STORE  = 4'd2;
    localparam [3:0] MEM_AMO    = 4'd3;
    localparam [3:0] MEM_LR     = 4'd4;
    localparam [3:0] MEM_SC     = 4'd5;
    localparam [3:0] MEM_CBO    = 4'd6;
    localparam [3:0] MEM_FLOAD  = 4'd7;
    localparam [3:0] MEM_FSTORE = 4'd8;

    localparam [2:0] WB_NONE = 3'd0;
    localparam [2:0] WB_ALU  = 3'd1;
    localparam [2:0] WB_MEM  = 3'd2;
    localparam [2:0] WB_PC4  = 3'd3;
    localparam [2:0] WB_CSR  = 3'd4;
    localparam [2:0] WB_FP   = 3'd5;
    localparam [2:0] WB_MDU  = 3'd6;

    localparam [2:0] CSRN_NONE = 3'd0;
    localparam [2:0] CSRN_W    = 3'd1;
    localparam [2:0] CSRN_S    = 3'd2;
    localparam [2:0] CSRN_C    = 3'd3;
    localparam [2:0] CSRN_PRIV = 3'd4;

    localparam [5:0] FP_NONE = 6'd0;
    localparam [5:0] FP_ADD  = 6'd1;
    localparam [5:0] FP_SUB  = 6'd2;
    localparam [5:0] FP_MUL  = 6'd3;
    localparam [5:0] FP_DIV  = 6'd4;
    localparam [5:0] FP_SQRT = 6'd5;
    localparam [5:0] FP_SGNJ = 6'd6;
    localparam [5:0] FP_MIN  = 6'd7;
    localparam [5:0] FP_MAX  = 6'd8;
    localparam [5:0] FP_CVT  = 6'd9;
    localparam [5:0] FP_MV_X = 6'd10;
    localparam [5:0] FP_MV_W = 6'd11;
    localparam [5:0] FP_CMP  = 6'd12;
    localparam [5:0] FP_FMA  = 6'd13;

    localparam [2:0] A_LOAD  = 3'd0;
    localparam [2:0] A_STORE = 3'd1;
    localparam [2:0] A_AMO   = 3'd2;
    localparam [2:0] A_LR    = 3'd3;
    localparam [2:0] A_SC    = 3'd4;
    localparam [2:0] A_CBO   = 3'd5;

    localparam [2:0] ROUTE_NONE  = 3'd0;
    localparam [2:0] ROUTE_CLINT = 3'd1;
    localparam [2:0] ROUTE_PLIC  = 3'd2;
    localparam [2:0] ROUTE_XIP   = 3'd3;
    localparam [2:0] ROUTE_AXI   = 3'd4;

    localparam [1:0] PRIV_U = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M = `RV32GC_PRIV_M;

    localparam [1:0]  FS_OFF     = `RV32GC_FS_OFF;
    localparam [1:0]  FS_INITIAL = `RV32GC_FS_INITIAL;
    localparam [1:0]  FS_CLEAN   = `RV32GC_FS_CLEAN;
    localparam [1:0]  FS_DIRTY   = `RV32GC_FS_DIRTY;
    localparam [31:0] FS_MASK    = (32'h3 << `RV32GC_MSTATUS_FS_LSB);
    localparam [31:0] SD_MASK    = (32'h1 << `RV32GC_MSTATUS_SD_BIT);
    localparam [31:0] VSXS_MASK  = (32'h3 << `RV32GC_MSTATUS_VS_LSB) |
                                   (32'h3 << `RV32GC_MSTATUS_XS_LSB);

    // M 级访问状态机（本文件私有，无外部含义）
    localparam [3:0] M_S_IDLE = 4'd0;
    localparam [3:0] M_S_TR   = 4'd1;    // Sv32 翻译（推进 PTW）
    localparam [3:0] M_S_PTEA = 4'd2;    // 接受 PTW 的 PTE 读请求（1 拍）
    localparam [3:0] M_S_PTER = 4'd3;    // 向 L1D 发 PTE 读（1 拍）
    localparam [3:0] M_S_PTEW = 4'd4;    // 等 PTE 读返回
    localparam [3:0] M_S_PADW = 4'd5;    // PTE 的 A/D 更新写（1 拍）
    localparam [3:0] M_S_PADX = 4'd6;    // 等 A/D 更新写完成
    localparam [3:0] M_S_ISS  = 4'd7;    // 采样 lsu 输出并发出访问（1 拍）
    localparam [3:0] M_S_RSP  = 4'd8;    // 等 L1D 读/写返回
    localparam [3:0] M_S_DRAIN= 4'd9;    // 缺失后等 L1D 回空闲再重试
    localparam [3:0] M_S_MMIO = 4'd10;   // 核内 CLINT/PLIC 单拍完成
    localparam [3:0] M_S_AXI  = 4'd11;   // 平台 MMIO 经 AXI（uncached 单 beat）
    localparam [3:0] M_S_CMO  = 4'd12;   // CMO 维护扫描等待（以 l1d.idle 判定完成）

    // AXI 事务归属（内部编码）
    localparam [2:0] AXO_NONE = 3'd0;
    localparam [2:0] AXO_IFIL = 3'd1;
    localparam [2:0] AXO_DFIL = 3'd2;
    localparam [2:0] AXO_WRBK = 3'd3;
    localparam [2:0] AXO_XIPF = 3'd4;
    localparam [2:0] AXO_MDTA = 3'd5;

    //--------------------------------------------------------------------------
    // 0.1 跨节前向声明（Verilog 的隐式线网规则会为"未声明即引用"的标识符
    //     静默生成 1 bit wire ⇒ 所有在定义处之前被引用的网必须显式登记于此）
    //--------------------------------------------------------------------------
    wire        e_done;
    wire        e_stall;
    wire        m_busy;
    wire        m_mem_pending;
    wire        pipe_adv;
    wire        load_use_stall;
    wire        m_kill_fsm;
    wire        xip_fetch_busy;
    reg         fencei_busy;
    reg  [31:0] fencei_pc_q;

    wire        l1d_cs_ready, l1d_cs_miss, l1d_cs_stall, l1d_cs_wr_done;
    wire [31:0] l1d_cs_rdata;

    wire        axi_fill_valid, axi_fill_done;
    wire [31:0] axi_fill_data;
    wire [4:0]  axi_fill_word_idx;
    wire        axi_fill_accept_ifil, axi_fill_accept_dfil;
    wire        axi_wb_accept, axi_wb_done;
    wire [4:0]  axi_wb_word_idx;
    wire        axi_rdata_valid;
    wire [31:0] axi_rdata_data, axi_rdata_q;
    reg  [2:0]  axi_owner_q;
    reg  [4:0]  axi_beat_q, axi_beats_q;
    reg         axi_is_wr_q, axi_done_q;

    wire        csr_wen_w;
    wire [31:0] csr_satp, csr_menvcfg, csr_senvcfg;
    wire        csr_tsr, csr_tw, satp_sv32;

    //--------------------------------------------------------------------------

    //--------------------------------------------------------------------------
    // 0.2 交付观测点：把交付模块上本层暂不消费的输出显式连到具名网，避免悬空引脚；
    //     后续调试/断言/波形直接引用 obs_* 即可。
    //--------------------------------------------------------------------------
    wire [31:0]    obs_fetch_pc_pa;
    wire [31:0]    obs_fetch_data_pa;
    wire [15:0]    obs_parcel_o;
    wire           obs_parcel_is_lo;
    wire           obs_parcel_is_lo_pa;
    wire           obs_uncached;
    wire           obs_tvm_o;
    wire           obs_trap_wr_m_epc;
    wire           obs_trap_wr_s_epc;
    wire [4:0]     obs_fault_cause_o;
    wire           obs_hit_o;
    wire [3:0]     obs_hit_idx_o;
    wire [31:0]    obs_hit_count_o;
    wire [31:0]    obs_miss_count_o;
    wire           obs_req_ready;
    wire [31:0]    obs_fill_pa;
    wire           obs_trap_wr_m_cause;
    wire           obs_trap_wr_m_tval;
    wire           obs_trap_wr_s_cause;
    wire           obs_trap_wr_s_tval;
    wire [31:0]    obs_flush_count_o;
    wire           obs_denied_by_full_o;

    //==========================================================================
    // 1. 组合工具 function（红线 3：组合逻辑用 function，不用大 always @(*)）
    //==========================================================================
    function [31:0] gpr_rd;
        input [4:0]  ra;
        input        we;
        input [4:0]  wa;
        input [31:0] wd;
        input [31:0] rf;
        begin
            gpr_rd = (ra == 5'd0) ? 32'h0000_0000 : ((we && (wa == ra)) ? wd : rf);
        end
    endfunction

    // 取指字内按地址取字节（小端）
    function [31:0] ld_extract;
        input [31:0] w;
        input [1:0]  off;
        input [1:0]  sz;
        input        uns;
        reg   [31:0] sh;
        begin
            sh = w >> {off, 3'b000};
            case (sz)
                2'd0:    ld_extract = uns ? {24'b0, sh[7:0]}   : {{24{sh[7]}},  sh[7:0]};
                2'd1:    ld_extract = uns ? {16'b0, sh[15:0]}  : {{16{sh[15]}}, sh[15:0]};
                default: ld_extract = sh;
            endcase
        end
    endfunction

    // store 字节使能（小端，按地址偏移左移）
    function [3:0] st_strb;
        input [1:0] off;
        input [1:0] sz;
        begin
            case (sz)
                2'd0:    st_strb = (4'b0001 << off);
                2'd1:    st_strb = (4'b0011 << off);
                default: st_strb = 4'b1111;
            endcase
        end
    endfunction

    // store 数据左移到对应字节道
    function [31:0] st_shift;
        input [31:0] d;
        input [1:0]  off;
        begin
            st_shift = d << {off, 3'b000};
        end
    endfunction

    // decoder mem_op → lsu mem_kind
    function [2:0] lsu_kind;
        input [3:0] mop;
        begin
            case (mop)
                MEM_LOAD,  MEM_FLOAD  : lsu_kind = A_LOAD;
                MEM_STORE, MEM_FSTORE : lsu_kind = A_STORE;
                MEM_AMO               : lsu_kind = A_AMO;
                MEM_LR                : lsu_kind = A_LR;
                MEM_SC                : lsu_kind = A_SC;
                MEM_CBO               : lsu_kind = A_CBO;
                default               : lsu_kind = A_LOAD;
            endcase
        end
    endfunction

    // ptw 访问类型（00=取指 01=load 10=store/AMO 11=cbo）
    //   → pmp_check 访问类型（0=load 1=store 2=execute 3=AMO）
    // ★ 两模块编码不同（ptw.v 端口注释 vs pmp_check.v 端口注释），转换在调用方完成。
    function [1:0] pmp_acc_xlat;
        input [1:0] acc_ptw;
        begin
            case (acc_ptw)
                2'b00:   pmp_acc_xlat = 2'd2;
                2'b01:   pmp_acc_xlat = 2'd0;
                2'b10:   pmp_acc_xlat = 2'd1;
                default: pmp_acc_xlat = 2'd3;
            endcase
        end
    endfunction

    // fcvt 二次译码（funct5 + fmt + rs2 → fpu.v 的 fp_op 16..25）
    function [6:0] fp_cvt_map;
        input [31:0] ins;
        reg   [4:0]  f5;
        reg          r0;
        reg          fmt_d;
        begin
            f5    = ins[31:27];
            r0    = ins[20];
            fmt_d = (ins[26:25] == `RV32GC_FMT_D);
            case (f5)
                5'b01000: fp_cvt_map = r0 ? 7'd24 : 7'd25;               // F↔D
                5'b11000: fp_cvt_map = fmt_d ? (r0 ? 7'd21 : 7'd20)      // →W/WU
                                             : (r0 ? 7'd17 : 7'd16);
                5'b11010: fp_cvt_map = fmt_d ? (r0 ? 7'd23 : 7'd22)      // →S/D
                                             : (r0 ? 7'd19 : 7'd18);
                default:  fp_cvt_map = 7'd0;
            endcase
        end
    endfunction

    // 浮点族码 + 指令位 → fpu.v 归一化 fp_op[6:0]（接线要点 6）
    function [6:0] fp_op_map;
        input [5:0]  fam;
        input [31:0] ins;
        reg   [2:0]  f3;
        begin
            f3 = ins[14:12];
            case (fam)
                FP_ADD : fp_op_map = 7'd0;
                FP_SUB : fp_op_map = 7'd1;
                FP_MUL : fp_op_map = 7'd2;
                FP_DIV : fp_op_map = 7'd3;
                FP_SQRT: fp_op_map = 7'd4;
                FP_SGNJ: fp_op_map = (f3 == `RV32GC_FP_F3_FSGNJ)  ? 7'd5 :
                                     (f3 == `RV32GC_FP_F3_FSGNJN) ? 7'd6 : 7'd7;
                FP_MIN : fp_op_map = 7'd8;
                FP_MAX : fp_op_map = 7'd9;
                FP_CMP : fp_op_map = (f3 == `RV32GC_FP_F3_FEQ) ? 7'd10 :
                                     (f3 == `RV32GC_FP_F3_FLT) ? 7'd11 : 7'd12;
                FP_MV_X: fp_op_map = (f3 == `RV32GC_FP_F3_FCLASS) ? 7'd13 : 7'd14;
                FP_MV_W: fp_op_map = 7'd15;
                FP_CVT : fp_op_map = fp_cvt_map(ins);
                FP_FMA : fp_op_map = (ins[6:0] == `RV32GC_OP_MADD)  ? 7'd26 :
                                     (ins[6:0] == `RV32GC_OP_MSUB)  ? 7'd27 :
                                     (ins[6:0] == `RV32GC_OP_NMSUB) ? 7'd28 :
                                     (ins[6:0] == `RV32GC_OP_NMADD) ? 7'd29 : 7'd0;
                default: fp_op_map = 7'd0;
            endcase
        end
    endfunction

    //==========================================================================
    // 2. 外部输入规范化 / 核内设备
    //==========================================================================
    // intrpt[7:5] 恒 0（08 §4.2 规则 3）：核内**不得**对高位做预留设计。
    wire [4:0] intrpt_lo = intrpt[4:0];
    wire [7:0] plic_src  = {3'b000, intrpt_lo};

    // PLIC"针→源号"映射（core_params.vh §5；RTL 与 DTS 只写一处）
    //   ★ 必须用**定了位宽的 localparam**：真源宏是未定位宽的十进制字面量，
    //     直接放进拼接会触发 "indefinite width"（iverilog 实测）。
    localparam [3:0] SRC_MAC  = `RV32GC_INTRPT_SRC_MAC;    // 5
    localparam [3:0] SRC_UART = `RV32GC_INTRPT_SRC_UART;   // 1
    localparam [3:0] SRC_SPI  = `RV32GC_INTRPT_SRC_SPI;    // 4
    localparam [3:0] SRC_NAND = `RV32GC_INTRPT_SRC_NAND;   // 2
    localparam [3:0] SRC_DMA  = `RV32GC_INTRPT_SRC_DMA;    // 3
    wire [31:0] plic_src_map = {
        4'd0, 4'd0, 4'd0,                          // [7:5] 恒 0（不使用）
        SRC_DMA,                                   // [4] dma_int   ⇒ 源 3
        SRC_NAND,                                  // [3] nand_int  ⇒ 源 2
        SRC_SPI,                                   // [2] spi_inta  ⇒ 源 4
        SRC_UART,                                  // [1] uart0_int ⇒ 源 1
        SRC_MAC                                    // [0] mac_int   ⇒ 源 5
    };

    //==========================================================================
    // 3. GPR（32×32，写优先）—— exe_ctrl.v 头注："读口本体在 core_top"
    //==========================================================================
    reg [31:0] gpr [0:31];
    integer    gi;

    wire        w_rf_we;
    wire [4:0]  w_rd;
    wire [31:0] w_wdata;

    wire [31:0] e_rf_rdata1;
    wire [31:0] e_rf_rdata2;

    // 调试读口（infor_flag/reg_num；组合口径，08 §4.4）
    assign rf_rdata = gpr_rd(reg_num, w_rf_we, w_rd, w_wdata, gpr[reg_num]);

    //==========================================================================
    // 4. 流水寄存器声明（FD / DE / EM / MW）
    //==========================================================================
    reg         fd_valid;
    reg  [31:0] fd_pc;
    reg  [31:0] fd_pc_pa;
    reg  [31:0] fd_insn;
    reg         fd_ilen32;
    reg         fd_exc_valid;
    reg  [4:0]  fd_exc_cause;
    reg  [31:0] fd_exc_tval;
    reg  [31:0] fd_exc_pc;

    reg         de_valid;
    reg  [31:0] de_pc;
    reg  [31:0] de_pc_pa;
    reg  [31:0] de_insn32;
    reg  [31:0] de_insn_raw;
    reg         de_ilen32;
    reg  [4:0]  de_rs1, de_rs2, de_rs3, de_rd;
    reg  [31:0] de_imm;
    reg  [3:0]  de_op_type;
    reg  [3:0]  de_alu_op;
    reg  [3:0]  de_mem_op;
    reg  [2:0]  de_mem_size;
    reg         de_mem_unsign;
    reg  [2:0]  de_wb_sel;
    reg  [2:0]  de_csr_op;
    reg  [5:0]  de_fp_op;
    reg         de_fp_we;
    reg         de_fp_ldst;
    reg  [2:0]  de_rm;
    reg  [11:0] de_csr_addr;
    reg         de_csr_zimm;
    reg  [4:0]  de_cbo_kind;
    reg         de_cbo_valid;
    reg         de_cbo_downgrade;
    reg         de_fence_i;
    reg         de_ebreak;
    reg         de_ecall;
    reg         de_mret;
    reg         de_sret;
    reg         de_wfi;
    reg         de_ill;
    reg  [31:0] de_exc_tval;
    reg         de_exc_valid;
    reg  [4:0]  de_exc_cause;
    reg  [31:0] de_exc_pc;
    reg         de_exc_is_fetch;

    reg         em_valid;
    reg  [31:0] em_pc;
    reg  [31:0] em_pc_next;
    reg  [31:0] em_insn_raw;
    reg  [4:0]  em_rd;
    reg  [2:0]  em_wb_sel;
    reg  [31:0] em_result;
    reg  [3:0]  em_mem_op;
    reg  [2:0]  em_mem_size;
    reg         em_mem_unsign;
    reg  [31:0] em_rs1_val;
    reg  [31:0] em_imm_val;
    reg  [31:0] em_store_data;
    reg  [63:0] em_fp_store;
    reg  [4:0]  em_amo_f5;
    reg  [4:0]  em_cbo_rs2;
    reg         em_cbo_downgrade;
    reg         em_fence_i;
    reg         em_fp_we;
    reg  [4:0]  em_fp_rd;
    reg  [63:0] em_fp_wdata;
    reg  [4:0]  em_fflags;
    reg         em_fflags_we;
    reg         em_csr_we;
    reg  [11:0] em_csr_addr;
    reg  [31:0] em_csr_wdata;
    reg  [31:0] em_csr_rdata;
    reg         em_xret_valid;
    reg  [1:0]  em_xret_kind;
    reg         em_exc_valid;
    reg  [4:0]  em_exc_cause;
    reg  [31:0] em_exc_tval;
    reg  [31:0] em_exc_pc;
    reg         em_exc_is_fetch;

    reg         mw_valid;
    reg  [31:0] mw_pc;
    reg  [31:0] mw_pc_next;
    reg  [31:0] mw_insn_raw;
    reg  [2:0]  mw_wb_sel;
    reg  [4:0]  mw_rd;
    reg  [31:0] mw_wdata;
    reg         mw_fp_we;
    reg  [4:0]  mw_fp_rd;
    reg  [63:0] mw_fp_wdata;
    reg         mw_csr_we;
    reg  [11:0] mw_csr_addr;
    reg  [31:0] mw_csr_wdata;
    reg         mw_xret_valid;
    reg  [1:0]  mw_xret_kind;
    reg         mw_fence_i;
    reg         mw_is_fp_instr;
    reg         mw_is_fp_wr;
    reg         mw_is_fpcsr_wr;
    reg         mw_exc_valid;
    reg  [4:0]  mw_exc_cause;
    reg  [31:0] mw_exc_tval;
    reg  [31:0] mw_exc_pc;
    reg         mw_exc_is_fetch;

    //==========================================================================
    // 5. F 级：fetch_unit + L1I + XIP 直连取指
    //==========================================================================
    // ---- 5.1 前置声明的跨级/跨模块信号 ----
    wire        trap_valid, trap_is_int;
    wire        trap_exc;         // W 的该指令自身陷落（不提交）
    wire        kill_young;       // 清 M/E/D 槽位（异常或 fence.i 同步）
    wire        bru_redirect;
    wire [31:0] bru_target;
    wire        redirect_exc_v;
    wire [31:0] redirect_exc_pc;

    //   ── 取指异常：`fetch_exc_*` 是**顶层合并后**的 payload（见 §5.2.1）；
    //      `fu_exc_*` 是 fetch_unit 的原生输出（PMP 拒权 / Sv32 翻译失败）。
    wire        fetch_exc_valid;
    wire [4:0]  fetch_exc_cause;
    wire [31:0] fetch_exc_tval;
    wire [31:0] fetch_exc_pc;
    wire        fu_exc_valid;
    wire [4:0]  fu_exc_cause;
    wire [31:0] fu_exc_tval;
    wire [31:0] fu_exc_pc;
    wire        fetch_bus_err;     // 取指通道总线错误（§11.7 赋值；按事务地址粘滞）

    wire [127:0] pmp_cfg_flat;
    wire [511:0] pmp_addr_flat;

    wire        csr_priv;
    wire [1:0]  csr_priv_2;
    wire [1:0]  csr_eff_priv;
    wire        csr_mprv, csr_sum, csr_mxr;
    wire        csr_sum_raw, csr_mxr_raw;
    wire [1:0]  csr_mpp;
    reg  [1:0]  mstatus_fs;

    // ---- 5.2 取指停顿协商 ----
    //   ① pipe_adv=0（M/E 停顿）⇒ 前端冻结，F 必须同停（否则交出的指令会丢）；
    //   ② 取指异常注入拍：冻结 F，使 PC 不越过故障取指；
    //   ③ break_point（08 §4.4）：F 级制造"停止推进"；
    //   ④ fence.i 同步期间：冻结 F 并重定向到 fence.i 之后；
    //   ⑤ XIP 直连在途。
    reg  fetch_exc_done_q;
    wire fetch_exc_pending = fetch_exc_valid & ~fetch_exc_done_q;
    wire fetch_exc_inject  = fetch_exc_pending & pipe_adv;
    wire fetch_pause       = ~pipe_adv | fetch_exc_pending | break_point |
                             fencei_busy | xip_fetch_busy;

    wire [31:0] fu_fetch_req_pa;
    wire        fu_fetch_req_valid;
    wire        fu_fetch_req_uncached;
    wire        fu_fetch_req_cacheable;
    wire [31:0] fu_fetch_pc;
    wire [31:0] fu_fetch_data;
    wire        fu_fetch_valid;
    wire        fu_fetch_ilen32;
    wire [31:0] fu_fetch_insn_va;
    wire [31:0] fu_fetch_insn_pa;
    wire [31:0] fu_fetch_uncached_pa;

    wire [31:0] fetch_rsp_data;
    wire [31:0] fetch_rsp_va;
    wire        fetch_rsp_valid;
    wire        fetch_rsp_ready;

    fetch_unit u_fetch_unit (
    .aclk                 (aclk),
    .aresetn              (aresetn),
    .rst_hold             (1'b0),
    .rst_valid            (1'b0),
    .redirect_exc_valid   (redirect_exc_v),
    .redirect_exc_pc      (redirect_exc_pc),
    .redirect_bru_valid   (bru_redirect),
    .redirect_bru_pc      (bru_target),
    .break_point          (break_point),
    .fetch_pause          (fetch_pause),
    .insn_accept          (pipe_adv),
    .sv32_translate_en    (1'b0),      // ★ 遗留 L1：取指侧 Sv32 未接
    .sv32_translate_done  (1'b0),
    .sv32_translate_fault (1'b0),
    .sv32_translate_paddr (32'h0000_0000),
    .priv                 (csr_priv_2),
    .pmpcfg_i             (pmp_cfg_flat),
    .pmpaddr_i            (pmp_addr_flat),
    .fetch_req_valid      (fu_fetch_req_valid),
    .fetch_req_pa         (fu_fetch_req_pa),
    .fetch_req_uncached   (fu_fetch_req_uncached),
    .fetch_req_cacheable  (fu_fetch_req_cacheable),
    .fetch_rsp_data       (fetch_rsp_data),
    .fetch_rsp_va         (fetch_rsp_va),
    .fetch_rsp_valid      (fetch_rsp_valid),
    .fetch_rsp_ready      (fetch_rsp_ready),
    .fetch_pc             (fu_fetch_pc),
    .fetch_pc_pa(obs_fetch_pc_pa),
    .fetch_data           (fu_fetch_data),
    .fetch_data_pa(obs_fetch_data_pa),
    .parcel_o(obs_parcel_o),
    .parcel_is_lo(obs_parcel_is_lo),
    .parcel_is_lo_pa(obs_parcel_is_lo_pa),
    .fetch_valid          (fu_fetch_valid),
    .fetch_ilen32         (fu_fetch_ilen32),
    .fetch_insn_va        (fu_fetch_insn_va),
    .fetch_insn_pa        (fu_fetch_insn_pa),
    .uncached(obs_uncached),
    .fetch_uncached_pa    (fu_fetch_uncached_pa),
    .fetch_exc_valid      (fu_exc_valid),
    .fetch_exc_cause      (fu_exc_cause),
    .fetch_exc_tval       (fu_exc_tval),
    .fetch_exc_pc         (fu_exc_pc)
    );

    //==========================================================================
    // 5.2.1 ★ 取指异常合并（**顶层唯一合并点**；§11.7 提供总线错误来源）
    //--------------------------------------------------------------------------
    //   两个来源：
    //     ① fetch_unit 原生：取指 PMP 无 X 权限（cause 1）/ Sv32 翻译失败（cause 12）；
    //     ② 取指通道总线错误：AXI 取指事务（L1I 行填充 AXO_IFIL / XIP 直连 AXO_XIPF）
    //        收到 SLVERR/DECERR ⇒ cause 1（instruction access fault）。
    //   ★ 优先级 ① > ②：① 在发起任何总线请求之前就已定案（PMP 拒权时 fetch_valid
    //     被门控，不会为该 parcel 发起填充），两者同时为真的唯一情形是"前一 parcel
    //     已发起填充、本 parcel 被 PMP 拒"——此时按 ① 报（tval = 故障 parcel 的 VA，
    //     比"整行总线错误"更精确）。
    //   ★ tval/mepc 口径（②）：均取**故障取指地址** `fu_fetch_pc`（正在取的
    //     instruction/parcel 地址）。**不可**用 insn_va —— 它由 parcel_align 从取指
    //     数据推得，而总线错误可能在填充尚未回填时就已锁存（数据无意义）。
    //   ★ 为什么在顶层合并而不改 fetch_unit：fetch_unit 的端口表是
    //     `sim/unit/tb_fetch_unit.sv` 的既有判据（本任务禁改）——新增输入端口会让该
    //     单元 TB 的该端悬空为 z ⇒ 回归假失败。故取指侧 RTL 保持端口契约不变。
    //==========================================================================
    assign fetch_exc_valid = fu_exc_valid | fetch_bus_err;
    assign fetch_exc_cause = fu_exc_valid ? fu_exc_cause : `RV32GC_EXC_INSN_ACCESS_FAULT;
    assign fetch_exc_tval  = fu_exc_valid ? fu_exc_tval  : fu_fetch_pc;
    assign fetch_exc_pc    = fu_exc_valid ? fu_exc_pc    : fu_fetch_pc;

    // ---- 5.3 L1I（16 KB / 2 路 / 32 B 行）----
    //   ★ fence.i 的**全阵列失效**：l1i 的 inval_all 只清"当前 cs_vaddr 索引所在组"
    //     （l1i.v:150-154 的 wr_addr = va_index）⇒ 必须由 core_top 扫 256 个组，
    //     否则 fence.i 后旧 tag 仍命中（陈旧指令，静默错）。
    reg  [7:0]  fencei_idx_q;
    wire [31:0] l1i_cs_vaddr = fencei_busy ? {19'b0, fencei_idx_q, 5'b00000}
                                           : fu_fetch_pc;
    wire        l1i_maint_inval = fencei_busy;

    wire        l1i_cs_ready;
    wire [31:0] l1i_cs_rdata;
    wire        l1i_cs_uncached;
    wire        l1i_cs_miss;
    wire        l1i_fill_req;
    wire [31:0] l1i_fill_paddr;
    wire [1:0]  l1i_fill_owner;
    wire [4:0]  l1i_fill_beats;
    wire        l1i_idle;

    l1i #(
    .OWNER_I_FILL (2'd0)
    ) u_l1i (
    .clk            (aclk),
    .rst_n          (aresetn),
    .cs_req         (fu_fetch_req_valid & fu_fetch_req_cacheable & ~fencei_busy),
    .cs_paddr       (fu_fetch_req_pa),
    .cs_vaddr       (l1i_cs_vaddr),
    .cs_ready       (l1i_cs_ready),
    .cs_rdata       (l1i_cs_rdata),
    .cs_uncached    (l1i_cs_uncached),
    .cs_miss        (l1i_cs_miss),
    .fill_req       (l1i_fill_req),
    .fill_paddr     (l1i_fill_paddr),
    .fill_owner     (l1i_fill_owner),
    .fill_beats     (l1i_fill_beats),
    .fill_accepted  (axi_fill_accept_ifil),
    .fill_valid     (axi_fill_valid),
    .fill_data      (axi_fill_data),
    .fill_word_idx  (axi_fill_word_idx),
    .fill_done      (axi_fill_done),
    .inval_all      (l1i_maint_inval),
    .idle           (l1i_idle)
    );

    // ---- 5.4 XIP 直连取指（uncached fetch）：单 beat AXI 读 + 保持到 PC 前移 ----
    //   口径（01-overview §6.3 / 08 §4.3）：命中 XIP 窗口的取指不查/不写 L1I，
    //   经核内 AXI 控制器取 1 个 32 bit 字后直接交回 fetch_unit。
    reg  [31:0] xip_word_pa_q;
    reg  [31:0] xip_word_data_q;
    reg         xip_word_vld_q;
    reg         xip_req_pend_q;    // XIP 取指请求**在途**（已送控制器、数据未回）
    assign axi_rdata_q = rdata;            // R 通道数据（唯一读取点）

    wire xip_req_go   = fu_fetch_req_valid & fu_fetch_req_uncached &
                        ~xip_word_vld_q & ~xip_req_pend_q;
    wire xip_hit_held = xip_word_vld_q & (fu_fetch_req_pa == xip_word_pa_q);
    // ★ D1 修复（组合环）：请求在途不得回灌 fetch_pause——
    //   原式 `xip_req_go | (...)` 使 fetch_pause → fetch_req_valid → xip_req_go →
    //   xip_fetch_busy → fetch_pause 成环（iverilog 判组合环 ⇒ 全网 x；M1 实测
    //   pipe_adv=x / fetch_pause=x / fetch_valid=x，一条指令都不提交）。
    //   新口径：busy = ① **在途请求**（xip_req_pend_q，寄存器 ⇒ 不成环）
    //                 ② 已握到的字**尚未被消费**（vld 保持且 PC 已前移）。
    //   ★ 为什么必须有 ①（M1 实测的第二处静默错）：没有在途保护时，重定向
    //     （如 `j 1b` 自跳）会在旧请求仍在途时又发一笔**不同地址**的 XIP 读，
    //     先回的旧数据被贴上新的 xip_word_pa_q 标签 ⇒ 命中判定为真 ⇒ 把
    //     0x0000_0000 当指令交给 D 级（实测：loop 首圈后 PC 落到 0 号陷阱向量）。
    assign xip_fetch_busy = xip_req_pend_q | (xip_word_vld_q & ~xip_hit_held);

    assign fetch_rsp_data  = obs_uncached ? xip_word_data_q : l1i_cs_rdata;
    assign fetch_rsp_va    = {fu_fetch_pc[31:2], 2'b00};
    assign fetch_rsp_valid = obs_uncached ? xip_hit_held : l1i_cs_ready;
    assign fetch_rsp_ready = ~fetch_pause;

    //==========================================================================
    // 6. D 级：译码（decoder 内含 compressed_expand / dec_imm / dec_csr）
    //==========================================================================
    wire [31:0] dec_insn32, dec_tval, dec_imm;
    wire        dec_ill, dec_is_c, dec_is_hint, dec_ctl_xfer;
    wire [4:0]  dec_rs1, dec_rs2, dec_rs3, dec_rd;
    wire [3:0]  dec_op_type, dec_alu_op, dec_mem_op;
    wire [2:0]  dec_mem_size, dec_wb_sel;
    wire        dec_mem_unsign;
    wire [2:0]  dec_csr_op;
    wire [5:0]  dec_fp_op;
    wire        dec_fp_we, dec_fp_ldst;
    wire [2:0]  dec_rm;
    wire        dec_is_amo;
    wire [11:0] dec_csr_addr;
    wire        dec_csr_ill, dec_csr_zimm;
    wire        dec_cbo_valid, dec_cbo_gate_ill, dec_cbo_downgrade;
    wire [4:0]  dec_cbo_kind;
    wire        dec_fence_i, dec_fence, dec_ebreak, dec_ecall;
    wire        dec_mret, dec_sret, dec_wfi;

    wire        csr_chk_illegal, csr_chk_ro_write;
    wire [31:0] csr_rdata_raw, csr_rdata_w, csr_byp_mval, csr_mstatus_raw;
    reg  [4:0]  fflags_r;
    reg  [2:0]  frm_r;
    wire [31:0] menvcfg_cbie_w, senvcfg_cbie_w;
    wire [1:0]  menvcfg_cbie, senvcfg_cbie;
    wire        menvcfg_cbcfe, senvcfg_cbcfe;

    // ---- 6.1 D 级控制信号使用 ---
    wire [3:0]  d_cbo_kind_w = dec_cbo_kind[3:0];
    assign menvcfg_cbie  = csr_menvcfg[5:4];       // menvcfg.CBIE（08 §6.5）
    assign senvcfg_cbie  = csr_senvcfg[5:4];       // senvcfg.CBIE
    assign menvcfg_cbcfe = csr_menvcfg[6];         // menvcfg.CBCFE
    assign senvcfg_cbcfe = csr_senvcfg[6];         // senvcfg.CBCFE
    assign menvcfg_cbie_w = {30'b0, menvcfg_cbie};
    assign senvcfg_cbie_w = {30'b0, senvcfg_cbie};

    // ---- 6.2 非法指令判定（08 §5.2 ①③④；§6.2 访问权限；§5.3 FPU ③）----
    //   ① decoder.ill_instr_o：未支持扩展 / 编码非法；
    //   ② decoder.csr_ill_o：CSR 地址/权限/只读写违规；
    //   ③ decoder.cbo_gate_ill_o：cbo.* 门控不满足（CBIE/CBCFE）；
    //   ④ **mstatus.FS=Off 时执行 FP 指令或访问 FP CSR** ⇒ 非法指令。
    //   ★ csr_file 的 chk_illegal/chk_ro_write 只作**交叉校验**：与 decoder 的
    //     判定取逻辑与后并入（不引入新的非法来源，避免两模块"已实现地址集合"
    //     口径差异导致误报）。见 §16 的 xcheck 说明。
    wire d_csr_access = (dec_csr_op == CSRN_W) | (dec_csr_op == CSRN_S) |
                        (dec_csr_op == CSRN_C);
    wire d_is_fp_instr = (dec_op_type == OPT_FP) | (dec_op_type == OPT_FPLD);
    //   ★ （2026-09-15 修复 R1）**必须**用 `d_csr_access` 门控：`dec_csr_addr` 就是
    //     `insn[31:20]`（对**任何**指令都有效，不是"这条指令是 CSR 访问"的判据）。
    //     不门控时，凡 `insn[31:20] ∈ {0x001,0x002,0x003}` 的指令都被当成
    //     fflags/frm/fcsr 访问 ⇒ FS=Off 时判非法：
    //       · `addi x31,x0,1`（0x00100F93，imm 字段 = 0x001）误陷阱；
    //       · **`ebreak`（0x00100073，insn[31:20] = 0x001）本身被误判非法** ⇒
    //         mcause = 2（非法指令）而不是 3（断点），断点语义整体错位。
    //     真判据是"本指令确实在做 CSR 访问"（decoder 的 csr_op_o ≠ CSRN_N）。
    wire d_is_fpcsr    = d_csr_access &
                         ((dec_csr_addr == `RV32GC_CSR_FFLAGS) |
                          (dec_csr_addr == `RV32GC_CSR_FRM)    |
                          (dec_csr_addr == `RV32GC_CSR_FCSR));
    wire d_fs_off_ill  = (mstatus_fs == FS_OFF) & (d_is_fp_instr | d_is_fpcsr);
    wire d_csr_xcheck  = d_csr_access & (csr_chk_illegal | csr_chk_ro_write) & dec_csr_ill;
    wire d_ill_total   = dec_ill | dec_csr_ill | dec_cbo_gate_ill | d_fs_off_ill |
                         d_csr_xcheck;

    decoder u_decoder (
    .insn_i            (fd_valid ? fd_insn : 32'h0000_0013),
    .priv_i            (csr_priv_2),
    .menvcfg_cbie_i    (menvcfg_cbie),
    .menvcfg_cbcfe_i   (menvcfg_cbcfe),
    .senvcfg_cbie_i    (senvcfg_cbie),
    .senvcfg_cbcfe_i   (senvcfg_cbcfe),
    .insn32_o          (dec_insn32),
    .tval_o            (dec_tval),
    .ill_instr_o       (dec_ill),
    .is_compressed_o   (dec_is_c),
    .is_hint_o         (dec_is_hint),
    .ctl_xfer_o        (dec_ctl_xfer),
    .rs1_o             (dec_rs1),
    .rs2_o             (dec_rs2),
    .rs3_o             (dec_rs3),
    .rd_o              (dec_rd),
    .imm_o             (dec_imm),
    .op_type_o         (dec_op_type),
    .alu_op_o          (dec_alu_op),
    .mem_op_o          (dec_mem_op),
    .mem_size_o        (dec_mem_size),
    .mem_unsign_o      (dec_mem_unsign),
    .wb_sel_o          (dec_wb_sel),
    .csr_op_o          (dec_csr_op),
    .fp_op_o           (dec_fp_op),
    .fp_we_o           (dec_fp_we),
    .fp_ldst_o         (dec_fp_ldst),
    .rm_o              (dec_rm),
    .rv32_is_amo_o     (dec_is_amo),
    .csr_addr_o        (dec_csr_addr),
    .csr_ill_o         (dec_csr_ill),
    .csr_zimm_o        (dec_csr_zimm),
    .cbo_valid_o       (dec_cbo_valid),
    .cbo_kind_o        (dec_cbo_kind),
    .cbo_gate_ill_o    (dec_cbo_gate_ill),
    .cbo_downgrade_o   (dec_cbo_downgrade),
    .fence_i_o         (dec_fence_i),
    .fence_o           (dec_fence),
    .ebreak_o          (dec_ebreak),
    .ecall_o           (dec_ecall),
    .mret_o            (dec_mret),
    .sret_o            (dec_sret),
    .wfi_o             (dec_wfi)
    );

    //==========================================================================
    // 7. E 级：ALU / BRU / MDU / FPU / fregfile / exe_ctrl
    //==========================================================================
    // ---- 7.1 旁路网络（exe_ctrl，优先级 M > W > RF）----
    wire [31:0] e_rs1_byp, e_rs2_byp;
    wire [1:0]  e_fwd_rs1, e_fwd_rs2;
    wire        m_rf_we;
    wire [4:0]  m_rd;
    wire [31:0] m_wdata;

    assign e_rf_rdata1 = gpr_rd(de_rs1, w_rf_we, w_rd, w_wdata, gpr[de_rs1]);
    assign e_rf_rdata2 = gpr_rd(de_rs2, w_rf_we, w_rd, w_wdata, gpr[de_rs2]);

    exe_ctrl u_exe_ctrl (
    .rs1_addr (de_rs1),
    .rs2_addr (de_rs2),
    .w_valid  (w_rf_we),
    .w_rd     (w_rd),
    .w_data   (w_wdata),
    .m_valid  (m_rf_we),
    .m_rd     (m_rd),
    .m_data   (m_wdata),
    .rf_rdata1(e_rf_rdata1),
    .rf_rdata2(e_rf_rdata2),
    .rs1      (e_rs1_byp),
    .rs2      (e_rs2_byp),
    .fwd_rs1  (e_fwd_rs1),
    .fwd_rs2  (e_fwd_rs2)
    );

    // ---- 7.2 ALU 操作数（alu.v 头注："本模块不做任何操作数选择"）----
    wire        e_is_rtype = (de_insn32[6:0] == `RV32GC_OP_OP);
    wire        e_is_auipc = (de_insn32[6:0] == `RV32GC_OP_AUIPC);
    wire [31:0] e_alu_a = e_is_auipc ? de_pc : e_rs1_byp;
    wire [31:0] e_alu_b = e_is_rtype ? e_rs2_byp : de_imm;
    wire [31:0] e_alu_result;

    alu u_alu (
    .a      (e_alu_a),
    .b      (e_alu_b),
    .alu_op (de_alu_op),
    .pc     (de_pc),
    .result (e_alu_result)
    );

    // ---- 7.3 BRU（br_op = {是 jalr, 是 jal, funct3}，bru.v §三）----
    wire        e_is_jalr = (de_op_type == OPT_JALR);
    wire        e_is_jal  = (de_op_type == OPT_JAL);
    wire [4:0]  e_br_op   = {e_is_jalr, e_is_jal, de_insn32[14:12]};
    wire        e_bru_taken;
    wire [31:0] e_bru_target;

    bru u_bru (
    .rs1    (e_rs1_byp),
    .rs2    (e_rs2_byp),
    .imm    (de_imm),
    .pc     (de_pc),
    .br_op  (e_br_op),
    .taken  (e_bru_taken),
    .target (e_bru_target)
    );

    wire e_is_ctl_xfer = (de_op_type == OPT_BRU) | (de_op_type == OPT_JAL) |
                         (de_op_type == OPT_JALR);
    assign bru_redirect = de_valid & e_is_ctl_xfer & e_bru_taken &
                          ~de_ill & ~de_exc_valid & ~kill_young;
    assign bru_target   = e_bru_target;

    wire [31:0] e_link = de_pc + (de_ilen32 ? 32'd4 : 32'd2);

    // ---- 7.4 MDU（多拍；按 busy/done 握手，禁止硬编码完成拍数）----
    wire        mdu_busy, mdu_done;
    wire [31:0] mdu_result;
    wire        e_need_mdu = (de_op_type == OPT_MDU);
    reg         mdu_issued_q;
    reg         mdu_res_v_q;
    reg  [31:0] mdu_res_q;
    wire        e_mdu_go = de_valid & e_need_mdu & ~mdu_issued_q &
                           ~de_ill & ~de_exc_valid & ~kill_young;

    mdu u_mdu (
    .aclk    (aclk),
    .aresetn (aresetn),
    .start   (e_mdu_go),
    .flush   (kill_young),
    .mdu_op  (de_insn32[14:12]),
    .a       (e_rs1_byp),
    .b       (e_rs2_byp),
    .busy    (mdu_busy),
    .done    (mdu_done),
    .result  (mdu_result)
    );

    // ---- 7.5 FPU + fregfile ----
    //   ★ fregfile 写使能必须与 `mw_valid` 相与（2026-09-15 修复）：`mw_fp_we` 是
    //     随流水携带的**电平**载荷，W 槽被清空/冻结（mw_valid=0）期间仍保持上一拍
    //     的值 ⇒ 不加门控会在停顿拍重复写同一 FD 项（幂等但脏，且与"提交即一次"
    //     口径不一致）。W 级 ABI 副作用一律以 `mw_valid` 为总门控。
    wire [63:0] freg_rdata1, freg_rdata2, freg_rdata3;
    wire [6:0]  e_fp_op = fp_op_map(de_fp_op, de_insn32);
    // a 端口是整数操作数：fmv.w.x/fmv.d.x(15) 与 fcvt.{s,d}.{w,wu}(18/19/22/23)
    wire e_fp_a_is_int = (e_fp_op == 7'd15) | (e_fp_op == 7'd18) | (e_fp_op == 7'd19) |
                         (e_fp_op == 7'd22) | (e_fp_op == 7'd23);
    //   ★ 操作数走 `e_fp_src*`（§12.5 的 FP load-use 前递）：M 槽 FP 结果 > fregfile 读口。
    //     端口 a 的整数源（fmv.*.x / fcvt.*.w*）仍取 e_rs1_byp，与前递无关。
    wire [63:0] e_fpu_a = e_fp_a_is_int ? {32'h0000_0000, e_rs1_byp} : e_fp_src1;

    wire        e_need_fpu = (de_op_type == OPT_FP);
    reg         fp_issued_q;
    reg         fpu_res_v_q;
    reg  [63:0] fpu_res_q;
    reg  [4:0]  fpu_fflags_q;
    wire        e_fp_go = de_valid & e_need_fpu & ~fp_issued_q &
                          ~de_ill & ~de_exc_valid & ~kill_young &
                          ~fp_load_use_stall;   // ★ FP load-use：结果未就绪前禁止派发
                                                //   （FPU 只在派发拍采样操作数，见 §12.5）

    wire        fpu_busy, fpu_done, fpu_fflags_we;
    wire [63:0] fpu_result;
    wire [4:0]  fpu_fflags;

    // ---- ★ frm（fcsr.frm）的「CSR 写 → 紧邻 FP 指令用」同拍旁路（2026-09-17 修复）----
    //   现象（arch-test rv32i/F）：所有 `frm=dyn` 的用例整体错 1 ulp（实测
    //   F-fadd.s-01 19 处、F-fmul/F-fdiv/F-fmadd 各若干），DUT 的结果恒等于
    //   **RNE** 的结果，而 spike 用测试设定的 frm（如 rup）。
    //   根因：ACT 的 dyn 用例序列是**紧邻**的
    //       `fsrmi 3`（写 frm，W 级落盘） → `fadd.s f19,f27,f21,dyn`
    //   两条指令相差 0 ⇒ FP 指令在 E 级组合读 `frm_r` 时，写 frm 的 CSR 指令还在
    //   **W 级**（本拍末才落盘）⇒ 读到**旧 frm**（0=RNE）。
    //   与 `csrr frm` 走的两级旁路（csr_em_wfr/csr_mw_wfr，见 §7.8.1）是**同一类
    //   缺陷**：FP 指令用 frm 也必须看到 M/W 级在途 CSR 写的新值。
    //   修法：把旁路值 `fp_frm_eff` 接到 `fpu.frm`，并与 §7.8.1 的 `csr_frm_rd`
    //   共用同一份表达式（唯一定义处，避免两处不同步）。
    wire        fp_em_wfr = em_valid & em_csr_we & ~em_exc_valid &
                            ((em_csr_addr == `RV32GC_CSR_FRM) |
                             (em_csr_addr == `RV32GC_CSR_FCSR));
    wire        fp_mw_wfr = csr_wen_w & ((mw_csr_addr == `RV32GC_CSR_FRM) |
                                         (mw_csr_addr == `RV32GC_CSR_FCSR));
    wire [2:0]  fp_em_frm = (em_csr_addr == `RV32GC_CSR_FRM) ? em_csr_wdata[2:0]
                                                             : em_csr_wdata[7:5];
    wire [2:0]  fp_mw_frm = (mw_csr_addr == `RV32GC_CSR_FRM) ? mw_csr_wdata[2:0]
                                                             : mw_csr_wdata[7:5];
    wire [2:0]  fp_frm_eff = fp_em_wfr ? fp_em_frm :
                             fp_mw_wfr ? fp_mw_frm : frm_r;

    fpu u_fpu (
    .clk       (aclk),
    .rst_n     (aresetn),
    .flush     (kill_young),
    .req_valid (e_fp_go),
    .fp_op     (e_fp_op),
    .fmt       (de_insn32[26:25]),
    .rm        (de_rm),
    .frm       (fp_frm_eff),
    .a         (e_fpu_a),
    .b         (e_fp_src2),            // ★ 前递后（§12.5）
    .c         (e_fp_src3),            // ★ 前递后（FMA 的 fs3；§12.5）
    .busy      (fpu_busy),
    .done      (fpu_done),
    .result    (fpu_result),
    .fflags_we (fpu_fflags_we),
    .fflags    (fpu_fflags)
    );

    fregfile u_fregfile (
    .clk    (aclk),
    .rst_n  (aresetn),
    .rs1    (de_rs1),
    .rs2    (de_rs2),
    .rs3    (de_rs3),
    .rdata1 (freg_rdata1),
    .rdata2 (freg_rdata2),
    .rdata3 (freg_rdata3),
    .we     (mw_fp_we & mw_valid),
    .rd     (mw_fp_rd),
    .wdata  (mw_fp_wdata)
    );

    // ---- 7.6 E 级多拍握手（结果锁存，避免 done 脉冲在冻结拍被吞掉）----
    wire e_multi_done_pulse = (e_need_mdu & mdu_done) | (e_need_fpu & fpu_done);
    wire e_multi_res_valid  = mdu_res_v_q | fpu_res_v_q;
    assign e_stall = de_valid & ~de_ill & ~de_exc_valid &
                     ((e_need_mdu | e_need_fpu) & ~(e_multi_done_pulse | e_multi_res_valid));
    assign e_done  = ~e_stall;

    // fflags 累积（08 §5.3 ②：精确累积；fsgnj/fclass/fmv 的 fflags 恒 0）
    wire e_fflags_we = e_need_fpu & fpu_fflags_we;

    // ---- 「更年轻的在途 FP 标志」（2026-09-17 修复，见 (3) 段后的修复记录）----
    //   W 级 CSR 写 fflags/fcsr 落盘时，必须把**比它更年轻、且还没进 fflags_r** 的
    //   FP 指令标志一并 OR 进去，否则老指令的 CSR 写会抹掉新指令刚置的 NV/NX。
    //   · em_fflags/em_fflags_we：M 槽的 FP 指令（其 E 级累积已被同一拍的 CSR 写覆盖）
    //   · fpu_fflags           ：E 槽的 FP 指令（与 CSR 写同拍落盘）
    //   两者都是 sticky-OR ⇒ 重复并入幂等（不会多置位，也不会少置位）。
    wire [4:0] e_flags_younger = (em_fflags_we ? em_fflags : 5'd0) |
                                 (e_fflags_we  ? fpu_fflags : 5'd0);

    // ---- 7.7 MDU/FPU 结果选择 ----
    wire [31:0] e_mdu_val = mdu_res_v_q ? mdu_res_q : mdu_result;
    wire [63:0] e_fpu_val = fpu_res_v_q ? fpu_res_q : fpu_result;
    wire [4:0]  e_fp_fflags_val = fpu_res_v_q ? fpu_fflags_q : fpu_fflags;

    // ---- 7.8 CSR（Zicsr）：读旧值 / 算新值；旧值随指令流水到 W 写回 rd ----
    //   csr_file.rdata 为组合读；CSR 写在 **W 拍末**才落 csr_file 寄存器
    //   ⇒ "写指令 → E 级读"的同拍旁路必须**两级**（写指令在 M 或在 W）：
    //     · M 级写（写指令在 M、读指令在 E）：取 `csr_byp_mval`
    //     · W 级写（写指令在 W、读指令在 E）：取 `csr_rdata_w`
    //   ★ 2026-09-15 第二轮修复（WARL 残留根治）：**两级旁路一律取 csr_file 的
    //     post-WARL 落盘值**，不再取"原始写数据"：
    //       · `csr_rdata_w` = csr_file 写口旁路读：raddr==waddr 时返回该 CSR 的落盘值；
    //       · `csr_byp_mval` = csr_file 的 M 级旁路预览：把 `em_csr_wdata` 写进
    //         de_csr_addr 之后的**读回值**（同一 WARL 引擎 csr_landing）。
    //     旧写法（M/W 都取写数据）会绕过全部 WARL ⇒ `csrw mtvec,0x8000_0002` 后紧邻
    //     `csrr` 实测 DUT 读回 0x8000_0002 而 Spike 为 0x8000_0000（k=0 分歧）；
    //     mepc/sepc bit0、medeleg/mideleg 实现位、PMP L 锁定、misa/mcountinhibit/
    //     mhpmevent 吞写、menvcfg.CBIE 同理。
    //   门控口径（与真实落盘条件逐字对齐）：
    //     · M 级 = `em_valid`（槽有效）∧ `em_csr_we`（确会写；已含 ~e_ill_total/~de_exc_valid）
    //             ∧ `~em_exc_valid`（自身不带异常）。CSR 指令 `m_is_mem=0` ⇒ 不会产生
    //               M 级访存异常（`m_exc_q`），故无需再与 m_exc_any 相与。
    //     · W 级 = `csr_wen_w`（= 与 csr_file 写口、mstatus.FS 落盘、commit 同一条件）。
    //   本拍被作废（kill_young / xret_redirect 冲刷）时 E 槽同拍 `de_valid<=0`，旁路值不会
    //   落到任何架构状态（仅 E 级组合借用）。
    //   FP CSR（fflags/frm/fcsr）由 core_top 持有（csr_file 读回 0）⇒ 在此覆盖（含同拍旁路）。
    wire [31:0] csr_fp_view =
        (de_csr_addr == `RV32GC_CSR_FFLAGS) ? {27'b0, fflags_r} :
        (de_csr_addr == `RV32GC_CSR_FRM)    ? {29'b0, frm_r}    :
        (de_csr_addr == `RV32GC_CSR_FCSR)   ? {24'b0, frm_r, fflags_r} : 32'h0;
    wire        csr_is_fp = (de_csr_addr == `RV32GC_CSR_FFLAGS) |
                            (de_csr_addr == `RV32GC_CSR_FRM)    |
                            (de_csr_addr == `RV32GC_CSR_FCSR);

    // ---- 7.8.1 CSR 写 → E 级读 同拍旁路（两级；同拍双命中时 younger 优先 = M > W）----
    wire        csr_em_hit = em_valid & em_csr_we & ~em_exc_valid &
                             (em_csr_addr == de_csr_addr);
    wire        csr_mw_hit = csr_wen_w & (mw_csr_addr == de_csr_addr);
    wire        csr_byp_hit = csr_em_hit | csr_mw_hit;
    //   ★ 优先级 **M > W**：两条写指令同拍命中同一地址时，M 槽那条**更年轻**
    //     （W 槽比 M 槽老一拍）⇒ E 级读必须看到更年轻那条的新值（程序序在后的写在后）。
    //     两个候选值都是 csr_file 的 post-WARL 落盘值（见 §7.8 注释）。
    wire [31:0] csr_byp_val = csr_em_hit ? csr_byp_mval : csr_rdata_w;
    wire [31:0] csr_base_rd = csr_byp_hit ? csr_byp_val : csr_rdata_raw;

    //   mstatus/sstatus 的 FS/SD 位由 core_top 持有 ⇒ 读路径覆盖（csr_file 内那份同步被遮盖）。
    //   ★ 旁路命中时 FS 必须取**旁路值里的新 FS**（`mstatus_fs` 寄存器本拍末才更新），
    //     否则 `csrw mstatus,…` 后紧邻 `csrr` 仍会读到旧 FS/SD（同一类"读旧值"缺陷）。
    wire [1:0]  csr_fs_rd = csr_byp_hit ? csr_byp_val[`RV32GC_MSTATUS_FS_LSB +: 2] : mstatus_fs;
    wire [31:0] csr_base_rd_fs =
        ((de_csr_addr == `RV32GC_CSR_MSTATUS) | (de_csr_addr == `RV32GC_CSR_SSTATUS))
        ? ((csr_base_rd & ~(FS_MASK | SD_MASK)) |
           ({30'b0, csr_fs_rd} << `RV32GC_MSTATUS_FS_LSB) |
           ((csr_fs_rd == FS_DIRTY) ? SD_MASK : 32'h0))
        : csr_base_rd;

    //   FP CSR 的**同拍旁路**（同一类"写 → 紧邻读旧值"缺陷；三个地址**互为别名**：
    //   写 fcsr 会同时改 fflags/frm）⇒ 按**字段**分别取更年轻写者的新字段值，
    //   字段掩码与 (7) 的落盘写法逐字一致（fflags=wdata[4:0]；frm：写 frm 取 wdata[2:0]、
    //   写 fcsr 取 wdata[7:5]）。读者地址决定合成：fflags / frm / fcsr=[7:5]+[4:0]。
    wire        csr_em_wff = em_valid & em_csr_we & ~em_exc_valid &
                             ((em_csr_addr == `RV32GC_CSR_FFLAGS) |
                              (em_csr_addr == `RV32GC_CSR_FCSR));
    wire        csr_em_wfr = fp_em_wfr;   // 与 FPU 侧共用（唯一定义处见 §7.5 前）
    wire        csr_mw_wff = csr_wen_w & ((mw_csr_addr == `RV32GC_CSR_FFLAGS) |
                                          (mw_csr_addr == `RV32GC_CSR_FCSR));
    wire        csr_mw_wfr = fp_mw_wfr;
    //   frm 新字段：写者地址决定位段（frm ⇒ [2:0]，fcsr ⇒ [7:5]）
    wire [2:0]  csr_em_frm_v = fp_em_frm;
    wire [2:0]  csr_mw_frm_v = fp_mw_frm;
    wire [4:0]  csr_fflags_rd = csr_em_wff ? em_csr_wdata[4:0] :
                                csr_mw_wff ? mw_csr_wdata[4:0] : fflags_r;
    wire [2:0]  csr_frm_rd    = fp_frm_eff;
    wire [31:0] csr_fp_byp =
        (de_csr_addr == `RV32GC_CSR_FFLAGS) ? {27'b0, csr_fflags_rd} :
        (de_csr_addr == `RV32GC_CSR_FRM)    ? {29'b0, csr_frm_rd}    :
        (de_csr_addr == `RV32GC_CSR_FCSR)   ? {24'b0, csr_frm_rd, csr_fflags_rd} :
                                              csr_fp_view;
    wire [31:0] csr_rdata  = csr_is_fp ? csr_fp_byp : csr_base_rd_fs;

    wire [31:0] csr_src_e = de_csr_zimm ? {27'b0, de_rs1} : e_rs1_byp;
    wire [31:0] csr_new_e = (de_csr_op == CSRN_W) ? csr_src_e :
                            (de_csr_op == CSRN_S) ? (csr_rdata | csr_src_e) :
                            (de_csr_op == CSRN_C) ? (csr_rdata & ~csr_src_e) :
                                                    csr_rdata;
    wire e_csr_we = (de_csr_op == CSRN_W) |
                    (((de_csr_op == CSRN_S) | (de_csr_op == CSRN_C)) & (de_rs1 != 5'd0));

    // ---- 7.9 特权指令（xRET / ecall / ebreak / wfi）合法性 ----
    wire e_xret_valid = de_mret | de_sret;
    wire [1:0] e_xret_kind = de_mret ? 2'b01 : 2'b00;
    //   mret：仅 M；sret：M/S 可用，U ⇒ 非法；S 且 mstatus.TSR=1 ⇒ 非法；
    //   wfi ：< M 且 mstatus.TW=1 ⇒ 非法（08 §6.2 TVM/TW/TSR 均实现）
    wire e_priv_ill = (de_mret & (csr_priv_2 != PRIV_M)) |
                      (de_sret & ((csr_priv_2 == PRIV_U) | csr_tsr)) |
                      (de_wfi  & (csr_priv_2 != PRIV_M) & csr_tw);
    wire e_ecall_ill = 1'b0;
    wire e_ill_total = de_ill | e_priv_ill;
    //   ecall 的 cause：U=8 / S=9 / M=11
    wire [4:0] e_ecall_cause = (csr_priv_2 == PRIV_U) ? `RV32GC_EXC_ECALL_U :
                               (csr_priv_2 == PRIV_S) ? `RV32GC_EXC_ECALL_S :
                                                        `RV32GC_EXC_ECALL_M;

    //==========================================================================
    // 8. 核内设备：CLINT / PLIC（MMIO 截获，绝不发 AXI）
    //==========================================================================
    wire [31:0] clint_req_addr, plic_req_addr;
    wire        clint_req_vld, clint_req_wr, plic_req_vld, plic_req_wr;
    wire [31:0] clint_req_wdata, plic_req_wdata;
    wire [3:0]  clint_req_strb, plic_req_strb;
    wire [31:0] clint_rdata, plic_rdata;
    wire        clint_hit, plic_hit;
    wire        clint_msip, clint_mtip;
    wire        plic_meip, plic_seip;

    clint u_clint (
    .aclk      (aclk),
    .aresetn   (aresetn),
    .req_valid (clint_req_vld),
    .req_write (clint_req_wr),
    .req_addr  (clint_req_addr),
    .req_wdata (clint_req_wdata),
    .req_wstrb (clint_req_strb),
    .resp_rdata(clint_rdata),
    .resp_hit  (clint_hit),
    .msip_o    (clint_msip),
    .mtip_o    (clint_mtip)
    );

    plic #(
    .NUM_SOURCES  (`RV32GC_PLIC_NUM_SOURCES),
    .NUM_CONTEXTS (`RV32GC_PLIC_NUM_CONTEXTS)
    ) u_plic (
    .aclk          (aclk),
    .aresetn       (aresetn),
    .src           (plic_src),
    .intrpt_src_map(plic_src_map),
    .req_valid     (plic_req_vld),
    .req_write     (plic_req_wr),
    .req_addr      (plic_req_addr),
    .req_wdata     (plic_req_wdata),
    .req_wstrb     (plic_req_strb),
    .resp_rdata    (plic_rdata),
    .resp_hit      (plic_hit),
    .meip_o        (plic_meip),
    .seip_o        (plic_seip)
    );

    //==========================================================================
    // 9. M 级：lsu + L1D + TLB/PTW（Sv32）+ AMO/CMO 时序
    //==========================================================================
    // ---- 9.1 M 级状态寄存器声明 ----
    reg  [3:0]  m_state_q;
    reg  [3:0]  m_retry_q;
    reg  [31:0] m_pa_q;
    reg         m_page_fault_q;
    reg  [4:0]  m_page_cause_q;
    reg         m_hi_q;              // 8 B 访问的第二半
    reg         m_amo_phase_q;       // AMO/SC 的写相
    reg         m_exc_q;
    reg  [4:0]  m_exc_cause_q;
    reg  [31:0] m_exc_tval_q;
    reg  [31:0] m_rd_data_q;         // L1D/MMIO/AXI 读回数据（size8 时 = 低字）
    //   ★ 2026-09-17 根因修复（D 扩展）：8 B FP 访问（fld/fsd）的**高字**。
    //     本核的数据访问在 ROUTE_AXI 上走 MDTA（单 beat 32 bit），8 B 访问必须
    //     **拆成两笔 4 B**（低字 pa / 高字 pa+4）—— 原实现只在 M_S_RSP 的 L1D
    //     分支里有拆分（而该分支对 DDR3 不可达），且把 64 bit 值写进 32 bit 的
    //     `m_rd_data_q`（静默截断）⇒ fld 的高 32 位恒 0、fsd 只写低 4 B。
    //     详见 §12.3 的 M_S_AXI 修复注释。
    reg  [31:0] m_rd_hi_q;           // 高字（size8 第二阶段）
    //   ★ 生命周期与 `m_rd_data_q` **完全一致**：只在复位清 0，**不**在 M_S_IDLE /
    //     m_kill_fsm 清 0 —— M→W 捕获可能被推迟（done 拍 pipe_adv=0 时由
    //     `m_issued_q & M_S_IDLE` 的锁存态在后续拍补捕），若在 M_S_IDLE 就清掉，
    //     被推迟的那次捕获会拿到 0（load 数据丢失）。陈旧值无害：两半都在
    //     "本次 8 B 访问完成"之前被覆写，且被 kill 的访问不产生捕获。
    reg  [31:0] m_amo_wdata_q;       // AMO 写相数据（在 cs_ready 拍锁存）
    reg         m_sc_ok_q;           // SC 成功标志（读相完成拍已锁存 ⇒ 写相判据）
    //   ★ 2026-09-17 新增（PMPZalrsc_cfg_wr-00）：SC 的**成败必须在请求拍采样**。
    //     amo_unit 按规范在同一拍清除保留（req_ok & is_sc ⇒ rsv_valid_r<=0，
    //     [norm:sc_reservation_invalidate]）⇒ 之后任何一拍读 lsu_sc_ok 都恒 0。
    //     SC 的两相（读相 + 写相）跨多拍，故请求拍采样后保持：
    //       m_sc_ok_cap_q = 本笔 SC 的成功标志；m_sc_cap_q = 已采样（每笔一次，
    //       使 L1D 缺失重试（M_S_DRAIN → M_S_ISS）不会用"0"覆盖已采到的成功标志）。
    reg         m_sc_ok_cap_q;
    reg         m_sc_cap_q;
    reg         m_done_q;            // 本笔访存完成（单拍脉冲）
    reg         m_issued_q;          // ★ 本 EM 访存指令已启动（单次启动记账；
                                     //   置位：FSM 在本笔指令上启动/直接完成；
                                     //   清零：EM 槽位更换（em_go）/ 同步让路
                                     //   （m_kill_fsm）。与 m_done_q 的关系见 §9.2）
    reg         m_mmio_clint_q, m_mmio_plic_q, m_mmio_we_q;
    reg  [31:0] m_mmio_pa_q, m_mmio_off_q, m_mmio_wdata_q;
    reg  [3:0]  m_mmio_strb_q;
    reg         m_ptw_pte_ready_q;
    reg  [31:0] m_ptw_pte_pa_q;
    reg         m_ptw_pte_resp_v_q;
    reg  [31:0] m_ptw_pte_resp_d_q;
    reg         m_ptw_ad_done_q;

    // ---- 9.2 M 级组合视图 ----
    wire [31:0] m_va      = em_rs1_val + em_imm_val;     // 访存虚拟地址（mtval 口径）
    wire        m_is_mem  = (em_mem_op != MEM_NONE);
    wire        m_is_fp8  = (em_mem_op == MEM_FLOAD) | (em_mem_op == MEM_FSTORE);
    wire        m_size8   = m_is_fp8 & (em_mem_size == 3'd3);   // fld/fsd = 8 B
    wire        m_eff_is_m= (csr_eff_priv == PRIV_M);
    wire        m_need_tr = satp_sv32 & ~m_eff_is_m & ~m_hi_q;
    wire [1:0]  m_tlb_acc = (em_mem_op == MEM_STORE) | (em_mem_op == MEM_AMO) |
                            (em_mem_op == MEM_SC) | (em_mem_op == MEM_CBO) ? 2'b10 : 2'b01;
    wire [31:0] m_pa_eff = m_pa_q + (m_hi_q ? 32'd4 : 32'd0);   // ★ 物理地址唯一赋值点派生

    // -------------------------------------------------------------------------
    // ★ 本笔 M 级访存"已完成"口径（load-use 互锁 / 单次启动 / M→W 放行 / M 旁路
    //   有效性的唯一判据）
    //   m_mem_done 语义 = 「EM 槽这条指令若为访存，其访存已完成（数据已可交回）」
    //     · 非访存指令 ⇒ 恒 1（无访存可等）
    //     · m_done_q             ⇒ 完成脉冲那一拍（数据当拍在 m_rd_data_q）
    //     · m_issued_q & FSM 空闲 ⇒ 完成态的**锁存**：m_done_q 只维持一拍；
    //                              若那一拍 pipe_adv=0（E 级 MDU/FPU 多拍停顿），
    //                              EM 槽仍持有这条已完成的访存指令且数据仍有效
    //                              ⇒ 必须按"已完成"对待，否则 load_use_stall 会
    //                              自保持（死锁）且 FSM 会重复启动（M1 的 UART sb
    //                              会发两次 AW）。
    //   ★ 必须带 `m_state_q == M_S_IDLE`：在途期间 m_issued_q 也=1 但**数据尚未
    //     回来**，此时绝不能算完成（否则 W 槽会用陈旧 m_rd_data_q 提前提交、M 旁路
    //     会转发陈旧值）。正确性依据：FSM 只在完成/异常直接完成时回 IDLE；
    //     kill 路径同时清 m_issued_q。
    // -------------------------------------------------------------------------
    wire m_mem_done = (~m_is_mem) | m_done_q |
                      (m_issued_q & (m_state_q == M_S_IDLE));

    // M 级忙：FSM 在途 或 手上有**尚未启动**的访存
    assign m_mem_pending = em_valid & m_is_mem & ~m_mem_done;
    assign m_busy = (m_state_q != M_S_IDLE) | m_mem_pending;
    assign pipe_adv = e_done & ~m_busy & ~load_use_stall;

    // 让路：异常或 fence.i 同步拍必须清掉 M/E/D（见文件头 §2f/§2g）
    assign trap_exc   = trap_valid & ~trap_is_int;

    //==========================================================================
    // ★ xRET 取指重定向（2026-09-15 修复 R2）
    //--------------------------------------------------------------------------
    //   问题：`xret_valid` 原先只进 priv_ctrl（改特权级/MPP），**没有**进取指重定向
    //   （原式 `redirect_exc_v = trap_valid | fencei_busy`）⇒ `mret`/`sret` 不回
    //   *epc，而是顺序继续执行 mret 之后的那条指令（实测：陷阱处理器以 mret 结尾
    //   时回不到 mepc，落到处理器尾后的字节流上）。
    //   修法：把 xRET 并进 W 级统一重定向入口，并把**同时**要做的冲刷口径与
    //   陷阱/ fence.i 完全对齐（`kill_young` / `m_kill_fsm`）：
    //     · 目标 PC：mret ⇒ mepc，sret ⇒ sepc（xret_kind：01=mret / 00=sret）；
    //     · 优先级（与 pc_gen 契约一致）：trap > xRET > fence.i > BRU > 断点
    //       —— trap/xRET/fence.i 合并进 pc_gen 的 `redirect_exc_*`（其内部高于
    //       BRU 与断点），三者之间在本文件的 PC 选择式里显式定序；
    //     · 冲刷：xRET 在 W 提交，比它**更年轻**的 M/E/D 槽指令全是错路径（W 之后
    //       的执行流被本重定向改写）⇒ 必须与陷阱拍同样作废，否则它们会继续
    //       M→W 提交（R2 修复前根本没有重定向，故也不存在这段冲刷）。
    //   两个细节：
    //     ① epc 取值：csr_file 只有**一个**组合读口（`raddr`），本拍把 raddr 切到
    //        mepc/sepc 取回。该拍 D/E/M 槽全被冲刷（见上），被"借走"的这次读不会
    //        落到任何架构状态；`chk_addr`（权限/只读判定）走另一路端口，不受影响。
    //     ② `~trap_exc` 与 priv_ctrl 的 xret 条件逐字一致：本指令自身陷落时不回
    //        *epc（此时 trap 侧拥有重定向优先级）。
    //==========================================================================
    wire        xret_redirect = mw_xret_valid & mw_valid & ~mw_exc_valid & ~trap_exc;
    wire [11:0] xret_epc_addr = (mw_xret_kind == 2'b01) ? `RV32GC_CSR_MEPC
                                                        : `RV32GC_CSR_SEPC;
    wire [31:0] xret_epc_pc   = csr_rdata_raw;   // = {*epc[31:1],1'b0}（csr_file 读口）
    wire [11:0] csr_raddr_mux = xret_redirect ? xret_epc_addr : de_csr_addr;

    assign kill_young = trap_valid | xret_redirect | fencei_busy;

    // ---- 9.3 TLB ----
    wire        tlb_hit, tlb_perm_fault;
    wire [31:0] tlb_pa;
    wire        ptw_fill_valid;
    wire [31:0] ptw_fill_va;
    wire [21:0] ptw_fill_ppn;
    wire [7:0]  ptw_fill_perm;
    wire        satp_wr_pulse;

    tlb u_tlb (
    .clk              (aclk),
    .rst_n            (aresetn),
    .lookup_valid     ((m_state_q == M_S_IDLE) & em_valid & m_is_mem &
                           ~em_exc_valid & m_need_tr),
    .lookup_va        (m_va),
    .lookup_asid      (csr_satp[30:22]),
    .lookup_acc       (m_tlb_acc),
    .lookup_priv      (csr_eff_priv),
    .lookup_sum       (csr_sum),
    .lookup_mxr       (csr_mxr),
    .hit_o            (tlb_hit),
    .perm_fault_o     (tlb_perm_fault),
    .pa_o             (tlb_pa),
    .fill_valid       (ptw_fill_valid),
    .fill_va          (ptw_fill_va),
    .fill_ppn         (ptw_fill_ppn),
    .fill_perm        (ptw_fill_perm),
    .fill_asid        (csr_satp[30:22]),
    .sfence_valid     (1'b0),        // ★ 遗留 L2：sfence.vma 未译码
    .sfence_va        (32'h0),
    .sfence_asid      (9'h0),
    .sfence_all_va    (1'b0),
    .sfence_all_asid  (1'b0),
    .satp_we          (satp_wr_pulse),
    .satp_asid_new    (csr_satp[30:22]),
    .hit_count_o(obs_hit_count_o),
    .miss_count_o(obs_miss_count_o),
    .flush_count_o    (obs_flush_count_o)
    );

    // ---- 9.4 PTW ----
    wire        ptw_req_done, ptw_fault;
    wire [31:0] ptw_pa_out;
    wire [4:0]  ptw_fault_cause;
    wire [31:0] ptw_fault_tval;
    wire        ptw_pte_req_valid;
    wire [31:0] ptw_pte_req_pa;
    wire        ptw_pmp_req_valid;
    wire [31:0] ptw_pmp_req_addr;
    wire [1:0]  ptw_pmp_req_acc, ptw_pmp_req_priv;
    wire        ptw_pte_ad_update;
    wire [31:0] ptw_pte_ad_pa, ptw_pte_ad_data;
    assign m_ptw_req_valid = (m_state_q == M_S_TR) & ~m_kill_fsm;
    assign m_kill_fsm      = trap_valid | xret_redirect | fencei_busy;

    ptw u_ptw (
    .clk            (aclk),
    .rst_n          (aresetn),
    .req_valid      (m_ptw_req_valid),
    .req_va         (m_va),
    .req_acc        (m_tlb_acc),
    .req_priv       (csr_eff_priv),
    .req_sum        (csr_sum),
    .req_mxr        (csr_mxr),
    .satp           (csr_satp),
    .req_ready(obs_req_ready),
    .req_done       (ptw_req_done),
    .pa_o           (ptw_pa_out),
    .fault_o        (ptw_fault),
    .fault_cause_o  (ptw_fault_cause),
    .fault_tval_o   (ptw_fault_tval),
    .pte_req_valid  (ptw_pte_req_valid),
    .pte_req_pa     (ptw_pte_req_pa),
    .pte_req_ready  (m_ptw_pte_ready_q),
    .pte_resp_valid (m_ptw_pte_resp_v_q),
    .pte_resp_data  (m_ptw_pte_resp_d_q),
    .pmp_req_valid  (ptw_pmp_req_valid),
    .pmp_req_addr   (ptw_pmp_req_addr),
    .pmp_req_acc    (ptw_pmp_req_acc),
    .pmp_req_priv   (ptw_pmp_req_priv),
    .pmp_resp_ok    (ptw_pmp_ok),
    .pte_ad_update  (ptw_pte_ad_update),
    .pte_ad_pa      (ptw_pte_ad_pa),
    .pte_ad_data    (ptw_pte_ad_data),
    .pte_ad_done    (m_ptw_ad_done_q),
    .fill_valid     (ptw_fill_valid),
    .fill_va        (ptw_fill_va),
    .fill_pa(obs_fill_pa),
    .fill_ppn       (ptw_fill_ppn),
    .fill_perm      (ptw_fill_perm)
    );

    // PTE 隐式访存的 PMP 检查（08 §5.4 ④：PTE 取也要过 PMP，违反 ⇒ access-fault）
    wire ptw_pmp_ok;
    pmp_check #(
    .PMP_ENTRIES (`RV32GC_PMP_ENTRIES)
    ) u_pmp_pte (
    .clk             (aclk),
    .rst_n           (aresetn),
    .cfg_i           (pmp_cfg_flat),
    .addr_i          (pmp_addr_flat),
    .acc_pa_i        (ptw_pmp_req_addr),
    .acc_bytes_i     (5'd4),
    .acc_priv_i      (ptw_pmp_req_priv),
    .acc_type_i      (pmp_acc_xlat(ptw_pmp_req_acc)),
    .allow_o         (ptw_pmp_ok),
    .fault_cause_o(obs_fault_cause_o),
    .hit_o(obs_hit_o),
    .hit_idx_o(obs_hit_idx_o),
    .denied_by_full_o(obs_denied_by_full_o)
    );

    // ---- 9.5 lsu（内含 pmp_check×2 / mmio_route / amo_unit / cmo_unit）----
    wire [31:0] lsu_mem_va, lsu_mem_pa, lsu_mem_addr, lsu_mtval;
    wire        lsu_exc, lsu_misaligned, lsu_pmp_deny, lsu_split;
    wire [4:0]  lsu_exc_cause;
    wire [1:0]  lsu_num_beats;
    wire [31:0] lsu_beat0_addr, lsu_beat1_addr;
    wire [4:0]  lsu_beat0_bytes, lsu_beat1_bytes;
    wire        lsu_beat0_ok, lsu_beat1_ok;
    wire [2:0]  lsu_route;
    wire        lsu_no_axi, lsu_clint_plic, lsu_xip, lsu_axi_unc, lsu_axi_cac;
    wire [3:0]  lsu_axi_cache;
    wire [31:0] lsu_amo_rd_old, lsu_amo_wdata;
    wire        lsu_sc_ok, lsu_amo_busy;
    wire        lsu_cmo_valid;
    wire [1:0]  lsu_cmo_action;
    wire [31:0] lsu_cmo_block_addr, lsu_cmo_block_size;
    wire [1:0]  lsu_eff_priv;
    wire        lsu_eff_sum, lsu_eff_mxr;
    wire [1:0]  lsu_need_perm;

    wire [1:0]  m_lsu_size = (em_mem_size > 3'd2) ? 2'd2 : em_mem_size[1:0];
    assign m_lsu_req_valid = (m_state_q == M_S_ISS) & ~m_kill_fsm;

    // ---- AMO/LR/SC 读相数据源（按路由选源；2026-09-17 修复 AMO 写相数据）----
    //   ROUTE_AXI 的 AMO 读结果落在 `axi_rdata_q`（R 通道唯一读取点），而 L1D 通路的
    //   读结果在 `l1d_cs_rdata`。amo_unit 的 rd_old_o/wdata_o 全部由 rdata_i 组合派生
    //   ⇒ 两条通路必须各自喂入**本通路**的读数据，否则写相数据取自另一条通路的残留值。
    //   （lsu_route 由 mem_pa 经 mmio_route 组合产生，不含 amo_rdata 路径 ⇒ 无组合环。）
    wire [31:0] lsu_amo_rdata_src = (lsu_route == ROUTE_AXI) ? axi_rdata_q : l1d_cs_rdata;
    wire        lsu_amo_rdata_vld = (lsu_route == ROUTE_AXI) ? axi_rdata_valid : l1d_cs_ready;

    lsu #(
    .ADDR_W      (32),
    .PMP_ENTRIES (`RV32GC_PMP_ENTRIES)
    ) u_lsu (
    .clk              (aclk),
    .rst_n            (aresetn),
    .req_valid_i      (m_lsu_req_valid),
    .rs1_i            (em_rs1_val),
    .imm_i            (em_imm_val),
    .mem_kind_i       (lsu_kind(em_mem_op)),
    .size_i           (m_lsu_size),
    .unsigned_i       (em_mem_unsign),
    .amo_f5_i         (em_amo_f5),
    .cbo_rs2_i        (em_cbo_rs2),
    .store_data_i     (em_store_data),
    .cur_priv_i       (csr_priv_2),
    .mprv_i           (csr_mprv),
    .mpp_i            (csr_mpp),
    .sum_i            (csr_sum_raw),
    .mxr_i            (csr_mxr_raw),
    .inval_downgrade_i(em_cbo_downgrade),
    .ptw_pa_i         (m_pa_eff),
    .ptw_fault_i      (m_page_fault_q),
    .ptw_cause_i      (m_page_cause_q),
    .pmp_cfg_i        (pmp_cfg_flat),
    .pmp_addr_i       (pmp_addr_flat),
    .mem_va_o         (lsu_mem_va),
    .mem_pa_o         (lsu_mem_pa),
    .mem_addr_o       (lsu_mem_addr),
    .exc_o            (lsu_exc),
    .exc_cause_o      (lsu_exc_cause),
    .mtval_o          (lsu_mtval),
    .misaligned_o     (lsu_misaligned),
    .pmp_deny_o       (lsu_pmp_deny),
    .split_o          (lsu_split),
    .num_beats_o      (lsu_num_beats),
    .beat0_addr_o     (lsu_beat0_addr),
    .beat1_addr_o     (lsu_beat1_addr),
    .beat0_bytes_o    (lsu_beat0_bytes),
    .beat1_bytes_o    (lsu_beat1_bytes),
    .beat0_ok_o       (lsu_beat0_ok),
    .beat1_ok_o       (lsu_beat1_ok),
    .route_o          (lsu_route),
    .no_axi_o         (lsu_no_axi),
    .mmio_clint_plic_o(lsu_clint_plic),
    .xip_direct_o     (lsu_xip),
    .axi_uncached_o   (lsu_axi_unc),
    .axi_cached_o     (lsu_axi_cac),
    .axi_cache_o      (lsu_axi_cache),
    .amo_rd_old_o     (lsu_amo_rd_old),
    .sc_success_o     (lsu_sc_ok),
    .amo_wdata_o      (lsu_amo_wdata),
    .amo_busy_o       (lsu_amo_busy),
    .cmo_valid_o      (lsu_cmo_valid),
    .cmo_action_o     (lsu_cmo_action),
    .cmo_block_addr_o (lsu_cmo_block_addr),
    .cmo_block_size_o (lsu_cmo_block_size),
    .eff_priv_o       (lsu_eff_priv),
    .eff_sum_o        (lsu_eff_sum),
    .eff_mxr_o        (lsu_eff_mxr),
    .need_perm_o      (lsu_need_perm),
        // ★ 接线要点 3：amo_unit 读相返回 —— **按路由选源**（2026-09-17 修复）：
        //   · L1D 通路（M_S_RSP）：l1d_cs_rdata / l1d_cs_ready；
        //   · ROUTE_AXI 通路（M_S_AXI，本仿真里 DDR 走这条）：AXI 单 beat 读回的整字
        //     axi_rdata_q —— 必须接进来，否则 amo_unit 的 `amo_apply(f5, rdata_i, rs2)`
        //     用的是**上一次 L1D 读的残留值** ⇒ 写相数据错（见 §13 M_S_AXI 注释）。
        //   amo_unit 是纯组合，rd_old_o/wdata_o 都只依赖 rdata_i ⇒ 该 mux 即足够；
        //   rdata_valid 只影响未被使用的 w_req_o/busy_o，故按同源选一个等效有效位。
    .amo_rdata_i      (lsu_amo_rdata_src),
    .amo_rdata_valid_i(lsu_amo_rdata_vld)
    );

    // ---- 9.6 L1D（32 KB / 4 路 / 32 B 行；写回 + 写分配）----
    wire        l1d_fill_req, l1d_wb_req, l1d_wb_ready, l1d_idle;
    wire [31:0] l1d_fill_paddr, l1d_wb_paddr, l1d_wb_data;
    wire [1:0]  l1d_fill_owner, l1d_wb_way, l1d_wb_owner;
    wire [4:0]  l1d_fill_beats, l1d_wb_beats;

    // CMO 维护（08 §7.2：clean/inval 为 256 拍逐组扫描，以 idle 判定完成）
    wire l1d_maint_inval = (m_state_q == M_S_ISS) & lsu_cmo_valid &
                           (lsu_cmo_action == 2'd3) & ~m_kill_fsm;
    wire l1d_maint_clean = (m_state_q == M_S_ISS) & lsu_cmo_valid &
                           ((lsu_cmo_action == 2'd1) | (lsu_cmo_action == 2'd2)) & ~m_kill_fsm;

    // L1D 访问时序（★ l1d 口径：cs_req 是"本拍发出的访问"，会被寄存后复用 ⇒
    //   必须**单拍脉冲**，结果在下一拍由 cs_ready/cs_wr_done/cs_miss 给出）
    wire        m_amo_write = m_amo_phase_q & ((em_mem_op == MEM_AMO) |
                                               ((em_mem_op == MEM_SC) & m_sc_ok_q));
    wire [31:0] m_store_w32 = m_is_fp8 ? (m_hi_q ? em_fp_store[63:32] : em_fp_store[31:0])
                                       : st_shift(em_store_data, m_va[1:0]);
    wire [3:0]  m_store_strb = m_is_fp8 ? 4'hF : st_strb(m_va[1:0], m_lsu_size);
    wire        m_mem_wr_op  = (em_mem_op == MEM_STORE) | (em_mem_op == MEM_FSTORE);

    // ---- FP 8 B 访存（fld/fsd）的**非自然对齐**检测（2026-09-17，PMPF_cfg_wr-00）----
    //   本核把 fld/fsd 拆成两个 4 B 半笔（`m_hi_q` 两相），而 lsu 只看到自然的
    //   4 B 访问 ⇒ lsu 的 misalign 判定（抉择 1「非对齐优先于 PMP」）对 8 B FP
    //   访存**永不命中**：既漏报 address-misaligned，又让 PMP 的 access-fault 抢先
    //   （实测 PMPF_cfg_wr-00：DUT cause 7/5，Spike cause 6/4，同 tval=0x80009004）。
    //   规范口径：F/D 的 8 B 访存要求自然对齐（地址低 3 位全 0）；非对齐 ⇒
    //   load ⇒ cause 4 / store ⇒ cause 6，且按本核抉择 1 **先于** PMP / 页错误。
    //   tval 与其它访存异常一致 = 虚拟地址（lsu 的 mtval 口径）。
    wire        m_fp8_misalign  = m_size8 & (m_va[2:0] != 3'b000);
    wire [4:0]  m_fp8_mis_cause = (em_mem_op == MEM_FLOAD)
                                  ? `RV32GC_EXC_LOAD_MISALIGNED     // 4
                                  : `RV32GC_EXC_STORE_MISALIGNED;   // 6
    wire        m_l1d_go     = (m_state_q == M_S_ISS) & ~m_kill_fsm &
                               ~lsu_exc & ~m_page_fault_q & ~lsu_cmo_valid &
                               ~lsu_clint_plic & (lsu_route != ROUTE_AXI) &
                               ~(m_mem_wr_op & m_size8 & m_hi_q);
    wire [31:0] m_ld_data_ext = ld_extract(l1d_cs_rdata, m_va[1:0], m_lsu_size,
                                           em_mem_unsign);
    //   ★ 2026-09-15 根因修复（同类缺陷：AXI 读通路的载入值未做宽度/偏移抽取）：
    //     平台 AXI 数据读（M_S_AXI）返回的是 **对齐 4 B 字**（AXI 读按 size=2 整字回，
    //     字节道由主设备自选）⇒ 整数 load 必须与 L1D 通路**同一口径**抽取：
    //       lb / lbu ⇒ 取 (字 >> 8*VA[1:0]) 的第 0 字节（符号/零扩展按 em_mem_unsign）
    //       lh / lhu ⇒ 同理取 16 bit
    //       lw       ⇒ 尺寸 2 ⇒ 结果 = 原字（不受影响）
    //     非整数 load（MEM_FLOAD：flw/fld，按设计 4 B 对齐）保持原字不动。
    //     原实现直接把 `axi_rdata_q` 写进 rd ⇒ `lbu` 得到**整字**（实测：地址
    //     0x80006679 处 NUL 字节被读成整字 0x520a000a）⇒ arch-test rvmodel 的
    //     `lbu t1,0(a0); beqz t1` 字符循环永远等不到 '\0'，收尾打印死循环、HTIF
    //     终止码永不写入（I-nop-00/I-add-00 都在此处挂死）。
    wire [31:0] m_axi_ld_data_ext = ld_extract(axi_rdata_q, m_va[1:0], m_lsu_size,
                                               em_mem_unsign);
    wire [31:0] m_axi_ld_data = (em_mem_op == MEM_LOAD) ? m_axi_ld_data_ext
                                                        : axi_rdata_q;

    //   ★ 2026-09-15 修复（同一条 MMIO 读通路的第二半缺陷）：核内 MMIO 的**寄存器地址**
    //     —— clint.v/plic.v 的寄存器译码是「窗口内偏移 == 寄存器偏移」的**整字比较**
    //     （两个模块的头注都写明"核内 MMIO 一律 32 位字对齐访问"），而 LSU 送来的是
    //     **字节地址**（m_pa_eff = rs1+imm 原样）。若把 lb/lbu/lh/lhu 的字节地址原样
    //     送去，偏移 0x4001/0x4002/0x4003 都不命中 ⇒ 设备 resp_rdata=0 ⇒ 上面的
    //     ld_extract 抽到的仍是 0（实测：lbu @+1 读回 0x00 而非 0x66）。
    //     故**读访问**把地址对齐到 4 B 边界再送设备：设备按整字寄存器应答，
    //     字节/半字由 ld_extract 按 VA[1:0] 抽取 —— 与 AXI 通路同语义
    //     （主设备给对齐地址 + 自行选字节道；AXI 是协议允许非对齐，核内 MMIO 是
    //      设备只认对齐 ⇒ 由主设备侧对齐）。
    //   · 写访问**不**在此处对齐：clint.v/plic.v 的写口径是"任一 wstrb 有效即整字写
    //     （不做字节合并）"，对齐后送"左移过的 store 数据"会整字覆盖寄存器；
    //     即 sb/sh 对核内 MMIO 的写通路是既有未支持项（登记在交付说明的遗留里，
    //     修复需动 clint.v/plic.v，超出本任务允许的文件范围）。
    wire [31:0] m_mmio_req_addr = (m_mem_wr_op | m_amo_write)
                                  ? m_pa_eff : {m_pa_eff[31:2], 2'b00};

    wire        l1d_cs_req  = (m_l1d_go | (m_state_q == M_S_PTER) |
                               (m_state_q == M_S_PADW)) & ~m_kill_fsm;
    wire        l1d_cs_we   = (m_state_q == M_S_PADW) ? 1'b1 :
                              ((m_state_q == M_S_PTER) ? 1'b0 : (m_mem_wr_op | m_amo_write));
    wire [31:0] l1d_cs_paddr= ((m_state_q == M_S_PTER) | (m_state_q == M_S_PADW))
                              ? m_ptw_pte_pa_q : m_pa_eff;
    wire [31:0] l1d_cs_vaddr= ((m_state_q == M_S_PTER) | (m_state_q == M_S_PADW))
                              ? m_ptw_pte_pa_q : m_va;
    wire [3:0]  l1d_cs_strb = (m_state_q == M_S_PADW) ? 4'hF : m_store_strb;
    wire [31:0] l1d_cs_wdata= (m_state_q == M_S_PADW) ? m_ptw_pte_resp_d_q :
                              (m_amo_phase_q ? m_amo_wdata_q : m_store_w32);

    l1d #(
    .OWNER_D_FILL (2'd1),
    .OWNER_WRBACK (2'd2)
    ) u_l1d (
    .clk            (aclk),
    .rst_n          (aresetn),
    .cs_req         (l1d_cs_req),
    .cs_we          (l1d_cs_we),
    .cs_wstrb       (l1d_cs_strb),
    .cs_paddr       (l1d_cs_paddr),
    .cs_vaddr       (l1d_cs_vaddr),
    .cs_wdata       (l1d_cs_wdata),
    .cs_ready       (l1d_cs_ready),
    .cs_rdata       (l1d_cs_rdata),
    .cs_miss        (l1d_cs_miss),
    .cs_stall       (l1d_cs_stall),
    .cs_wr_done     (l1d_cs_wr_done),
    .fill_req       (l1d_fill_req),
    .fill_paddr     (l1d_fill_paddr),
    .fill_owner     (l1d_fill_owner),
    .fill_beats     (l1d_fill_beats),
    .fill_accepted  (axi_fill_accept_dfil),
    .fill_valid     (axi_fill_valid),
    .fill_data      (axi_fill_data),
    .fill_word_idx  (axi_fill_word_idx),
    .fill_done      (axi_fill_done),
    .wb_req         (l1d_wb_req),
    .wb_paddr       (l1d_wb_paddr),
    .wb_way         (l1d_wb_way),
    .wb_owner       (l1d_wb_owner),
    .wb_beats       (l1d_wb_beats),
    .wb_accepted    (axi_wb_accept),
    .wb_word_idx    (axi_wb_word_idx),
    .wb_data        (l1d_wb_data),
    .wb_done        (axi_wb_done),
    .wb_ready       (l1d_wb_ready),
    .inval_all      (l1d_maint_inval),
    .clean_all      (l1d_maint_clean),
    .idle           (l1d_idle)
    );

    // ---- 9.7 核内 MMIO 分流（第二份 mmio_route：仅供 core_top 区分 CLINT/PLIC；
    //          lsu 内部那份生成 route_o。两者用同一模块 ⇒ 译码口径不会分叉）----
    wire [2:0]  m_mr_route;
    wire        m_mr_no_axi, m_mr_clint_plic, m_mr_xip, m_mr_unc, m_mr_cac;
    wire        m_mr_clint, m_mr_plic, m_mr_periph;

    mmio_route #(
    .ADDR_W (32)
    ) u_mmio_route_top (
    .pa_i           (m_pa_eff),
    .route_o        (m_mr_route),
    .no_axi_o       (m_mr_no_axi),
    .clint_plic_o   (m_mr_clint_plic),
    .xip_direct_o   (m_mr_xip),
    .axi_uncached_o (m_mr_unc),
    .axi_cached_o   (m_mr_cac),
    .clint_hit_o    (m_mr_clint),
    .plic_hit_o     (m_mr_plic),
    .periph_hit_o   (m_mr_periph)
    );

    assign clint_req_vld   = (m_state_q == M_S_MMIO) & m_mmio_clint_q;
    assign plic_req_vld    = (m_state_q == M_S_MMIO) & m_mmio_plic_q;
    assign clint_req_wr    = m_mmio_we_q;
    assign plic_req_wr     = m_mmio_we_q;
    assign clint_req_addr  = m_mmio_off_q;
    //   ★ 2026-09-15 修复（PLIC 寄存器地址译码偏差 +0x100000）：
    //     m_mmio_off_q = PA − CLINT_BASE 是 **CLINT 窗口内偏移**（二者共用一份记账，
    //     见 §9 的 M_S_ISS），而 plic.v 的寄存器译码口径是 **PLIC 窗口内偏移**
    //     （PRIORITY 0x0 / PENDING 0x1000 / ENABLE 0x2000 / THRESHOLD 0x0020_0000，
    //      见 plic.v 文件头「寄存器映射」）。直接把 m_mmio_off_q 送过去 ⇒ 整个 PLIC
    //     窗口偏移 +0x100000（= PLIC_BASE − CLINT_BASE）⇒ 寄存器全不命中：
    //     读恒 0、写被丢弃（核内截获仍然成立，故不报错、只是静默失效）。
    //     这里减去基址差，恢复「PLIC 窗口内偏移」口径；与读对齐口径同源
    //     （m_mmio_off_q 由 m_mmio_req_addr 派生 —— 读已按 4 B 对齐，见 §9 的
    //      m_mmio_req_addr 定义），本行不改动对齐语义。
    //   · 遗留（**不在本次改动范围**，需另立任务）：mmio_route 的 PLIC 窗口判定是
    //     PA[31:16]==0x1F10（1F10_0000–1F10_FFFF，仅 64 KiB），而 PLIC 的
    //     threshold/claim 区在 PLIC_BASE+0x20_0000（PA 0x1F30_0000 / 0x1F31_1000）
    //     ⇒ 该区访问**不命中核内窗口**（落 DDR3/AXI 默认通路）。本行修复只解决
    //     「偏移口径」，threshold/claim 的可达性需同步放宽 mmio_route/pkg 的窗口。
    assign plic_req_addr   = m_mmio_off_q - (`RV32GC_PLIC_BASE - `RV32GC_CLINT_BASE);
    assign clint_req_wdata = m_mmio_wdata_q;
    assign plic_req_wdata  = m_mmio_wdata_q;
    assign clint_req_strb  = m_mmio_strb_q;
    assign plic_req_strb   = m_mmio_strb_q;

    //==========================================================================
    // 10. W 级：csr_file / priv_ctrl / trap_ctrl（统一异常入口）
    //==========================================================================
    wire [127:0] pmp_cfg_o;
    wire [511:0] pmp_addr_o;
    
    wire [31:0]  csr_mcounteren, csr_scounteren;
    wire [31:0]  csr_mtvec, csr_stvec, csr_medeleg, csr_mideleg, csr_mie, csr_mip;
    wire [31:0]  mstatus_set, mstatus_clr;
    //   ★ mstatus 的置位/清除向量由 priv_ctrl 产生，**直接**送 csr_file 落地
    //     （顶层不再做任何纠正/改写；见 §10 的 R3 根因修复说明）。
    wire         priv_flush_req;
    wire [1:0]   priv_next;
    wire         csr_fetch_is_m;
    wire [31:0]  cycle_cnt, instret_cnt;

    assign csr_wen_w = mw_valid & mw_csr_we & ~mw_exc_valid & ~trap_exc;
    assign satp_wr_pulse = csr_wen_w & (mw_csr_addr == `RV32GC_CSR_SATP);

    csr_file u_csr_file (
    .clk         (aclk),
    .rst_n       (aresetn),
    //   ★ 读地址在 xRET 重定向拍切到 mepc/sepc（见 §9 的 R2 修复说明）：
    //     该拍 D/E/M 槽已被 kill_young 冲刷，这次"借读"不会落入架构状态。
    .raddr       (csr_raddr_mux),
    .rdata       (csr_rdata_raw),
    .wen         (csr_wen_w),
    .waddr       (mw_csr_addr),
    .wdata       (mw_csr_wdata),
    .w_illegal   (1'b0),
    //   `rdata_w` = 写口旁路读（raddr==waddr ⇒ 该 CSR 的 **post-WARL 落盘值**），
    //   用作 **W 级**旁路值；`byp_rdata` 是同一 WARL 引擎对**更年轻的 M 级写**
    //   （byp_wdata = 本拍 M 槽的原始写数据）的预览，用作 **M 级**旁路值（M > W）。
    .rdata_w     (csr_rdata_w),
    .byp_wdata   (em_csr_wdata),
    .byp_rdata   (csr_byp_mval),
    .priv        (csr_priv_2),
    .chk_addr    (dec_csr_addr),
    .chk_illegal (csr_chk_illegal),
    .chk_ro_write(csr_chk_ro_write),
    .mstatus_o   (csr_mstatus_raw),
    .mstatus_set (mstatus_set),
    .mstatus_clr (mstatus_clr),
    .trap_we     (trap_we),
    .trap_epc_i  (trap_epc_i),
    .trap_cause_i(trap_cause_i),
    .trap_tval_i (trap_tval_i),
    .trap_data_i (32'h0000_0000),
    .irq_msip    (clint_msip),
    .irq_mtip    (clint_mtip),
    .irq_meip    (plic_meip),
    .irq_stip    (1'b0),      // 核内无 S 级定时器源（08 §6.6）
    .irq_seip    (plic_seip),
    .cycle_i     ({32'h0, cycle_cnt}),
    .instret_i   ({32'h0, instret_cnt}),
    .pmp_cfg_o   (pmp_cfg_o),
    .pmp_addr_o  (pmp_addr_o),
    .satp_o      (csr_satp),
    .menvcfg_o   (csr_menvcfg),
    .senvcfg_o   (csr_senvcfg),
    .mcounteren_o(csr_mcounteren),
    .scounteren_o(csr_scounteren),
    .mtvec_o     (csr_mtvec),
    .stvec_o     (csr_stvec),
    .medeleg_o   (csr_medeleg),
    .mideleg_o   (csr_mideleg),
    .mie_o       (csr_mie),
    .mip_o       (csr_mip)
    );

    assign pmp_cfg_flat  = pmp_cfg_o;
    assign pmp_addr_flat = pmp_addr_o;
    assign satp_sv32     = csr_satp[`RV32GC_SATP_MODE_BIT];

    // mstatus 的 FS/SD 由 core_top 持有（csr_file 内那份同步被覆盖）
    //   ★ 08 §5.3 ③：FS=Off 执行 FP 指令 ⇒ 非法指令；FPU 指令推进 FS。
    wire [31:0] mstatus_merged =
        ((csr_mstatus_raw & ~(FS_MASK | SD_MASK | VSXS_MASK)) |
         ({30'b0, mstatus_fs} << `RV32GC_MSTATUS_FS_LSB) |
         ((mstatus_fs == FS_DIRTY) ? SD_MASK : 32'h0));

    // 读路径的 FS 覆盖（mstatus/sstatus 视图）
    wire [31:0] csr_mstatus_view =
        ((csr_rdata_raw & ~(FS_MASK | SD_MASK)) |
         ({30'b0, mstatus_fs} << `RV32GC_MSTATUS_FS_LSB) |
         ((mstatus_fs == FS_DIRTY) ? SD_MASK : 32'h0));

    priv_ctrl u_priv_ctrl (
    .clk              (aclk),
    .rst_n            (aresetn),
    .trap_valid       (trap_valid),
    .trap_target      (trap_target),
    .xret_valid       (mw_xret_valid & mw_valid & ~mw_exc_valid & ~trap_exc),
    .xret_kind        (mw_xret_kind),
    .mstatus_i        (mstatus_merged),
    .csr_wen          (csr_wen_w),
    .csr_waddr        (mw_csr_addr),
    .csr_wdata        (mw_csr_wdata),
    .mstatus_set      (mstatus_set),
    .mstatus_clr      (mstatus_clr),
    .priv_o           (csr_priv_2),
    .eff_priv_o       (csr_eff_priv),
    .mprv_o           (csr_mprv),
    .sum_o            (csr_sum),
    .mxr_o            (csr_mxr),
    .mpp_o            (csr_mpp),
    .tvm_o(obs_tvm_o),
    .tw_o             (csr_tw),
    .tsr_o            (csr_tsr),
    .fetch_priv_is_m_o(csr_fetch_is_m),
    .flush_req        (priv_flush_req),
    .priv_next_o      (priv_next)
    );
    assign csr_priv = csr_priv_2[0];

    wire [1:0]  trap_target;
    wire [31:0] trap_cause, trap_tval, trap_epc, trap_pc, trap_redirect_pc;
    wire [3:0]  trap_we;
    wire [31:0] trap_epc_i, trap_cause_i, trap_tval_i, trap_data_i;

    trap_ctrl u_trap_ctrl (
    .commit_valid  (mw_valid),
    .commit_pc     (mw_pc),
    .commit_pc_next(mw_pc_next),
    .commit_insn   (mw_insn_raw),
    //   ★ 异常标记必须与 `mw_valid` 相与（2026-09-15 修复）：`mw_exc_valid` 是随流水
    //     携带的**电平**载荷，W 槽被清空（mw_valid=0）后仍会保持上一拍的值 ⇒ 若直接把
    //     裸信号送进 trap_ctrl（`trap_valid = exc_valid | any_irq_v`），会**逐拍重复取
    //     同一次陷阱**（本任务实测：陷阱后 mw_valid 被清 0，trap_valid 却持续有效 ⇒
    //     PC 反复回 mtvec、程序卡死；旧实现因"更年轻指令漏进 W 槽"凑巧遮住了该缺陷）。
    //     W 级 ABI 副作用一律以 `mw_valid` 为总门控（与 commit/csr/w_rf_we 同口径）。
    .exc_valid     (mw_valid & mw_exc_valid),
    .exc_cause     (mw_exc_cause),
    .exc_tval      (mw_exc_tval),
    .exc_is_fetch  (mw_exc_is_fetch),
    .priv          (csr_priv_2),
    .medeleg       (csr_medeleg),
    .mideleg       (csr_mideleg),
    .mip           (csr_mip),
    .mie           (csr_mie),
    .mstatus_i     (mstatus_merged),
    .mtvec         (csr_mtvec),
    .stvec         (csr_stvec),
    .trap_valid    (trap_valid),
    .trap_is_int   (trap_is_int),
    .trap_target   (trap_target),
    .trap_cause    (trap_cause),
    .trap_tval     (trap_tval),
    .trap_epc      (trap_epc),
    .trap_pc       (trap_pc),
    .trap_we       (trap_we),
    .trap_epc_i    (trap_epc_i),
    .trap_cause_i  (trap_cause_i),
    .trap_tval_i   (trap_tval_i),
    .trap_data_i   (trap_data_i),
    .trap_wr_m_epc(obs_trap_wr_m_epc),
    .trap_wr_m_cause(obs_trap_wr_m_cause),
    .trap_wr_m_tval(obs_trap_wr_m_tval),
    .trap_wr_s_epc(obs_trap_wr_s_epc),
    .trap_wr_s_cause(obs_trap_wr_s_cause),
    .trap_wr_s_tval(obs_trap_wr_s_tval),
    .redirect_pc   (trap_redirect_pc)
    );

    assign redirect_exc_v  = trap_valid | xret_redirect | fencei_busy;
    //   优先级：trap > xRET > fence.i（三者合并走 pc_gen 的异常/中断入口，
    //   该入口在 pc_gen 内高于 BRU 与断点 ⇒ 全局次序 trap > xRET > fence.i > BRU > 断点）。
    assign redirect_exc_pc = trap_valid    ? trap_redirect_pc :
                             xret_redirect ? xret_epc_pc      :
                                             fencei_pc_q;

    //==========================================================================
    // 10.1 xPP（xPP/xPIE/xIE）陷阱语义 —— 根因已在子模块修复，顶层**无**纠正层
    //--------------------------------------------------------------------------
    //   【历史】上一轮（2026-09-15 R3）曾在此加过一段"xPP 读-写时序纠正层"：
    //   顶层改写 priv_ctrl 送来的 mstatus 置位/清除向量（陷阱 MPP 替换 + 把
    //   "xRET ⇒ xPP←U" 的清除延后一拍，寄存器 `xret_xpp_msk_q`），以绕过两处
    //   **子模块根因**：
    //     ① priv_ctrl `trap_set_m` 把**旧 MPP** 当新 MPP（规范要求 xPP ← 陷阱发生
    //        时的特权级 y）；S 组 SPP 亦为"只置位不替换"；
    //     ② csr_file `mstatus_o = (view & ~clr) | set`：**读视图**被同拍 clr/set
    //        污染 ⇒ priv_ctrl 同一拍读到的 xIE/xPIE/xPP 是"更新后"的值
    //        （MPIE 恒 0、MIE 恒 1、mret 读到被自己清掉的 MPP ⇒ 目标恒 U）。
    //   【现状】两处根因已按规范修好（priv_ctrl.v §3.1 替换语义 + 读**前值**；
    //   csr_file.v §5 读视图不含同拍 clr/set）⇒ 纠正层**整段删除**，`mstatus_set`/
    //   `mstatus_clr` 由 priv_ctrl 直连 csr_file（见 §10 例化处）。收益：三层组合环
    //   （priv_ctrl ↔ csr_file ↔ trap_ctrl）一并消除（Verilator UNOPTFLAT -3）。
    //==========================================================================

    //==========================================================================
    // 11. AXI 侧：axi_req_desc + axi_master_ctrl + mshr_simple（唯一总线主端口）
    //==========================================================================
    // ---- 11.1 请求仲裁（单笔在途；优先级：写回 > D 填充 > M 数据 > XIP 取指 > I 填充）----
    wire axi_busy, axi_req_ready, axi_wdata_ready, axi_resp_error;
    wire [1:0] axi_resp_code;
    wire [2:0] axi_ctrl_owner;
    wire axi_rdata_last;
    wire [3:0]  axi_rdata_id;
    wire axi_ctrl_done;
    wire [2:0] axi_ctrl_done_owner;
    wire [31:0] axi_ctrl_done_addr;

    //   ★ D4 记账要点：MDTA 的完成判定在 done 脉冲那一拍（axi_done_q=1），而
    //     AXI 控制器在 ST_DONE 之后**已释放总线**（axi_free=1）——若 want 只看
    //     状态位，会在"done 已到、M FSM 尚未离开 M_S_AXI"的那一拍**重复发起同一笔
    //     MDTA 事务**（M1 实测：UART 的 sb 连发两次 AW ⇒ 同一字符写两遍）。
    //     故 want 必须排除 done 拍（M_S_AXI 收到 done 当拍就完成并转 IDLE）。
    //   ★ 冲刷拍（m_kill_fsm=kill_young）同样必须排除：该拍 M 槽指令已被判定作废，
    //     不得再为它发起新的 MDTA 请求（在途记账兜底，见文件头 §2j）。
    wire m_axi_want   = (m_state_q == M_S_AXI) & ~axi_done_q & ~m_kill_fsm;
    wire axi_free     = (axi_owner_q == AXO_NONE) & ~axi_busy;
    wire grant_wrbk   = axi_free &  l1d_wb_req;
    wire grant_dfil   = axi_free & ~l1d_wb_req &  l1d_fill_req;
    wire grant_mdta   = axi_free & ~l1d_wb_req & ~l1d_fill_req &  m_axi_want;
    wire grant_xipf   = axi_free & ~l1d_wb_req & ~l1d_fill_req & ~m_axi_want & xip_req_go;
    wire grant_ifil   = axi_free & ~l1d_wb_req & ~l1d_fill_req & ~m_axi_want &
                        ~xip_req_go & l1i_fill_req;
    wire axi_req_go   = grant_wrbk | grant_dfil | grant_mdta | grant_xipf | grant_ifil;

    wire [2:0]  axi_owner_sel = grant_wrbk ? AXO_WRBK :
                                grant_dfil ? AXO_DFIL :
                                grant_mdta ? AXO_MDTA :
                                grant_xipf ? AXO_XIPF : AXO_IFIL;
    wire [31:0] axi_req_addr_sel = grant_wrbk ? l1d_wb_paddr :
                                   grant_dfil ? l1d_fill_paddr :
                                   grant_mdta ? m_mmio_pa_q :
                                   grant_xipf ? fu_fetch_req_pa :
                                                l1i_fill_paddr;
    wire [4:0]  axi_req_beats_sel = grant_wrbk ? (l1d_wb_beats + 5'd1) :
                                    grant_dfil ? (l1d_fill_beats + 5'd1) :
                                    grant_mdta ? 5'd1 :
                                    grant_xipf ? 5'd1 :
                                                 (l1i_fill_beats + 5'd1);
    // ---- 11.1.1 ★ D4 修复：MDTA（M 级平台 MMIO/XIP 数据访问）的**写支持** ----
    //   原实现只把 `grant_wrbk`（L1D 脏行写回）认成写：
    //     · axi_req_iswr_sel = grant_wrbk ⇒ 对 UART 的 sb 被当**读**发出（AR）；
    //     · W 数据通路固定取 l1d_wb_*（写回数据流）⇒ MMIO store 无数据可发；
    //     · M_S_AXI 完成判定按"读"取 rdata ⇒ 写事务无从完成。
    //   新口径：
    //     · is_write = 写回 **或** （MDTA 且该笔是写：m_mmio_we_q 在 M_S_ISS 锁存）
    //       ⇒ axi_master_ctrl 据此**互斥**走 AW/W/B（写）或 AR/R（读）；
    //     · W 数据/字节使能：写回取 L1D 写回流（l1d_wb_ready/l1d_wb_data），
    //       MDTA 写取 M 级锁存的 store 数据/字节使能（m_mmio_wdata_q/m_mmio_strb_q）
    //       —— 同一 mux 覆盖"在途写事务"的整个 ST_AW/ST_W 阶段；
    //     · 完成：等 B 响应后的 done（见 §11.6 的 done owner 记账）。
    wire axi_mdta_wr      = (axi_owner_q == AXO_MDTA) & axi_is_wr_q;   // 在途 MDTA 写
    wire axi_wdata_is_l1d = grant_wrbk | ((axi_owner_q == AXO_WRBK) & axi_is_wr_q);
    wire axi_wdata_valid_sel = axi_wdata_is_l1d ? l1d_wb_ready : axi_mdta_wr;
    wire [31:0] axi_wdata_data_sel = axi_wdata_is_l1d ? l1d_wb_data : m_mmio_wdata_q;
    wire [3:0]  axi_wstrb_sel      = axi_wdata_is_l1d ? 4'hF : m_mmio_strb_q;

    wire axi_req_iswr_sel = grant_wrbk | (grant_mdta & m_mmio_we_q);

    // ---- 11.2 axi_req_desc：PMA 译码 + 4 K 拆分描述符（地址窗口唯一实现处）----
    wire        desc_valid_t, desc_split_t, desc_legal_t;
    wire [31:0] desc_addr_t;
    wire [3:0]  desc_len_t, desc_cache_t, desc_id_t;
    wire [2:0]  desc_size_t, desc_prot_t, desc_lock_t;
    wire [1:0]  desc_burst_t;
    wire [4:0]  desc_beats_t, desc_to_4k_t;
    wire        pma_cacheable_t, pma_uncached_t, pma_is_ddr_t, pma_is_xip_t;
    wire        pma_is_clint_t, pma_is_plic_t, pma_is_apb_t, pma_is_confreg_t;
    wire        pma_is_mac_t, pma_must_intercept_t;

    axi_req_desc #(
    .ADDR_W (32), .LEN_W (4), .SIZE_W (3), .BURST_W (2),
    .CACHE_W(4), .PROT_W(3), .ID_W  (4)
    ) u_axi_req_desc (
    .req_valid        (axi_req_go),
    .req_paddr        (axi_req_addr_sel),
    .req_beats        (axi_req_beats_sel),
    .req_is_write     (axi_req_iswr_sel),
    .req_id           (`RV32GC_AXI_ID_I_FILL),
    .pma_cacheable    (pma_cacheable_t),
    .pma_uncached     (pma_uncached_t),
    .pma_is_ddr       (pma_is_ddr_t),
    .pma_is_xip       (pma_is_xip_t),
    .pma_is_clint     (pma_is_clint_t),
    .pma_is_plic      (pma_is_plic_t),
    .pma_is_apb       (pma_is_apb_t),
    .pma_is_confreg   (pma_is_confreg_t),
    .pma_is_mac       (pma_is_mac_t),
    .pma_must_intercept(pma_must_intercept_t),
    .desc_valid       (desc_valid_t),
    .desc_addr        (desc_addr_t),
    .desc_len         (desc_len_t),
    .desc_size        (desc_size_t),
    .desc_burst       (desc_burst_t),
    .desc_cache       (desc_cache_t),
    .desc_prot        (desc_prot_t),
    .desc_lock        (desc_lock_t),
    .desc_id          (desc_id_t),
    .desc_beats       (desc_beats_t),
    .desc_split       (desc_split_t),
    .desc_legal       (desc_legal_t),
    .desc_to_4k       (desc_to_4k_t)
    );

    // ---- 11.3 ★ 接线要点 2：beats_1/beats_2 在 core_top 换算 ----
    //   首笔 = min(desc_beats, 4 K 边界内 beat 数)；第二笔 = 总 beat 数 - 首笔。
    //   2A 的请求只有两类：① 32 B 行填充（8 beat，行基址 32 B 对齐 ⇒ 不跨 4 K）；
    //   ② MMIO/XIP 单 beat。⇒ desc_split 恒 0、第二笔恒 0；公式仍按规格完整实现。
    wire [4:0] axi_beats_1 = (desc_to_4k_t < desc_beats_t) ? desc_to_4k_t : desc_beats_t;
    wire [4:0] axi_beats_2 = axi_req_beats_sel - axi_beats_1;

    axi_master_ctrl #(
    .ADDR_W (32), .DATA_W (32), .STRB_W (4), .ID_W (4), .LEN_W (4),
    .SIZE_W (3),  .BURST_W(2),  .CACHE_W(4), .PROT_W(3), .OWNER_W(3),
    // ★ D5：集成侧按描述符属性驱动 AxCACHE/WSTRB（单元 TB 契约值见该模块参数注释）
    .USE_REQ_ATTRS (1)
    ) u_axi_master_ctrl (
    .clk         (aclk),
    .rst_n       (aresetn),
    .req_valid   (axi_req_go),
    .req_is_write(axi_req_iswr_sel),
    .req_owner   (axi_owner_sel),
    .req_addr    (axi_req_addr_sel),
    .req_len     (desc_len_t),
    .req_beats   (axi_req_beats_sel),
    .req_split   (desc_split_t),
    .req_beats_1 (axi_beats_1),
    .req_beats_2 (axi_beats_2),
    .req_id      (`RV32GC_AXI_ID_I_FILL),
    .req_ready   (axi_req_ready),
    // ---- 请求属性（★ D5：AxCACHE 按描述符 PMA 字段、WSTRB 按本笔字节使能）----
    .req_cache   (desc_cache_t),
    .req_strb    (axi_wstrb_sel),
    // ---- W 数据（★ D4：写回取 L1D 写回流；MDTA 写取 M 级锁存的 store 数据）----
    .wdata_valid (axi_wdata_valid_sel),
    .wdata_data  (axi_wdata_data_sel),
    .wdata_ready (axi_wdata_ready),
    .rdata_valid (axi_rdata_valid),
    .rdata_data  (axi_rdata_data),
    .rdata_id    (axi_rdata_id),
    .rdata_last  (axi_rdata_last),
    .rdata_ready (1'b1),
    .done        (axi_ctrl_done),
    .done_owner  (axi_ctrl_done_owner),
    .done_addr   (axi_ctrl_done_addr),
    .resp_error  (axi_resp_error),
    .resp_code   (axi_resp_code),
    .m_awid      (awid),
    .m_awaddr    (awaddr),
    .m_awlen     (awlen),
    .m_awsize    (awsize),
    .m_awburst   (awburst),
    .m_awlock    (awlock_raw),
    .m_awcache   (awcache),
    .m_awprot    (awprot),
    .m_awvalid   (awvalid),
    .m_awready   (awready),
    .m_wdata     (wdata),
    .m_wstrb     (wstrb),
    .m_wlast     (wlast),
    .m_wvalid    (wvalid),
    .m_wready    (wready),
    .m_bid       (bid),
    .m_bresp     (bresp),
    .m_bvalid    (bvalid),
    .m_bready    (bready),
    .m_arid      (arid),
    .m_araddr    (araddr),
    .m_arlen     (arlen),
    .m_arsize    (arsize),
    .m_arburst   (arburst),
    .m_arlock    (arlock_raw),
    .m_arcache   (arcache),
    .m_arprot    (arprot),
    .m_arvalid   (arvalid),
    .m_arready   (arready),
    .m_rid       (rid),
    .m_rdata     (rdata),
    .m_rresp     (rresp),
    .m_rlast     (rlast),
    .m_rvalid    (rvalid),
    .m_rready    (rready),
    .busy        (axi_busy),
    .owner       (axi_ctrl_owner)
    );

    // ★ awlock/arlock：高位显式置 0（08 §4.2 规则 2；平台只接 [0:0]）
    wire [2:0] awlock_raw, arlock_raw;
    assign awlock = {1'b0, awlock_raw[0]};
    assign arlock = {1'b0, arlock_raw[0]};
    assign wid    = `RV32GC_AXI_ID_I_FILL;      // 2A 单笔在途只发 ID 0

    // ---- 11.4 缓存侧握手与 beat 记账 ----
    wire axi_fire_req = axi_req_go & axi_req_ready;
    assign axi_fill_accept_ifil = axi_fire_req & (axi_owner_sel == AXO_IFIL);
    assign axi_fill_accept_dfil = axi_fire_req & (axi_owner_sel == AXO_DFIL);
    assign axi_wb_accept        = axi_fire_req & (axi_owner_sel == AXO_WRBK);

    assign axi_fill_valid    = axi_rdata_valid;
    assign axi_fill_data     = axi_rdata_data;
    assign axi_fill_word_idx = axi_beat_q;
    assign axi_fill_done     = axi_rdata_valid & axi_rdata_last;

    wire axi_wb_fire = wvalid & wready;
    assign axi_wb_word_idx = axi_beat_q;
    assign axi_wb_done     = axi_wb_fire & (axi_beat_q == (axi_beats_q - 5'd1));

    // ---- 11.5 mshr_simple：2A 简化 MSHR（每侧 1 项在途）----
    //   用途：作为**缓存行事务**的在途跟踪（busy/owner/paddr + done 归属），
    //   与 axi_master_ctrl 的 busy/owner 互为交叉校验（单笔在途三件套）。
    wire        mshr_alloc_req   = axi_fire_req & ((axi_owner_sel == AXO_IFIL) |
                                                   (axi_owner_sel == AXO_DFIL) |
                                                   (axi_owner_sel == AXO_WRBK));
    wire        mshr_alloc_ready, mshr_busy, mshr_done, mshr_fill_ready;
    wire [2:0]  mshr_owner, mshr_done_owner;
    wire [31:0] mshr_paddr, mshr_done_paddr;
    wire [4:0]  mshr_beats;
    wire [2:0]  mshr_alloc_owner = (axi_owner_sel == AXO_IFIL) ? 3'd0 :
                                   (axi_owner_sel == AXO_DFIL) ? 3'd1 : 3'd2;

    mshr_simple #(
    .ADDR_W (32), .DATA_W (32), .BEATS_W (5), .OWNER_W (3)
    ) u_mshr_simple (
    .clk         (aclk),
    .rst_n       (aresetn),
    .alloc_req   (mshr_alloc_req),
    .alloc_owner (mshr_alloc_owner),
    .alloc_paddr (axi_req_addr_sel),
    .alloc_beats (axi_beats_1 - 5'd1),
    .alloc_ready (mshr_alloc_ready),
    .busy        (mshr_busy),
    .owner       (mshr_owner),
    .paddr       (mshr_paddr),
    .beats       (mshr_beats),
    .fill_valid  (axi_rdata_valid),
    .fill_data   (axi_rdata_data),
    .fill_ready  (mshr_fill_ready),
    .done        (mshr_done),
    .done_owner  (mshr_done_owner),
    .done_paddr  (mshr_done_paddr)
    );

    // ---- 11.6 总线事务记账（owner/beat/done 的唯一定义处）----
    //   ★ D4 记账要点：axi_ctrl_done（单拍）到达时 owner_q 会**同拍清成 NONE**
    //     ⇒ "owner_q == AXO_MDTA & axi_done_q" 的组合式永远不成立（完成事件丢失）。
    //     因此 done 脉冲必须**成对记下来源**（axi_done_owner_q / axi_done_wr_q），
    //     M 级 FSM 用这一对判定"本笔 MDTA 事务完成"。
    reg [2:0] axi_done_owner_q;
    reg       axi_done_wr_q;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            axi_owner_q <= AXO_NONE;
            axi_beat_q  <= 5'd0;
            axi_beats_q <= 5'd0;
            axi_is_wr_q <= 1'b0;
            axi_done_q  <= 1'b0;
            axi_done_owner_q <= AXO_NONE;
            axi_done_wr_q    <= 1'b0;
        end else begin
            axi_done_q <= 1'b0;
            if (axi_owner_q == AXO_NONE) begin
                if (axi_fire_req) begin
                    axi_owner_q <= axi_owner_sel;
                    axi_beats_q <= axi_beats_1;
                    axi_is_wr_q <= axi_req_iswr_sel;
                    axi_beat_q  <= 5'd0;
                end
            end else if (~axi_is_wr_q) begin
                if (axi_rdata_valid) axi_beat_q <= axi_beat_q + 5'd1;
                if (axi_ctrl_done) begin
                    axi_done_q  <= 1'b1;
                    axi_done_owner_q <= axi_owner_q;
                    axi_done_wr_q    <= axi_is_wr_q;
                    axi_owner_q <= AXO_NONE;
                    axi_beat_q  <= 5'd0;
                end
            end else begin
                if (axi_wb_fire) axi_beat_q <= axi_beat_q + 5'd1;
                if (axi_ctrl_done) begin
                    axi_done_q  <= 1'b1;
                    axi_done_owner_q <= axi_owner_q;
                    axi_done_wr_q    <= axi_is_wr_q;
                    axi_owner_q <= AXO_NONE;
                    axi_beat_q  <= 5'd0;
                end
            end
        end
    end

    //==========================================================================
    // 11.7 ★ 总线响应错误（SLVERR/DECERR）消费 —— 读 / 写 / 取指三通道
    //--------------------------------------------------------------------------
    //   背景（为什么顶层还要再锁存一道）：axi_master_ctrl 的 `resp_error` 是
    //   "错误可见脉冲"—— r_fire/b_fire 当拍有效，并靠 err_pending_q **维持到
    //   ST_DONE 拍**；而本文件的 `axi_done_q` 是 done 的**下一拍**（§11.6 记账）
    //   ⇒ 两者不同龄，直接拿 `axi_done_q & axi_resp_error` 永远为假。故把错误锁存
    //   进 `axi_err_q`，供"done 拍"的消费者判读。
    //
    //   三通道各自认领（互不串扰）：
    //     · 数据读（MDTA 读：本核数据侧唯一通路，含 lb/lh/lw/fld/lr）⇒ cause 5
    //     · 数据写（MDTA 写：含 sb/sh/sw/fsd 及 AMO/SC 的写相）      ⇒ cause 7
    //     · 取指（L1I 行填充 AXO_IFIL / XIP 直连取指 AXO_XIPF）      ⇒ cause 1
    //   每笔事务起点（axi_fire_req）清 axi_err_q ⇒ done 拍读到的错误必属**本笔**，
    //   不会把上一笔（如取指填充）的错误误记到本笔数据访问上。
    //
    //   ★ 未覆盖（**明确记录**，不写不可达死逻辑）：L1D 行填充（AXO_DFIL）与脏行
    //     写回（AXO_WRBK）的响应错误。2A 集成下数据侧**全部**经 MDTA
    //     （mmio_route 把除 CLINT/PLIC/XIP 外的所有 PA 判为 ROUTE_AXI，L1D 只服务
    //     XIP 路由），DFIL/WRBK 在本核数据通路上不可达。后续接入 D-Cache 时须补：
    //     行填充错误 ⇒ 该行 load/store 报 access fault 并**不得装入**该行；
    //     写回错误 ⇒ 该行中毒，后续对该行的 store 报 cause 7。
    //==========================================================================
    reg        axi_err_q;         // 本笔总线事务收到非 OKAY 响应（锁存至事务起点）
    reg  [1:0] axi_err_code_q;    // 最近一次非 OKAY 的 resp 编码（诊断）
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            axi_err_q      <= 1'b0;
            axi_err_code_q <= 2'b00;
        end else if (axi_resp_error) begin
            axi_err_q      <= 1'b1;
            axi_err_code_q <= axi_resp_code;
        end else if (axi_fire_req) begin
            axi_err_q      <= 1'b0;   // 新事务开始 ⇒ 上一笔的错误已过"认领拍"
        end
    end

    // ---- 数据通道：错误 ⇒ access fault 的原因码（写类恒 7；纯读恒 5）----
    //   与 lsu/PMP 的口径一致：AMO/SC 无论读相写相都属"store/AMO access fault"
    //   （`RV32GC_EXC_STORE_ACCESS_FAULT` 的注释即为此），LR/load 为 cause 5。
    wire m_bus_err_is_store = m_mem_wr_op | m_amo_write |
                              (em_mem_op == MEM_AMO) | (em_mem_op == MEM_SC);
    wire [4:0] m_bus_err_cause = m_bus_err_is_store ? `RV32GC_EXC_STORE_ACCESS_FAULT
                                                    : `RV32GC_EXC_LOAD_ACCESS_FAULT;

    // ---- 取指通道：按"取指事务地址"锁存错误行（IFIL=行基址 / XIPF=字地址）----
    //   ★ 为什么按地址**粘滞**而不是"一次性上报"：错误行的填充数据是垃圾，而 L1I
    //     仍会把该行装入阵列并在此后从 Cache 命中送出 —— 若只报一次，后续落在同一
    //     行的取指会**静默放行**（本例 jalr 到 PA 0 后若再跳一次即复现）。
    //     比对对象 `fu_fetch_req_pa` 是**取指事务地址**（cacheable=行基址 /
    //     uncached=字地址），由 fetch_unit 直接自 PC 派生（不受 fetch_pause 影响）
    //     ⇒ 与 fetch_pause 之间**不构成组合环**。
    //   ★ 粘滞槽只有 1 个（记住"最近一次出错的事务地址"）：对静态地址映射的 TB/
    //     平台是充分的（出错地址集合固定）；后续如需多行中毒，扩成小表即可。
    wire axi_err_ifetch = axi_resp_error & ((axi_owner_q == AXO_IFIL) |
                                            (axi_owner_q == AXO_XIPF));
    reg        fetch_bus_err_q;
    reg [31:0] fetch_bus_err_pa_q;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            fetch_bus_err_q    <= 1'b0;
            fetch_bus_err_pa_q <= 32'h0;
        end else if (axi_err_ifetch) begin
            fetch_bus_err_q    <= 1'b1;
            fetch_bus_err_pa_q <= axi_ctrl_done_addr;   // 本笔取指事务地址（addr_q）
        end
    end
    assign fetch_bus_err = fetch_bus_err_q & (fu_fetch_req_pa == fetch_bus_err_pa_q);

    //==========================================================================
    // 12. E→M / M→W 的组合推进与提交（12.x 全部为 assign / function）
    //==========================================================================
    // ---- 12.0 本节的组合载荷声明（供 §13 时序块引用）----
    wire        em_go, mw_go, mw_cap;
    wire        m_exc_any, mw_n_excv;
    wire        m_ptw_req_valid;
    wire        m_lsu_req_valid;
    // ---- 12.1 E 级异常汇总（D 级非法 + E 级特权违规 + ecall/ebreak）----
    //   优先级：携带异常（取指）> 非法指令 > ecall/ebreak（同一条指令最多一个）
    wire [4:0] e_exc_cause =
        de_exc_valid        ? de_exc_cause      :
        e_ill_total         ? `RV32GC_EXC_ILLEGAL_INSN :
        de_ebreak           ? `RV32GC_EXC_BREAKPOINT   :
        de_ecall            ? e_ecall_cause            :
                              `RV32GC_EXC_ILLEGAL_INSN;
    wire [31:0] e_exc_tval =
        de_exc_valid ? de_exc_tval :
        e_ill_total  ? de_exc_tval :      // T1：非法指令写原始指令位
        de_ebreak    ? de_pc :
        de_ecall     ? de_pc :
                       32'h0;
    wire e_exc_v = de_valid & (de_exc_valid | e_ill_total | de_ebreak | de_ecall);

    // ---- 12.2 EM 下一拍载荷（便于时序块内一次赋值）----
    wire e_mdu_fp_sel = (de_op_type == OPT_MDU);
    wire [31:0] e_result_sel =
        (de_op_type == OPT_MDU)        ? e_mdu_val :
        (de_wb_sel == WB_PC4)          ? e_link    :
        (de_wb_sel == WB_FP)           ? e_fpu_val[31:0] :
                                         e_alu_result;

    wire [63:0] e_fp_wdata_sel =
        (de_op_type == OPT_FPLD) ? 64'h0 :        // flw/fld 的写数据在 M 级取回
                                    e_fpu_val;

    wire em_n_valid   = de_valid;
    wire [31:0] em_n_pcnext = e_link;             // 分支/跳转目标由 BRU 另行重定向
    wire [2:0]  em_n_wbsel  = de_wb_sel;
    wire [31:0] em_n_result = e_result_sel;
    wire [3:0]  em_n_memop  = de_mem_op;
    wire [63:0] em_n_fpwdata= e_fp_wdata_sel;
    wire [4:0]  em_n_fflags = e_fp_fflags_val;
    wire        em_n_excv   = e_exc_v;
    wire [4:0]  em_n_exccause = e_exc_cause;
    wire [31:0] em_n_exctval  = e_exc_tval;
    wire [31:0] em_n_excpc    = de_pc;

    assign em_go = pipe_adv;

    // ---- 12.3 M→W ----
    assign m_exc_any = em_exc_valid | m_exc_q;
    wire [4:0]  m_exc_cause_sel = em_exc_valid ? em_exc_cause : m_exc_cause_q;
    wire [31:0] m_exc_tval_sel  = em_exc_valid ? em_exc_tval  : m_exc_tval_q;

    wire mw_n_valid = em_valid;
    wire [2:0] mw_n_wbsel = em_wb_sel;
    assign mw_n_excv = m_exc_any;
    wire [4:0]  mw_n_exccause = m_exc_cause_sel;
    wire [31:0] mw_n_exctval  = m_exc_tval_sel;

    assign mw_go  = em_valid & m_mem_done;      // ★ 访存完成（含锁存态）才放行

    // ---- 12.3.1 ★ 冲刷门控（2026-09-15 修复"陷阱/fence.i 冲刷洞"）----
    //   `fencei_sync_pending` = 本拍 W 槽正是**即将启动同步**的 fence.i：
    //   条件与 §13(9) 的"启动全阵列失效扫描"逐字一致（唯一定义处，两处共用）。
    //   为什么不能只靠 kill_young：kill_young（= fencei_busy）从**下一拍**才拉高，
    //   而 M 槽的那条 fence.i+4 恰在本拍被放行 ⇒ 会在窗口内提交一次、窗口后重取
    //   再提交一次（实测：fence.i+4 提交 2 次）。
    wire fencei_sync_pending =
        mw_valid & mw_fence_i & ~mw_exc_valid & ~trap_exc & ~fencei_busy;

    // M→W 放行：M 槽指令已完成，且本拍**不是**冲刷拍（kill_young）也不是
    // fence.i 同步启动拍 —— 这两种情况下 M 槽持的都是"比陷阱指令/fence.i 更年轻"
    // 的指令，绝不允许进入 W（否则下一拍被提交：instret/CSR/FP 副作用越界）。
    //   ★ 不再含 `~bru_redirect`：分支在 E 解析时 M 槽持**更老**指令，必须照常提交
    //     （见文件头 §2b/§2j；旧式把更老提交一并丢掉）。
    assign mw_cap = mw_go & ~kill_young & ~fencei_sync_pending;

    // ---- 12.4 M 级的读回/写回数据与旁路 ----
    assign m_wdata =
        (em_wb_sel == WB_MEM) ? m_rd_data_q :
        (em_wb_sel == WB_CSR) ? em_csr_rdata :
        (em_wb_sel == WB_FP)  ? em_fp_wdata[31:0] :
        (em_wb_sel == WB_MDU) ? em_result :
        (em_wb_sel == WB_PC4) ? em_pc_next :
                                em_result;
    assign m_rd   = em_rd;
    assign m_rf_we= em_valid & (em_wb_sel != WB_NONE) & (em_rd != 5'd0) &
                    ~m_exc_any & m_mem_done;    // ★ 只用"访存已完成"的锁存态

    // ---- ★ FLW/FLD 写回浮点寄存器堆的数据（NaN-boxing 口径，2026-09-17 修复）----
    //   现象（实测 arch-test rv32i/F）：flw 之后所有以该 f 寄存器为操作数的 FP
    //   指令都按 S canonical NaN 参与运算 —— F-feq.s-00 的判等结果与 NV 标志整片
    //   偏差（feq(+0,+0) 给 0 而非 1）、F-fadd.s-01 结果全是 0x7FC0_0000、
    //   F-fcvt.w.s-00 的负溢出饱和方向"错"（其实输入被替换成了 canonical NaN ⇒
    //   按 NaN 规则给正最大 0x7FFF_FFFF，而 spike 给 0x8000_0000）。
    //   根因：E 级 `e_fp_wdata_sel` 对 OPT_FPLD 恒给 64'h0（注释说"写数据在 M 级取回"
    //   —— 但 M/W 侧从来**没有**把 `m_rd_data_q` 接进 FP 写口）⇒ flw 把 0 写进
    //   fregfile（高 32 位也不是全 1）⇒ d-st-ext.adoc:52-59 的 NaN-boxing 检查
    //   （fpu.v §3① / fpu_cmp.v §5）判"非 boxed"、按 0x7FC0_0000 参与运算。
    //   修复：M→W 捕获时把已完成的 load 数据接进 `mw_fp_wdata`：
    //     · FLW（size=2）⇒ 低 32 位 = 载入字，高 32 位全 1（NaN-boxed，
    //       d-st-ext.adoc:45-47 norm:FP_transfer_instrs_narrow_transfer_in）
    //     · FLD（size=3）⇒ 完整 64 位 = {m_rd_hi_q, m_rd_data_q[31:0]}
    //       （两半由 M 级 FSM 的 8 B 两阶段访问分别锁存；2026-09-17 修复）
    //   ★ 缺陷修复记录（2026-09-17，D 扩展）：原式 `m_size8 ? m_rd_data_q : …`
    //     把 32 bit 的 `m_rd_data_q` 零扩展成 64 bit ⇒ **fld 的高 32 位恒 0**。
    //     后果（arch-test rv32i/D 实测 71/104 失败，全部由本缺陷派生）：
    //       · fclass.d 的 D 操作数高字（含符号与指数高位）恒 0 ⇒ 恒判 +亚正规
    //         （实测恒 0x20，spike 为 0x40/0x02 等）；
    //       · 所有 D 算术的操作数被替换成"符号 0、指数 0"的极小亚正规数
    //         ⇒ 结果错、flags 错（本该 NX 的精确和、本不该 UF 的乘积…）；
    //       · fsd 存出的高 4 B 是垃圾（见 M_S_AXI 的另一半修复）。
    wire [63:0] m_fp_ld_wdata = m_size8 ? {m_rd_hi_q, m_rd_data_q[31:0]}
                                        : {32'hFFFF_FFFF, m_rd_data_q[31:0]};

    // load-use 停顿：M 级是对 GPR 的 load/AMO/LR/SC **且其结果尚未可用**，
    //   而紧随其后的 E 级指令要用该 rd ⇒ 本拍不推进（F/D/E 冻结）。
    //   ★ 完成即解除（~m_mem_done，而非仅 ~m_done_q）：
    //     · m_done_q 只维持一拍；若那一拍恰因 E 级多拍（MDU/FPU）而 pipe_adv=0，
    //       下一拍 m_done_q 已清零 ⇒ 若不加锁存态，本条件自保持 ⇒ **死锁**
    //       （EM 永远不换人、访存 FSM 还会重复启动）。
    //     · 解除当拍 m_rf_we=1、m_wdata=m_rd_data_q ⇒ E 级经 M 旁路取到 load 数据，
    //       随 em_go 锁存进 em_rs1_val/em_store_data（不造组合提前转发路径）。
    wire m_is_load_kind = (em_mem_op == MEM_LOAD) | (em_mem_op == MEM_AMO) |
                          (em_mem_op == MEM_LR)   | (em_mem_op == MEM_SC);
    wire e_use_rs1 = (de_rs1 != 5'd0) & (~de_ill);
    wire e_use_rs2 = (de_rs2 != 5'd0) & (~de_ill) &
                     ((de_insn32[6:0] == `RV32GC_OP_OP) |
                      (de_mem_op == MEM_STORE) | (de_mem_op == MEM_AMO) |
                      (de_mem_op == MEM_SC) | (de_mem_op == MEM_FSTORE) |
                      (de_op_type == OPT_BRU) | (de_op_type == OPT_JALR));
    //==========================================================================
    // 12.5 ★★ FP load-use / FP 结果前递（**M → E**，2026-09-17 新增显式互锁）
    //--------------------------------------------------------------------------
    // 为什么必须显式做（而不是靠 fregfile 的写优先旁路）：
    //   fregfile 的写优先旁路只覆盖 **W 槽**（写口在 W，见 fregfile.v §11②）。
    //   若 E 槽消费者与 M 槽生产者"紧邻"（中间无气泡），E 组合读口读到的是**旧值**：
    //     · FP load（flw/fld）在 M 要等访存完成（8 B 还要两阶段）⇒ 结果此刻还不在
    //       fregfile，也不在 W 写口；
    //     · OP-FP/FMA 的结果在 M 槽的 em_fp_wdata（W 才落 fregfile）；
    //     · FPU 是"派发拍采样操作数"的单元（fpu.v §2）⇒ 一旦带旧操作数派发，
    //       之后再停拍也救不回来 ⇒ 必须**同时**做"停拍 + M→E 前递"。
    //
    // 口径（与整数 load-use 同一风格，不引入新状态机）：
    //   ①前递源 = M 槽**会写 FP 寄存器**的指令（em_fp_we；含 FP load 与 OP-FP/FMA）；
    //     数据 = FP load 取回值（NaN-boxing 口径见 §12.4 的 m_fp_ld_wdata）或
    //     随流水携带的 em_fp_wdata；FP load 在 m_mem_done 之前**不算就绪**。
    //   ②使用判定 = E 槽的 FP 源（OP-FP/FMA 的 fs1/fs2、FMA 的 fs3、FP store 的存数 fs2）
    //     与 M 槽目的号相等。★ **f0 是普通 FP 寄存器**（与 x0 不同）⇒ 这里
    //     **不**排除 0 号（整数侧排除 x0 是因为写 x0 无效果）。
    //   ③未就绪（FP load 在途）⇒ `fp_load_use_stall`：冻结 E（并入门控 load_use_stall）
    //     **且**禁止 FPU 派发（见 §7.5 的 e_fp_go）——否则 FPU 会在停拍前就带着旧
    //     操作数发出去。就绪那拍前递与 W 写口写优先**同时**生效，二者值相同（幂等）。
    //   ④fregfile 与 exe_ctrl 均无需改动：FP 读口只有本文件三处消费
    //     （u_fpu 的 a/b/c、em_fp_store 捕获），此处统一改走 e_fp_src*。
    //==========================================================================
    wire        m_fp_prod     = em_valid & em_fp_we & ~m_exc_any;
    wire        m_fp_prod_rdy = (em_mem_op != MEM_FLOAD) | m_mem_done;
    wire [63:0] m_fp_fwd_data = (em_mem_op == MEM_FLOAD) ? m_fp_ld_wdata
                                                         : em_fp_wdata;
    // E 槽 FP 源使用判定（保守但精确到"真会用该读口"的类别）
    wire e_fp_use1 = (de_op_type == OPT_FP) & ~e_fp_a_is_int & ~de_ill;   // fs1
    wire e_fp_use2 = ((de_op_type == OPT_FP) | (de_mem_op == MEM_FSTORE))
                     & ~de_ill;                                           // fs2 / 存数
    wire e_fp_use3 = (de_op_type == OPT_FP) & (de_fp_op == FP_FMA) & ~de_ill; // fs3
    wire e_fs1_hit = m_fp_prod & e_fp_use1 & (de_rs1 == em_fp_rd);
    wire e_fs2_hit = m_fp_prod & e_fp_use2 & (de_rs2 == em_fp_rd);
    wire e_fs3_hit = m_fp_prod & e_fp_use3 & (de_rs3 == em_fp_rd);
    wire fp_load_use_stall = ~m_fp_prod_rdy & (e_fs1_hit | e_fs2_hit | e_fs3_hit);
    // 前递后的 FP 源（fs1/fs2/fs3）：优先级 M（更年轻）> fregfile 读口（含 W 写优先）
    wire [63:0] e_fp_src1 = e_fs1_hit ? m_fp_fwd_data : freg_rdata1;
    wire [63:0] e_fp_src2 = e_fs2_hit ? m_fp_fwd_data : freg_rdata2;
    wire [63:0] e_fp_src3 = e_fs3_hit ? m_fp_fwd_data : freg_rdata3;

    assign load_use_stall = (em_valid & m_is_load_kind & (em_rd != 5'd0) &
                             ~m_mem_done &
                             ((e_use_rs1 & (de_rs1 == em_rd)) |
                              (e_use_rs2 & (de_rs2 == em_rd))))
                            | fp_load_use_stall;

    //==========================================================================
    // 13. 主时序块（流水寄存器 / GPR / FP-CSR / mstatus.FS / 计数 / M 级 FSM）
    //     理由（红线 3）：全部是不可用 assign 表达的状态元件
    //     （流水寄存器、GPR/FP-CSR 存储体、M 级 FSM）。无 always @(*)。
    //==========================================================================
    reg [63:0] cycle_cnt_r;
    reg [63:0] instret_cnt_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            //------------------------ FD ------------------------
            fd_valid <= 1'b0; fd_pc <= 32'h0; fd_pc_pa <= 32'h0;
            fd_insn <= 32'h0000_0013; fd_ilen32 <= 1'b1;
            fd_exc_valid <= 1'b0; fd_exc_cause <= 5'd0;
            fd_exc_tval <= 32'h0; fd_exc_pc <= 32'h0;
            //------------------------ DE ------------------------
            de_valid <= 1'b0; de_pc <= 32'h0; de_pc_pa <= 32'h0;
            de_insn32 <= 32'h0000_0013; de_insn_raw <= 32'h0000_0013; de_ilen32 <= 1'b1;
            de_rs1 <= 5'd0; de_rs2 <= 5'd0; de_rs3 <= 5'd0; de_rd <= 5'd0; de_imm <= 32'h0;
            de_op_type <= OPT_ALU; de_alu_op <= 4'd0; de_mem_op <= MEM_NONE;
            de_mem_size <= 3'd0; de_mem_unsign <= 1'b0; de_wb_sel <= WB_NONE;
            de_csr_op <= CSRN_NONE; de_fp_op <= FP_NONE; de_fp_we <= 1'b0;
            de_fp_ldst <= 1'b0; de_rm <= 3'd0; de_csr_addr <= 12'h0; de_csr_zimm <= 1'b0;
            de_cbo_kind <= 5'd0; de_cbo_valid <= 1'b0; de_cbo_downgrade <= 1'b0;
            de_fence_i <= 1'b0; de_ebreak <= 1'b0; de_ecall <= 1'b0;
            de_mret <= 1'b0; de_sret <= 1'b0; de_wfi <= 1'b0;
            de_ill <= 1'b0; de_exc_tval <= 32'h0; de_exc_valid <= 1'b0;
            de_exc_cause <= 5'd0; de_exc_pc <= 32'h0; de_exc_is_fetch <= 1'b0;
            //------------------------ EM ------------------------
            em_valid <= 1'b0; em_pc <= 32'h0; em_pc_next <= 32'h0;
            em_insn_raw <= 32'h0000_0013; em_rd <= 5'd0; em_wb_sel <= WB_NONE;
            em_result <= 32'h0; em_mem_op <= MEM_NONE; em_mem_size <= 3'd0;
            em_mem_unsign <= 1'b0; em_rs1_val <= 32'h0; em_imm_val <= 32'h0;
            em_store_data <= 32'h0; em_fp_store <= 64'h0;
            em_amo_f5 <= 5'd0; em_cbo_rs2 <= 5'd0; em_cbo_downgrade <= 1'b0;
            em_fence_i <= 1'b0;
            em_fp_we <= 1'b0; em_fp_rd <= 5'd0; em_fp_wdata <= 64'h0;
            em_fflags <= 5'd0; em_fflags_we <= 1'b0;
            em_csr_we <= 1'b0; em_csr_addr <= 12'h0; em_csr_wdata <= 32'h0;
            em_csr_rdata <= 32'h0; em_xret_valid <= 1'b0; em_xret_kind <= 2'd0;
            em_exc_valid <= 1'b0; em_exc_cause <= 5'd0; em_exc_tval <= 32'h0;
            em_exc_pc <= 32'h0; em_exc_is_fetch <= 1'b0;
            //------------------------ MW ------------------------
            mw_valid <= 1'b0; mw_pc <= 32'h0; mw_pc_next <= 32'h0;
            mw_insn_raw <= 32'h0000_0013; mw_wb_sel <= WB_NONE; mw_rd <= 5'd0;
            mw_wdata <= 32'h0; mw_fp_we <= 1'b0; mw_fp_rd <= 5'd0; mw_fp_wdata <= 64'h0;
            mw_csr_we <= 1'b0; mw_csr_addr <= 12'h0; mw_csr_wdata <= 32'h0;
            mw_xret_valid <= 1'b0; mw_xret_kind <= 2'd0; mw_fence_i <= 1'b0;
            mw_is_fp_instr <= 1'b0; mw_is_fp_wr <= 1'b0; mw_is_fpcsr_wr <= 1'b0;
            mw_exc_valid <= 1'b0; mw_exc_cause <= 5'd0; mw_exc_tval <= 32'h0;
            mw_exc_pc <= 32'h0; mw_exc_is_fetch <= 1'b0;
            //------------------------ 存储体 ------------------------
            for (gi = 0; gi < 32; gi = gi + 1) gpr[gi] <= 32'h0;
            fflags_r <= 5'd0; frm_r <= 3'd0; mstatus_fs <= FS_OFF;
            cycle_cnt_r <= 64'd0; instret_cnt_r <= 64'd0;
            //------------------------ E 级多拍 ------------------------
            mdu_issued_q <= 1'b0; mdu_res_v_q <= 1'b0; mdu_res_q <= 32'h0;
            fp_issued_q <= 1'b0; fpu_res_v_q <= 1'b0; fpu_res_q <= 64'h0;
            fpu_fflags_q <= 5'd0;
            //------------------------ F 级辅助 ------------------------
            fetch_exc_done_q <= 1'b0;
            xip_word_pa_q <= 32'h0; xip_word_data_q <= 32'h0; xip_word_vld_q <= 1'b0;
            xip_req_pend_q <= 1'b0;
            fencei_busy <= 1'b0; fencei_idx_q <= 8'd0; fencei_pc_q <= 32'h0;
            //------------------------ M 级 FSM ------------------------
            m_state_q <= M_S_IDLE; m_retry_q <= M_S_ISS; m_pa_q <= 32'h0;
            m_page_fault_q <= 1'b0; m_page_cause_q <= 5'd0;
            m_hi_q <= 1'b0; m_amo_phase_q <= 1'b0;
            m_exc_q <= 1'b0; m_exc_cause_q <= 5'd0; m_exc_tval_q <= 32'h0;
            m_rd_data_q <= 32'h0; m_rd_hi_q <= 32'h0;
            m_amo_wdata_q <= 32'h0; m_sc_ok_q <= 1'b0;
            m_sc_ok_cap_q <= 1'b0; m_sc_cap_q <= 1'b0;
            m_done_q <= 1'b0;
            m_issued_q <= 1'b0;
            m_mmio_clint_q <= 1'b0; m_mmio_plic_q <= 1'b0; m_mmio_we_q <= 1'b0;
            m_mmio_pa_q <= 32'h0; m_mmio_off_q <= 32'h0; m_mmio_wdata_q <= 32'h0;
            m_mmio_strb_q <= 4'h0;
            m_ptw_pte_ready_q <= 1'b0; m_ptw_pte_pa_q <= 32'h0;
            m_ptw_pte_resp_v_q <= 1'b0; m_ptw_pte_resp_d_q <= 32'h0;
            m_ptw_ad_done_q <= 1'b0;
        end else begin
            // ================= 默认脉冲清零 =================
            m_done_q          <= 1'b0;
            m_ptw_pte_ready_q <= 1'b0;
            m_ptw_pte_resp_v_q<= 1'b0;
            m_ptw_ad_done_q   <= 1'b0;

            // ================= (1) FD（F→D）=================
            if (kill_young | bru_redirect) begin
                fd_valid <= 1'b0;
            end else if (pipe_adv) begin
                fd_valid     <= fu_fetch_valid | fetch_exc_inject;
                // ★ mepc 口径：取指总线错误时 fu_fetch_insn_va 由 parcel_align 从
                //   取指数据推得（错误行的填充数据无意义，且错误可能在回填前就锁存）
                //   ⇒ 该情形改用**故障取指地址** fu_fetch_pc（与 fetch_exc_pc 同源）。
                fd_pc        <= fetch_bus_err ? fu_fetch_pc : fu_fetch_insn_va;
                fd_pc_pa     <= obs_fetch_pc_pa;
                fd_insn      <= fu_fetch_data;
                fd_ilen32    <= fu_fetch_ilen32;
                fd_exc_valid <= fetch_exc_inject;
                fd_exc_cause <= fetch_exc_cause;
                fd_exc_tval  <= fetch_exc_tval;
                fd_exc_pc    <= fetch_exc_pc;
            end

            // ================= (2) DE（D→E）=================
            if (kill_young | bru_redirect) begin
                de_valid <= 1'b0;
            end else if (pipe_adv) begin
                de_valid        <= fd_valid;
                de_pc           <= fd_pc;
                de_pc_pa        <= fd_pc_pa;
                de_insn32       <= dec_insn32;
                de_insn_raw     <= fd_insn;
                de_ilen32       <= fd_ilen32;
                de_rs1          <= dec_rs1;
                de_rs2          <= dec_rs2;
                de_rs3          <= dec_rs3;
                de_rd           <= dec_rd;
                de_imm          <= dec_imm;
                de_op_type      <= dec_op_type;
                de_alu_op       <= dec_alu_op;
                de_mem_op       <= dec_mem_op;
                de_mem_size     <= dec_mem_size;
                de_mem_unsign   <= dec_mem_unsign;
                de_wb_sel       <= dec_wb_sel;
                de_csr_op       <= dec_csr_op;
                de_fp_op        <= dec_fp_op;
                de_fp_we        <= dec_fp_we;
                de_fp_ldst      <= dec_fp_ldst;
                de_rm           <= dec_rm;
                de_csr_addr     <= dec_csr_addr;
                de_csr_zimm     <= dec_csr_zimm;
                de_cbo_kind     <= dec_cbo_kind;
                de_cbo_valid    <= dec_cbo_valid;
                de_cbo_downgrade<= dec_cbo_downgrade;
                de_fence_i      <= dec_fence_i;
                de_ebreak       <= dec_ebreak;
                de_ecall        <= dec_ecall;
                de_mret         <= dec_mret;
                de_sret         <= dec_sret;
                de_wfi          <= dec_wfi;
                de_ill          <= d_ill_total;
                // ★ 修复（2026-09-17，PMP 子集）：`de_exc_tval` 同时服务两条互斥路径，
                //   必须按来源选择，不能一律取 dec_tval：
                //     · 取指异常（fd_exc_valid=1：PMP 无 X / 取指页故障，cause 1/12）
                //       ⇒ tval = **故障 parcel 的虚拟地址**（fetch_unit 的 fetch_exc_tval，
                //         规范 [norm:mtvalvaddrnot_paddr]；Spike 同口径）。
                //     · 非法指令（fd_exc_valid=0，由 E 级 e_ill_total 上报，cause 2）
                //       ⇒ tval = dec_tval（原始指令位，T1 本设计选择）。
                //   实测现象（修复前）：PMPS/PMPU/PMPF 的取指陷阱 tval 写成 dec_tval ⇒
                //   若故障取指取到了数据字（如锁死区内的 nop，0x00000013）就写指令位，
                //   若该拍无取指响应则写**上一条指令的残留位**（如 0x00e12023 = sw），
                //   与 Spike 的「故障地址」逐行不一致（PSm_cfg_XWR_all-01-00 等 21 例）。
                de_exc_tval     <= fd_exc_valid ? fd_exc_tval : dec_tval;
                de_exc_valid    <= fd_exc_valid;
                de_exc_cause    <= fd_exc_cause;
                de_exc_pc       <= fd_exc_pc;
                de_exc_is_fetch <= fd_exc_valid & (fd_exc_cause != `RV32GC_EXC_INSN_PAGE_FAULT);
            end

            // ================= (3) E 级多拍握手 =================
            if (pipe_adv) begin
                mdu_issued_q <= 1'b0;
                fp_issued_q  <= 1'b0;
                mdu_res_v_q  <= 1'b0;
                fpu_res_v_q  <= 1'b0;
            end else begin
                if (e_mdu_go) mdu_issued_q <= 1'b1;
                if (e_fp_go)  fp_issued_q  <= 1'b1;
                if (e_need_mdu & mdu_done) begin
                    mdu_res_v_q <= 1'b1;
                    mdu_res_q   <= mdu_result;
                end
                if (e_need_fpu & fpu_done) begin
                    fpu_res_v_q  <= 1'b1;
                    fpu_res_q    <= fpu_result;
                    fpu_fflags_q <= fpu_fflags;
                end
            end

            // fflags 累积（08 §5.3 ②）
            if (e_fflags_we) fflags_r <= fflags_r | fpu_fflags;
            //   ★ 修复记录（2026-09-17）——「更年轻的 FP 标志被更老的 CSR 写抹掉」
            //     现象（实测 arch-test rv32i/F）：F-feq.s-00 165 处 dut=0/spike=0x10
            //     （feq.s 遇 sNaN 应置 NV）、F-fcvt.s.w-00 24 处 dut=0/spike=0x01
            //     （fcvt.s.w 不精确应置 NX）。
            //     根因：fflags 在本核于 **E 级**累积（上面这行），而写 fflags/fcsr 的
            //     CSR 指令在 **W 级**落盘（下面 (7) 段）。测试序列是 `csrwi fflags,0`
            //     紧邻 `feq.s`（相隔 1~2 条）⇒ CSR 写的落盘拍**晚于** FP 指令的累积拍，
            //     且 (7) 段赋值在 always 块里更靠后 ⇒ 直接覆盖掉刚置的 NV/NX。
            //     口径：fflags 是**粘滞 OR 累积**（语义上 = 按程序序依次 OR），老指令的
            //     CSR 写不能抹掉新指令的置位。已完成指令的标志早已在 fflags_r 里；
            //     仍**在途**（比该 CSR 写更年轻）的 FP 指令标志必须并入落盘值：
            //       · M 槽 em_fflags（其 E 级累积在上一拍 ⇒ 被本拍 CSR 写覆盖）
            //       · E 槽 fpu_fflags（与本次 CSR 写同拍落盘 ⇒ 被同块后赋值覆盖）
            //     sticky-OR 幂等 ⇒ 重复并入不会多置位（见下面 (7) 段的 e_flags_younger）。

            // 计数器（Zicntr；csr_file 侧合成软件可写视图）
            cycle_cnt_r   <= cycle_cnt_r + 64'd1;
            instret_cnt_r <= instret_cnt_r +
                             ((mw_valid & ~trap_exc) ? 64'd1 : 64'd0);

            // ================= (4) EM（E→M）=================
            //   ★ 冲刷优先（2026-09-15 修复）：kill_young（陷阱拍 / fence.i 同步窗口）
            //     必须清空 EM 槽 —— 此时 E 槽持有的是比陷阱指令/fence.i **更年轻**的
            //     指令，若照常 `em_go` 锁存，它会在下一拍成为 M 槽指令：
            //       · 再下一拍经 M→W 放行被提交（W 级越界提交）；
            //       · 若它是访存指令，M FSM 还会**重新启动**这笔访问（副作用翻倍）。
            //     与 FD/DE 的 `kill_young ⇒ valid<=0` 口径一致（见文件头 §2j ①）。
            if (kill_young) begin
                em_valid <= 1'b0;
            end else if (em_go) begin
                em_valid        <= em_n_valid;
                em_pc           <= de_pc;
                em_pc_next      <= em_n_pcnext;
                em_insn_raw     <= de_insn_raw;
                em_rd           <= de_rd;
                em_wb_sel       <= em_n_wbsel;
                em_result       <= em_n_result;
                em_mem_op       <= em_n_memop;
                em_mem_size     <= de_mem_size;
                em_mem_unsign   <= de_mem_unsign;
                em_rs1_val      <= e_rs1_byp;
                em_imm_val      <= de_imm;
                em_store_data   <= e_rs2_byp;
                //   ★ FP store 的存数走前递后的 fs2（§12.5）：否则"FP load → 紧邻 fsd/fsw"
                //     会存下旧值（fregfile 写优先只覆盖 W 槽）。
                em_fp_store     <= e_fp_src2;
                em_amo_f5       <= de_insn32[31:27];
                em_cbo_rs2      <= de_insn32[24:20];
                em_cbo_downgrade<= de_cbo_downgrade;
                em_fence_i      <= de_fence_i;
                em_fp_we        <= de_fp_we & ~e_ill_total & ~de_exc_valid;
                em_fp_rd        <= de_rd;
                em_fp_wdata     <= em_n_fpwdata;
                em_fflags       <= em_n_fflags;
                em_fflags_we    <= e_fflags_we & ~e_ill_total & ~de_exc_valid;
                em_csr_we       <= e_csr_we & ~e_ill_total & ~de_exc_valid;
                em_csr_addr     <= de_csr_addr;
                em_csr_wdata    <= csr_new_e;
                em_csr_rdata    <= csr_rdata;
                em_xret_valid   <= e_xret_valid & ~e_ill_total & ~de_exc_valid;
                em_xret_kind    <= e_xret_kind;
                em_exc_valid    <= em_n_excv;
                em_exc_cause    <= em_n_exccause;
                em_exc_tval     <= em_n_exctval;
                em_exc_pc       <= em_n_excpc;
                em_exc_is_fetch <= de_exc_is_fetch;
            end

            // ================= (5) MW（M→W）=================
            //   ★ **提交即一次**（2026-09-15 修复）：W 是"提交即完成"的单拍槽位
            //     （08 §5.6①：W 级**无背压**），因此 `mw_valid` 只允许在
            //     **本拍确实换人**时为 1，其余拍一律清 0：
            //         换人 ⟺ mw_cap（M 槽指令已完成 ∧ 非冲刷拍 ∧ 非 fence.i 同步启动拍）
            //               ∧ mw_n_valid（M 槽确有指令）
            //               ∧ pipe_adv（流水本拍推进）
            //     否则同一指令会滞留在 W 槽并**逐拍重复提交**（instret 多计、CSR/FP
            //     副作用重复；trap/fence.i 拍还会重复进入陷阱）。
            //     · 实测触发场景：E 级 MDU/FPU 多拍停顿（pipe_adv=0）而 M 槽指令已完成
            //       ⇒ 旧代码每拍都把同一条指令重新写进 W。
            //     · pipe_adv=1 但 mw_cap=0（M 槽空 / 访存在途 / **冲刷拍** /
            //       **分支重定向拍不再清 0**）同样清 0。
            //     · 冲刷拍（kill_young / fencei_sync_pending）走 else 分支 ⇒ 把 mw_valid
            //       清 0：比陷阱指令/fence.i 更年轻的 M 槽指令一律不提交（见 §2j ②③）。
            //     · 注意：**分支重定向拍（bru_redirect）不在冲刷集合内** —— M/W 槽持的
            //       是比分支更老的指令（§2b），必须照常提交；`mw_cap` 里已无该项。
            if (mw_cap) begin
                mw_valid        <= mw_n_valid & pipe_adv;
                mw_pc           <= em_pc;
                mw_pc_next      <= em_pc_next;
                mw_insn_raw     <= em_insn_raw;
                mw_wb_sel       <= mw_n_wbsel;
                mw_rd           <= em_rd;
                mw_wdata        <= m_wdata;
                mw_fp_we        <= em_fp_we & ~mw_n_excv;
                mw_fp_rd        <= em_fp_rd;
                //   ★ FLW/FLD 的数据在 M 级访存完成时才有（见 §12.4 的修复记录）：
                //     其余 FP 指令仍用随流水携带的 `em_fp_wdata`（E 级算好的结果）。
                mw_fp_wdata     <= (em_mem_op == MEM_FLOAD) ? m_fp_ld_wdata
                                                            : em_fp_wdata;
                mw_csr_we       <= em_csr_we & ~mw_n_excv;
                mw_csr_addr     <= em_csr_addr;
                mw_csr_wdata    <= em_csr_wdata;
                mw_xret_valid   <= em_xret_valid & ~mw_n_excv;
                mw_xret_kind    <= em_xret_kind;
                mw_fence_i      <= em_fence_i;    // fence.i（Zifencei）标记随流水携带到 W
                mw_is_fp_instr  <= (em_mem_op == MEM_FLOAD) | (em_mem_op == MEM_FSTORE) |
                                   em_fp_we | em_fflags_we;
                mw_is_fp_wr     <= em_fp_we | em_fflags_we;
                mw_is_fpcsr_wr  <= em_csr_we &
                                   ((em_csr_addr == `RV32GC_CSR_FFLAGS) |
                                    (em_csr_addr == `RV32GC_CSR_FCSR));
                mw_exc_valid    <= mw_n_excv;
                mw_exc_cause    <= mw_n_exccause;
                mw_exc_tval     <= mw_n_exctval;
                mw_exc_pc       <= em_pc;
                mw_exc_is_fetch <= em_exc_is_fetch & mw_n_excv;
            end else begin
                // 本拍未换人 ⇒ W 槽不得再持有上一条指令（否则重复提交）
                mw_valid        <= 1'b0;
            end

            // ================= (6) GPR 写 =================
            if (w_rf_we) gpr[w_rd] <= w_wdata;
            gpr[0] <= 32'h0;

            // ================= (7) FP CSR + mstatus.FS =================
            //   ★ 落盘值必须并入 `e_flags_younger`（2026-09-17 修复）：
            //     CSR 写指令按程序序**老于**仍在 M/E 槽的 FP 指令，故它的写不能抹掉
            //     这些年轻指令刚置的 NV/NX；sticky-OR 幂等 ⇒ 并入不会多置位。
            //     细节与实测证据见上面 (3) 段后的「修复记录」。
            if (csr_wen_w) begin
                case (mw_csr_addr)
                    `RV32GC_CSR_FFLAGS: fflags_r <= mw_csr_wdata[4:0] | e_flags_younger;
                    `RV32GC_CSR_FRM:    frm_r    <= mw_csr_wdata[2:0];
                    `RV32GC_CSR_FCSR:   begin
                        fflags_r <= mw_csr_wdata[4:0] | e_flags_younger;
                        frm_r    <= mw_csr_wdata[7:5];
                    end
                    default: ;
                endcase
            end
            //   FS 推进（08 §5.3 ③）：软件写 mstatus/sstatus 优先；否则 FP 指令执行时
            //   写 FP 状态 ⇒ Dirty；仅读 ⇒ Initial 变 Clean（"精确脏位"口径）。
            if (csr_wen_w & ((mw_csr_addr == `RV32GC_CSR_MSTATUS) |
                             (mw_csr_addr == `RV32GC_CSR_SSTATUS))) begin
                mstatus_fs <= mw_csr_wdata[`RV32GC_MSTATUS_FS_LSB +: 2];
            end else if (mw_valid & ~mw_exc_valid & ~trap_exc & mw_is_fp_instr) begin
                mstatus_fs <= mw_is_fp_wr ? FS_DIRTY :
                              ((mstatus_fs == FS_INITIAL) ? FS_CLEAN : mstatus_fs);
            end

            // ================= (8) F 级辅助 =================
            if (fetch_exc_inject)      fetch_exc_done_q <= 1'b1;
            else if (~fetch_exc_valid) fetch_exc_done_q <= 1'b0;

            // ---- XIP 取指：地址锁存 / 在途记账 / 数据保持（§5.4）----
            //   在途记账：请求被控制器接受时置位，数据回来（vld 置位）时清位。
            //   它保证 xip_word_pa_q 与随后回来的数据**严格一一对应**（见 §5.4 的
            //   ★ 说明）；在途期间 fetch_pause=1 ⇒ F 级不会发第二笔不同地址的请求。
            if (xip_req_pend_q) begin
                if ((axi_owner_q == AXO_XIPF) & axi_rdata_valid) xip_req_pend_q <= 1'b0;
            end else if (axi_fire_req & (axi_owner_sel == AXO_XIPF)) begin
                xip_req_pend_q <= 1'b1;
            end
            if (xip_req_go) begin
                xip_word_pa_q <= fu_fetch_req_pa;
            end
            if ((axi_owner_q == AXO_XIPF) & axi_rdata_valid) begin
                xip_word_data_q <= axi_rdata_data;
                xip_word_vld_q  <= 1'b1;
            end else if (xip_word_vld_q & ~xip_hit_held) begin
                xip_word_vld_q  <= 1'b0;
            end

            // ================= (9) fence.i 全阵列失效扫描 =================
            //   ★ l1i 的 inval_all 只清"当前 cs_vaddr 索引所在组"（l1i.v:150-154）
            //     ⇒ 必须由 core_top 扫 256 组；期间冻结 F 并重定向到 fence.i 之后。
            if (fencei_sync_pending) begin
                fencei_busy  <= 1'b1;
                fencei_idx_q <= 8'd0;
                fencei_pc_q  <= mw_pc_next;
            end else if (fencei_busy) begin
                if (fencei_idx_q == 8'hFF) fencei_busy <= 1'b0;
                fencei_idx_q <= fencei_idx_q + 8'd1;
            end

            // ================= (10) M 级 FSM =================
            if (m_kill_fsm) begin
                // 异常 / fence.i 同步：放弃在途访存（副作用由 l1d_cs_req 的门控阻断）
                m_state_q      <= M_S_IDLE;
                m_page_fault_q <= 1'b0;
                m_amo_phase_q  <= 1'b0;
                m_hi_q         <= 1'b0;
                m_sc_cap_q     <= 1'b0;      // SC 采样记账随本笔作废
            end else begin
                case (m_state_q)
                    //----------- 空闲：判定是否需要翻译 -----------
                    M_S_IDLE: begin
                        m_hi_q         <= 1'b0;
                        m_amo_phase_q  <= 1'b0;
                        m_sc_cap_q     <= 1'b0;   // 新一笔访存重新采样 SC 成败
                        m_exc_q        <= 1'b0;
                        m_page_fault_q <= 1'b0;
                        // ★ 单次启动口径（修复 D6 的 `~m_done_q` 补丁）：
                        //   本 EM 访存指令**每笔只启动一次** —— 判据用
                        //   `~m_issued_q`（本 EM 槽这条指令是否已启动）而不是
                        //   `~m_done_q`（完成脉冲只维持一拍）。
                        //   反例（M1 实测 + 本任务验收④）：访存完成拍 pipe_adv=0
                        //   （E 级 MDU/FPU 多拍停顿）⇒ 下一拍 EM 槽仍持有同一条
                        //   已完成的访存指令、而 m_done_q 已清零。若只看 ~m_done_q，
                        //   FSM 会对同一条指令再走一遍 IDLE→ISS→AXI：store 重复发
                        //   AW（UART 同一字符写两遍）、AMO 重复读改写（副作用翻倍）。
                        if (em_valid & m_is_mem & ~em_exc_valid & ~m_issued_q) begin
                            m_issued_q <= 1'b1;
                            if (m_need_tr & tlb_perm_fault) begin
                                m_pa_q         <= 32'h0;
                                m_page_fault_q <= 1'b1;
                                m_page_cause_q <= (m_tlb_acc == 2'b01)
                                                  ? `RV32GC_EXC_LOAD_PAGE_FAULT
                                                  : `RV32GC_EXC_STORE_PAGE_FAULT;
                                m_state_q      <= M_S_ISS;
                            end else if (m_need_tr & ~tlb_hit) begin
                                m_state_q <= M_S_TR;
                            end else begin
                                m_pa_q    <= m_need_tr ? tlb_pa : m_va;
                                m_state_q <= M_S_ISS;
                            end
                        end else if (em_valid & m_is_mem & em_exc_valid & ~m_issued_q) begin
                            // 取指/译码异常随指令携带 ⇒ 不做访存，直接完成
                            //   （同样只走一次：异常完成也不需要存储器访问）
                            m_issued_q    <= 1'b1;
                            m_exc_q       <= 1'b1;
                            m_exc_cause_q <= em_exc_cause;
                            m_exc_tval_q  <= em_exc_tval;
                            m_done_q      <= 1'b1;
                        end
                    end

                    //----------- Sv32 翻译：推进 PTW -----------
                    M_S_TR: begin
                        if (ptw_pte_ad_update) begin
                            m_ptw_pte_pa_q     <= ptw_pte_ad_pa;
                            m_ptw_pte_resp_d_q <= ptw_pte_ad_data;
                            m_state_q          <= M_S_PADW;
                        end else if (ptw_pte_req_valid) begin
                            m_ptw_pte_pa_q <= ptw_pte_req_pa;
                            m_state_q      <= M_S_PTEA;
                        end else if (ptw_req_done) begin
                            m_pa_q         <= ptw_fault ? 32'h0 : ptw_pa_out;
                            m_page_fault_q <= ptw_fault;
                            m_page_cause_q <= ptw_fault_cause;
                            m_state_q      <= M_S_ISS;
                        end
                    end

                    M_S_PTEA: begin
                        m_ptw_pte_ready_q <= 1'b1;      // ptw 转入 S_L1_W / S_L0_W
                        m_state_q         <= M_S_PTER;
                    end

                    M_S_PTER: begin m_state_q <= M_S_PTEW; end

                    M_S_PTEW: begin
                        if (l1d_cs_ready) begin
                            m_ptw_pte_resp_v_q <= 1'b1;
                            m_ptw_pte_resp_d_q <= l1d_cs_rdata;
                            m_state_q          <= M_S_TR;
                        end else if (l1d_cs_miss) begin
                            m_state_q <= M_S_DRAIN;
                            m_retry_q <= M_S_PTER;
                        end
                    end

                    M_S_PADW: begin m_state_q <= M_S_PADX; end

                    M_S_PADX: begin
                        if (l1d_cs_wr_done) begin
                            m_ptw_ad_done_q <= 1'b1;
                            m_state_q       <= M_S_TR;
                        end else if (l1d_cs_miss) begin
                            m_state_q <= M_S_DRAIN;
                            m_retry_q <= M_S_PADW;
                        end
                    end

                    //----------- 采样 lsu 输出并发出访问（1 拍）-----------
                    M_S_ISS: begin
                        // lsu 为纯组合：本拍采样即锁定（em_* 在 M 忙期间保持不动）
                        m_mmio_clint_q <= lsu_clint_plic & m_mr_clint;
                        m_mmio_plic_q  <= lsu_clint_plic & m_mr_plic;
                        m_mmio_we_q    <= m_mem_wr_op | m_amo_write;
                        m_mmio_off_q   <= m_mmio_req_addr - `RV32GC_CLINT_BASE;
                        m_mmio_wdata_q <= m_amo_phase_q ? m_amo_wdata_q : m_store_w32;
                        m_mmio_strb_q  <= m_store_strb;
                        m_mmio_pa_q    <= m_pa_eff;

                        // ★ SC 成败必须在**请求拍**采样并保持（2026-09-17，
                        //   PMPZalrsc_cfg_wr-00 根因）：amo_unit 在本拍按规范清除保留
                        //   （req_ok & is_sc ⇒ rsv_valid_r<=0，[norm:sc_reservation_invalidate]），
                        //   而 SC 的"成功标志"要在**读相返回拍**才被 FSM 取用 —— 那时
                        //   lsu_sc_ok 已恒 0（实测 rd 被写成"失败"1，Spike 为 0）。
                        //   故在首次进入 M_S_ISS（~m_sc_cap_q）采样；L1D 缺失重试
                        //   （M_S_DRAIN → M_S_ISS）只重发访问、不重采样（否则覆盖成 0）。
                        if ((em_mem_op == MEM_SC) & ~m_sc_cap_q) begin
                            m_sc_ok_cap_q <= lsu_sc_ok;
                            m_sc_cap_q    <= 1'b1;
                        end

                        if (m_fp8_misalign | lsu_exc | m_page_fault_q) begin
                            // 访存异常：不做存储器访问，直接完成（W 级统一入口处理）
                            //   优先级（与 lsu 内部口径一致）：FP 8 B 非对齐 > lsu 异常
                            //   （非对齐 > PMP，见 lsu §10）> 页错误。
                            m_exc_q       <= 1'b1;
                            m_exc_cause_q <= m_fp8_misalign ? m_fp8_mis_cause :
                                             (m_page_fault_q ? m_page_cause_q : lsu_exc_cause);
                            m_exc_tval_q  <= (m_fp8_misalign | m_page_fault_q) ? m_va : lsu_mtval;
                            m_page_fault_q<= 1'b0;
                            m_state_q     <= M_S_IDLE;
                            m_done_q      <= 1'b1;
                        end else if (lsu_cmo_valid) begin
                            m_state_q <= M_S_CMO;
                        end else if (lsu_clint_plic) begin
                            m_state_q <= M_S_MMIO;
                        end else if (lsu_route == ROUTE_AXI) begin
                            m_state_q <= M_S_AXI;
                        end else begin
                            m_state_q <= M_S_RSP;
                        end
                    end

                    //----------- 等 L1D 读/写完成 -----------
                    M_S_RSP: begin
                        if (l1d_cs_ready) begin
                            // 读命中：按类型产生 rd 值
                            if (em_mem_op == MEM_AMO) begin
                                m_rd_data_q   <= lsu_amo_rd_old;
                                m_amo_wdata_q <= lsu_amo_wdata;   // ★ 必须本拍锁存
                                m_sc_ok_q     <= 1'b1;
                                m_amo_phase_q <= 1'b1;
                                m_state_q     <= M_S_ISS;
                            end else if (em_mem_op == MEM_SC) begin
                                // ★ 用请求拍锁存值（m_sc_ok_cap_q）而非当拍 lsu_sc_ok：
                                //   后者在读相返回拍已被 SC 自身的"清保留"抹成 0。
                                //   ★ 失败时**不得**回 M_S_ISS：该拍 m_amo_write=0
                                //   （SC 且 sc_ok=0）⇒ 会重发一次**读**并再次回到本分支
                                //   ⇒ 无限循环（与本文件 M_S_AXI 同源的写相门控缺陷）。
                                m_sc_ok_q     <= m_sc_ok_cap_q;
                                m_amo_wdata_q <= lsu_amo_wdata;
                                m_rd_data_q   <= m_sc_ok_cap_q ? 32'd0 : 32'd1;
                                if (m_sc_ok_cap_q) begin
                                    m_amo_phase_q <= 1'b1;        // 成功 ⇒ 补写相
                                    m_state_q     <= M_S_ISS;
                                end else begin
                                    m_state_q     <= M_S_IDLE;    // 失败 ⇒ 不写内存
                                    m_done_q      <= 1'b1;
                                end
                            end else if (em_mem_op == MEM_LR) begin
                                m_rd_data_q <= ld_extract(l1d_cs_rdata, m_va[1:0],
                                                          m_lsu_size, em_mem_unsign);
                                m_state_q   <= M_S_IDLE;
                                m_done_q    <= 1'b1;
                            end else if (m_size8 & ~m_hi_q) begin
                                m_rd_data_q <= l1d_cs_rdata;   // 低字（fld 第一阶段）
                                m_hi_q      <= 1'b1;
                                m_state_q   <= M_S_ISS;
                            end else if (m_size8 & m_hi_q) begin
                                m_rd_hi_q   <= l1d_cs_rdata;   // 高字（fld 第二阶段）
                                m_state_q   <= M_S_IDLE;
                                m_done_q    <= 1'b1;
                            end else begin
                                m_rd_data_q <= m_ld_data_ext;
                                m_state_q   <= M_S_IDLE;
                                m_done_q    <= 1'b1;
                            end
                        end else if (l1d_cs_wr_done) begin
                            if (m_size8 & ~m_hi_q) begin
                                m_hi_q    <= 1'b1;
                                m_state_q <= M_S_ISS;
                            end else if (m_amo_phase_q) begin
                                m_amo_phase_q <= 1'b0;
                                m_state_q     <= M_S_IDLE;
                                m_done_q      <= 1'b1;
                            end else begin
                                m_state_q <= M_S_IDLE;
                                m_done_q  <= 1'b1;
                            end
                        end else if (l1d_cs_miss) begin
                            m_state_q <= M_S_DRAIN;      // 等行填充完成
                            m_retry_q <= M_S_ISS;
                        end
                    end

                    //----------- 缺失后等 L1D 回空闲再重试 -----------
                    M_S_DRAIN: begin
                        if (l1d_idle & ~l1d_cs_stall) m_state_q <= m_retry_q;
                    end

                    //----------- 核内 MMIO（CLINT/PLIC）单拍完成 -----------
                    M_S_MMIO: begin
                        // ★ 2026-09-15 修复（与 M_S_AXI 同源缺陷的另一处残留）：
                        //   CLINT/PLIC 的 resp_rdata 是 **32 bit 寄存器整字**，
                        //   原实现直取整字 ⇒ lb/lbu/lh/lhu 拿到的都是整个字
                        //   （实测：对 mtimecmp 做 `lbu` 会得到 0x88776655 而不是 0x55）。
                        //   改为**与 L1D/AXI 通路同一 function** `ld_extract`，按
                        //   VA[1:0] 做偏移、按 m_lsu_size 截宽度、按 em_mem_unsign
                        //   做符号/零扩展（三处调用共用一个真源，杜绝口径分叉）。
                        //   · lw（size=2）⇒ 结果恒等于原字，行为不变；
                        //   · AMO/LR/SC 恒为字对齐（VA[1:0]=0）且 size=2 ⇒ 行为不变。
                        m_rd_data_q <= ld_extract(m_mr_clint ? clint_rdata : plic_rdata,
                                                  m_va[1:0], m_lsu_size, em_mem_unsign);
                        m_state_q   <= M_S_IDLE;
                        m_done_q    <= 1'b1;
                    end

                    //----------- 平台 MMIO/XIP 数据访问（AXI 单 beat）-----------
                    //   ★ D4：完成点 = 本笔 MDTA 事务的 done（读 = R 最后一 beat，
                    //     写 = **B 响应** 之后的 done），来源用 done 记账对判定
                    //     （axi_done_owner_q/axi_done_wr_q，见 §11.6）。
                    //     写事务不需要读回数据（store 无 rd 值）。
                    M_S_AXI: begin
                        if (axi_done_q & (axi_done_owner_q == AXO_MDTA)) begin
                            // ★ 2026-09-15 修复：整数 load 走 `m_axi_ld_data`
                            //   （已按 VA[1:0]/尺寸抽取 + 符号扩展），不再直取整字。
                            // ★ 2026-09-17 根因修复（D 扩展 fld/fsd 的 8 B 两阶段）：
                            //   MDTA 一笔 = 单 beat 32 bit，而 fld/fsd 是 8 B
                            //   ⇒ 必须拆成**两笔**（低字 pa / 高字 pa+4），与 M_S_RSP
                            //   的 L1D 分支同口径（`m_hi_q` 表示"正在做高字"，
                            //   `m_pa_eff = m_pa_q + (m_hi_q ? 4 : 0)` 已按此派生）。
                            //   原实现在 ROUTE_AXI 上只发一笔就完成 ⇒ fld 高字恒 0、
                            //   fsd 只写低 4 B（实测 D-fsd-00：签名高字槽仍是预填
                            //   0xdeadbeef；D 算术的操作数高字被抹成 0）。
                            //   第二阶段重回 M_S_ISS：该拍按 m_hi_q=1 重新锁存
                            //   `m_mmio_pa_q`=pa+4 与 `m_store_w32`=存数高字
                            //   （fsd 写），load 则把回来的整字存进 `m_rd_hi_q`。
                            // ★ 2026-09-17 根因修复（PMPZaamo/PMPZalrsc_cfg_wr-00）：
                            //   ROUTE_AXI 通路**缺 AMO/SC 的写相**。原实现只按通用分支
                            //   把读回整字写进 rd 并置 done ⇒ 对 AMO/LR/SC 有三处错：
                            //     ① AMO：只有读相、没有写相 ⇒ 内存永不更新（实测
                            //        PMPZaamo：同一地址上连续 9 个 AMO 全部读回初值
                            //        0x00000013，而 Spike 读回 0x13→0x807a→0x8062→…）；
                            //     ② SC ：rd 被写成"读回的旧值"而不是成功标志 0/1
                            //        （实测 PMPZalrsc：rd=0x13 而 Spike=0）；
                            //     ③ SC 成功时的写相同样缺失。
                            //   修复 = 与 L1D 通路（M_S_RSP 的 MEM_AMO/MEM_SC 分支）
                            //   **同口径**补两相：读相锁存 rd 与写数据，置 `m_amo_phase_q`
                            //   后回 M_S_ISS —— 该拍 `m_amo_write=1` ⇒ `m_mmio_we_q=1`
                            //   ⇒ 由 MDTA 写事务把 `m_amo_wdata_q` 写回。
                            //   数据真源仍是 amo_unit：`lsu_amo_wdata`/`lsu_amo_rd_old`/
                            //   `m_sc_ok_cap_q`（读相数据经 §9.5 的路由 mux 选自 axi_rdata_q；
                            //   SC 成功标志在 M_S_ISS 请求拍锁存，理由见那里的注释）。
                            // ★ 2026-09-17（PMPSm_cfg_A_tor_zero-00 收尾）：**总线响应
                            //   错误优先于一切正常收尾** —— SLVERR/DECERR ⇒ access fault。
                            //   本分支只可能在 M_S_ISS 的异常判定（FP 8B 非对齐 >
                            //   lsu 异常[非对齐 > PMP] > 页错误）**全部通过**之后到达
                            //   （能发出事务 ⇒ 前几关已过）⇒ 陷阱优先级天然排在它们
                            //   **之后**，与物理次序一致。
                            //   tval = 访问 VA（m_va），与 PMP/页错误同口径；cause：
                            //   写类（store/fstore/AMO/SC 写相）恒 7、纯读恒 5（§11.7）。
                            //   在途 AMO/SC 的写相一并作废（m_amo_phase_q 清 0）。
                            if (axi_err_q) begin
                                m_exc_q       <= 1'b1;
                                m_exc_cause_q <= m_bus_err_cause;
                                m_exc_tval_q  <= m_va;
                                m_amo_phase_q <= 1'b0;
                                m_state_q     <= M_S_IDLE;
                                m_done_q      <= 1'b1;
                            end else if (~axi_done_wr_q & (em_mem_op == MEM_AMO)) begin
                                m_rd_data_q   <= lsu_amo_rd_old;   // 读相：旧值
                                m_amo_wdata_q <= lsu_amo_wdata;   // ★ 必须本拍锁存
                                m_sc_ok_q     <= 1'b1;
                                m_amo_phase_q <= 1'b1;
                                m_state_q     <= M_S_ISS;         // 去发写相
                            end else if (~axi_done_wr_q & (em_mem_op == MEM_SC)) begin
                                m_sc_ok_q     <= m_sc_ok_cap_q;
                                m_amo_wdata_q <= lsu_amo_wdata;   // SC 的写数据 = rs2
                                m_rd_data_q   <= m_sc_ok_cap_q ? 32'd0 : 32'd1;
                                if (m_sc_ok_cap_q) begin
                                    m_amo_phase_q <= 1'b1;        // 成功 ⇒ 补写相
                                    m_state_q     <= M_S_ISS;
                                end else begin
                                    m_state_q     <= M_S_IDLE;    // 失败 ⇒ 不写内存
                                    m_done_q      <= 1'b1;
                                end
                            end else if (m_amo_phase_q) begin
                                // AMO/SC 的**写相完成**（axi_done_wr_q=1）⇒ 收尾。
                                //   ★ 必须在此显式识别：本状态对读相与写相给出同一个
                                //     done 脉冲，若不加这一支，上面的读相分支会对同一条
                                //     AMO 反复重入 ⇒ 写相无限重复（本修复首版实测：
                                //     PMPZaamo_cfg_wr-00 超时未到终止点）。
                                m_amo_phase_q <= 1'b0;
                                m_state_q     <= M_S_IDLE;
                                m_done_q      <= 1'b1;
                            end else if (m_size8 & ~m_hi_q) begin
                                if (~axi_done_wr_q) m_rd_data_q <= m_axi_ld_data;
                                m_hi_q    <= 1'b1;
                                m_state_q <= M_S_ISS;
                            end else if (m_size8 & m_hi_q) begin
                                if (~axi_done_wr_q) m_rd_hi_q <= m_axi_ld_data;
                                m_state_q <= M_S_IDLE;
                                m_done_q  <= 1'b1;
                            end else begin
                                if (~axi_done_wr_q) m_rd_data_q <= m_axi_ld_data;
                                m_state_q <= M_S_IDLE;
                                m_done_q  <= 1'b1;
                            end
                        end
                    end

                    //----------- CMO 维护扫描等待（以 l1d.idle 判定完成）-----------
                    M_S_CMO: begin
                        if (l1d_idle) begin
                            m_state_q <= M_S_IDLE;
                            m_done_q  <= 1'b1;
                        end
                    end

                    default: m_state_q <= M_S_IDLE;
                endcase
            end

            // ---- ★ 单次启动记账清零：EM 槽位更换（em_go）或同步让路（m_kill_fsm）----
            //   必须放在 FSM 之后（同一 always 块内最后赋值生效）：进入 M 级的新
            //   指令一律从"未启动"开始；被 kill 的指令作废，其记账也必须清零
            //   （否则该槽位再也启动不了访存）。与 m_done_q 同为脉冲语义。
            if (m_kill_fsm | em_go) m_issued_q <= 1'b0;
        end
    end

    assign cycle_cnt   = cycle_cnt_r;
    assign instret_cnt = instret_cnt_r;

    //==========================================================================
    // 14. W 级提交、调试探针
    //==========================================================================
    assign w_rf_we = mw_valid & (mw_wb_sel != WB_NONE) & (mw_rd != 5'd0) &
                     ~mw_exc_valid & ~trap_exc;
    assign w_rd    = mw_rd;
    assign w_wdata = mw_wdata;

    assign ws_valid          = mw_valid & ~trap_exc;
    assign debug0_wb_pc      = mw_pc;
    // ★ debug0_wb_rf_wen 必须 [3:0]；2A 单发射只驱动 [0]，[3:1] 恒 0
    assign debug0_wb_rf_wen  = {3'b000, (mw_valid & ~mw_exc_valid & ~trap_exc &
                                         ((mw_wb_sel != WB_NONE & (mw_rd != 5'd0)) |
                                          mw_fp_we))};
    assign debug0_wb_rf_wnum  = mw_rd;
    assign debug0_wb_rf_wdata = mw_wdata;

    //==========================================================================
    // 15. 编译期自检（把规格字面值写进可执行代码，防后续误改）
    //==========================================================================
    initial begin
        if (`RV32GC_RESET_PC != 32'h1C00_0000) begin
            $display("CORE_TOP FAIL: RESET_PC 必须为 0x1C00_0000（08 §4.3）");
            $fatal(1, "CORE_TOP PARAM FAIL");
        end
        if (`RV32GC_ISSUE_WIDTH != 1 || `RV32GC_STAGES != 5) begin
            $display("CORE_TOP FAIL: 2A 必须为单发射 5 级（08 §1.1）");
            $fatal(1, "CORE_TOP PARAM FAIL");
        end
        if (`RV32GC_AXI_LEN_MAX != 4'd15 || `RV32GC_AXI_ID_W != 4) begin
            $display("CORE_TOP FAIL: AXI len/ID 位宽与平台不符");
            $fatal(1, "CORE_TOP PARAM FAIL");
        end
    end

endmodule
