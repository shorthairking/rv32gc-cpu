//==============================================================================
// sim/unit/dyn_probe_n6_body.inc —— EXP-N6 探针公共体（lockstep / ipc / core_top 复用）
//------------------------------------------------------------------------------
// 前提：被 include 的模块里已有
//   · `tb_back2_lockstep_top u_tb ();` / `tb_back2_ipc u_tb ();` /
//     `tb_core_top_2b u_tb ();`（三者都有可达的 backend_top 实例）
//   · `wire [31:0] dyn_bench;`（基准编号）
//   · `define DYN_BK <backend_top 层次路径>`
//   · `define DYN_FNAME "<输出 CSV 相对路径>"`
// 本文件只做**只读层次引用**与 `dyn_probe_n6_core` 例化；不改产品 RTL。
//
//   ★ 被引用的信号（唯一真源 = rtl/back2/backend_top.v 与 rtl/exec/fpu.v）：
//       i5_sel_v / iq_base_rdy / iwm_gnt / iq_iss_v / x_i2_v / fpu_if_v  (backend_top.v)
//       fp_op / fmt / sc_v / busy / ds_pend / ds_busy / disp_any / disp_ds (fpu.v)
//   ★ `opx`/`acx`（被接收而操作码/格式未定）在**探针内**逐位用 case-equality 判别：
//     未定位只允许出现在 `acc==0` 的无关拍上；任何 `acc==1` 而 op/fmt 未定都必须被
//     这两列抓出来，由分析器 fail-closed 断言 `opx==0 ∧ acx==0`。纯组合 ⇒ 无副作用。
//==============================================================================

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

    wire       n6_req  = `DYN_BK.i5_sel_v;
    wire       n6_rdy  = `DYN_BK.iq_base_rdy[5];
    wire       n6_rdym = `DYN_BK.iwm_gnt[5];
    wire       n6_gnt  = `DYN_BK.iq_iss_v[5];
    wire       n6_acc  = `DYN_BK.x_i2_v[5];
    wire       n6_finv = `DYN_BK.fpu_if_v;

    wire [6:0] n6_op   = `DYN_BK.u_fpu.fp_op;
    wire [1:0] n6_fmt  = `DYN_BK.u_fpu.fmt;
    wire       n6_dan  = `DYN_BK.u_fpu.disp_any;
    wire       n6_dds  = `DYN_BK.u_fpu.disp_ds;
    wire [7:0] n6_scv  = `DYN_BK.u_fpu.sc_v;
    wire       n6_busy = `DYN_BK.u_fpu.busy;
    wire       n6_dsp  = `DYN_BK.u_fpu.ds_pend;
    wire       n6_dsb  = `DYN_BK.u_fpu.ds_busy;

    //   逐位"已定义"（0/1 皆已定义；x/z 未定义）
    wire n6_op_def = (n6_op[0]===1'b0||n6_op[0]===1'b1) && (n6_op[1]===1'b0||n6_op[1]===1'b1) &&
                     (n6_op[2]===1'b0||n6_op[2]===1'b1) && (n6_op[3]===1'b0||n6_op[3]===1'b1) &&
                     (n6_op[4]===1'b0||n6_op[4]===1'b1) && (n6_op[5]===1'b0||n6_op[5]===1'b1) &&
                     (n6_op[6]===1'b0||n6_op[6]===1'b1);
    wire n6_ac_def = (n6_fmt[0]===1'b0||n6_fmt[0]===1'b1) && (n6_fmt[1]===1'b0||n6_fmt[1]===1'b1);
    wire n6_opx = n6_acc & ~n6_op_def;
    wire n6_acx = n6_acc & ~n6_ac_def;
    //   ★ `rdyx`/`rdymx`（白证列）：`iq_base_rdy[5]` 由 CSR→FP 互锁的年龄窗 + ROB
    //     头/计数比较组合而成，复位后最初若干拍这些锁存仍未定 ⇒ 整值打成 'x'。
    //     但 `rdy` 只在 `req==1`（确实要发射）时才被消费 ⇒ 未定位只允许落在
    //     `req==0` 的无关拍上。本列逐位用 case-equality 判别，**恒 0** 是
    //     "所有真正的发射请求都看到了已定义的许可"的可证条件（分析器 fail-closed）。
    wire n6_rdy_def  = (n6_rdy  === 1'b0) || (n6_rdy  === 1'b1);
    wire n6_rdym_def = (n6_rdym === 1'b0) || (n6_rdym === 1'b1);
    wire n6_rdyx  = (n6_req === 1'b1) && !n6_rdy_def;
    wire n6_rdymx = (n6_req === 1'b1) && n6_rdy_def && (n6_rdy === 1'b1) && !n6_rdym_def;

    dyn_probe_n6_core #(.FNAME(`DYN_FNAME)) u_n6probe (
        .clk (clk), .rst_n (rst_n), .bench (dyn_bench),
        .req (n6_req), .rdy (n6_rdy), .rdym (n6_rdym), .gnt (n6_gnt),
        .acc (n6_acc), .dan (n6_dan), .dds (n6_dds),
        .op (n6_op), .fmt (n6_fmt), .scv (n6_scv),
        .busy (n6_busy), .dsp (n6_dsp), .dsb (n6_dsb), .finv (n6_finv),
        .opx (n6_opx), .acx (n6_acx), .rdyx (n6_rdyx), .rdymx (n6_rdymx)
    );
