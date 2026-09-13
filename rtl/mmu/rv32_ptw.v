//=============================================================================
// rv32_ptw.v —— Sv32 两级页表遍历状态机（Svade：只读 PTE，不改写 A/D）
//
// 规范出处（**以 Spike 为准**）：
//   riscv-isa-manual/src/priv/supervisor.adoc:1727-1745 —— Sv32 翻译算法步骤 1..9：
//     :1727-1728 步骤 1  a = satp.ppn × PAGESIZE，i = LEVELS-1 = 1
//     :1730      步骤 2  pte = mem[a + va.vpn[i] × PTESIZE]（PTESIZE=4）
//     :1732      步骤 3  V=0 或 (R=0 且 W=1) 或"保留位/编码被置位" ⇒ 页错误
//     :1734-1735 步骤 4  非叶（R=X=0）⇒ i←i-1 继续；**i<0 ⇒ 页错误**
//     :1737      步骤 5  叶子且 i>0 且 pte.ppn[i-1:0]!=0 ⇒ 页错误（超级页未对齐）
//     :1739/1743 步骤 6/8 U 位、R/W/X 权限 —— **本模块不做**，由调用方 live 判定
//     :1745      步骤 9  A/D —— Svade ⇒ 页错误，**本模块不做**，由调用方 live 判定
//     :1699-1702 4 MiB 页必须物理 4 MiB 对齐，否则页错误
//     :1704-1706 非叶 PTE 的 D/A/U 位"预留给未来标准使用"，软件必须写 0
//   tools/spike/riscv/mmu.cc  mmu_t::walk（参考实现）：
//     :727-733   逐级循环 for (i = levels-1; i>=0; i--)；idx = (addr>>(12+i*10)) & 0x3FF；
//                pte_paddr = base + idx*ptesize（第 1 级 base=satp.ppn<<12）
//     :734       ppn = (pte & ~PTE_ATTR) >> 10（PTE_PPN_SHIFT=10，encoding.h:526）
//     :751-754   PTE_TABLE 判定（encoding.h:528）= V=1 且 R=W=X=0：非叶若
//                (D|A|U|N|PBMT) 任一置位 ⇒ break ⇒ 页错误（**非叶 D|A|U 非法**）
//     :757-758   !V || (!R && W) ⇒ break ⇒ 页错误
//     :765-766   (ppn & ((1<<ptshift)-1)) != 0 ⇒ break ⇒ 页错误；第 1 级 i=1 ⇒
//                ptshift=10 ⇒ 要求 ppn[9:0]==0，等价于 **pte[19:10]==0**
//     :805-807   循环整体退出（含"第 2 级仍为非叶"即 i<0 的情形）⇒ 页错误
//     :751 只查 D|A|U|N|PBMT，**不查 G** ⇒ 非叶 PTE 的 G 位不构成页错误（本实现照此）
//   tools/spike/riscv/mmu.h:606-611 decode_vm_info：Sv32 ⇒ levels=2, idxbits=10,
//     ptesize=4, ptbase=(satp & SATP32_PPN)<<12（SATP32_PPN=0x003FFFFF，encoding.h:368）
//
// ⚠ 注意 docs/design/spec/07-priv-csr-mmu.md:280 写的"pte[31:10] 保留位非零 ⇒ 页错误"
//   是 **Sv39+ 的口径**：Sv32 的 PTE 只有 32 位，pte[31:10] 全部是 PPN，没有保留位；
//   本模块按 Sv32 口径实现（Spike mmu.cc:741-750 的 PTE_RSVD/SVRSW60T59B/SVNAPOT/PBMT
//   检查在 RV32/Sv32 下都不存在，因为 encoding.h:521-523 那些位都在 bit57 以上）。
//
// 地址计算（每级一次 4 字节页表读）：
//   第 1 级（根表）: bus_addr = (satp_ppn << 12) + {va[31:22], 2'b00}
//   第 2 级        : bus_addr = (pte1_ppn << 12) + {va[21:12], 2'b00}
//                    （pte1_ppn = 第 1 级非叶 PTE 的 PPN，取本拍读回的组合值）
//   ⚠ 基线必须是 ppn × PAGESIZE = **ppn << 12**（supervisor.adoc:1727-1730 步骤 1/2 与
//     Spike mmu.cc:726-732 的 `base = ppn << PGSHIFT`、`pte_paddr = base + idx*ptesize`）。
//     任务书里写的 `{ppn, 10'b0}` 等价于 ppn<<10，比正确值小 4 倍（少移 2 位），
//     会让页表基址落在错误地址；本实现按规范取 ppn<<12。
//     PPN 22 位 + 12 位偏移 = 34 位，本设计 PA=32 位 ⇒ 取低 32 位（PPN[21:20] 被丢弃，
//     与 docs/design/spec/07-priv-csr-mmu.md:108"实际用 PPN[19:0]"一致）。
//
// 状态机（不依赖任何外部 stall；只靠 bus_ack/bus_err 推进）：
//   IDLE --req↑--> L1 --ack(非叶)--> L2 --ack(叶子)--> RES(done=1)
//                  \--ack(叶/非法)                                   /--req--> 重新开始
//                   \--bus_err-------\          \--bus_err---------/  \--abort-> IDLE
//                                     \---> RES(fault=1)
//   结果（done/fault 互斥）保持到下一次 req 或 abort。
//
// 总线协议约定（valid-until-ready，调用方接总线时须满足）：
//   * 每级访问：本模块置 bus_req=1 并保持，同时给出稳定 bus_addr；等到 bus_ack 或
//     bus_err 有效的那一拍采数/采错，随后 bus_req 拉低。
//   * bus_rdata 与 bus_ack 同拍有效；bus_err=1 表示该次读失败（如 PMA 违例、
//     AXI DECERR/SLVERR），本模块报 fault（**不做重试**）。bus_err 与 bus_deny（PMP 拒绝）
//     都归为 **访问错误**（fault_is_access=1），cause 由调用方按原访问类型取
//     （取指 1 / load 5 / store·AMO·CBO 7）；结构性非法 PTE 才是页错误
//     （fault_is_access=0，cause 12/13/15）。依据 tools/spike/riscv/mmu.h:486-497
//     `pte_load()`（PMP 失败与 mmio_load 失败都 `throw_access_exception`）。
//   * 允许 bus_ack 为组合（0 延迟）或任意拍延迟（≥1）；两种都能工作。
//   * 同一时刻只允许一次未完成请求：本模块在等 ack 期间不会改 bus_addr。
//
// perm 位映射（与 PTE[7:0] 逐位对齐，便于调用方 live 判权）：
//   perm[0]=V perm[1]=R perm[2]=W perm[3]=X perm[4]=U perm[5]=G perm[6]=A perm[7]=D
//   （即 perm = pte[7:0]；调用方需要 {D,A,X,W,R,U} 时自行取对应位）
//=============================================================================
// 注：本仓库 RTL 文件一律不带 `timescale（全量编译时避免跨文件继承告警）；
//     本模块无任何延时，不需要时间单位。
module rv32_ptw (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        req,            // 启动信号：**上升沿**有效（IDLE/结果态拉高一拍即可；
                                     //   持续拉高的 req 不会反复重启，结果保持稳定）
  input  wire [31:0] va,
  input  wire [21:0] satp_ppn,
  //---------------------------------------------------------------- 页表读（4 字节）
  output reg         bus_req,
  output reg  [31:0] bus_addr,
  input  wire [31:0] bus_rdata,
  input  wire        bus_ack,
  input  wire        bus_err,
  // PMP 拒绝本次页表读（核内由共享的 PMP 匹配引擎给出；只在本模块 bus_req=1 且引擎
  // 确实分配给本模块的那一拍有效）。语义与 reference 一致：
  // tools/spike/riscv/mmu.h:486-497 `pte_load()` 在真正读 PTE 之前做
  //   `pmp_ok(pte_paddr, ptesize, LOAD, PRV_S, false)`，失败即 `throw_access_exception`
  //   ⇒ **访问错误**（cause 取原访问类型：取指 1 / load 5 / store·AMO·CBO 7），不是页错误。
  input  wire        bus_deny,
  //---------------------------------------------------------------- 结果
  output reg         busy,           // 遍历中（IDLE/DONE/FAULT 态为 0）
  output reg         done,           // 翻译成功：ppn/is_4m/perm 有效（与 fault 互斥）
  output reg         fault,          // 结构性非法或总线错误
  output reg         fault_is_access,// fault 的分类：1 = 访问错误（总线错误 / PMP 拒绝），
                                     //                0 = 页错误（PTE 结构非法等）
  output reg  [21:0] ppn,
  output reg         is_4m,
  output reg  [7:0]  perm,
  output reg  [31:0] fault_va,
  input  wire        abort            // sfence.vma 等：立刻回 IDLE 并丢弃在途结果
);

  localparam [1:0] ST_IDLE = 2'd0,
                   ST_L1   = 2'd1,   // 第 1 级（根表）页表读
                   ST_L2   = 2'd2,   // 第 2 级页表读
                   ST_RES  = 2'd3;   // 结果态：done/fault 保持

  reg [1:0]  state;
  reg [31:0] va_r;                   // 锁存的请求 VA（fault_va / 二级索引）
  reg        req_prev;               // req 上一拍值：启动只在 req 上升沿发生

  //--------------------------------------------------------------------------
  // 当前 bus_rdata 的 PTE 解析（组合）
  //--------------------------------------------------------------------------
  wire        pte_v    = bus_rdata[0];
  wire        pte_r    = bus_rdata[1];
  wire        pte_w    = bus_rdata[2];
  wire        pte_x    = bus_rdata[3];
  wire        pte_u    = bus_rdata[4];
  wire        pte_a    = bus_rdata[6];
  wire        pte_d    = bus_rdata[7];
  wire [21:0] pte_ppn  = bus_rdata[31:10];               // Sv32：PPN 22 位
  wire        pte_leaf = (pte_r | pte_w | pte_x);         // 叶子判据：R|W|X != 0
  // 非法编码：V=0 或 R=0&&W=1（mmu.cc:757-758 / supervisor.adoc:1732）
  wire        pte_bad  = (!pte_v) | ((!pte_r) & pte_w);
  // 启动条件：req 上升沿（持续拉高的 req 不会在出结果后立刻重启，保证结果稳定）
  wire        req_start = req & ~req_prev;
  // 非叶 PTE 的禁用位：D|A|U（mmu.cc:751-753 / supervisor.adoc:1704-1706）
  wire        pte_tbl_bad = (pte_d | pte_a | pte_u);

  //--------------------------------------------------------------------------
  // 页表项物理地址（组合）：(基址 PPN << 12) + vpn × 4
  //   34 位中间量 → 取低 32 位（PA=32 位，PPN[21:20] 忽略）
  //--------------------------------------------------------------------------
  wire [33:0] l1_base = {satp_ppn, 12'b0};   // 根表基址（satp_ppn 在遍历期间不变）
  wire [33:0] l2_base = {pte_ppn, 12'b0};    // 第 2 级基址 = **本拍刚读到的**第 1 级 PTE 的 PPN


  //--------------------------------------------------------------------------
  // 结果态入口（任务内为非阻塞赋值，等价于内联写法）
  //--------------------------------------------------------------------------
  task enter_fault;
    begin
      bus_req  <= 1'b0;
      busy     <= 1'b0;
      done     <= 1'b0;
      fault    <= 1'b1;
      fault_is_access <= 1'b0;      // 默认：结构性页错误
      fault_va <= va_r;
      state    <= ST_RES;
    end
  endtask

  // 访问错误（总线错误 / PMP 拒绝页表读）：cause 由调用方按**原访问类型**取（1/5/7）
  task enter_fault_access;
    begin
      bus_req  <= 1'b0;
      busy     <= 1'b0;
      done     <= 1'b0;
      fault    <= 1'b1;
      fault_is_access <= 1'b1;
      fault_va <= va_r;
      state    <= ST_RES;
    end
  endtask

  task enter_done;
    input is4;
    begin
      bus_req  <= 1'b0;
      busy     <= 1'b0;
      done     <= 1'b1;
      fault    <= 1'b0;
      fault_is_access <= 1'b0;
      ppn      <= pte_ppn;
      is_4m    <= is4;
      perm     <= bus_rdata[7:0];       // 原始叶子 PTE 低 8 位（含 V/G/A/D）
      state    <= ST_RES;
    end
  endtask

  //--------------------------------------------------------------------------
  // 状态机
  //--------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      state    <= ST_IDLE;
      bus_req  <= 1'b0;
      bus_addr <= 32'd0;
      busy     <= 1'b0;
      done     <= 1'b0;
      fault    <= 1'b0;
      ppn      <= 22'd0;
      is_4m    <= 1'b0;
      perm     <= 8'd0;
      fault_va <= 32'd0;
      fault_is_access <= 1'b0;
      va_r     <= 32'd0;
      req_prev <= 1'b0;
    end else if (abort) begin
      req_prev <= req;
      // sfence.vma 等：无条件立刻回 IDLE，丢弃在途请求与结果
      state   <= ST_IDLE;
      bus_req <= 1'b0;
      busy    <= 1'b0;
      done    <= 1'b0;
      fault   <= 1'b0;
    end else begin
      req_prev <= req;
      case (state)
        //------------------------------------------------------------ 空闲
        ST_IDLE: begin
          if (req_start) begin
            va_r     <= va;
            bus_addr <= l1_base[31:0] + {va[31:22], 2'b00};       // 根表第 va.vpn[1] 项
            bus_req  <= 1'b1;
            busy     <= 1'b1;
            done     <= 1'b0;
            fault    <= 1'b0;
            state    <= ST_L1;
          end
        end
        //------------------------------------------------ 第 1 级（根表）读
        ST_L1: begin
          if (bus_deny) begin
            enter_fault_access;                                   // PMP 拒绝页表读
          end else if (bus_err) begin
            enter_fault_access;                                   // 页表读总线错误
          end else if (bus_ack) begin
            if (pte_bad) begin
              enter_fault;                                        // V=0 / R=0&&W=1
            end else if (!pte_leaf) begin
              if (pte_tbl_bad) begin
                enter_fault;                                      // 非叶且 D|A|U 置位
              end else begin
                // ⚠ l2_base 必须取**本拍组合读到的 pte_ppn**（非阻塞赋值下寄存器版本还是旧值）
                bus_addr <= l2_base[31:0] + {va_r[21:12], 2'b00};      // 二级表第 va.vpn[0] 项
                state    <= ST_L2;                                // bus_req 保持 1
              end
            end else begin
              // 第 1 级叶子 = 4 MiB 超级页：PPN 低 10 位必须为 0（pte[19:10]==0）
              if (pte_ppn[9:0] != 10'd0) begin
                enter_fault;                                      // 超级页未对齐
              end else begin
                enter_done(1'b1);                                 // is_4m=1，PPN 低 10 位为 0
              end
            end
          end
        end
        //------------------------------------------------------ 第 2 级读
        ST_L2: begin
          if (bus_deny) begin
            enter_fault_access;                                   // PMP 拒绝页表读
          end else if (bus_err) begin
            enter_fault_access;
          end else if (bus_ack) begin
            if (pte_bad) begin
              enter_fault;                                        // V=0 / R=0&&W=1
            end else if (!pte_leaf) begin
              enter_fault;                                        // i<0：i 已到 0 仍为非叶
            end else begin
              enter_done(1'b0);                                   // 4 KiB 页
            end
          end
        end
        //-------------------------------------------------------- 结果态
        ST_RES: begin
          // done/fault 保持到下一次 req（新请求优先于结果保存；见 req_start 的边沿语义）
          if (req_start) begin
            va_r     <= va;
            bus_addr <= l1_base[31:0] + {va[31:22], 2'b00};
            bus_req  <= 1'b1;
            busy     <= 1'b1;
            done     <= 1'b0;
            fault    <= 1'b0;
            state    <= ST_L1;
          end
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
