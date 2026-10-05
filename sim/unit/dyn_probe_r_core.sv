//==============================================================================
// sim/unit/dyn_probe_r_core.sv —— 动态**容量**数据采集探针（EXP-R2/R3/R4/R5 通用采样核）
//------------------------------------------------------------------------------
// 目的：为下一阶段四项容量缩减决策采集"容量能不能砍"的事实依据（answer.md §十九）：
//   · EXP-R2 NREG    ：PRF 96→64 是否可行 ⇒ 需 max live physical registers 高水位
//   · EXP-R3 TRQ     ：训练 FIFO 16→? ⇒ 需 trq backlog 高水位 / 分支提交突发
//   · EXP-R4 SQ      ：SQ 32→16 是否可行 ⇒ 需 SQ 占用高水位 + 字节掩码分布
//   · EXP-R5 FPU     ：iterative div/sqrt 是否值得 ⇒ 需 op-kind 直方图 + div/sqrt 频率
//
// 【设计纪律】
//   · **不修改任何产品 RTL**：只从 TB 层次引用读信号，逐拍把已归约好的小整数写进 CSV；
//     全部统计/判定由确定性脚本 `fpga/scratch/dyn_analyze_r.py` 完成（PASS/FAIL 由脚本判）。
//   · 文件名**不匹配** `sim/unit/tb_*.sv`（regress.sh 通配）⇒ 不进既有回归、不影响任何判据。
//   · 输出仅 CSV 一行表头 + 每拍一行；**不打印任何含 PASS 字样的文案**；
//     任何字段为 x/z 一律由分析器判 FAIL（fail-closed）。
//   · 编译必须用**冻结树**（`git archive cfc0af9` 到 /tmp）：见 fpga/scratch/dyn_r_run.sh。
//
// 【列定义】（表头自描述；口径与真源行号见 fpga/scratch/dyn_behavior_r.md §0）
//   bench/row   基准编号 / 探针行号（每基准独立从 0 计）
//   ---- 组 R：rename / checkpoint / 回滚 ----
//   freei/freef rename 两域 free list **剩余空位**（free_cnt_w，rename.v:320）
//   livei/livef 已占用物理寄存器数 = NREG − free（整数 96 / 浮点 64；ARCH_N=32 为下界）
//   cki/ckf     rename 两域**活跃检查点数** = popcount(ck_val)（rename.v:161）
//   ckbusy      后端 ck_busy_q 原值（**注意只声明了 4 bit**，backend_top.v:630）
//   ckpend      popcount(ck_pend_q)（待释放检查点，backend_top.v:632）
//   snapv/snapid 本拍检查点快照脉冲 / 其 id（backend_top.v:447-448/1154）
//   squash      分支误判回滚脉冲（squash_v_w，backend_top.v:2110）
//   flushall    整机冲刷（陷阱 / xret，flush_all_w，backend_top.v:2120）
//   rstck/rstrob 回滚入口：检查点入口 / ROB 索引入口（backend_top.v:2112-2115）
//   undo        rename 逆序回放进行中（u_ren_i.undo_act，rename.v:186）
//   age         回滚点距 ROB 头的距离（squash_age_w，backend_top.v:602；rob.v:304）
//   rob         本拍 ROB 有效项数（rob_cnt_w，backend_top.v:603）
//   robhead     本拍 ROB 头索引（rob_head_w[5:0]，backend_top.v:597）
//   rbidx       回滚 ROB 索引（restore_rob_idx_w = x_i2_rob[2]，backend_top.v:2115）
//   ---- 组 T：TRQ（分支训练 FIFO）----
//   trqcnt      trq_cnt 原值（backend_top.v:2288；**已知同拍入队+出队会多计 1**，见 :2282）
//   trqw/trqr   写/读指针（backend_top.v:2287）⇒ 权威积压 = (trqw − trqr) mod 32
//   trqacc      本拍分支提交入队条数（backend_top.v:2292/2296）
//   trqfull     trq_full（阈值 12，backend_top.v:2289）
//   trqfire     本拍训练条目出队（train_valid_o & train_ready_i，backend_top.v:2331）
//   nbr         本拍提交的分支条数（提交 lane 载荷 is_branch；= 分支提交突发）
//   ---- 组 L：LSU / LSQ ----
//   stqcnt      SQ 占用 = stq_used（lsq_simple.v:313）
//   lqcnt       LQ 占用 = popcount(ld_v)（lsq_simple.v:565）
//   fwdhit      本拍字节级转发命中道数（fwd_hit_w，lsq_simple.v:460/553）
//   fwdall      全转发判据（fwd_all_w，lsq_simple.v:548）
//   stmask      E1 store 的实际字节掩码（lmask_w，lsq_simple.v:404；非 store 拍无意义）
//   stsize      E1 store 的 size（log2 字节数：0=SB 1=SH 2=SW 3=SD，lsq_simple.v:85）
//   stv/ldv     E1 本拍是 store / 是 load（lsq_simple.v: exe_valid & exe_is_store）
//   ---- 组 F：FPU ----
//   fpop        E1 浮点操作码（w_fpop 口径，IW 载荷 [44:39]，backend_top.v:312/1366）
//   freq        E1 有浮点请求（x_i2_v[5]，backend_top.v:1575）
//   fifv        FPU 在途登记（fpu_if_v，backend_top.v:462）⇒ in-flight 上界
//   fdsbusy     div/sqrt 迭代在途（u_fpu.ds_busy，fpu.v:260）
//   fbusy       FPU 忙（fpu.v:486）
//   fdone       结果有效脉冲（fpu.done，backend_top.v:1567）
//   ---- 交叉验证 ----
//   ncmt        本拍提交条数（与既有 dyn 探针同口径：提交 lane valid 计数）
//==============================================================================
`timescale 1ns / 1ps

module dyn_probe_r_core #(
    parameter FNAME = "dyn_r.csv"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] bench,
    // 组 R
    input  wire [7:0]  freei,
    input  wire [7:0]  freef,
    input  wire [7:0]  livei,
    input  wire [7:0]  livef,
    input  wire [4:0]  cki,
    input  wire [4:0]  ckf,
    input  wire [3:0]  ckbusy,
    input  wire [4:0]  ckpend,
    input  wire        snapv,
    input  wire [3:0]  snapid,
    input  wire        squash,
    input  wire        flushall,
    input  wire        rstck,
    input  wire        rstrob,
    input  wire        undo,
    input  wire [5:0]  age,
    input  wire [7:0]  rob,
    input  wire [5:0]  robhead,
    input  wire [5:0]  rbidx,
    input  wire [1:0]  rbact,
    // 组 T
    input  wire [4:0]  trqcnt,
    input  wire [4:0]  trqw,
    input  wire [4:0]  trqr,
    input  wire [1:0]  trqacc,
    input  wire        trqfull,
    input  wire        trqfire,
    input  wire        tpcx,
    input  wire [2:0]  nbr,
    // 组 L
    input  wire [5:0]  stqcnt,
    input  wire [4:0]  lqcnt,
    input  wire [7:0]  fwdhit,
    input  wire        fwdall,
    input  wire [3:0]  stmask,
    input  wire [2:0]  stsize,
    input  wire        stv,
    input  wire        ldv,
    input  wire [5:0]  stqv,
    // 组 F
    input  wire [6:0]  fpop,
    input  wire        freq,
    input  wire        fifv,
    input  wire        fdsbusy,
    input  wire        fbusy,
    input  wire        fdone,
    input  wire [4:0]  feck,
    input  wire        fefull,
    // 交叉验证
    input  wire [2:0]  ncmt
);

    integer fd;
    integer row;
    integer last_bench;
    integer flush_i;

    initial begin
        fd         = $fopen(FNAME, "w");
        row        = 0;
        last_bench = -1;
        flush_i    = 0;
        if (fd == 0)
            $display("DYN_PROBE_R: 无法打开输出文件 %0s", FNAME);
        else
            $fwrite(fd, {"bench,row,freei,freef,livei,livef,cki,ckf,ckbusy,ckpend,",
                         "snapv,snapid,squash,flushall,rstck,rstrob,undo,age,rob,robhead,rbidx,rbact,",
                         "trqcnt,trqw,trqr,trqacc,trqfull,trqfire,tpcx,nbr,",
                         "stqcnt,lqcnt,fwdhit,fwdall,stmask,stsize,stv,ldv,stqv,",
                         "fpop,freq,fifv,fdsbusy,fbusy,fdone,feck,fefull,ncmt\n"});
    end

    always @(posedge clk) begin
        if (rst_n && (fd != 0)) begin
            if (bench != last_bench) begin
                last_bench = bench;
                row        = 0;
            end
            $fwrite(fd, {"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,",
                         "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,",
                         "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,",
                         "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,",
                         "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n"},
                bench, row,
                freei, freef, livei, livef,
                cki, ckf, ckbusy, ckpend,
                snapv, snapid, squash, flushall, rstck, rstrob, undo,
                age, rob, robhead, rbidx, rbact,
                trqcnt, trqw, trqr, trqacc, trqfull, trqfire, tpcx, nbr,
                stqcnt, lqcnt, fwdhit, fwdall, stmask, stsize, stv, ldv, stqv,
                fpop, freq, fifv, fdsbusy, fbusy, fdone, feck, fefull,
                ncmt);
            row     = row + 1;
            flush_i = flush_i + 1;
            if (flush_i >= 128) begin
                flush_i = 0;
                $fflush(fd);
            end
        end
    end

    final begin
        if (fd != 0) $fflush(fd);
    end

endmodule
