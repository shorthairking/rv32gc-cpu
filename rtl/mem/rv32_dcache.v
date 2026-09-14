//=============================================================================
// rv32_dcache.v —— L1 数据 Cache（阶段 2A-④ 第二块：L1D，最小正确版）
//-----------------------------------------------------------------------------
// 结构与出处（每一处都可复查）：
//   · 容量/相联度/行大小：**32 KB = 128 组 × 8 路 × 32 B** —— `docs/design/03-cache.md`
//     §1/§3（L1D 32 KB/8 路/32 B）；参数宏 `L1D_SETS/L1D_WAYS` 见 `rv32gc_defs.vh`
//     （与 `docs/design/spec/06-lsu-mem.md` §1.2 一致）；行大小 `CACHE_LINE_BYTES=32`。
//   · **VIPT**：组索引 = `pa[11:5]`（== `va[11:5]`，索引位全部落在页内偏移 `va[11:0]` 内），
//     标记 = `pa[31:12]`（物理）。128 组 × 32 B = 4 KB = 页大小 ⇒ **无别名**，所以
//     `sfence.vma` **不需要**失效本 Cache（`03-cache.md` §1 别名安全性分析 +
//     `docs/design/spec/04-frontend.md:282-289`，与 L1I 同理由）。换页改的是 VA→PA 映射，
//     同一物理行在任意 VA 映射下组号必然相同、标记仍是 PA。
//   · **写策略 = 写直达 + 不写分配（write-through, no-write-allocate）**：store 一律落总线
//     （保持既有 `d_req_*` 单拍写通路），**命中时同时更新该行数据**（否则后续 load 会读到旧值），
//     **缺失不分配行**。⇒ **没有脏行**，因此不需要写回、Store Buffer、Victim Buffer；CBO 的
//     clean/flush 语义自然退化为空操作（本模块只做失效，无写回）。
//     裁剪理由：`AGENT.md` §7「④ Cache 的最小可用实施方案」（写回+写分配+MSHR 阵列+Store Buffer
//     超出本阶段可验证余量；写直达把"脏行/DMA 一致性/写回队列"三类风险一次消除）。
//   · **读策略 = 读分配**：load 缺失 ⇒ 取**整行 32 B** 填充（`03-cache.md` §3 缺失处理的最小裁剪：
//     单未完成缺失、无 MSHR 阵列、无关键字优先、无 next-line 预取）。
//   · **替换 = 轮转 RR**（每组 3 bit 指针，指向下次牺牲路）。**裁剪**：规格 §3 要求伪 LRU +
//     Victim Buffer；本阶段只做 RR（与 L1I 同口径，裁剪理由同上）。
//   · **XIP 绕 Cache（D16②，数据侧口径与取指一致）**：数据地址落在 SPI-XIP 窗口
//     （`` `IS_SPI_XIP ``：`0x1C00_0000` 1 MiB 或别名 `0x1FE8_0000`）**既不命中也不分配**，
//     每次访问都直接走总线。SPI 侧没有 Cache 一致性维护 ⇒ 一旦入 Cache 就再也读不到 Flash
//     的新内容。同理，**非 DDR 窗口（设备/UART/CONFREG/CLINT/PLIC/未映射）一律不缓存**
//     （`03-cache.md` §5 地址分类：只有 DDR 与 SRAM 可缓存；SRAM 窗口即 XIP 窗口，按 XIP 处理）。
//   · **原子/PTW/CBO 三类旁路**（`AGENT.md` §7 ④ 硬要求）：
//       - LR/SC/AMO：**整体绕 Cache**（继续走既有总线路径），不命中、不分配；
//         其中 **SC/AMO 的写完成且确实写了字节（wstrb!=0）时失效被写行**（若命中）。
//         LR/AMO 的读只读内存、不改内存，无需失效。
//       - PTW 页表读：**旁路**（`up_bypass`），永不命中/不分配 —— 页表项会被软件改写，
//         页表读必须是"每次都看内存"。
//       - CBO.INVAL/CLEAN/FLUSH：第 17 轮的通路是"向块基址发一次**读**让平台裁决可访问性"
//         （`rv32gc_core.v` MEM_CBO 段，**本模块不改其语义**）⇒ 本模块把它当**旁路读**
//         （仍走总线、仍可能报 store 访问错误 7），并在**成功**返回时**失效该块所在行**。
//         本设计无脏行 ⇒ clean/flush 无写回可做，与"失效"等价。
//       - CBO.ZERO：**不旁路** —— 它是 8 个普通 4 字节写（`rv32gc_core.v` 的 M_REQ_W 循环），
//         因此天然"命中则更新行、缺失则只落总线（不分配）"，即 32 B 清零穿过/更新 Cache。
//   · `fence.i` **不需要**动 L1D（自修改代码的写已经过 store 通路写入内存与行；取指侧失效
//     由 L1I 负责，见 `rtl/frontend/rv32_icache.v`）。
//
// 插入点（`rtl/top/rv32gc_core.v`）：
//   核内 MEM/PTW 仲裁点（`d_req_valid_w` / `d_req_*`）── rv32_dcache ── rv32_axi_master 的 d 客户端
//   上游契约与本核原来的 d 端口**逐位一致**：`valid/ready` 同拍握手取请求；接受后上游 `d_busy_q`
//   置位 ⇒ 在响应交付前不会再发新请求（因此本模块只需 1 个在途请求槽）。
//   ⚠ 硬约束一：**响应不得与请求握手同拍拉起** —— 核内 `d_busy_q` 的写法是
//     `if (d_req_take) busy<=1; else if (rsp_valid) busy<=0;`，同拍会丢响应 ⇒ 永久 busy。
//     本模块命中路径是"接受拍 → 下一拍 rsp_valid"（≥1 拍），不会同拍。
//   ⚠ 硬约束二：**不得给"不需要 Cache 动作"的访问加拍数**。写直达的 store 与所有旁路访问
//     （PTW/XIP/设备/原子）都**组合转发**到下游（与 ENABLE=0 的直通路径同一套 mux），
//     只在收到总线响应时用**延迟副作用**（`sid_*`）更新/失效行；因此这些访问逐拍等于基线，
//     不会被 Cache 拖慢（实测教训：先把它们塞进 FSM，memtest 的写循环每笔 +2 拍，
//     正好抵消掉 load 命中的收益）。只有**可缓存 load** 走 FSM：
//     命中（下一拍用阵列数据应答）与缺失（读分配填充）。
//
// 缺失填充（读分配）：经下游 `dl_*` 客户端做**一次 8 beat 突发读**取整行 32 B
//   （`rtl/bus/rv32_axi_master.v` 的 L1D refill 客户端，AXI ID 1；与
//   `docs/design/03-cache.md` §7「L1D refill = INCR，8 beat」一致）。
//   填充期间上游 `up_req_ready=0`；填充读回 err ⇒ 放弃填充（不分配）并把 err 交付上游。
//
// `ENABLE` 参数（安全阀，`AGENT.md` §7 ④）：`ENABLE=0` 时本模块**组合直通**（不命中/不分配、
//   不加任何拍数），与接线前逐拍等价，便于 A/B 对比与"回归挂了立刻切回基线"。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_dcache #(
  parameter integer ENABLE = 1          // 0 = 直通（组合旁路，等价未接 Cache 的基线接线）
) (
  input  wire         clk,
  input  wire         rst_n,

  // ---- 上游：核内 MEM/PTW 仲裁后的单一数据端口 ----
  input  wire         up_req_valid,
  input  wire         up_req_we,
  input  wire [31:0]  up_req_addr,      // **PA**（MMU 之后；MMU off 时 == VA）
  input  wire [31:0]  up_req_wdata,
  input  wire [3:0]   up_req_wstrb,
  output wire         up_req_ready,
  output wire         up_rsp_valid,
  output wire [31:0]  up_rsp_rdata,
  output wire         up_rsp_err,
  input  wire         up_rsp_ready,     // 本核 d_rsp_ready 恒 1

  // ---- 旁路分类（来自 rv32gc_core，见例化处注释）----
  input  wire         up_bypass,        // PTW 页表读
  input  wire         up_atomic,        // LR/SC/AMO（写完成需失效被写行）
  input  wire         up_cbo,           // CBO CLEAN/FLUSH/INVAL 探针读（成功 ⇒ 失效该行）

  // ---- 下游 A：rv32_axi_master 的数据单拍客户端（旁路 / 写直达）----
  output wire         dn_req_valid,
  output wire         dn_req_we,
  output wire [31:0]  dn_req_addr,
  output wire [31:0]  dn_req_wdata,
  output wire [3:0]   dn_req_wstrb,
  input  wire         dn_req_ready,
  input  wire         dn_rsp_valid,
  input  wire [31:0]  dn_rsp_rdata,
  input  wire         dn_rsp_err,
  output wire         dn_rsp_ready,

  // ---- 下游 B：rv32_axi_master 的数据**行填充**客户端（8 beat 突发 → 256 bit 整行）----
  output wire         dl_req_valid,
  output wire [31:0]  dl_req_addr,
  input  wire         dl_req_ready,
  input  wire         dl_rsp_valid,
  input  wire [255:0] dl_rsp_data,
  input  wire         dl_rsp_err,
  output wire         dl_rsp_ready,

  // ---- 结构可观测量（TB 断言/调试；不参与功能）----
  output wire         dbg_hit,          // 本拍请求命中已缓存行（组合；load/store 都算）
  output wire [2:0]   dbg_hit_way,
  output wire [6:0]   dbg_set,
  output wire         dbg_alloc_wen,    // 本拍在写 Cache 阵列（行填充分配）
  output wire [31:0]  dbg_alloc_addr,   // 被写入的行地址（PA 行对齐）
  output wire         dbg_alloc_store,  // 本拍在"store 命中更新行"写阵列
  output wire         dbg_fill_busy,    // 读分配填充进行中
  output reg  [31:0]  perf_access,
  output reg  [31:0]  perf_hit,
  output reg  [31:0]  perf_miss,
  output reg  [31:0]  perf_bypass
);

  localparam integer SETS  = `L1D_SETS;   // 128
  localparam integer WAYS  = `L1D_WAYS;   // 8
  localparam integer SET_W = 7;
  localparam integer TAG_W = 20;
  localparam integer WAY_W = 3;
  localparam integer ENT   = SETS * WAYS; // 1024 行

  localparam [1:0] S_IDLE = 2'd0,
                   S_HIT  = 2'd1,
                   S_FILL = 2'd2;

  localparam integer CACHE_ON = (ENABLE != 0);

  //-----------------------------------------------------------------------------
  // 阵列（一行 32 B；tag 20 bit；valid 单独一条 1024 bit 寄存器）
  //-----------------------------------------------------------------------------
  (* ram_style = "block" *) reg [TAG_W-1:0] tag_mem [0:ENT-1];  // {set[6:0], way[2:0]}；ram_style 供 Vivado 正确推断 BRAM
  (* ram_style = "block" *) reg [255:0] line_mem [0:ENT-1];
  reg [ENT-1:0]   valid_q;                 // 同上索引（整条寄存器：复位/清空一次赋值）
  // 组内轮转牺牲指针（RR 替换）：128 组 × 3 bit 打成**一整条寄存器**（不是"数组 + for"）。
  reg [SETS*WAY_W-1:0] rr_q;

  //-----------------------------------------------------------------------------
  // 组合查表：一次索引到单组，只比较 8 路标记（不做任何 128 组遍历）
  //-----------------------------------------------------------------------------
  wire [31:0] lk_line = {up_req_addr[31:5], 5'b0};   // 行对齐
  wire [6:0]  lk_set  = up_req_addr[11:5];           // VIPT 组索引（页内位）
  wire [19:0] lk_tag  = up_req_addr[31:12];          // 物理标记

  wire [7:0] way_vld = valid_q[{lk_set, 3'b000} +: WAYS];

  wire [TAG_W-1:0] tag_w0 = tag_mem[{lk_set, 3'd0}];
  wire [TAG_W-1:0] tag_w1 = tag_mem[{lk_set, 3'd1}];
  wire [TAG_W-1:0] tag_w2 = tag_mem[{lk_set, 3'd2}];
  wire [TAG_W-1:0] tag_w3 = tag_mem[{lk_set, 3'd3}];
  wire [TAG_W-1:0] tag_w4 = tag_mem[{lk_set, 3'd4}];
  wire [TAG_W-1:0] tag_w5 = tag_mem[{lk_set, 3'd5}];
  wire [TAG_W-1:0] tag_w6 = tag_mem[{lk_set, 3'd6}];
  wire [TAG_W-1:0] tag_w7 = tag_mem[{lk_set, 3'd7}];

  wire [7:0] way_hit = { (tag_w7 == lk_tag) && way_vld[7],
                         (tag_w6 == lk_tag) && way_vld[6],
                         (tag_w5 == lk_tag) && way_vld[5],
                         (tag_w4 == lk_tag) && way_vld[4],
                         (tag_w3 == lk_tag) && way_vld[3],
                         (tag_w2 == lk_tag) && way_vld[2],
                         (tag_w1 == lk_tag) && way_vld[1],
                         (tag_w0 == lk_tag) && way_vld[0] };
  wire       hit_raw = |way_hit;
  wire [2:0] hit_way = way_hit[0] ? 3'd0 : way_hit[1] ? 3'd1 :
                       way_hit[2] ? 3'd2 : way_hit[3] ? 3'd3 :
                       way_hit[4] ? 3'd4 : way_hit[5] ? 3'd5 :
                       way_hit[6] ? 3'd6 : 3'd7;

  wire [255:0] data_w0 = line_mem[{lk_set, 3'd0}];
  wire [255:0] data_w1 = line_mem[{lk_set, 3'd1}];
  wire [255:0] data_w2 = line_mem[{lk_set, 3'd2}];
  wire [255:0] data_w3 = line_mem[{lk_set, 3'd3}];
  wire [255:0] data_w4 = line_mem[{lk_set, 3'd4}];
  wire [255:0] data_w5 = line_mem[{lk_set, 3'd5}];
  wire [255:0] data_w6 = line_mem[{lk_set, 3'd6}];
  wire [255:0] data_w7 = line_mem[{lk_set, 3'd7}];
  wire [255:0] hit_line = (hit_way == 3'd0) ? data_w0 : (hit_way == 3'd1) ? data_w1 :
                          (hit_way == 3'd2) ? data_w2 : (hit_way == 3'd3) ? data_w3 :
                          (hit_way == 3'd4) ? data_w4 : (hit_way == 3'd5) ? data_w5 :
                          (hit_way == 3'd6) ? data_w6 : data_w7;
  // 命中词（行内 4 字节，按 addr[4:2] 选）：本核数据侧每次访问都是单拍 4 字节对齐访问
  wire [31:0] hit_word = hit_line[{up_req_addr[4:2], 5'b0} +: 32];

  //-----------------------------------------------------------------------------
  // 可缓存性判定（`03-cache.md` §5 地址分类 + D16② XIP 绕 Cache）
  //   可缓存 = DDR 窗口（0x0000_0000–0x07FF_FFFF）；SRAM 窗口 == SPI-XIP 窗口 ⇒ 旁路。
  //   设备/未映射窗口（UART/CONFREG/CLINT/PLIC/…）一律不缓存（读有副作用、无一致性保证）。
  //-----------------------------------------------------------------------------
  wire        in_ddr    = (up_req_addr < `DDR_SIZE);
  wire        in_xip    = `IS_SPI_XIP(up_req_addr);
  wire        cacheable = in_ddr && !in_xip;

  // 旁路（不参与 Cache 命中/分配）：PTW / 原子 / CBO 探针 / 非可缓存窗口
  wire        spec    = up_bypass | up_atomic | up_cbo;
  wire        can_acc = CACHE_ON && cacheable && !spec;   // 走 Cache 语义的访问
  wire        is_load = !up_req_we;
  // 只有"可缓存 load"需要 FSM：命中（下一拍应答）/ 缺失（读分配填充）
  wire        need_fsm = can_acc && is_load;
  wire        hit      = need_fsm && hit_raw;             // 走 Cache 语义的 load 命中
  wire        fast     = !need_fsm;                       // 其余全部组合转发（零加拍）
  // 结构可观测量：本拍请求是否命中已缓存行（load/store 都算，给 TB 断言用）
  wire        hit_dbg  = CACHE_ON && cacheable && !spec && hit_raw;

  assign dbg_hit     = hit_dbg;
  assign dbg_hit_way = hit_way;
  assign dbg_set     = lk_set;

  //-----------------------------------------------------------------------------
  // FSM 状态（仅服务可缓存 load）
  //-----------------------------------------------------------------------------
  reg [1:0]   st_q;
  reg [31:0]  req_addr_q;      // 缺失 load 的目标地址（取行内字用）
  reg [6:0]   req_set_q;
  reg [19:0]  req_tag_q;
  reg [2:0]   req_vic_q;       // RR 牺牲路

  reg         fast_q;          // 接受拍锁存的"本笔走快路径"（响应侧路由用）
  reg         dl_req_valid_q;
  reg         up_rsp_valid_q;
  reg [31:0]  up_rsp_rdata_q;
  reg         up_rsp_err_q;

  assign dbg_fill_busy  = (st_q == S_FILL);
  assign dbg_alloc_wen  = CACHE_ON && (st_q == S_FILL) && dl_rsp_valid && !dl_rsp_err;
  assign dbg_alloc_addr = {req_tag_q, req_set_q, 5'b0};

  //-----------------------------------------------------------------------------
  // 延迟副作用（store 命中更新行 / 旁路写与 CBO 失效行）
  //   在"请求被接受"拍锁存 {组,路,标记,地址,写数据,字节使能,命中行}，
  //   在"下游单拍响应成功"拍真正写阵列 —— 这样既不丢副作用、又不给快路径加拍数。
  //   安全性：上游在收到响应前不会再发请求（`d_busy_q`），因此锁存到响应之间
  //   **没有任何其它访问能改阵列**；阵列写在响应拍提交，下一次查找最早在 3 拍之后
  //   （M_DONE→M_IDLE→M_REQ），必能看到更新后的行。
  //-----------------------------------------------------------------------------
  wire        req_take = up_req_valid && up_req_ready;    // 请求被接受（快路径或 FSM 路径）

  reg         sid_upd_q;       // 命中 store：更新行
  reg         sid_inv_q;       // 旁路写 / CBO 探针：失效行
  reg [6:0]   sid_set_q;
  reg [2:0]   sid_way_q;
  reg [19:0]  sid_tag_q;
  reg [31:0]  sid_addr_q;
  reg [31:0]  sid_wdata_q;
  reg [3:0]   sid_wstrb_q;
  reg [255:0] sid_line_q;

  // store 命中回写：按 wstrb 生成 32 位掩码 + 数据（无效字节被掩码清掉），再用移位定位
  wire [31:0]  stmask32 = {{8{sid_wstrb_q[3]}}, {8{sid_wstrb_q[2]}},
                           {8{sid_wstrb_q[1]}}, {8{sid_wstrb_q[0]}}};
  wire [255:0] st_data_sh = {224'd0, sid_wdata_q} << {sid_addr_q[4:2], 5'b0};
  wire [255:0] st_mask_sh = {224'd0, stmask32}    << {sid_addr_q[4:2], 5'b0};
  wire [255:0] sid_line_upd = (sid_line_q & ~st_mask_sh) | (st_data_sh & st_mask_sh);

  // 失效查表（CBO / 旁路写完成时用）：同样是"索引一次 + 8 路并行比较"
  wire [7:0] inv_vld = valid_q[{sid_set_q, 3'b000} +: WAYS];
  wire [7:0] inv_wh  = { (tag_mem[{sid_set_q, 3'd7}] == sid_tag_q) && inv_vld[7],
                         (tag_mem[{sid_set_q, 3'd6}] == sid_tag_q) && inv_vld[6],
                         (tag_mem[{sid_set_q, 3'd5}] == sid_tag_q) && inv_vld[5],
                         (tag_mem[{sid_set_q, 3'd4}] == sid_tag_q) && inv_vld[4],
                         (tag_mem[{sid_set_q, 3'd3}] == sid_tag_q) && inv_vld[3],
                         (tag_mem[{sid_set_q, 3'd2}] == sid_tag_q) && inv_vld[2],
                         (tag_mem[{sid_set_q, 3'd1}] == sid_tag_q) && inv_vld[1],
                         (tag_mem[{sid_set_q, 3'd0}] == sid_tag_q) && inv_vld[0] };

  // 本拍请求是否需要"延迟副作用"
  wire sid_inv_now = req_take && CACHE_ON && cacheable &&
                     ( up_cbo | (up_req_we && (up_atomic | up_bypass)) );        // 失效
  wire sid_upd_now = req_take && can_acc && up_req_we && hit_raw;                // 命中 store 更新

  assign dbg_alloc_store = CACHE_ON && dn_rsp_valid && !dn_rsp_err && sid_upd_q;

  //-----------------------------------------------------------------------------
  // 端口驱动
  //   快路径（fast=1）：请求/响应**组合**穿过本模块（与 ENABLE=0 同一套 mux，零加拍）
  //   FSM 路径：可缓存 load 命中/缺失
  //-----------------------------------------------------------------------------
  // ⚠ 响应侧必须用**接受拍锁存的** `fast_q`：响应到达时上游已在 M_WAIT
  //   （d_req_valid=0、d_req_addr 已归零），此时再算 fast 会算成"可缓存 load"，
  //   把响应错误地接到 FSM 寄存器上 ⇒ 丢响应、核永久 busy（本会话实测踩到）。
  assign up_req_ready  = CACHE_ON ? (fast ? dn_req_ready : (st_q == S_IDLE)) : dn_req_ready;
  assign up_rsp_valid  = CACHE_ON ? (fast_q ? dn_rsp_valid : up_rsp_valid_q) : dn_rsp_valid;
  assign up_rsp_rdata  = CACHE_ON ? (fast_q ? dn_rsp_rdata : up_rsp_rdata_q) : dn_rsp_rdata;
  assign up_rsp_err    = CACHE_ON ? (fast_q ? dn_rsp_err   : up_rsp_err_q)   : dn_rsp_err;

  // FSM 从不使用单拍通道（store/旁路全走快路径，可缓存 load 走行填充突发）
  assign dn_req_valid  = CACHE_ON ? (fast ? up_req_valid : 1'b0) : up_req_valid;
  assign dn_req_we     = up_req_we;
  assign dn_req_addr   = up_req_addr;
  assign dn_req_wdata  = up_req_wdata;
  assign dn_req_wstrb  = up_req_wstrb;
  assign dn_rsp_ready  = CACHE_ON ? (fast_q ? up_rsp_ready : 1'b1) : up_rsp_ready;

  // 行填充突发客户端（只有 FSM 缺失路径使用；ENABLE=0 恒不发）
  assign dl_req_valid  = CACHE_ON ? dl_req_valid_q : 1'b0;
  assign dl_req_addr   = {req_tag_q, req_set_q, 5'b0};
  assign dl_rsp_ready  = CACHE_ON ? 1'b1 : 1'b0;

  // 本次缺失 load 要的那个字（整行一次到齐后从 256 bit 里选）
  wire [31:0] fill_word_sel = dl_rsp_data[{req_addr_q[4:2], 5'b0} +: 32];

  //-----------------------------------------------------------------------------
  // 时序
  //-----------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      st_q            <= S_IDLE;
      valid_q         <= {ENT{1'b0}};
      rr_q            <= {(SETS*WAY_W){1'b0}};
      req_addr_q      <= 32'd0;
      req_set_q       <= 7'd0;
      req_tag_q       <= 20'd0;
      req_vic_q       <= 3'd0;
      dl_req_valid_q  <= 1'b0;
      up_rsp_valid_q  <= 1'b0;
      up_rsp_rdata_q  <= 32'd0;
      up_rsp_err_q    <= 1'b0;
      fast_q          <= 1'b0;
      sid_upd_q       <= 1'b0;
      sid_inv_q       <= 1'b0;
      sid_set_q       <= 7'd0;
      sid_way_q       <= 3'd0;
      sid_tag_q       <= 20'd0;
      sid_addr_q      <= 32'd0;
      sid_wdata_q     <= 32'd0;
      sid_wstrb_q     <= 4'd0;
      sid_line_q      <= 256'd0;
      perf_access     <= 32'd0;
      perf_hit        <= 32'd0;
      perf_miss       <= 32'd0;
      perf_bypass     <= 32'd0;
    end else if (CACHE_ON) begin
      // ---------------- 延迟副作用：请求接受拍锁存 ----------------
      if (req_take) begin
        perf_access <= perf_access + 32'd1;
        if (!can_acc) perf_bypass <= perf_bypass + 32'd1;
        fast_q      <= fast;
        sid_upd_q   <= sid_upd_now;
        sid_inv_q   <= sid_inv_now;
        sid_set_q   <= lk_set;
        sid_way_q   <= hit_way;
        sid_tag_q   <= lk_tag;
        sid_addr_q  <= up_req_addr;
        sid_wdata_q <= up_req_wdata;
        sid_wstrb_q <= up_req_wstrb;
        sid_line_q  <= hit_line;
      end
      // ---------------- 延迟副作用：下游单拍响应拍落地 ----------------
      if (dn_rsp_valid) begin
        sid_upd_q <= 1'b0;
        sid_inv_q <= 1'b0;
        if (!dn_rsp_err) begin
          if (sid_upd_q) line_mem[{sid_set_q, sid_way_q}] <= sid_line_upd;
          if (sid_inv_q) valid_q[{sid_set_q, 3'b000} +: WAYS] <=
                             valid_q[{sid_set_q, 3'b000} +: WAYS] & ~inv_wh;
        end
      end

      // ---------------- 响应被取走 ----------------
      if (up_rsp_valid_q && up_rsp_ready) up_rsp_valid_q <= 1'b0;
      // ---------------- 行填充请求被接受 ----------------
      if (dl_req_valid_q && dl_req_ready) dl_req_valid_q <= 1'b0;

      case (st_q)
        //---------------------------------------------------------------------
        S_IDLE: begin
          if (up_req_valid && need_fsm) begin          // 只有可缓存 load 会进 FSM
            req_addr_q <= up_req_addr;
            req_set_q  <= lk_set;
            req_tag_q  <= lk_tag;
            if (hit_raw) begin
              perf_hit       <= perf_hit + 32'd1;
              up_rsp_valid_q <= 1'b1;                  // 下一拍应答（不得与握手同拍）
              up_rsp_rdata_q <= hit_word;
              up_rsp_err_q   <= 1'b0;
              st_q           <= S_HIT;
            end else begin
              perf_miss      <= perf_miss + 32'd1;
              req_vic_q      <= rr_q[lk_set * WAY_W +: WAY_W];   // RR 牺牲路
              dl_req_valid_q <= 1'b1;                  // 一次 8 beat 突发取整行
              st_q           <= S_FILL;
            end
          end
        end
        //---------------------------------------------------------------------
        S_HIT: if (up_rsp_valid_q && up_rsp_ready) st_q <= S_IDLE;
        //---------------------------------------------------------------------
        S_FILL: begin
          if (dl_rsp_valid) begin
            if (dl_rsp_err) begin
              // 行读出错 ⇒ 放弃填充（**不分配**），把总线错误交付上游（load access fault）
              up_rsp_valid_q <= 1'b1;
              up_rsp_rdata_q <= 32'd0;
              up_rsp_err_q   <= 1'b1;
            end else begin
              // 整行到齐：分配（RR 牺牲路）＋把本次 load 要的那个字返回
              tag_mem[{req_set_q, req_vic_q}]  <= req_tag_q;
              line_mem[{req_set_q, req_vic_q}] <= dl_rsp_data;
              valid_q[{req_set_q, 3'b000} +: WAYS] <=
                  valid_q[{req_set_q, 3'b000} +: WAYS] | (8'b0000_0001 << req_vic_q);
              rr_q[req_set_q * WAY_W +: WAY_W] <= req_vic_q + 3'd1;   // 轮转
              up_rsp_valid_q <= 1'b1;
              up_rsp_rdata_q <= fill_word_sel;
              up_rsp_err_q   <= 1'b0;
            end
            st_q <= S_HIT;
          end
        end
        //---------------------------------------------------------------------
        default: st_q <= S_IDLE;
      endcase
    end
  end

endmodule
