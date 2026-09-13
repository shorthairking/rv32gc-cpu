//=============================================================================
// rv32_plic.v —— 核内 PLIC（Platform-Level Interrupt Controller，hart0 双上下文）
//   · 决策 D5：PLIC 基址 0x1F10_0000，**核内截获、不下 AXI**（chiplab 平台没有该窗口）。
//   · 布局与 **SiFive PLIC 1.0.0** 一致，Linux `sifive,plic-1.0.0` 驱动可直接使用：
//       0x0000 + 4*N        priority[N]  N=1..NSRC（0 = source 0 保留，读 0）
//       0x1000              pending      RO，bit k = source k（bit0 恒 0、只读）
//       0x2000 + 0x80*ctx   enable[ctx]  RW，bit k = 允许 source k（bit0 恒 0）
//       0x200000 + 0x1000*ctx        threshold[ctx]      RW（WARL：0..7）
//       0x200004 + 0x1000*ctx        claim/complete[ctx] RW：读=claim，写=complete
//     ctx 0 = hart0-M（→ mip.MEIP, bit 11）、ctx 1 = hart0-S（→ mip.SEIP, bit 9）。
//   · 源映射（本平台）：src[k-1] ↔ source (k+1)，见文件末"源号 → 平台线"。
//
// 规范 / 设计出处（路径相对 workspace 根 /home/shorthair/dsh/rv32-cpu）
//   [1] docs/design/spec/07-priv-csr-mmu.md:438-453（§8.2 本项目 PLIC 寄存器映射、
//       SiFive 兼容、2 上下文、源号↔intrpt 对应表）
//   [2] docs/design/spec/07-priv-csr-mmu.md:455-470（§8.3 gateway / claim / complete
//       流程：claim 读返回 best 并**硬件自动清 pending**，complete 前该源被
//       gateway=BUSY 屏蔽防重入，平台中断电平敏感 ⇒ complete 后源仍高则重新挂起）
//   [3] riscv-isa-manual/src/priv/machine.adoc:1401-1405（mip.MEIP 只读，由 PLIC 驱动；
//       M 外部中断不可委托）
//   [4] riscv-isa-manual/src/priv/machine.adoc:1433-1447（mip.SEIP = 软件位 | 外部
//       PLIC 输出，核内做 OR；本模块提供外部那一半）
//   [5] rtl/pkg/rv32gc_defs.vh:130  `PLIC_BASE = 32'h1F10_0000
//   与 [1] 第 446-447 行**不一致之处**（以本文件为准，理由见下）：规格书表格把
//   threshold/claim 写成 `0x200000+4*ctx` / `0x200000+4*ctx+0x1000`（ctx 步长 4），
//   而 Linux sifive-plic 驱动与 SiFive PLIC 1.0.0 的上下文步长是 **0x1000**：
//   ctx0 → threshold `0x200000` / claim `0x200004`，ctx1 → `0x201000` / `0x201004`。
//   任务契约（"必须与 Linux 的 sifive,plic-1.0.0 驱动期望一致"）取后者，本实现照此译码。
//
// 语义（本实现的完整定义；规范留白处已在单元测试固化为期望值）
//   · **gateway / pending 状态机**（每源 1 位 pending + 1 位 in-service）：
//       IDLE（!pending && !in-service）：源电平拉高 ⇒ pending 置 1（电平敏感锁存；
//              pending 不因源变低而自动清除）
//       CLAIMED（in-service=1）：claim 清 pending 并置 in-service；**在 complete
//              之前该源的重新挂起被屏蔽**（防重入）
//       COMPLETE（写 complete 且源号在服务中）：清 in-service；若源电平仍为高，
//              同一拍重新置 pending（⇒ 电平仍高时 EIP 立刻再次拉高，符合标准
//              PLIC 的"电平敏感设备"行为，也符合 [2]）
//   · **EIP**（纯组合，两上下文独立）：
//       meip = ∃k∈[1..NSRC]: pending[k] && enable[0][k] && priority[k] > threshold[0]
//       seip 同理用 ctx1。priority=0 的源永不触发（priority > threshold ≥ 0）。
//       提高 threshold 到 ≥ priority 会让 EIP **立即**回落（无需 claim）。
//   · **claim**：返回最高 priority 的 pending&enable&(pri>thr) 源；**同优先级取编号最小**；
//       无候选返回 0（source 0 永不返回）。副作用与读数据同拍提交：清 pending[best]、
//       置 in-service[best]。核内单拍访存模型下 req 只拉高一拍 ⇒ 恰好执行一次。
//   · **complete**：写 wdata=源号；仅当该源当前处于 in-service 才生效（其它值忽略，
//       不会误清 pending），随后按上面的 COMPLETE 规则重新评估。
//   · threshold 为 3 位 WARL（0..7，写高位被丢弃）；enable 只保留 bit[NSRC:1]，
//       bit0 与高位恒 0；priority 为完整 32 位。
//   · 只读寄存器（pending）写忽略；未实现偏移**读 0、写忽略**（不产生副作用）。
//   · 复位：priority/enable/threshold 全 0、pending/in-service 全 0 ⇒ 无中断。
//   · `rdata` 只由 `addr` 译码，不受 `req` 门控（调用方在 req && !we 时采样）。
//   · 内部状态一律用**向量**而非存储器数组：iverilog 对 `@*`/连续赋值里出现的数组
//     会打印 "sensitive to all N words in array" 告警，且**不把函数体内部读到的
//     数组纳入连续赋值灵敏表**（实测会导致 best 不刷新）。扁平向量同时解决这两点。
//
// 源号 → 平台线（[1] 第 449-452 行；端口 `src[k-1]` ↔ source k）
//   source 1/2/3/4/5/6/7/8 ← src[0..7]，对应 intrpt[0]=MAC、[1]=UART0、[2]=SPI、
//   [3]=NAND、[4]=DMA、[5..7]=预留。source 0 不存在（保留）。
//=============================================================================
`include "rv32gc_defs.vh"        // 仅用 `PLIC_BASE（rv32gc_defs.vh:130）

module rv32_plic #(parameter integer NSRC = 8) (
  input  wire                clk,
  input  wire                rst_n,
  input  wire [NSRC-1:0]     src,   // 平台中断源电平：bit k ↔ PLIC source (k+1)（source 0 保留）
  // ---- 核内访存窗口 ----
  input  wire                req,
  input  wire                we,
  input  wire [31:0]         addr,
  input  wire [3:0]          wstrb,
  input  wire [31:0]         wdata,
  output wire [31:0]         rdata,
  // ---- 中断输出 ----
  output wire                meip,  // context 0（M 模式）→ mip.MEIP (bit 11)
  output wire                seip   // context 1（S 模式）→ mip.SEIP (bit 9)
);

  //---------------------------------------------------------------------------
  // 寄存器偏移（相对 `PLIC_BASE；ctx 步长按 SiFive PLIC 1.0.0 = 0x1000）
  //---------------------------------------------------------------------------
  localparam [31:0] OFF_PRIORITY_MASK = 32'h0000_0FFF;   // 0x0000..0x0FFF = priority[]
  localparam [31:0] OFF_PENDING       = 32'h0000_1000;
  localparam [31:0] OFF_ENABLE0       = 32'h0000_2000;
  localparam [31:0] OFF_ENABLE1       = 32'h0000_2080;
  localparam [31:0] OFF_THRESH0       = 32'h0020_0000;
  localparam [31:0] OFF_CLAIM0        = 32'h0020_0004;
  localparam [31:0] OFF_THRESH1       = 32'h0020_1000;
  localparam [31:0] OFF_CLAIM1        = 32'h0020_1004;

  //---------------------------------------------------------------------------
  // 状态（全部为向量：pri[k] = pri_f[32*k +: 32]，k=1..NSRC）
  //---------------------------------------------------------------------------
  reg [(NSRC+1)*32-1:0] pri_f;    // 源优先级；word 0 保留（读 0、写忽略），word k=源 k
  reg [NSRC:0]      pend_r;       // 挂起位；bit0 恒 0
  reg [NSRC:0]      insvc_r;      // gateway in-service（claim 置位，complete 清除）
  reg [NSRC:0]      en0_r, en1_r; // 每上下文使能位；bit0 恒 0
  reg [2:0]         thr0_r, thr1_r;  // 每上下文阈值（WARL 0..7）

  localparam [NSRC:0] EN_MASK = { {NSRC{1'b1}}, 1'b0 };   // 合法使能位 = bit[NSRC:1]

  integer wi;                     // 时序块内的循环变量
  reg [NSRC:0] pend_nxt, insvc_nxt;

  //---------------------------------------------------------------------------
  // 地址译码
  //---------------------------------------------------------------------------
  wire [31:0] off = addr - `PLIC_BASE;

  wire is_pri    = (off <= OFF_PRIORITY_MASK);      // priority 区 0x0000-0x0FFF
  wire [31:0] pri_idx = off[11:2];
  wire pri_ok    = is_pri & (pri_idx >= 32'd1) & (pri_idx <= NSRC);

  wire sel_pend  = (off == OFF_PENDING);
  wire sel_en0   = (off == OFF_ENABLE0);
  wire sel_en1   = (off == OFF_ENABLE1);
  wire sel_thr0  = (off == OFF_THRESH0);
  wire sel_thr1  = (off == OFF_THRESH1);
  wire sel_clm0  = (off == OFF_CLAIM0);
  wire sel_clm1  = (off == OFF_CLAIM1);

  wire rd = req & ~we;
  wire wr = req & we;

  //---------------------------------------------------------------------------
  // best[ctx]：pending & enable & priority > threshold 中最高优先级，同级取最小编号
  //   注意：必须在本 always @(*) 里直接读状态向量（不能塞进函数，也不能用存储器
  //   数组），否则 iverilog 不会把函数体内部读到数组纳入灵敏表，best 不刷新。
  //---------------------------------------------------------------------------
  reg [NSRC:0] best0, best1;
  reg [31:0]   bp0, bp1;
  integer b;

  always @(*) begin
    // context 0（M）
    best0 = { (NSRC+1){1'b0} };
    bp0   = 32'd0;
    for (b = 1; b <= NSRC; b = b + 1) begin
      if (pend_r[b] & en0_r[b] & (pri_f[32*b +: 32] > {29'b0, thr0_r})
                    & (pri_f[32*b +: 32] > bp0)) begin
        best0 = b;
        bp0   = pri_f[32*b +: 32];
      end
    end
    // context 1（S）
    best1 = { (NSRC+1){1'b0} };
    bp1   = 32'd0;
    for (b = 1; b <= NSRC; b = b + 1) begin
      if (pend_r[b] & en1_r[b] & (pri_f[32*b +: 32] > {29'b0, thr1_r})
                    & (pri_f[32*b +: 32] > bp1)) begin
        best1 = b;
        bp1   = pri_f[32*b +: 32];
      end
    end
  end

  assign meip = (best0 != { (NSRC+1){1'b0} });
  assign seip = (best1 != { (NSRC+1){1'b0} });

  //---------------------------------------------------------------------------
  // 按 wstrb 逐字节合并
  //---------------------------------------------------------------------------
  function [31:0] byte_merge;
    input [31:0] old_v;
    input [31:0] new_v;
    input [3:0]  strb;
    integer i;
    begin
      for (i = 0; i < 4; i = i + 1) begin
        if (strb[i]) byte_merge[8*i +: 8] = new_v[8*i +: 8];
        else         byte_merge[8*i +: 8] = old_v[8*i +: 8];
      end
    end
  endfunction

  //---------------------------------------------------------------------------
  // 时序：pending / in-service（gateway）+ 寄存器写
  //---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      pri_f  <= { ((NSRC+1)*32){1'b0} };
      pend_r <= { (NSRC+1){1'b0} };
      insvc_r <= { (NSRC+1){1'b0} };
      en0_r  <= { (NSRC+1){1'b0} };
      en1_r  <= { (NSRC+1){1'b0} };
      thr0_r <= 3'd0;
      thr1_r <= 3'd0;
    end else begin
      // ---- 次态默认保持 ----
      pend_nxt  = pend_r;
      insvc_nxt = insvc_r;

      // ---- claim（读 claim/complete）：返回 best 的同时清 pending、置 in-service ----
      if (rd && sel_clm0 && (best0 != { (NSRC+1){1'b0} })) begin
        pend_nxt[best0]  = 1'b0;
        insvc_nxt[best0] = 1'b1;
      end
      if (rd && sel_clm1 && (best1 != { (NSRC+1){1'b0} })) begin
        pend_nxt[best1]  = 1'b0;
        insvc_nxt[best1] = 1'b1;
      end

      // ---- complete（写 claim/complete）：仅对 in-service 源生效 ----
      if (wr && (sel_clm0 || sel_clm1)) begin
        for (wi = 1; wi <= NSRC; wi = wi + 1) begin
          if ((wdata == wi) && insvc_r[wi]) begin
            insvc_nxt[wi] = 1'b0;
            pend_nxt[wi]  = src[wi-1];   // 电平仍高 ⇒ 同一拍重新挂起
          end
        end
      end

      // ---- 寄存器写（只读寄存器与未实现偏移：忽略）----
      if (wr) begin
        if (is_pri) begin
          if ((pri_idx >= 32'd1) && (pri_idx <= NSRC))
            pri_f[32*pri_idx +: 32] <= byte_merge(pri_f[32*pri_idx +: 32], wdata, wstrb);
        end else if (sel_en0) begin
          en0_r <= byte_merge(en0_r, wdata, wstrb) & EN_MASK;
        end else if (sel_en1) begin
          en1_r <= byte_merge(en1_r, wdata, wstrb) & EN_MASK;
        end else if (sel_thr0) begin
          thr0_r <= byte_merge(thr0_r, wdata, wstrb) & 3'b111;
        end else if (sel_thr1) begin
          thr1_r <= byte_merge(thr1_r, wdata, wstrb) & 3'b111;
        end
      end

      // ---- gateway：源电平高且既未挂起也未在服务 ⇒ 置挂起（电平敏感）----
      pend_nxt[0]  = 1'b0;
      insvc_nxt[0] = 1'b0;
      for (wi = 1; wi <= NSRC; wi = wi + 1) begin
        if (src[wi-1] && !pend_nxt[wi] && !insvc_nxt[wi]) pend_nxt[wi] = 1'b1;
      end

      pend_r  <= pend_nxt;
      insvc_r <= insvc_nxt;
    end
  end

  //---------------------------------------------------------------------------
  // 读数据（组合；claim 读返回 best[ctx]）
  //   用连续赋值而不是 always @(*)：iverilog -Wall 会为 @* 中的数组读打印告警。
  //---------------------------------------------------------------------------
  wire [31:0] rd_pri = pri_ok ? pri_f[32*pri_idx +: 32] : 32'h0;

  assign rdata = is_pri   ? rd_pri             :
                 sel_pend ? pend_r             :   // bit0 恒 0
                 sel_en0  ? en0_r              :
                 sel_en1  ? en1_r              :
                 sel_thr0 ? {29'b0, thr0_r}    :
                 sel_thr1 ? {29'b0, thr1_r}    :
                 sel_clm0 ? best0              :   // claim
                 sel_clm1 ? best1              :   // claim
                            32'h0;

endmodule
