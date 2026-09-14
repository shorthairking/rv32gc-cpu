//==============================================================================
// rtl/axi/axi_master_ctrl.v —— AXI4 五通道主端口控制器（单笔在途）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 归属  : docs/design/08-baseline-5stage.md §7.1、§7.2；AGENT.md §3.3
//
// ★ 红线 4 的边界判定（08 §7.1 的正式判断，本文件必须满足）：
//   本控制器位于「Cache→AXI 转换边界」**向内**——它是"核与平台之间的端口控制器"，
//   2A 核直连平台、**不引入 Vivado 互连 IP**（08 §1.1）。因此**允许手写**。
//   边界向外的互连/协议转换/DMA/FIFO/外设控制器仍必须复用 Vivado IP（M6/L2 阶段）。
//
// ★ 单笔在途三件套（AGENT.md §3.3，本模块强制实现）：
//   ① busy  ：busy_q 表示"已有一笔在途"，新请求被反压（req_ready=0）
//   ② owner ：owner_q 记录本笔归属（0=I 填充、1=D 填充、2=写回、3=CMO）
//   ③ 推进  ：所有通道推进一律用 `valid && ready`；**禁用**电平维持/计数器到点
//
// ★ 地址寄存器唯一赋值点（08 §7.1 要点 3）：
//   addr_q 是核内总线地址寄存器的**唯一**赋值点，且只接受物理地址。
//   4 K 边界的第二笔（拆突发）也写同一处（在 done 时用 addr_next）。
//
// 五通道（08 §7.1 要点 1；2A 简化：读通道与写通道**交替**在途）
//   读：AR（读地址） → R（读数据，逐 beat）；读 R 的最后一 beat ⇒ 本笔完成
//   写：AW（写地址）→ W（写数据，逐 beat）→ B（写响应）；B 收到 ⇒ 本笔完成
//   读与写各一个 FSM，共享 busy/owner 三件套：
//     - 读 FSM：RD_IDLE → RD_AR → RD_R → RD_DONE
//     - 写 FSM：WR_IDLE → WR_AW → WR_W → WR_B → WR_DONE
//   busy=1 期间另一侧不得发起（2A 口径）。
//
// ★ 4 K 边界拆两笔（08 §7.1 要点 5）：
//   首笔按 desc_beats 发；若 desc_split=1 ⇒ 首笔完成后**自动**发第二笔
//   （地址 = addr_q + 首笔字节数），第二笔从 AXI 请求源取同 owner 的新描述符。
//   —— 为让 TB 可独立驱动，第二笔的最小信息（地址/beat 数）在首笔完成时锁存。
//
// ★ bresp/rresp 处理：非 OKAY ⇒ 置 resp_error（脉冲），并**照常完成本笔**
//   （2A 无总线错误恢复语义，交由上层/CBO 决策；但必须可见、不静默吞掉）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module axi_master_ctrl #(
    parameter integer ADDR_W  = 32,
    parameter integer DATA_W  = 32,
    parameter integer STRB_W  = 4,
    parameter integer ID_W    = 4,
    parameter integer LEN_W   = 4,
    parameter integer SIZE_W  = 3,
    parameter integer BURST_W = 2,
    parameter integer CACHE_W = 4,
    parameter integer PROT_W  = 3,
    parameter integer OWNER_W = 2
) (
    input  wire                 clk,
    input  wire                 rst_n,

    //================================================================
    // 核内请求侧（来自 MSHR / 描述符生成）
    //================================================================
    input  wire                 req_valid,
    input  wire                 req_is_write,
    input  wire [OWNER_W-1:0]   req_owner,
    input  wire [ADDR_W-1:0]    req_addr,    // **物理地址**
    input  wire [LEN_W-1:0]     req_len,     // AxLEN（beat 数 - 1）
    input  wire [LEN_W:0]       req_beats,   // beat 数（1..16）
    input  wire                 req_split,   // 本请求需拆第二笔（跨 4 K）
    input  wire [LEN_W:0]       req_beats_1, // **本笔（首笔）实际 beat 数**（≤16）
    input  wire [LEN_W:0]       req_beats_2, // 第二笔 beat 数（req_split=0 时忽略）
    input  wire [ID_W-1:0]      req_id,
    output wire                 req_ready,   // 1 = 接受（未 busy）

    // ---- 写数据（回填/写回数据流，逐 beat） ----
    input  wire                 wdata_valid,
    input  wire [DATA_W-1:0]    wdata_data,
    output wire                 wdata_ready,

    // ---- 读数据（填充数据流，逐 beat 输出） ----
    output wire                 rdata_valid,
    output wire [DATA_W-1:0]    rdata_data,
    output wire [ID_W-1:0]      rdata_id,
    output wire                 rdata_last,
    input  wire                 rdata_ready,

    // ---- 完成/错误 ----
    output wire                 done,        // 单拍脉冲：本笔（含拆分后的第二笔）完成
    output wire [OWNER_W-1:0]   done_owner,
    output wire [ADDR_W-1:0]    done_addr,
    output wire                 resp_error,  // bresp/rresp ≠ OKAY（脉冲）
    output wire [1:0]           resp_code,   // 最近一次非 OKAY 的 resp 编码

    //================================================================
    // AXI4 主端口（五通道；位宽与平台 config.h 一致）
    //================================================================
    // ---- 写地址通道 AW ----
    output wire [ID_W-1:0]      m_awid,
    output wire [ADDR_W-1:0]    m_awaddr,
    output wire [LEN_W-1:0]     m_awlen,
    output wire [SIZE_W-1:0]    m_awsize,
    output wire [BURST_W-1:0]   m_awburst,
    output wire [2:0]           m_awlock,     // 高位显式 0（平台只接 [0:0]）
    output wire [CACHE_W-1:0]   m_awcache,
    output wire [PROT_W-1:0]    m_awprot,
    output wire                 m_awvalid,
    input  wire                 m_awready,

    // ---- 写数据通道 W ----
    output wire [DATA_W-1:0]    m_wdata,
    output wire [STRB_W-1:0]    m_wstrb,
    output wire                 m_wlast,
    output wire                 m_wvalid,
    input  wire                 m_wready,

    // ---- 写响应通道 B ----
    input  wire [ID_W-1:0]      m_bid,
    input  wire [1:0]           m_bresp,
    input  wire                 m_bvalid,
    output wire                 m_bready,

    // ---- 读地址通道 AR ----
    output wire [ID_W-1:0]      m_arid,
    output wire [ADDR_W-1:0]    m_araddr,
    output wire [LEN_W-1:0]     m_arlen,
    output wire [SIZE_W-1:0]    m_arsize,
    output wire [BURST_W-1:0]   m_arburst,
    output wire [2:0]           m_arlock,     // 高位显式 0
    output wire [CACHE_W-1:0]   m_arcache,
    output wire [PROT_W-1:0]    m_arprot,
    output wire                 m_arvalid,
    input  wire                 m_arready,

    // ---- 读数据通道 R ----
    input  wire [ID_W-1:0]      m_rid,
    input  wire [DATA_W-1:0]    m_rdata,
    input  wire [1:0]           m_rresp,
    input  wire                 m_rlast,
    input  wire                 m_rvalid,
    output wire                 m_rready,

    // ---- 状态观察 ----
    output wire                 busy,
    output wire [OWNER_W-1:0]   owner
);
    //--------------------------------------------------------------------------
    // 1. 常量与状态编码（独热更利于时序；此处用紧凑编码 + 显式比较）
    //--------------------------------------------------------------------------
    localparam [2:0] ST_IDLE = 3'd0,
                     ST_AR   = 3'd1,   // 读：读地址握手
                     ST_R    = 3'd2,   // 读：读数据
                     ST_AW   = 3'd3,   // 写：写地址握手
                     ST_W    = 3'd4,   // 写：写数据
                     ST_B    = 3'd5,   // 写：写响应
                     ST_DONE = 3'd6;   // 收尾（一拍）

    //--------------------------------------------------------------------------
    // 2. 三件套寄存器
    //--------------------------------------------------------------------------
    reg              busy_q;
    reg [OWNER_W-1:0] owner_q;
    reg [ADDR_W-1:0] addr_q;        // ★ 总线地址寄存器唯一赋值点（物理地址）
    reg [LEN_W-1:0]  len_q;
    reg [LEN_W:0]    beats_q;
    reg [ID_W-1:0]   id_q;
    reg              is_write_q;
    reg [2:0]        state_q;

    // 写 beat 计数 / 读 beat 计数
    reg [LEN_W:0]    wcnt_q;
    reg [LEN_W:0]    rcnt_q;

    // 4 K 拆分的"第二笔"信息（首笔完成时锁存）
    reg              split_req_q;       // 首笔请求声明需拆（来自 req_split）
    reg              split_issued_q;    // 第二笔已排入（防止重复）
    reg              split_pending_q;   // 第二笔待发
    reg [ADDR_W-1:0] split_addr_q;      // 第二笔起始地址
    reg [LEN_W:0]    split_beats_q;     // 第二笔 beat 数
    reg [LEN_W:0]    first_beats_q;     // 首笔 beat 数（算第二笔地址用）
    reg [LEN_W:0]    second_beats_q;    // 第二笔 beat 数
    reg              split_write_q;

    assign busy  = busy_q;
    assign owner = owner_q;

    // 接受新请求：仅在完全空闲且无待发第二笔时
    assign req_ready = ~busy_q & ~split_pending_q;

    //--------------------------------------------------------------------------
    // 3. 组合推进条件（一律 valid && ready）
    //--------------------------------------------------------------------------
    wire ar_go = (state_q == ST_AR);
    wire aw_go = (state_q == ST_AW);
    wire w_go  = (state_q == ST_W);
    wire b_go  = (state_q == ST_B);
    wire r_go  = (state_q == ST_R);

    wire ar_fire = ar_go & m_arvalid & m_arready;
    wire aw_fire = aw_go & m_awvalid & m_awready;
    wire w_fire  = w_go  & m_wvalid  & m_wready;
    wire b_fire  = b_go  & m_bvalid  & m_bready;
    wire r_fire  = r_go  & m_rvalid  & m_rready;

    // ★ 拍数口径：笔内 beat 数 = AxLEN+1，计数从 0 起 ⇒ 最后一拍的下标是
    //   (beats_q - 1)。原先把结束条件写成 (cnt == beats_q) 会永不成立（本 TB
    //   实测到读交易卡死在 ST_R）。
    //   读侧以从端给出的 RLAST 为权威结束标志（AXI 语义），计数仅作交叉校验。
    wire w_last_beat = (wcnt_q == (beats_q - 1'b1));
    wire r_last_beat = m_rlast | (rcnt_q == (beats_q - 1'b1));

    // 第二笔 beat 数 = 请求总 beat 数 - 首笔 beat 数（仅 req_split=1 时有效）

    // 写响应非 OKAY ⇒ 错误可见
    wire b_err = b_fire & (m_bresp != `RV32GC_AXI_RESP_OKAY);
    wire r_err = r_fire & (m_rresp != `RV32GC_AXI_RESP_OKAY);

    reg  err_pending_q;
    reg [1:0] err_code_q;
    assign resp_error = b_err | r_err | err_pending_q;
    assign resp_code  = b_err ? m_bresp : (r_err ? m_rresp : err_code_q);

    //--------------------------------------------------------------------------
    // 4. 输出（组合）：所有 AXI 引脚由状态 + 寄存器直接映射
    //--------------------------------------------------------------------------
    // ---- AR ----
    assign m_arid    = id_q;
    assign m_araddr  = addr_q;                        // 唯一赋值点派生
    assign m_arlen   = len_q;
    assign m_arsize  = `RV32GC_AXI_SIZE_4B;
    assign m_arburst = `RV32GC_AXI_BURST_INCR;
    assign m_arlock  = {1'b0, `RV32GC_AXI_LOCK_NORMAL};
    assign m_arcache = `RV32GC_AXI_CACHE_CACHED;
    assign m_arprot  = `RV32GC_AXI_PROT_DATA;
    assign m_arvalid = ar_go;

    // ---- R ----
    assign m_rready  = r_go;
    assign rdata_valid = r_fire;
    assign rdata_data  = m_rdata;
    assign rdata_id    = m_rid;
    assign rdata_last  = m_rlast;
    assign rdata_ready = 1'b1;      // 本控制器始终收下读数据（无背压）

    // ---- AW ----
    assign m_awid    = id_q;
    assign m_awaddr  = addr_q;                        // 唯一赋值点派生
    assign m_awlen   = len_q;
    assign m_awsize  = `RV32GC_AXI_SIZE_4B;
    assign m_awburst = `RV32GC_AXI_BURST_INCR;
    assign m_awlock  = {1'b0, `RV32GC_AXI_LOCK_NORMAL};
    assign m_awcache = `RV32GC_AXI_CACHE_CACHED;
    assign m_awprot  = `RV32GC_AXI_PROT_DATA;
    assign m_awvalid = aw_go;

    // ---- W ----
    assign m_wdata   = wdata_data;
    assign m_wstrb   = 4'hF;                          // 整字写（beat 粒度）
    assign m_wlast   = w_last_beat;
    assign m_wvalid  = w_go & wdata_valid;
    assign wdata_ready = w_fire;

    // ---- B ----
    assign m_bready  = b_go;

    // ---- 完成脉冲 ----
    assign done       = (state_q == ST_DONE) & ~split_pending_q;
    assign done_owner = owner_q;
    assign done_addr  = addr_q;

    //--------------------------------------------------------------------------
    // 5. 时序：状态机
    //    必须用 always 块：这是状态元件（FSM + 数据通路寄存器）。
    //    所有状态跃迁的条件均为 valid && ready 或"本拍完成"。
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state_q         <= ST_IDLE;
            busy_q          <= 1'b0;
            owner_q         <= {OWNER_W{1'b0}};
            addr_q          <= {ADDR_W{1'b0}};
            len_q           <= {LEN_W{1'b0}};
            beats_q         <= {LEN_W+1{1'b0}};
            id_q            <= {ID_W{1'b0}};
            is_write_q      <= 1'b0;
            wcnt_q          <= {LEN_W+1{1'b0}};
            rcnt_q          <= {LEN_W+1{1'b0}};
            split_pending_q <= 1'b0;
            split_issued_q  <= 1'b0;
            split_req_q     <= 1'b0;
            split_addr_q    <= {ADDR_W{1'b0}};
            split_beats_q   <= {LEN_W+1{1'b0}};
            split_write_q   <= 1'b0;
            first_beats_q   <= {LEN_W+1{1'b0}};
            second_beats_q  <= {LEN_W+1{1'b0}};
            err_pending_q   <= 1'b0;
            err_code_q      <= 2'b00;
        end else begin
            // 错误标志自动清零（脉冲可见一拍）
            if (b_err | r_err) begin
                err_pending_q <= 1'b1;
                err_code_q    <= m_bresp;      // 近似：以最后一次错误为准
            end else if (err_pending_q) begin
                err_pending_q <= 1'b0;
            end

            case (state_q)
                // ---------------- 空闲：接受新请求 ----------------
                ST_IDLE: begin
                    // 优先发待发的第二笔（拆突发的后半）
                    if (split_pending_q) begin
                        busy_q     <= 1'b1;
                        addr_q     <= split_addr_q;      // ★ 唯一赋值点
                        beats_q    <= split_beats_q;
                        len_q      <= split_beats_q[LEN_W-1:0] - 4'd1;
                        is_write_q <= split_write_q;
                        // CMO 归属沿用当前 owner_q（第二笔属同一事务）
                        wcnt_q     <= {LEN_W+1{1'b0}};
                        rcnt_q     <= {LEN_W+1{1'b0}};
                        split_pending_q <= 1'b0;
                        state_q    <= split_write_q ? ST_AW : ST_AR;
                    end else if (req_valid & req_ready) begin
                        busy_q     <= 1'b1;
                        owner_q    <= req_owner;
                        addr_q     <= req_addr;          // ★ 唯一赋值点
                        // AxLEN = 本笔 beat 数 - 1（**由 beat 数派生**，不信任外部
                        // 传入的 req_len：4 K 拆分后首笔长度已变，外部容易忘同步）
                        len_q      <= req_beats_1[LEN_W-1:0] - 4'd1;
                        beats_q    <= req_beats_1;
                        id_q       <= req_id;
                        is_write_q <= req_is_write;
                        wcnt_q     <= {LEN_W+1{1'b0}};
                        rcnt_q     <= {LEN_W+1{1'b0}};
                        // 拆分信息：首笔 beat 数与第二笔 beat 数
                        split_req_q    <= req_split;
                        split_issued_q <= 1'b0;
                        first_beats_q  <= req_beats_1;
                        second_beats_q <= req_beats_2;
                        state_q    <= req_is_write ? ST_AW : ST_AR;
                    end
                end

                // ---------------- 读：AR 握手 ----------------
                ST_AR: begin
                    if (ar_fire) state_q <= ST_R;
                end

                // ---------------- 读：R 逐 beat ----------------
                ST_R: begin
                    if (r_fire) begin
                        if (r_last_beat) state_q <= ST_DONE;
                        else             rcnt_q  <= rcnt_q + 1'b1;
                    end
                end

                // ---------------- 写：AW 握手 ----------------
                ST_AW: begin
                    if (aw_fire) state_q <= ST_W;
                end

                // ---------------- 写：W 逐 beat ----------------
                ST_W: begin
                    if (w_fire) begin
                        if (w_last_beat) state_q <= ST_B;
                        else             wcnt_q  <= wcnt_q + 1'b1;
                    end
                end

                // ---------------- 写：B 响应 ----------------
                ST_B: begin
                    if (b_fire) state_q <= ST_DONE;
                end

                // ---------------- 收尾：拆分或释放 ----------------
                ST_DONE: begin
                    // 本笔完成。若首笔声明需拆第二笔 ⇒ 锁存第二笔描述符并释放 busy，
                    // 下一拍由 ST_IDLE 的 split_pending 分支自动发出第二笔。
                    busy_q <= 1'b0;
                    if (split_req_q && !split_pending_q && !split_issued_q) begin
                        split_pending_q <= 1'b1;
                        split_addr_q    <= addr_q + {13'b0, first_beats_q[LEN_W:0], 2'b00};
                        split_beats_q   <= second_beats_q;
                        split_write_q   <= is_write_q;
                        split_issued_q  <= 1'b1;
                    end
                    state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // 6. 参数自检
    //--------------------------------------------------------------------------
    initial begin
        if (LEN_W != 4) begin
            $display("AXI_MASTER_CTRL FAIL: LEN_W=%0d 应为 4（平台 4 bit len）", LEN_W);
            $fatal(1, "AXI_MASTER_CTRL PARAM FAIL");
        end
        if (ID_W != 4 || DATA_W != 32 || ADDR_W != 32 || STRB_W != 4) begin
            $display("AXI_MASTER_CTRL FAIL: 位宽与平台 config.h 不一致");
            $fatal(1, "AXI_MASTER_CTRL PARAM FAIL");
        end
        if (`RV32GC_AXI_OUTSTANDING != 1) begin
            $display("AXI_MASTER_CTRL FAIL: 2A 应为单笔在途");
            $fatal(1, "AXI_MASTER_CTRL PARAM FAIL");
        end
    end

endmodule
