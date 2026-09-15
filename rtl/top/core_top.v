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
//   (c) **load-use 停顿 1 拍**：load 数据在 M 级末才可用；紧随其后要用该 rd 的
//       E 级指令停顿 1 拍，由 exe_ctrl 的 W 旁路供给（不造组合提前转发路径）。
//   (d) **W 级统一异常入口**：所有同步异常随指令携带异常标记进入 W，
//       由 trap_ctrl 唯一入口写 *epc/*cause/*tval；core_top 不在别处写陷阱 CSR。
//   (e) **中断取点**：trap_ctrl 内部已用 `commit_valid` 限定"指令边界之后"（T6）；
//       core_top 送 `commit_valid = mw_valid`。
//   (f) **精确异常**：`trap_valid`（W 拍）必须同拍压制 M 级（更年轻指令）的存储器
//       副作用并清掉 M/E/D 槽位 —— 见 `kill_young`。
//   (g) **中断与异常的提交差异**：同步异常 ⇒ W 的该指令**不提交**；
//       中断 ⇒ 在提交边界之后取，W 的该指令**照常提交**（只清更年轻的）。
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
    wire        m_done_q_ok;
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

    wire        fetch_exc_valid;
    wire [4:0]  fetch_exc_cause;
    wire [31:0] fetch_exc_tval;
    wire [31:0] fetch_exc_pc;

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
    .fetch_exc_valid      (fetch_exc_valid),
    .fetch_exc_cause      (fetch_exc_cause),
    .fetch_exc_tval       (fetch_exc_tval),
    .fetch_exc_pc         (fetch_exc_pc)
    );

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
    wire [31:0] csr_rdata_raw, csr_rdata_w, csr_mstatus_raw;
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
    wire d_is_fpcsr    = (dec_csr_addr == `RV32GC_CSR_FFLAGS) |
                         (dec_csr_addr == `RV32GC_CSR_FRM)    |
                         (dec_csr_addr == `RV32GC_CSR_FCSR);
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
    wire [63:0] freg_rdata1, freg_rdata2, freg_rdata3;
    wire [6:0]  e_fp_op = fp_op_map(de_fp_op, de_insn32);
    // a 端口是整数操作数：fmv.w.x/fmv.d.x(15) 与 fcvt.{s,d}.{w,wu}(18/19/22/23)
    wire e_fp_a_is_int = (e_fp_op == 7'd15) | (e_fp_op == 7'd18) | (e_fp_op == 7'd19) |
                         (e_fp_op == 7'd22) | (e_fp_op == 7'd23);
    wire [63:0] e_fpu_a = e_fp_a_is_int ? {32'h0000_0000, e_rs1_byp} : freg_rdata1;

    wire        e_need_fpu = (de_op_type == OPT_FP);
    reg         fp_issued_q;
    reg         fpu_res_v_q;
    reg  [63:0] fpu_res_q;
    reg  [4:0]  fpu_fflags_q;
    wire        e_fp_go = de_valid & e_need_fpu & ~fp_issued_q &
                          ~de_ill & ~de_exc_valid & ~kill_young;

    wire        fpu_busy, fpu_done, fpu_fflags_we;
    wire [63:0] fpu_result;
    wire [4:0]  fpu_fflags;

    fpu u_fpu (
    .clk       (aclk),
    .rst_n     (aresetn),
    .flush     (kill_young),
    .req_valid (e_fp_go),
    .fp_op     (e_fp_op),
    .fmt       (de_insn32[26:25]),
    .rm        (de_rm),
    .frm       (frm_r),
    .a         (e_fpu_a),
    .b         (freg_rdata2),
    .c         (freg_rdata3),
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
    .we     (mw_fp_we),
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

    // ---- 7.7 MDU/FPU 结果选择 ----
    wire [31:0] e_mdu_val = mdu_res_v_q ? mdu_res_q : mdu_result;
    wire [63:0] e_fpu_val = fpu_res_v_q ? fpu_res_q : fpu_result;
    wire [4:0]  e_fp_fflags_val = fpu_res_v_q ? fpu_fflags_q : fpu_fflags;

    // ---- 7.8 CSR（Zicsr）：读旧值 / 算新值；旧值随指令流水到 W 写回 rd ----
    //   csr_file.rdata 为组合读；写端口旁路 rdata_w 覆盖同拍"W 写 → E 读"冒险。
    //   FP CSR（fflags/frm/fcsr）由 core_top 持有（csr_file 读回 0）⇒ 在此覆盖。
    wire [31:0] csr_fp_view =
        (de_csr_addr == `RV32GC_CSR_FFLAGS) ? {27'b0, fflags_r} :
        (de_csr_addr == `RV32GC_CSR_FRM)    ? {29'b0, frm_r}    :
        (de_csr_addr == `RV32GC_CSR_FCSR)   ? {24'b0, frm_r, fflags_r} : 32'h0;
    wire        csr_is_fp = (de_csr_addr == `RV32GC_CSR_FFLAGS) |
                            (de_csr_addr == `RV32GC_CSR_FRM)    |
                            (de_csr_addr == `RV32GC_CSR_FCSR);
    wire [31:0] csr_base_rd = (csr_wen_w & (mw_csr_addr == de_csr_addr)) ? csr_rdata_w
                                                                         : csr_rdata_raw;
    //   mstatus/sstatus 的 FS/SD 位由 core_top 持有 ⇒ 读路径覆盖（csr_file 内那份同步被遮盖）
    wire [31:0] csr_base_rd_fs =
        ((de_csr_addr == `RV32GC_CSR_MSTATUS) | (de_csr_addr == `RV32GC_CSR_SSTATUS))
        ? ((csr_base_rd & ~(FS_MASK | SD_MASK)) |
           ({30'b0, mstatus_fs} << `RV32GC_MSTATUS_FS_LSB) |
           ((mstatus_fs == FS_DIRTY) ? SD_MASK : 32'h0))
        : csr_base_rd;
    wire [31:0] csr_rdata  = csr_is_fp ? csr_fp_view : csr_base_rd_fs;

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
    reg  [31:0] m_rd_data_q;         // L1D/MMIO/AXI 读回数据
    reg  [31:0] m_amo_wdata_q;       // AMO 写相数据（在 cs_ready 拍锁存）
    reg         m_sc_ok_q;           // SC 成功标志（同上）
    reg         m_done_q;            // 本笔访存完成（单拍）
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

    // M 级忙：FSM 在途 或 手上有未启动的访存
    assign m_mem_pending = em_valid & m_is_mem & ~m_done_q;
    assign m_busy = (m_state_q != M_S_IDLE) | m_mem_pending;
    assign pipe_adv = e_done & ~m_busy & ~load_use_stall;

    // 让路：异常或 fence.i 同步拍必须清掉 M/E/D（见文件头 §2f/§2g）
    assign kill_young = trap_valid | fencei_busy;
    assign trap_exc   = trap_valid & ~trap_is_int;

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
    assign m_kill_fsm      = trap_valid | fencei_busy;

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
        // ★ 接线要点 3：amo_unit 读相返回 = L1D 读返回（母 Agent 授权新增端口）
    .amo_rdata_i      (l1d_cs_rdata),
    .amo_rdata_valid_i(l1d_cs_ready)
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
    wire        m_l1d_go     = (m_state_q == M_S_ISS) & ~m_kill_fsm &
                               ~lsu_exc & ~m_page_fault_q & ~lsu_cmo_valid &
                               ~lsu_clint_plic & (lsu_route != ROUTE_AXI) &
                               ~(m_mem_wr_op & m_size8 & m_hi_q);
    wire [31:0] m_ld_data_ext = ld_extract(l1d_cs_rdata, m_va[1:0], m_lsu_size,
                                           em_mem_unsign);

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
    assign plic_req_addr   = m_mmio_off_q;
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
    wire         priv_flush_req;
    wire [1:0]   priv_next;
    wire         csr_fetch_is_m;
    wire [31:0]  cycle_cnt, instret_cnt;

    assign csr_wen_w = mw_valid & mw_csr_we & ~mw_exc_valid & ~trap_exc;
    assign satp_wr_pulse = csr_wen_w & (mw_csr_addr == `RV32GC_CSR_SATP);

    csr_file u_csr_file (
    .clk         (aclk),
    .rst_n       (aresetn),
    .raddr       (de_csr_addr),
    .rdata       (csr_rdata_raw),
    .wen         (csr_wen_w),
    .waddr       (mw_csr_addr),
    .wdata       (mw_csr_wdata),
    .w_illegal   (1'b0),
    .rdata_w     (csr_rdata_w),
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
    .exc_valid     (mw_exc_valid),
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

    assign redirect_exc_v  = trap_valid | fencei_busy;
    assign redirect_exc_pc = trap_valid ? trap_redirect_pc : fencei_pc_q;

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
    wire m_axi_want   = (m_state_q == M_S_AXI) & ~axi_done_q;
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

    assign mw_go  = em_valid & (~m_is_mem | m_done_q);
    assign mw_cap = (mw_go | kill_young) & ~bru_redirect;

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
                    ~m_exc_any & m_done_q_ok;

    // load-use 停顿 1 拍：M 级是对 GPR 的 load/AMO/LR/SC，且 E 级要用该 rd
    //   ⇒ 本拍不推进（前端冻结），下一拍 load 已进入 W，由 exe_ctrl 的 W 旁路供给。
    wire m_is_load_kind = (em_mem_op == MEM_LOAD) | (em_mem_op == MEM_AMO) |
                          (em_mem_op == MEM_LR)   | (em_mem_op == MEM_SC);
    wire e_use_rs1 = (de_rs1 != 5'd0) & (~de_ill);
    wire e_use_rs2 = (de_rs2 != 5'd0) & (~de_ill) &
                     ((de_insn32[6:0] == `RV32GC_OP_OP) |
                      (de_mem_op == MEM_STORE) | (de_mem_op == MEM_AMO) |
                      (de_mem_op == MEM_SC) | (de_mem_op == MEM_FSTORE) |
                      (de_op_type == OPT_BRU) | (de_op_type == OPT_JALR));
    assign load_use_stall = em_valid & m_is_load_kind & (em_rd != 5'd0) &
                          ((e_use_rs1 & (de_rs1 == em_rd)) |
                           (e_use_rs2 & (de_rs2 == em_rd)));

    assign m_done_q_ok = (~m_is_mem) | m_done_q;

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
            m_rd_data_q <= 32'h0; m_amo_wdata_q <= 32'h0; m_sc_ok_q <= 1'b0;
            m_done_q <= 1'b0;
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
                fd_pc        <= fu_fetch_insn_va;
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
                de_exc_tval     <= dec_tval;
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

            // 计数器（Zicntr；csr_file 侧合成软件可写视图）
            cycle_cnt_r   <= cycle_cnt_r + 64'd1;
            instret_cnt_r <= instret_cnt_r +
                             ((mw_valid & ~trap_exc) ? 64'd1 : 64'd0);

            // ================= (4) EM（E→M）=================
            if (em_go) begin
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
                em_fp_store     <= freg_rdata2;
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
            //   `mw_cap` 在 trap/fence.i 拍也必须写（把 mw_valid 清 0），
            //    否则 W 槽位会重复提交同一条指令（重复陷阱）。
            if (mw_cap) begin
                mw_valid        <= mw_n_valid;
                mw_pc           <= em_pc;
                mw_pc_next      <= em_pc_next;
                mw_insn_raw     <= em_insn_raw;
                mw_wb_sel       <= mw_n_wbsel;
                mw_rd           <= em_rd;
                mw_wdata        <= m_wdata;
                mw_fp_we        <= em_fp_we & ~mw_n_excv;
                mw_fp_rd        <= em_fp_rd;
                mw_fp_wdata     <= em_fp_wdata;
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
            end

            // ================= (6) GPR 写 =================
            if (w_rf_we) gpr[w_rd] <= w_wdata;
            gpr[0] <= 32'h0;

            // ================= (7) FP CSR + mstatus.FS =================
            if (csr_wen_w) begin
                case (mw_csr_addr)
                    `RV32GC_CSR_FFLAGS: fflags_r <= mw_csr_wdata[4:0];
                    `RV32GC_CSR_FRM:    frm_r    <= mw_csr_wdata[2:0];
                    `RV32GC_CSR_FCSR:   begin
                        fflags_r <= mw_csr_wdata[4:0];
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
            if (mw_valid & mw_fence_i & ~mw_exc_valid & ~trap_exc & ~fencei_busy) begin
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
            end else begin
                case (m_state_q)
                    //----------- 空闲：判定是否需要翻译 -----------
                    M_S_IDLE: begin
                        m_hi_q         <= 1'b0;
                        m_amo_phase_q  <= 1'b0;
                        m_exc_q        <= 1'b0;
                        m_page_fault_q <= 1'b0;
                        // ★ M1 新发现缺陷（D6）：`~m_done_q` 门控 —— 本笔访存
                        //   完成的**下一拍** EM 槽仍持有该指令（完成拍 m_busy=1
                        //   ⇒ pipe_adv=0，EM 没换人），若此处不带 ~m_done_q，
                        //   FSM 会对**同一条已完成的访存指令**再走一遍
                        //   IDLE→ISS→AXI：M1 实测 UART 的 sb 被发两次 AW（每次
                        //   多写一个字符，逐字符回显判据必挂）。
                        if (em_valid & m_is_mem & ~em_exc_valid & ~m_done_q) begin
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
                        end else if (em_valid & m_is_mem & em_exc_valid) begin
                            // 取指/译码异常随指令携带 ⇒ 不做访存，直接完成
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
                        m_mmio_off_q   <= m_pa_eff - `RV32GC_CLINT_BASE;
                        m_mmio_wdata_q <= m_amo_phase_q ? m_amo_wdata_q : m_store_w32;
                        m_mmio_strb_q  <= m_store_strb;
                        m_mmio_pa_q    <= m_pa_eff;

                        if (lsu_exc | m_page_fault_q) begin
                            // 访存异常：不做存储器访问，直接完成（W 级统一入口处理）
                            m_exc_q       <= 1'b1;
                            m_exc_cause_q <= m_page_fault_q ? m_page_cause_q : lsu_exc_cause;
                            m_exc_tval_q  <= m_page_fault_q ? m_va : lsu_mtval;
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
                                m_sc_ok_q     <= lsu_sc_ok;
                                m_amo_wdata_q <= lsu_amo_wdata;
                                m_rd_data_q   <= lsu_sc_ok ? 32'd0 : 32'd1;
                                m_amo_phase_q <= 1'b1;
                                m_state_q     <= M_S_ISS;
                            end else if (em_mem_op == MEM_LR) begin
                                m_rd_data_q <= ld_extract(l1d_cs_rdata, m_va[1:0],
                                                          m_lsu_size, em_mem_unsign);
                                m_state_q   <= M_S_IDLE;
                                m_done_q    <= 1'b1;
                            end else if (m_size8 & ~m_hi_q) begin
                                m_rd_data_q <= {l1d_cs_rdata, 32'h0};  // 低字（fld）
                                m_hi_q      <= 1'b1;
                                m_state_q   <= M_S_ISS;
                            end else if (m_size8 & m_hi_q) begin
                                m_rd_data_q <= {l1d_cs_rdata, m_rd_data_q[31:0]}; // 高字
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
                        m_rd_data_q <= m_mr_clint ? clint_rdata : plic_rdata;
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
                            if (~axi_done_wr_q) m_rd_data_q <= axi_rdata_q;
                            m_state_q   <= M_S_IDLE;
                            m_done_q    <= 1'b1;
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
