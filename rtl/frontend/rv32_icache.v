//=============================================================================
// rv32_icache.v —— L1 指令 Cache（阶段 2A-④ 第一步：L1I）
//-----------------------------------------------------------------------------
// 结构与出处（每一处都可复查）：
//   · 容量/相联度/行大小：16 KB = 128 组 × 4 路 × 32 B —— `docs/design/03-cache.md` §1/§2、
//     `docs/design/spec/04-frontend.md` §4.1；行大小亦见 `docs/design/spec/00-conventions.md`
//     的 `CACHE_LINE_BYTES = 32`（`rtl/pkg/rv32gc_defs.vh`）。
//   · **VIPT**：组索引 = `pa[11:5]`（== `va[11:5]`，索引位全部落在页内偏移 `va[11:0]` 内）；
//     标记 = `pa[31:12]`（物理）。因为 `128 组 × 32 B = 4 KB = 页大小`，且 `pa[11:5] == va[11:5]`，
//     同一物理行在任意 VA 映射下组号必然相同 ⇒ **无别名**（证明见
//     `docs/design/spec/04-frontend.md:282-289`）。因此本模块只吃 **PA 行地址**：
//     地址经 MMU 翻译后（`pa_valid` 门控）才发请求，与 ITLB「权限与 Tag 并行」无关
//     （本核取指路径是"先翻译再取行"的单行缓冲，不是 IF0/IF1/IF2 流水）。
//   · **替换＝轮转 RR**（每组 7 bit 指针 `rr_q[set]`，指向下次牺牲路）。**裁剪**：规格
//     `03-cache.md` §2 要求伪 LRU，本阶段只做 RR —— 4 路下两者命中率差距有限、验证成本低，
//     裁剪理由写在 `AGENT.md` §7「④ Cache 的最小可用实施方案」。
//   · **单未完成缺失**（无 MSHR 阵列、无 next-line 预取、无关键字优先）：本核取指单元
//     同一时刻只有一笔在途行请求，平台按 32 B 整行（8 beat）返回，所以"缺失→整行填充→立即
//     返回"一拍完成，关键字优先无从发挥（规格 §4.5 的关键字优先是给"半个行 16 B 先到"的
//     流水前端用的）。裁剪同样见 `AGENT.md` §7 ④。
//
// 插入点（`rtl/top/rv32gc_core.v`）：
//     rv32_ifetch ──(行请求/整行响应)── rv32_icache ──(同一握手)── rv32_axi_master
//   `rv32_ifetch` 每次跨 32 B 行时请求整行（`if_req_addr` = **PA 行地址**），本模块对同一
//   握手透明转发：命中 1 拍给数据；缺失则发 AXI 读，响应回来**同一拍**写阵列 + 回数据。
//
// D16② 「命中 SPI-XIP 窗口绕过 I-Cache」（**不可省**，见 `rv32_ifetch.v` 头部 64-77 行说明）：
//   · 请求侧：`req_xip`（= `rv32_ifetch.req_xip_q`）+ 本模块自算的 `IS_SPI_XIP(req_addr)`
//     任一成立即 **禁止命中**，每拍都走总线 XIP 读；
//   · 填充侧：以**在途请求地址**为准（`fill_addr_q`）再判一次，XIP 行**不得写阵列/置 valid**；
//     不能只看请求侧的瞬态判定 —— 填充发生在若干拍之后，必须看那一笔请求自己的窗口归属。
//   ⇒ 平台不提供 I-Cache 一致性维护，XIP 行一旦入 Cache 就再也读不到 Flash 的新内容。
//
// `fence.i` 失效：提交拍给 `invalidate` 一个脉冲，本模块**1 拍清空全部 512 个 valid 位**
//   （`valid_q` 是一整条 512 bit 寄存器，不是 128 组 × 4 路的逐组扫描，规格 §4.3 ③）。
//   `sfence.vma` **不需要**失效本 Cache：VIPT + 页内索引 + 物理标记 ⇒ 换地址空间后同一物理行
//   仍在同一组、标记仍是 PA（规格 §4.6 第二行、§5.3 最后一行）。
//   在途填充被 `fence.i` 打断时：该笔读可能早于 `fence.i`（读到旧指令），必须**丢弃并重发**，
//   而不是填进来（否则 Cache 里留下旧行 ⇒ SMC 取到旧指令）。
//
// `ENABLE` 参数（安全阀，`AGENT.md` §7 ④）：`ENABLE=0` 时退化为"直通" —— 永不命中、永不填充，
//   行为与接线前（ifetch 直连 AXI）逐拍等价，便于 A/B 对比与"回归挂了立刻切回基线"。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_icache #(
  parameter integer ENABLE = 1          // 0 = 直通（不命中 / 不填充，等价基线接线）
) (
  input  wire         clk,
  input  wire         rst_n,

  // ---- fence.i 提交拍：1 拍整表失效 ----
  input  wire         invalidate,

  // ---- 请求侧（来自 rv32_ifetch）----
  input  wire         req_valid,
  input  wire [31:0]  req_addr,         // **PA** 行地址（= {pa[31:5], 5'b0}）
  input  wire         req_xip,          // D16②：本请求行属于 SPI-XIP 窗口（rv32_ifetch.req_xip_q）
  output wire         req_ready,

  // ---- 响应侧（回 rv32_ifetch，握手与 rv32_axi_master 的取指客户端一致）----
  output reg          rsp_valid,
  output reg  [255:0] rsp_data,
  output reg          rsp_err,
  input  wire         rsp_ready,

  // ---- 下游：rv32_axi_master 的取指客户端 ----
  output reg          axi_req_valid,
  output reg  [31:0]  axi_req_addr,
  input  wire         axi_req_ready,
  input  wire         axi_rsp_valid,
  input  wire [255:0] axi_rsp_data,
  input  wire         axi_rsp_err,
  output wire         axi_rsp_ready,

  // ---- 结构可观测量（TB 断言 / 调试；不参与功能）----
  output wire         dbg_alloc_wen,    // 本拍在写 Cache 阵列（分配）——XIP 期间必须恒 0
  output wire [31:0]  dbg_alloc_addr,   // 被写入的行地址（PA 行对齐）
  output wire         dbg_hit,
  output wire [3:0]   dbg_hit_way,
  output wire [6:0]   dbg_set,
  output reg  [31:0]  perf_access,      // 访问次数（不含 XIP 直通？——含，见 S_IDLE 计数）
  output reg  [31:0]  perf_hit,
  output reg  [31:0]  perf_miss
);

  localparam integer SETS  = 128;
  localparam integer WAYS  = 4;
  localparam integer SET_W = 7;
  localparam integer TAG_W = 20;
  localparam integer ENT   = SETS * WAYS;     // 512 行

  localparam [1:0] S_IDLE = 2'd0,
                   S_RESP = 2'd1,
                   S_FILL = 2'd2;

  localparam integer CACHE_ON = (ENABLE != 0);

  //-----------------------------------------------------------------------------
  // 阵列（一行 32 B；tag 20 bit；valid 单独一条 512 bit 寄存器便于 1 拍全清）
  //-----------------------------------------------------------------------------
  reg [TAG_W-1:0]     tag_mem  [0:ENT-1];     // {set[6:0], way[1:0]}
  reg [255:0]         line_mem [0:ENT-1];
  reg [ENT-1:0]       valid_q;                // 同上索引；fence.i 一拍全清
  // 组内轮转牺牲指针（RR 替换）：128 组 × 7 bit 打成**一整条寄存器**，
  // 复位/fence.i 都是一次赋值（不是"数组 + for 循环"——那种写法 verilator 直接报错）。
  reg [SETS*SET_W-1:0] rr_q;

  //-----------------------------------------------------------------------------
  // 组合查表：一次索引到单组，只比较 4 路标记（不做任何 128 组遍历）
  //-----------------------------------------------------------------------------
  wire [31:0] req_line = {req_addr[31:5], 5'b0};   // 行对齐
  wire [6:0]  lk_set   = req_line[11:5];           // VIPT 组索引（页内位）
  wire [19:0] lk_tag   = req_line[31:12];          // 物理标记

  wire [3:0]  way_vld = valid_q[{lk_set, 2'b00} +: WAYS];
  wire [TAG_W-1:0] tag_w0 = tag_mem[{lk_set, 2'b00}];
  wire [TAG_W-1:0] tag_w1 = tag_mem[{lk_set, 2'b01}];
  wire [TAG_W-1:0] tag_w2 = tag_mem[{lk_set, 2'b10}];
  wire [TAG_W-1:0] tag_w3 = tag_mem[{lk_set, 2'b11}];

  wire [3:0] way_hit = { (tag_w3 == lk_tag) && way_vld[3],
                         (tag_w2 == lk_tag) && way_vld[2],
                         (tag_w1 == lk_tag) && way_vld[1],
                         (tag_w0 == lk_tag) && way_vld[0] };
  wire       hit_raw = |way_hit;
  wire [1:0] hit_way = way_hit[0] ? 2'd0 :
                       way_hit[1] ? 2'd1 :
                       way_hit[2] ? 2'd2 : 2'd3;

  wire [255:0] data_w0 = line_mem[{lk_set, 2'b00}];
  wire [255:0] data_w1 = line_mem[{lk_set, 2'b01}];
  wire [255:0] data_w2 = line_mem[{lk_set, 2'b10}];
  wire [255:0] data_w3 = line_mem[{lk_set, 2'b11}];
  wire [255:0] hit_data = (hit_way == 2'd0) ? data_w0 :
                          (hit_way == 2'd1) ? data_w1 :
                          (hit_way == 2'd2) ? data_w2 : data_w3;

  //-----------------------------------------------------------------------------
  // D16② XIP 判定点（请求侧 + 填充侧）
  //-----------------------------------------------------------------------------
  wire req_bypass = req_xip | `IS_SPI_XIP(req_line);   // PA 判定

  // 命中：ENABLE 有效 ∧ 阵列命中 ∧ 非 XIP 窗口 ∧ 本拍不是 fence.i 失效拍
  wire hit = CACHE_ON && hit_raw && !req_bypass && !invalidate;

  //-----------------------------------------------------------------------------
  // 状态
  //-----------------------------------------------------------------------------
  reg [1:0]  state_q;
  reg [6:0]  set_q;           // 在途缺失的组号
  reg [19:0] tag_q;           // 在途缺失的物理标记
  reg [31:0] fill_addr_q;     // 在途请求行地址（PA；填充侧 XIP 判定用）
  reg        fill_xip_q;      // 在途请求的窗口归属（D16②，发起拍采样）
  reg        fill_kill_q;     // 在途填充被 fence.i 打断 ⇒ 响应到达时丢弃并重发
  reg        mem_taken_q;     // 该笔 AXI 读已被主设备接受（AR 之前已在途）

  // 牺牲路（RR）：一次索引到单组（变量部分选择，7 bit）
  wire [SET_W-1:0] vic_idx = rr_q[set_q * SET_W +: SET_W];   // 该组当前 RR 指针（0..3）
  wire [1:0]       vic_way = vic_idx[1:0];
  wire [SET_W-1:0] rr_nxt  = vic_idx + {{(SET_W-1){1'b0}}, 1'b1};   // 下次牺牲路（+1 轮转）

  // 本拍真正写阵列？—— XIP 行 / 总线错误行 / 被 fence.i 打断的行都不写
  wire fill_now = (state_q == S_FILL) && axi_rsp_valid && !fill_kill_q &&
                  !(invalidate && mem_taken_q) && CACHE_ON &&
                  !(fill_xip_q | `IS_SPI_XIP(fill_addr_q)) && !axi_rsp_err;

  assign req_ready     = (state_q == S_IDLE);
  assign axi_rsp_ready = (state_q == S_FILL);   // 收到即接收（整行 32 B 一次给全）

  assign dbg_alloc_wen  = fill_now;
  assign dbg_alloc_addr = fill_addr_q;
  assign dbg_hit        = hit;
  assign dbg_hit_way    = hit_way;
  assign dbg_set        = lk_set;

  //-----------------------------------------------------------------------------
  // 时序
  //-----------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      valid_q       <= {ENT{1'b0}};
      rr_q          <= {(SETS*SET_W){1'b0}};
      state_q       <= S_IDLE;
      set_q         <= 7'd0;
      tag_q         <= 20'd0;
      fill_addr_q   <= 32'd0;
      fill_xip_q    <= 1'b0;
      fill_kill_q   <= 1'b0;
      mem_taken_q   <= 1'b0;
      rsp_valid     <= 1'b0;
      rsp_data      <= 256'd0;
      rsp_err       <= 1'b0;
      axi_req_valid <= 1'b0;
      axi_req_addr  <= 32'd0;
      perf_access   <= 32'd0;
      perf_hit      <= 32'd0;
      perf_miss     <= 32'd0;
    end else begin
      // 1) fence.i：整表失效（1 拍；valid_q 是一整条寄存器，非逐组扫描）
      if (invalidate) valid_q <= {ENT{1'b0}};

      // 2) 在途填充归属跟踪（用于"被 fence.i 打断 ⇒ 丢弃重发"）
      if (axi_req_valid && axi_req_ready) mem_taken_q <= 1'b1;
      if (axi_rsp_valid && axi_rsp_ready) mem_taken_q <= 1'b0;
      // 已交付给主设备（AR 之前在途）的读被 fence.i 打断 ⇒ 该笔数据可能过期
      if (invalidate && mem_taken_q) fill_kill_q <= 1'b1;

      // 3) 响应被取走
      if (rsp_valid && rsp_ready) rsp_valid <= 1'b0;

      case (state_q)
        //---------------------------------------------------------------------
        S_IDLE: begin
          if (req_valid && req_ready) begin
            perf_access <= perf_access + 32'd1;
            if (hit) begin
              // 命中：下一拍给整行（同步读 1 拍，规格 §4.3 ①）
              perf_hit  <= perf_hit + 32'd1;
              state_q   <= S_RESP;
              rsp_valid <= 1'b1;
              rsp_data  <= hit_data;
              rsp_err   <= 1'b0;
            end else begin
              // 缺失（或 XIP 绕行 / ENABLE=0 直通）：发 AXI 行读
              perf_miss     <= perf_miss + 32'd1;
              state_q       <= S_FILL;
              axi_req_valid <= 1'b1;
              axi_req_addr  <= req_line;
              fill_addr_q   <= req_line;
              fill_xip_q    <= req_bypass;
              fill_kill_q   <= 1'b0;      // 本笔读在失效之后才发出 ⇒ 数据必然最新
              mem_taken_q   <= 1'b0;
              set_q         <= lk_set;
              tag_q         <= lk_tag;
            end
          end
        end
        //---------------------------------------------------------------------
        S_FILL: begin
          if (axi_req_valid && axi_req_ready) axi_req_valid <= 1'b0;
          if (axi_rsp_valid) begin
            if (fill_kill_q || (invalidate && mem_taken_q)) begin
              // 该笔读早于 fence.i ⇒ 可能读到旧指令：丢弃，同址重发（新读发生在失效之后）
              fill_kill_q   <= 1'b0;
              mem_taken_q   <= 1'b0;
              axi_req_valid <= 1'b1;    // 地址不变（axi_req_addr 保持）
            end else begin
              if (fill_now) begin
                // 填充：RR 牺牲路；XIP / 总线错误 / ENABLE=0 已在 fill_now 里排除
                tag_mem[{set_q, vic_way}] <= tag_q;
                line_mem[{set_q, vic_way}] <= axi_rsp_data;
                valid_q[{set_q, 2'b00} +: WAYS] <=
                    valid_q[{set_q, 2'b00} +: WAYS] | (4'b0001 << vic_way);
                rr_q[set_q * SET_W +: SET_W] <= rr_nxt;
              end
              state_q   <= S_RESP;
              rsp_valid <= 1'b1;
              rsp_data  <= axi_rsp_data;
              rsp_err   <= axi_rsp_err;
            end
          end
        end
        //---------------------------------------------------------------------
        S_RESP: if (rsp_valid && rsp_ready) state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
