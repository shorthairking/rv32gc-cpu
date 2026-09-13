//=============================================================================
// rv32_tlb.v —— Sv32 全相联地址翻译缓存（CAM，纯标签-数据存储 + 组合查询）
//
// 职责边界（**只存不判**）：
//   * 本模块只保存"已翻译过的页"的标签与叶子 PTE 原始字段，命中判定（tag/ASID/G）
//     在这里做；**权限判定（U/SUM/MXR/R/W/X/A/D）一律由调用方按当前特权级与访问
//     类型 live 判定**——TLB 不参与权限裁决，因此切换 SUM/MXR/priv 无需失效 TLB。
//   * 本里程碑为 Svade：A/D 缺失 ⇒ 页错误，PTE 不被改写，故这里缓存的 A/D 位是
//     叶子 PTE 的原值，随 `perm` 一起回给调用方做 Svade 判定。
//
// 命中判定（组合 1 拍，与 docs/design/spec/07-priv-csr-mmu.md:267-268 一致）：
//     hit = VALID & (G | (ASID == satp_asid))
//           & (IS_4M ? VPN_TAG[19:10] == va[31:22]     // 4 MiB 超级页：忽略 va[21:12]
//                    : VPN_TAG[19:0]  == va[31:12]);   // 4 KiB 页：全 20 位比较
//   多个表项同时命中是规范允许的（supervisor.adoc:1790-1795 的 NOTE：允许同一地址
//   存在多个翻译缓存表项），本实现取**编号最小**的命中项，行为确定。
//
// 字段宽度来源：
//   * Sv32 = 两级、4 KiB 页、PTE 32 位，PTE[31:10] 为 PPN（PPN 共 22 位）：
//     tools/spike/riscv/mmu.h:606-611（levels=2, idxbits=10, ptesize=4）、
//     tools/spike/riscv/encoding.h:511-518（V/R/W/X/U/G/A/D 位序）、:526 PTE_PPN_SHIFT=10
//   * 4 MiB 超级页的 PPN 低 10 位必须为 0（物理对齐）：
//     riscv-isa-manual/src/priv/supervisor.adoc:1699-1702、:1737（`i>0 && pte.ppn[i-1:0]!=0` ⇒ 页错误）
//     ⇒ 4M 表项的 PPN 只使用 [21:10]，低 10 位由 VA 提供（调用方拼接），
//       故本模块对 4M 表项的 PPN 低 10 位不做保证、也不算作有效信息。
//   * G 忽略 ASID 比较：supervisor.adoc:1779-1782（"Entries in the
//     address-translation cache may then satisfy subsequent step 2 reads if the ASID
//     associated with the entry matches the ASID loaded in step 1 or if the entry is
//     associated with a _global_ mapping"）
//   * ASID 字段宽度 9 位（satp[30:22]）：docs/design/spec/07-priv-csr-mmu.md:108
//
// 替换策略：轮转（round-robin）。`flush_all` 清全部 VALID（本里程碑 sfence.vma
//   一律当作 x0,x0 全清，失效粒度矩阵见 07-priv-csr-mmu.md:323-332）。
//
// 实现备注：表项存储用**打包向量**（[ENTRIES*W-1:0] + 变量基址 part-select `+:`）
//   而不是 `reg [W-1:0] arr [0:ENTRIES-1]`——后者会让 `always @*` 展开成"对全部
//   数组字敏感"，iverilog -Wall 会逐数组报警告；打包向量零告警，且同样可综合。
//
// 复位：VALID 全 0；`flush_all`/`fill_en`/查询信号无复位值。
//=============================================================================
// 注：本仓库 RTL 文件一律不带 `timescale（全量编译时避免跨文件继承告警）；
//     本模块无任何延时，不需要时间单位。
module rv32_tlb #(
  parameter integer ENTRIES = 8          // 表项数（≥1；非 2 的幂也可工作）
) (
  input  wire        clk,
  input  wire        rst_n,
  //---------------------------------------------------------------- 查询（组合）
  input  wire [31:0] va,
  input  wire [8:0]  satp_asid,          // 当前 ASID（satp[30:22]）
  output wire        hit,
  output wire [21:0] ppn,                // 命中项 PPN；4M 时低 10 位为 0（调用方按 is_4m 拼 VA[21:12]）
  output wire        is_4m,
  output wire [7:0]  perm,               // 叶子 PTE 原值 perm[7:0] = {D,A,G,U,X,W,R,V}（V 恒 1）
  //---------------------------------------------------------------- 填充（单拍）
  input  wire        fill_en,
  input  wire [31:0] fill_va,
  input  wire [8:0]  fill_asid,
  input  wire        fill_g,
  input  wire        fill_is_4m,
  input  wire [21:0] fill_ppn,
  input  wire [7:0]  fill_perm,
  //---------------------------------------------------------------- 失效（本里程碑：全清）
  input  wire        flush_all
);

  //--------------------------------------------------------------------------
  // 表项存储（打包向量：项 k 占 [k*W +: W]）
  //--------------------------------------------------------------------------
  reg [ENTRIES-1:0]      v_bus;          // VALID
  reg [ENTRIES*20-1:0]   tag_bus;        // VPN_TAG = va[31:12]
  reg [ENTRIES*9-1:0]    asid_bus;
  reg [ENTRIES-1:0]      g_bus;          // G：忽略 ASID 比较
  reg [ENTRIES-1:0]      f4m_bus;        // IS_4M：1 = 4 MiB 超级页
  reg [ENTRIES*22-1:0]   ppn_bus;
  reg [ENTRIES*8-1:0]    perm_bus;

  integer                rr;             // 轮转替换指针：下一个受害者
  integer                qi;             // 查询循环变量

  //--------------------------------------------------------------------------
  // 组合查询（全相联 CAM；编号最小的命中项胜出）
  //   失效项字段可能为 X，故一切字段比较都在对应 VALID 为 1 时才求值。
  //--------------------------------------------------------------------------
  reg        hit_c;
  reg [21:0] ppn_c;
  reg        is4m_c;
  reg [7:0]  perm_c;
  reg        asid_ok;
  reg        tag_ok;
  reg [9:0]  vpn1_va;                    // 当前 VA 的 VPN[1]（= va[31:22]）
  reg [19:0] tag_e;                      // 命中项的 20 位标签

  always @* begin
    hit_c  = 1'b0;
    ppn_c  = 22'd0;
    is4m_c = 1'b0;
    perm_c = 8'd0;
    vpn1_va = va[31:22];
    for (qi = 0; qi < ENTRIES; qi = qi + 1) begin
      if (v_bus[qi]) begin
        // G=1 ⇒ 忽略 ASID 比较
        asid_ok = g_bus[qi] | (asid_bus[qi*9 +: 9] == satp_asid);
        tag_e   = tag_bus[qi*20 +: 20];
        // 4M ⇒ 只比较 VPN[1]（va[31:22]），va[21:12] 不参与标签
        tag_ok  = f4m_bus[qi] ? (tag_e[19:10] == vpn1_va) : (tag_e[19:0] == va[31:12]);
        if (!hit_c && asid_ok && tag_ok) begin
          hit_c  = 1'b1;
          ppn_c  = ppn_bus[qi*22 +: 22];
          is4m_c = f4m_bus[qi];
          perm_c = perm_bus[qi*8 +: 8];
        end
      end
    end
  end

  assign hit   = hit_c;
  assign ppn   = ppn_c;
  assign is_4m = is4m_c;
  assign perm  = perm_c;

  //--------------------------------------------------------------------------
  // 填充 / 失效
  //   flush_all 优先级最高（同一拍 fill_en 被忽略）；否则写 rr 指向的项并推进指针。
  //--------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      v_bus    <= {ENTRIES{1'b0}};
      tag_bus  <= {(ENTRIES*20){1'b0}};
      asid_bus <= {(ENTRIES*9){1'b0}};
      g_bus    <= {ENTRIES{1'b0}};
      f4m_bus  <= {ENTRIES{1'b0}};
      ppn_bus  <= {(ENTRIES*22){1'b0}};
      perm_bus <= {(ENTRIES*8){1'b0}};
      rr       <= 0;
    end else if (flush_all) begin
      v_bus <= {ENTRIES{1'b0}};
    end else if (fill_en) begin
      v_bus[rr]                   <= 1'b1;
      tag_bus[rr*20 +: 20]        <= fill_va[31:12];
      asid_bus[rr*9 +: 9]         <= fill_asid;
      g_bus[rr]                   <= fill_g;
      f4m_bus[rr]                 <= fill_is_4m;
      ppn_bus[rr*22 +: 22]        <= fill_ppn;
      perm_bus[rr*8 +: 8]         <= fill_perm;
      rr <= (rr == (ENTRIES - 1)) ? 0 : (rr + 1);
    end
  end

endmodule
