//==============================================================================
// sim/unit/dyn_probe_n29b_core.sv —— EXP-N29B：**纯等待变体等待特性档案**（只读采样核）
//------------------------------------------------------------------------------
// 目的：为 EXP-N29B 的送审核心数据提供**逐工作集**的等待特性：
//   · `e1ld`    该 bench 的 load-E1 总条数（分母）
//   · `dep`     其中**有依赖**（E1 当拍 `|fwd_hit_w` ⇒ `ld_dep_v=1`）的条数
//               = 进入等待路径的 load 数（纯等待变体下"凡依赖即等待"）
//   · `blk_cyc` 该 bench 内 `|ld_wait` 为真的**周期数**（等待闸门挡住的拍数）
//   · `blk_ep`  "被挡**事件**"数（`|ld_wait` 由 0→1 的次数；≈ 真正被延迟的 load 条数）
//   · `max_run` 最长**连续**被挡拍数（同一 bench 内 `|ld_wait` 连续为真的最长段）
//
// 纪律：
//   · **只读**层次引用（`ld_wait`/`ld_v`/`ld_ex`/`fwd_hit_w`/`exe_*`），不改任何产品 RTL；
//   · 文件名不匹配 `sim/unit/tb_*.sv` ⇒ 不进 `scripts/regress.sh` 的既有回归；
//   · 只在 `final` 打印（**不含**任何 PASS 字样；不干扰 TB 自身锚点计数）。
//
// 口径注意：`ld_wait` 是 §3.2 的**组合**等待闸门（`ld_v & ld_ex & ld_dep_v & ~ld_mis &
//   (stq_old_age < age_ld)`）⇒ `|ld_wait` = "本拍至少有一条已 E1 的 load 因依赖未落地
//   而被挡在请求口外"。
//==============================================================================
`timescale 1ns / 1ps

module dyn_probe_n29b_core #(
    parameter integer NB = 64
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] bench,
    input  wire        e1ld,
    input  wire        dep,
    input  wire        any_wait
);

    integer e1 [0:NB-1];
    integer dp [0:NB-1];
    integer bc [0:NB-1];
    integer be [0:NB-1];
    integer mr [0:NB-1];
    integer run;
    integer prev_any;
    integer seen [0:NB-1];      // 该 bench 是否出现过（即使 0 条 load 也要出一行）
    integer bi, last_bi;
    integer k;

    initial begin
        for (k = 0; k < NB; k = k + 1) begin
            e1[k] = 0; dp[k] = 0; bc[k] = 0; be[k] = 0; mr[k] = 0; seen[k] = 0;
        end
        run = 0; prev_any = 0; last_bi = -1;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            bi = (bench < NB) ? bench : 0;
            seen[bi] = 1;
            if (bi != last_bi) begin
                last_bi = bi;
                run     = 0;          // 连续段不跨 bench
                prev_any = 0;
            end
            if (e1ld) begin
                e1[bi] = e1[bi] + 1;
                if (dep) dp[bi] = dp[bi] + 1;
            end
            if (any_wait) begin
                bc[bi] = bc[bi] + 1;
                run    = run + 1;
                if (run > mr[bi]) mr[bi] = run;
                if (!prev_any) be[bi] = be[bi] + 1;
            end else begin
                run = 0;
            end
            prev_any = any_wait;
        end
    end

    final begin
        for (k = 0; k < NB; k = k + 1)
            if (seen[k])
                $display("N29B_WAIT: bench=%0d e1ld=%0d dep=%0d blk_cyc=%0d blk_ep=%0d max_run=%0d",
                         k, e1[k], dp[k], bc[k], be[k], mr[k]);
    end

endmodule
