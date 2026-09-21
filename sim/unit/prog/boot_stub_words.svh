// ==== 自动生成（**不要手改**）================================================
// 生成器 : sw/boot/check_stub_layout.sh --update-sim-words
// 源     : sw/boot/boot_stub.S（同一份桩源码，段长用 --defsym 换成仿真小值）
//          + sim/unit/prog/boot_stub_probe.S（TB 的迷你 OpenSBI 占位程序）
// 布局常量取自**汇编后 ELF 的符号表**（nm）⇒ 桩源码一改、重跑生成器，
// 本文件随之变化，tb_boot_stub 立刻跟着变（改错常量 ⇒ TB 必红）。
//   · 桩镜像 32 字（逐字和 0x2B912E65，首字 32'h00000717）
//   · 占位程序 11 字（逐字和 0x68859469）
// 期望用途：TB `include 本文件后调用 load_boot_stub_words() 填 Flash 模型，
//          用 boot_sim_probe_word(i) 取占位程序字（同时作为 DDR 期望值）。
//=============================================================================

localparam integer BOOT_SIM_SEG_COUNT   = 3;
localparam [31:0]  BOOT_SIM_FLASH_BASE  = 32'h1C000000;
localparam [31:0]  BOOT_SIM_XIP_SIZE    = 32'h00100000;
localparam integer BOOT_SIM_SRC_OPENSBI = 32'h00004000;
localparam integer BOOT_SIM_LEN_OPENSBI = 32'h00001000;
localparam [31:0]  BOOT_SIM_DST_OPENSBI = 32'h01000000;
localparam integer BOOT_SIM_SRC_UBOOT   = 32'h00080000;
localparam integer BOOT_SIM_LEN_UBOOT   = 32'h00002000;
localparam [31:0]  BOOT_SIM_DST_UBOOT   = 32'h02000000;
localparam integer BOOT_SIM_SRC_DTB     = 32'h000E8000;
localparam integer BOOT_SIM_LEN_DTB     = 32'h00000400;
localparam [31:0]  BOOT_SIM_DST_DTB     = 32'h03000000;
localparam [31:0]  BOOT_SIM_NEXT_ENTRY  = 32'h01000000;
localparam [31:0]  BOOT_SIM_FDT_DST     = 32'h03000000;
localparam integer BOOT_SIM_HARTID      = 0;
localparam integer BOOT_SIM_STUB_WORDS  = 32;
localparam [31:0]  BOOT_SIM_STUB_SUM    = 32'h2B912E65;
localparam [31:0]  BOOT_SIM_STUB_W0     = 32'h00000717;
localparam [31:0]  BOOT_SIM_STUB_WLAST  = 32'h00000400;
localparam integer BOOT_SIM_PROBE_WORDS = 11;
localparam [31:0]  BOOT_SIM_PROBE_SUM   = 32'h68859469;
localparam [31:0]  BOOT_SIM_PROBE_MBOX  = 32'h00800000;
localparam [31:0]  BOOT_SIM_PROBE_MAGIC = 32'hB007A5A5;
localparam [31:0]  BOOT_SIM_PROBE_SIG   = 32'h5A5AB007;

// 把桩镜像逐字写进 TB 侧 Flash 模型（flash[] 必须在 `include 之前声明）
task automatic load_boot_stub_words;
    begin
        flash[   0] = 32'h00000717; flash[   1] = 32'h05C70713; flash[   2] = 32'h1C000E37; flash[   3] = 32'h00300793;
        flash[   4] = 32'h00072283; flash[   5] = 32'h00472303; flash[   6] = 32'h00872383; flash[   7] = 32'h00C70713;
        flash[   8] = 32'h01C282B3; flash[   9] = 32'h0002AE83; flash[  10] = 32'h01D32023; flash[  11] = 32'h00428293;
        flash[  12] = 32'h00430313; flash[  13] = 32'hFFC38393; flash[  14] = 32'hFE0396E3; flash[  15] = 32'hFFF78793;
        flash[  16] = 32'hFC0798E3; flash[  17] = 32'h00000513; flash[  18] = 32'h030005B7; flash[  19] = 32'h00000613;
        flash[  20] = 32'h010002B7; flash[  21] = 32'h00028067; flash[  22] = 32'h0000006F; flash[  23] = 32'h00004000;
        flash[  24] = 32'h01000000; flash[  25] = 32'h00001000; flash[  26] = 32'h00080000; flash[  27] = 32'h02000000;
        flash[  28] = 32'h00002000; flash[  29] = 32'h000E8000; flash[  30] = 32'h03000000; flash[  31] = 32'h00000400;
    end
endtask

// 占位程序第 i 个字（0 ≤ i < BOOT_SIM_PROBE_WORDS；越界返回 NOP）
function [31:0] boot_sim_probe_word;
    input integer i;
    begin
        case (i)
               0: boot_sim_probe_word = 32'h008002B7;
               1: boot_sim_probe_word = 32'h00A2A023;
               2: boot_sim_probe_word = 32'h00B2A223;
               3: boot_sim_probe_word = 32'h00C2A423;
               4: boot_sim_probe_word = 32'hB007A337;
               5: boot_sim_probe_word = 32'h5A530313;
               6: boot_sim_probe_word = 32'h0062A623;
               7: boot_sim_probe_word = 32'h5A5AB337;
               8: boot_sim_probe_word = 32'h00730313;
               9: boot_sim_probe_word = 32'h0062A823;
              10: boot_sim_probe_word = 32'h0000006F;
            default: boot_sim_probe_word = 32'h0000_0013;
        endcase
    end
endfunction

