//=============================================================================
// rv32_pmp.v —— PMP（Physical Memory Protection）访问检查器
//   · 纯组合：无时钟、无复位、无状态；只回答"这次访问是否被允许"，不做地址翻译
//   · 默认 16 项（PMP_ENTRIES 可参数化）、4 字节粒度（G=0：NA4 可选、pmpaddr 全位可写）
//   · RV32：pmpaddr[i] = 物理地址 >> 2；本次比较用 word 索引 w = addr[31:2]
//     一次访问 acc_size ≤ 4B，最多跨 2 个 word：w0 = addr[31:2]，w1 = (addr+bytes-1)[31:2]
//
// 规范出处（原文摘录见下方标注；路径相对 workspace 根 /home/shorthair/dsh/rv32-cpu）
//   [1] riscv-isa-manual/src/priv/machine.adoc:3406-3412
//         pmpcfg 权限位 R/W/X 置位=允许，清零=拒绝；R=0 且 W=1 是保留 WARL 组合
//   [2] riscv-isa-manual/src/priv/machine.adoc:3432  (norm:pmp_a_field_off)
//         A=0(OFF) ⇒ 该项不匹配任何地址
//   [3] riscv-isa-manual/src/priv/machine.adoc:3438-3456  ← A 字段编码表
//         A=0 OFF / A=1 TOR / A=2 NA4 / A=3 NAPOT
//         **四个编码全部已定义，规范不存在"保留的 A=2'b10"**（A=2 就是 NA4）。
//         本项目规格书 docs/design/spec/07-priv-csr-mmu.md:351-357 的伪代码一致。
//   [4] riscv-isa-manual/src/priv/machine.adoc:3458-3494
//         NAPOT: pmpaddr 低位连续 1 的个数 k 编码区间大小 2^(k+3) 字节（= 2^(k+1) 个 word）；
//         pmpaddr 全 1 ⇒ 2^(XLEN+3) 字节 ⇒ 覆盖整个地址空间
//   [5] riscv-isa-manual/src/priv/machine.adoc:3496-3506 (norm:pmp_a_field_tor)
//         TOR: pmpaddr[i-1] <= y < pmpaddr[i]（i=0 时下界为 0）；上界不取等；
//         与 pmpcfg[i-1] 的取值无关；pmpaddr[i-1] >= pmpaddr[i] 时该项不匹配任何地址
//   [6] riscv-isa-manual/src/priv/machine.adoc:3557-3562 (norm:pmp_l_bit_m_mode_enforcement)
//         L=1 ⇒ 权限对 M 模式也生效；L=0 ⇒ 匹配到该项的 M 模式访问成功
//   [7] riscv-isa-manual/src/priv/machine.adoc:3575-3578 (norm:pmp_entry_priority)
//         静态优先级：**编号最小的匹配项**决定结论（不是"所有匹配项都要允许"）
//   [8] riscv-isa-manual/src/priv/machine.adoc:3577-3582 (norm:pmp_full_match_required)
//         选中项必须覆盖本次访问的**全部字节**，否则失败（与 L/R/W/X 无关）
//   [9] riscv-isa-manual/src/priv/machine.adoc:3584-3590 (norm:pmp_rwx_check)
//         全字节命中：L=0 且 M ⇒ 成功；否则按访问类型查 R/W/X
//   [10] riscv-isa-manual/src/priv/machine.adoc:3591-3596 (norm:pmp_no_entry_match)
//         无匹配项：M ⇒ 成功；S/U ⇒ 失败（本设计 PMP_ENTRIES>0）
//
// 参考实现对照：**凡规范留有余地的 WARL 语义，一律以 Spike 的行为为准**
// （本工程的 arch-test 参考签名由 Spike 生成：scripts/arch_test_build.sh:5-7,23）：
//   [S1] tools/spike/riscv/mmu.cc:482-513  pmp_lookup()：逐项算 any_match/all_match，
//        取**最低编号**的 any_match 项；若 any_match 但 !all_match ⇒ always_fail
//        （与 [7][8] 一致）
//   [S2] tools/spike/riscv/csrs.cc:204-235 pmpaddr_csr_t::access_ok()，MML=0 分支：
//          return (prvm && !cfgl) || (LOAD&&R) || (STORE&&W) || (FETCH&&X);
//        即 L=0 且 M 直接通过；否则按访问类型按位判定。
//        **R=0,W=1 不做特殊处理**（Spike 允许写、拒绝读），故本模块同样"写只看 W、读只看 R"，
//        不因保留编码 [1] 而拒绝写。
//
// 本设计的取舍（规范留有余地 / 接口边界，均已在单元测试中固化为期望值）：
//   · need_r=need_w=need_x=0 的退化输入：权限合取式恒真 ⇒ 只要选中项全字节命中即允许。
//     （调用方不会产生这种输入；选择"允许"是为了让本模块保持纯组合、无隐藏状态。）
//   · addr 仅 32 位：物理地址位 [33:32] 未建模（与基线核一致：VA=PA，34 位 Sv32 物理地址
//     留给 MMU 接入时扩展）。
//   · acc_size=2'b11 按 4 字节处理；>4 字节的访存须由调用方拆成多次检查（规范 [8] 允许多次
//     检查、部分可见：machine.adoc:3566-3570）。
//=============================================================================
`include "rv32gc_defs.vh"        // 仅用 `PRV_M（rv32gc_defs.vh:362）

module rv32_pmp #(
  parameter integer PMP_ENTRIES = 16
)(
  // ---- 配置来源（由 rv32_csr 提供；本模块只读）----
  input  wire [PMP_ENTRIES*8-1:0]  pmpcfg,    // cfg[i] = pmpcfg[8*i +: 8] = {L(7),0(6),0(5),A(4:3),X(2),W(1),R(0)}
  input  wire [PMP_ENTRIES*32-1:0] pmpaddr,   // addr[i] = pmpaddr[32*i +: 32]（= 物理地址 >> 2）
  // ---- 被检查的访问 ----
  input  wire [31:0]  addr,        // 检查地址（基线核无 MMU，虚拟地址=物理地址）
  input  wire [1:0]   acc_size,    // 访问字节数编码：0=1B, 1=2B, 2=4B（3 亦按 4B）
  input  wire [1:0]   eff_priv,    // **有效**特权级（调用方已按 mstatus.MPRV 规则算好）
  input  wire         need_r,      // 需要读权限（LOAD / LR / AMO 置 1）
  input  wire         need_w,      // 需要写权限（STORE / SC / AMO 置 1）
  input  wire         need_x,      // 需要执行权限（取指置 1）
  // ---- 第二组权限需求（**与第一组共享同一次地址匹配**）----
  // 为什么需要第二组：AMO 必须"先按读查、再按写查"（缺 R 报 cause 5、缺 W 报 cause 7，
  // 与 Spike 的 mmu 调用顺序一致；arch-test PMPZaamo 用的正是 L=1,R=0,W=0 的项）。
  // 用两个模块实例会**把整条匹配树复制一遍** —— 实测让整核 iverilog 仿真慢 3 倍以上
  // （地址每拍翻转就重算 16 项 × 2 word 的比较树），因此改成"一份匹配 + 两组权限"。
  input  wire         need_r2,
  input  wire         need_w2,
  input  wire         need_x2,
  // ---- 结果 ----
  output wire         permit,                    // 1 = 允许（按 need_r/need_w/need_x）
  output wire         permit2,                   // 1 = 允许（按 need_r2/need_w2/need_x2）
  output wire [PMP_ENTRIES-1:0] match_any,       // 该项匹配本次访问的**任意一个字节**
  output wire [PMP_ENTRIES-1:0] match_all        // 该项匹配本次访问的**全部字节**
);

  //---------------------------------------------------------------------------
  // A 字段编码 [3]
  //---------------------------------------------------------------------------
  localparam [1:0] A_OFF   = 2'b00;
  localparam [1:0] A_TOR   = 2'b01;
  localparam [1:0] A_NA4   = 2'b10;
  localparam [1:0] A_NAPOT = 2'b11;

  //---------------------------------------------------------------------------
  // 访问覆盖的 word 区间（≤4B ⇒ 最多 2 个 word）
  //---------------------------------------------------------------------------
  wire [2:0]  nbytes  = (acc_size == 2'd0) ? 3'd1 :
                        (acc_size == 2'd1) ? 3'd2 : 3'd4;
  wire [31:0] word0   = addr[31:2];
  wire [32:0] acc_end = {1'b0, addr} + {30'd0, nbytes} - 33'd1;   // 末字节地址（33 位，防半路借位丢失）
  wire [31:0] word1   = acc_end[31:2];

  // pmpaddr[i-1]（i=0 时为 0）—— TOR 下界 [5]，与 pmpcfg[i-1] 无关
  wire [PMP_ENTRIES*32+31:0] pmpaddr_lo = {pmpaddr, 32'b0};

  //---------------------------------------------------------------------------
  // NAPOT 匹配 [4]（**必须无循环**：仿真性能关键）
  //   k = pa 低位连续 1 的个数（0..32）；掩码按 **word 索引** 计算：
  //     低位第一个 0 的位置（one-hot）：low0 = ~pa & (pa+1)
  //     掩码 mask = (low0 << 1) - 1 = 2^(k+1) - 1   （区间大小 = 2^(k+1) 个 word）
  //   · pa 全 1（k=32）⇒ low0=0 ⇒ mask=0xFFFF_FFFF ⇒ 覆盖整个 word 空间 ✓
  //   · k=31 ⇒ low0=0x8000_0000 ⇒ (low0<<1)=0 ⇒ mask=0xFFFF_FFFF ⇒ 同全空间 ✓
  //   · k=0（8 字节区间）⇒ low0=1 ⇒ mask=1 ⇒ 2 个 word ✓
  // 注意：原先用「for 循环数低位连续 1」的实现在仿真里被每条连续赋值反复求值，
  //       实测把整核仿真拖慢 10 倍以上（memtest 从 <2 分钟变成 >6 分钟仍未跑完），
  //       故改为下面的无循环写法；语义由 tb_unit_pmp 的 443 项检查（含 k=0..32 与
  //       全 1 全空间匹配）与 Python oracle 差分共同锁定。
  //---------------------------------------------------------------------------
  function automatic [31:0] napot_mask;
    input [31:0] pa;
    reg   [31:0] low0;
    begin
      low0       = ~pa & (pa + 32'd1);
      napot_mask = (low0 << 1) - 32'd1;
    end
  endfunction

  function automatic napot_match_word;
    input [31:0] w;
    input [31:0] pa;
    reg   [31:0] m;
    begin
      m = napot_mask(pa);
      napot_match_word = ((w & ~m) == (pa & ~m));
    end
  endfunction

  //---------------------------------------------------------------------------
  // 逐项：匹配任意字节 / 匹配全部字节
  //---------------------------------------------------------------------------
  genvar g;
  generate
    for (g = 0; g < PMP_ENTRIES; g = g + 1) begin : g_entry
      wire [7:0]  cfg   = pmpcfg[8*g +: 8];
      wire [1:0]  amode = cfg[4:3];
      wire [31:0] pa    = pmpaddr[32*g +: 32];
      wire [31:0] pa_lo = pmpaddr_lo[32*g +: 32];
      wire [31:0] nmsk  = napot_mask(pa);          // 每项只算一次（供 w0/w1 共用）
      wire        m0, m1;

      assign m0 = (amode == A_OFF)   ? 1'b0 :
                  (amode == A_TOR)   ? ((g == 0) ? (word0 < pa)
                                                 : ((word0 >= pa_lo) && (word0 < pa))) :
                  (amode == A_NA4)   ? (word0 == pa) :
                                       ((word0 & ~nmsk) == (pa & ~nmsk));

      assign m1 = (amode == A_OFF)   ? 1'b0 :
                  (amode == A_TOR)   ? ((g == 0) ? (word1 < pa)
                                                 : ((word1 >= pa_lo) && (word1 < pa))) :
                  (amode == A_NA4)   ? (word1 == pa) :
                                       ((word1 & ~nmsk) == (pa & ~nmsk));

      assign match_any[g] = m0 | m1;
      assign match_all[g] = m0 & m1;      // w1==w0 时等价于 m0
    end
  endgenerate

  //---------------------------------------------------------------------------
  // 静态优先级 [7]：编号最小的 match_any 项被选中（高→低扫描，最后写入者即最低编号）
  //---------------------------------------------------------------------------
  integer si;
  reg     sel_found;      // 存在匹配项
  reg     sel_all;        // 选中项覆盖全部字节
  reg     sel_l, sel_r, sel_w, sel_x;

  always @* begin
    sel_found = 1'b0;
    sel_all   = 1'b0;
    sel_l     = 1'b0;
    sel_r     = 1'b0;
    sel_w     = 1'b0;
    sel_x     = 1'b0;
    for (si = PMP_ENTRIES - 1; si >= 0; si = si - 1)
      if (match_any[si]) begin
        sel_found = 1'b1;
        sel_all   = match_all[si];
        sel_l     = pmpcfg[8*si + 7];
        sel_x     = pmpcfg[8*si + 2];
        sel_w     = pmpcfg[8*si + 1];
        sel_r     = pmpcfg[8*si + 0];
      end
  end

  // 权限判定 [S2]：按访问类型按位合取；need_* 全 0 ⇒ 恒真（退化输入按允许处理）
  // 两组权限需求共享上面这一次匹配与选中项（sel_*），只有合取式各算一份。
  wire perm_ok1 = (need_r  ? sel_r : 1'b1) & (need_w  ? sel_w : 1'b1) & (need_x  ? sel_x : 1'b1);
  wire perm_ok2 = (need_r2 ? sel_r : 1'b1) & (need_w2 ? sel_w : 1'b1) & (need_x2 ? sel_x : 1'b1);

  assign permit  = !sel_found                       ? (eff_priv == `PRV_M) :   // [10]
                   !sel_all                         ? 1'b0               :   // [8]
                   (!sel_l && (eff_priv == `PRV_M)) ? 1'b1               :   // [6][9]
                                                      perm_ok1;
  assign permit2 = !sel_found                       ? (eff_priv == `PRV_M) :
                   !sel_all                         ? 1'b0               :
                   (!sel_l && (eff_priv == `PRV_M)) ? 1'b1               :
                                                      perm_ok2;

endmodule
