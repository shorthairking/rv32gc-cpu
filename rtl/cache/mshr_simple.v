//==============================================================================
// rtl/cache/mshr_simple.v —— 2A 简化 MSHR（每侧 1 项在途）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 归属  : docs/design/08-baseline-5stage.md §5.5 抉择 10（2A MSHR 深度 = 1/侧）、
//         §7.1 要点 2（单笔在途三件套）；docs/design/05-cache-memory.md §4.3
//
// 职责  : 记录「一笔在途的 Cache 行填充请求」的全部描述符，并在数据返回时
//         把它交给消费者（L1I/L1D）。三项在途属于同一笔事务，所以**只需 1 项**。
//
// 单笔在途三件套（AGENT.md §3.3，本模块是它的载体）：
//   ① busy    —— 单笔在途标志：busy=1 时新请求被反压（alloc_ready=0）
//   ② owner   —— 归属寄存器：记录本笔请求属于谁
//                 （2A 用 2 bit 编码：0=I-Cache 填充、1=D-Cache 填充、2=脏行写回）
//   ③ 推进    —— 完成判定一律用 `valid && ready`（本模块的 done 端口即此语义），
//                 禁止用"电平维持"或"计数器到点"隐式推进
//
// 为什么 owner 不能省：返回通道是共享的（2A 只有一条 AXI 返回通路），
//   数据回到核里时若不知道这笔属于 I 还是 D，就会把 I 行填进 D 阵列
//   ——这正是「归属寄存器」存在的唯一理由，属于总线口仲裁的必备件。
//
// 地址寄存器唯一赋值点（08 §7.1 要点 3）：本模块的 addr_q 是**物理地址**
//   总线地址寄存器的唯一赋值点（VA/PA 混用是静默错）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module mshr_simple #(
    parameter integer ADDR_W  = 32,     // 物理地址位宽
    parameter integer DATA_W  = 32,     // 每拍数据位宽（AXI beat）
    parameter integer BEATS_W = 5,      // beat 计数位宽（≤16 beat ⇒ 5 bit 足够）
    parameter integer OWNER_W = 2       // 归属编码位宽
) (
    input  wire                 clk,
    input  wire                 rst_n,      // 同步复位，低有效

    // ---- 分配（来自 Cache 的缺失请求） ----
    input  wire                 alloc_req,  // 请求分配一项
    input  wire [OWNER_W-1:0]   alloc_owner,// 归属：0=I 填充、1=D 填充、2=写回
    input  wire [ADDR_W-1:0]    alloc_paddr,// **物理地址**（唯一赋值点）
    input  wire [BEATS_W-1:0]   alloc_beats,// 本笔突发 beat 数 - 1（AxLEN）
    output wire                 alloc_ready,// 1 = 接受（未 busy）；0 = 反压

    // ---- 状态观察（供 L1 控制器与 TB 使用） ----
    output wire                 busy,       // ① 单笔在途标志
    output wire [OWNER_W-1:0]   owner,      // ② 归属寄存器
    output wire [ADDR_W-1:0]    paddr,      // 在途请求的物理地址
    output wire [BEATS_W-1:0]   beats,      // 在途请求的 burst 长度-1

    // ---- 数据回填（AXI R/W beat 到达） ----
    input  wire                 fill_valid, // 1 = 本拍有 beat 数据
    input  wire [DATA_W-1:0]    fill_data,  // beat 数据
    output wire                 fill_ready, // = busy（收得下才收；valid&&ready 推进）

    // ---- 完成（最后一 beat 已收下） ----
    output wire                 done,       // 单拍脉冲：本笔事务完成
    output wire [OWNER_W-1:0]   done_owner, // 完成笔的归属（回送给对的消费者）
    output wire [ADDR_W-1:0]    done_paddr  // 完成笔的物理地址
);
    //--------------------------------------------------------------------------
    // 1. 状态寄存器（仅两个：在途标志 + 描述符）
    //--------------------------------------------------------------------------
    reg                 busy_q;
    reg [OWNER_W-1:0]   owner_q;
    reg [ADDR_W-1:0]    paddr_q;
    reg [BEATS_W-1:0]   beats_q;
    reg [BEATS_W-1:0]   beat_cnt_q;     // 已收 beat 数

    //--------------------------------------------------------------------------
    // 2. 组合输出与推进条件（全部用 assign，无 always @(*)）
    //--------------------------------------------------------------------------
    assign busy        = busy_q;
    assign owner       = owner_q;
    assign paddr       = paddr_q;
    assign beats       = beats_q;

    // 分配：只有在不 busy 时才接受（单笔在途）
    assign alloc_ready = ~busy_q;

    // 回填：只有在 busy 时才收（valid && ready 推进的唯一合法形式）
    assign fill_ready  = busy_q;

    // 完成：本拍收下最后一 beat ⇒ 单拍脉冲
    wire last_beat = (beat_cnt_q == beats_q);
    assign done        = fill_valid & fill_ready & last_beat;
    assign done_owner  = owner_q;
    assign done_paddr  = paddr_q;

    //--------------------------------------------------------------------------
    // 3. 时序：状态更新
    //    必须用 always 块：这是状态元件（寄存器），无法用 assign 表达。
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            busy_q     <= 1'b0;
            owner_q    <= {OWNER_W{1'b0}};
            paddr_q    <= {ADDR_W{1'b0}};
            beats_q    <= {BEATS_W{1'b0}};
            beat_cnt_q <= {BEATS_W{1'b0}};
        end else begin
            if (fill_valid && fill_ready) begin
                if (last_beat) begin
                    // 本笔收完 ⇒ 释放在途项（busy 拉低）
                    busy_q     <= 1'b0;
                    beat_cnt_q <= {BEATS_W{1'b0}};
                end else begin
                    beat_cnt_q <= beat_cnt_q + 1'b1;
                end
            end else if (alloc_req && alloc_ready) begin
                // 新请求进入 ⇒ 登记三件套（描述符只在此处写入）
                busy_q     <= 1'b1;
                owner_q    <= alloc_owner;
                paddr_q    <= alloc_paddr;
                beats_q    <= alloc_beats;
                beat_cnt_q <= {BEATS_W{1'b0}};
            end
        end
    end

    //--------------------------------------------------------------------------
    // 4. 参数自检
    //--------------------------------------------------------------------------
    initial begin
        if (`RV32GC_MEMSHR_DEPTH != 1) begin
            $display("MSHR_SIMPLE FAIL: 2A MSHR 深度应为 1（08 §5.5 抉择 10）");
            $fatal(1, "MSHR_SIMPLE PARAM FAIL");
        end
        if (ADDR_W != 32) begin
            $display("MSHR_SIMPLE FAIL: ADDR_W=%0d 应等于 XLEN=32", ADDR_W);
            $fatal(1, "MSHR_SIMPLE PARAM FAIL");
        end
        if (OWNER_W < 2) begin
            $display("MSHR_SIMPLE FAIL: OWNER_W=%0d 至少 2 bit", OWNER_W);
            $fatal(1, "MSHR_SIMPLE PARAM FAIL");
        end
    end

endmodule
