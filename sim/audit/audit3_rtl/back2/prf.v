//==============================================================================
// rtl/back2/prf.v —— 物理寄存器堆（写优先读口 + epoch 过滤的写口）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-2）
// 规格  : docs/design/03-out-of-order.md §5.2 **T1 写优先寄存器堆**（同拍写口与读口
//         命中同一物理寄存器 ⇒ 写数据直通读口，不依赖"写先于读"的时序假设）、
//         §8.2（epoch 过滤：冲刷后过期写回不得污染已被复用的物理寄存器）、
//         docs/design/02-pipeline.md §3.9（I2 读物理寄存器堆）。
//
// 【实现】以寄存器阵列（触发器）承载，组合读 + 写优先旁路：
//   rdata[r] = |w：waddr[w]==raddr[r] ? wdata[w] : mem[raddr[r]]   （多路写口取最高编号者）
//   ★ 写口按 `wepoch[w] == epoch` 门控（过期写直接丢弃，见 §8.2）。
//   ★ 本里程碑的流水结构里"写回拍"与"读口拍"天然错开一拍，写优先旁路仍然实现并
//     由单元 TB 定向制造同拍同址读写以验证（03 §5.4 的 T1 反向实验）。
//   ★ 存储元件用触发器阵列而非 Block Memory：物理寄存器堆需要**多写多读组合口**
//     与写优先旁路，Vivado BMG 的简单双端口（1 写 1 读、同步读）在结构与端口数上
//     都不满足（红线 1：先检索 IP；检索结论与 front4 LHT 同一口径，见交付说明）。
//
// 风格  : 组合读用 `assign` + 条件表达式；always 块只用于存储体（时序元件）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module prf #(
    parameter integer NW   = 8,
    parameter integer NRD  = 18,
    parameter integer NREG = `BACK2_PRF_I_N,
    parameter integer PDW  = `BACK2_PREG_I_W,
    parameter integer DW   = 32
) (
    input  wire                clk,
    input  wire                rst_n,

    // ---- 写口 ----
    input  wire [NW-1:0]       we,
    input  wire [NW*PDW-1:0]   waddr,
    input  wire [NW*DW-1:0]    wdata,
    input  wire [NW*`BACK2_EPOCH_W-1:0] wepoch,      // 仅诊断观测（见 §写口判据）
    input  wire [`BACK2_EPOCH_W-1:0]    epoch,
    //   ★ **写口有效判据（唯一）**：由调用方给出"该写回所属 ROB 项仍在 ROB 窗口内"。
    //     不能用 `wepoch == epoch`：冲刷（squash）会**保留**比分支更老的、正在执行的项，
    //     它们的写回带的是**发射时**的 epoch（旧值）⇒ 被过滤掉 ⇒ 消费者读到陈旧值
    //     （实测：4 深 WAW 链的 `srli` 读到 0 而非 0x1a，C1 锁步分歧）。
    //     窗口判据同时覆盖原目标：被冲刷项的 ROB 索引落在窗口外 ⇒ 写回被丢弃，
    //     不会污染回滚后复用同一物理号的新项。
    input  wire [NW-1:0]                wkeep,

    // ---- 读口（组合，写优先旁路）----
    input  wire [NRD-1:0]      re,
    input  wire [NRD*PDW-1:0]  raddr,
    output wire [NRD*DW-1:0]   rdata
);

    reg [DW-1:0] mem [0:NREG-1];

    //--------------------------------------------------------------------------
    // 写优先旁路：逐级条件选择（后写口优先；物理寄存器在飞项唯一 ⇒ 实际最多 1 命中）
    //--------------------------------------------------------------------------
    //   ★★ 2B-5（时序收敛）：**去掉写优先旁路** —— 读口只输出阵列值 `mem[raddr]`。
    //     【为什么可以去】（结构论证 + TB 绿证）
    //       · 本后端的**操作数全在 E1 读**（`iprf_ra[0..10]` = `x_i2_uop[*]` 的 ps1i/ps2i），
    //         而 `iq.v` 的唤醒口径是“**同拍唤醒即可选**”：生产者在第 N 拍写回
    //         ⇒ 消费者最早在 N 拍被**选中并发射** ⇒ 它在 **N+1 拍**才进入 `x_i2` 执行
    //         ⇒ 读到的是已在 N→N+1 沿落地的 `mem` 值 ✓（无需同拍直通）。
    //       · 同拍发射的两条（生产者+消费者）**不可能同拍执行**：消费者若在 N 拍发射，则它的源在 N-1 拍
    //         已就绪 ⇒ 生产者已在 ≤N-1 拍写完 ⇒ `mem` 已是新值。
    //       · 提交读口（`iprf_ra[11..15]` / `fprf_ra[4..7]`）读的是“该指令自己写的物理寄存器 /
    //         CSR 的 rs1”，二者都已在提交前完成写回（提交前必须 `done`），且该 preg
    //         在本指令提交前不会被重新分配 ⇒ 直接读 `mem` 正确 ✓。
    //     【为什么必须去】：写优先旁路把 `wdata`（= 后端写回总线 `wbi_data`）与 `rdata`
    //       直接连通，而 `rdata` 又经 ALU/BRU 回到 `wbi_data` ⇒ **真实组合环**（Vivado 实测：
    //       101 条 `[Synth 8-326] inferred exception to break timing loop`，全部穿 `u_prf_ii_142/rdata[*]`
    //       与 `u_backi_163/wbi_data[*]`）⇒ 时序驱动综合阶段反复迭代、超时无产物。
    //     【绿证】三 TB + regress 全绿（见报告 §B4.42）。
    genvar gr;
    generate
    for (gr = 0; gr < NRD; gr = gr + 1) begin : g_rd
        assign rdata[gr*DW +: DW] = mem[raddr[gr*PDW +: PDW]];
    end
    endgenerate

    //--------------------------------------------------------------------------
    // 存储体
    //--------------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NREG; i = i + 1) mem[i] <= {DW{1'b0}};
        end else begin
            for (i = 0; i < NW; i = i + 1) begin
                if (we[i] && wkeep[i])
                    mem[waddr[i*PDW +: PDW]] <= wdata[i*DW +: DW];
            end
        end
    end

endmodule
