//==============================================================================
// sim/unit/tb_m3_ddr3.sv —— M3 里程碑「DDR3 裸机内存测试」core_top 级自包含 TB
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
// 顶层名: tb_m3_ddr3（scripts/regress.sh 自动发现 sim/unit/tb_*.sv 后用 -s 指定）
// 依据  : docs/design/08-baseline-5stage.md §8.4（裸机内存测试：DDR3 0x0 起、
//         模式集 00/FF/55/AA + 地址相关 + 每 4 KB 页首/页尾、显式计数判定）、
//         §8.5（反证实验：关掉 XIP 直连旁路 ⇒ 必红；关掉核内 MMIO 截获 ⇒ 必红）、
//         §5.4（LSU/访存：DDR3 走 ROUTE_AXI 单 beat）、§6.6（CLINT/PLIC 核内截获
//         —— 不截获即"静默数据损坏"：写 mtimecmp 会改掉 DDR3 默认设备内容）、
//         AGENT.md §0.6（未捕获即失败）、§3.2（变异测试纪律）
// 程序  : sim/unit/prog/ddr3_memtest.S（真源；TB 内嵌字数组与该文件逐条一致）
//
//------------------------------------------------------------------------------
// 一、这个 TB 测什么（三件事 + 一条硬件交叉核对）
//------------------------------------------------------------------------------
//   ① DDR3 裸机遍历（08 §8.4）：程序对**缩减窗口**做全遍历，7 个模式：
//        0x0000_0000 / 0xFFFF_FFFF / 0x5555_5555 / 0xAAAA_AAAA / 地址相关
//        0xA5A5_0000|addr[15:0] / 每 4 KB 页首页尾 / 字节·半字（wstrb+符号扩展）
//      逐模式显式计数（写/读/错），TB 逐项核对并打印计数表 ⇒ 漏判即失败。
//   ② XIP 直连旁路反证（08 §8.4 判据②）：程序从 0x1C00_0000 取指启动，并调用
//      驻留 Flash（XIP 窗口）的子程序；子程序首字是"可变指令"，TB 在运行中
//      （程序写邮箱后）把它从 addi a1,x0,0x111 **改成** addi a1,x0,0x222；
//      第二遍执行**必须**看到新内容 ⇒ 证明 XIP 取指绕过 I-Cache。
//   ③ 核内 MMIO 截获反证（08 §8.4 判据③/§8.5）：程序在 DDR3 探针地址（=
//      CLINT 寄存器的别名地址）写值并读回 → 写 CLINT 窗口 0x1F00_4000/
//      0x1F00_4004/0x1F00_0000 → 读回 CLINT（正向证据）→ 再读 DDR3 探针；
//      **前后必须逐字不变**，且 AXI 上**不得出现任何 CLINT/PLIC 地址的事务**。
//   ④ 软硬件交叉核对：TB 在 AXI 上按地址区间统计事务数，与程序自报的软计数
//      逐项相等（软件说访问了多少次，总线就必须恰好出现多少笔）。
//
//------------------------------------------------------------------------------
// 二、结构（自包含：不依赖 sim/tb/*、不依赖外部 hex/脚本/cwd）
//------------------------------------------------------------------------------
//   tb_m3_ddr3
//     ├── u_dut : rtl/top/core_top.v（48 端口逐字契约；rtl 只读）
//     └── 本文件内置 AXI4 从设备 + 三个存储体/窗口：
//           · flash[0:1023]  0x1C00_0000（4 KiB）： .boot 复位桩 + XIP 子程序
//                            （含"可变指令"@+0x40，TB 运行中改写）
//           · ram  [0:2 MiB/4] 0x0000_0000（2 MiB）： DDR3 默认从设备（平台
//                            128 MiB 的低位片段）+ 主程序 + 结果区 + TB 邮箱
//           · CLINT/PLIC 窗口：**平台默认从设备混叠**建模（写 0x1F00_xxxx 会像
//                            平台上一样落到 DDR3 低位地址）—— 这正是"不截获即
//                            静默数据损坏"的可观测后果；同时单独计数为违规。
//
//------------------------------------------------------------------------------
// 三、内存布局（程序真源 ddr3_memtest.S §二 的镜像）
//------------------------------------------------------------------------------
//   Flash/XIP 0x1C00_0000 : +0x00 复位桩（lui+jalr 跳 DDR3）  +0x40 XIP 子程序
//   DDR3 0x0000_0000      : +0 .. +16 KiB   模式遍历窗口（M0..M4 全遍历）
//                           +0 .. +1 MiB    4 KB 页首/页尾专项覆盖区（M5）
//                           +0x3C00..+0x4000 字节/半字专项区（M6）
//                           +0x4000/+0x4004/+0xBFF8  CLINT 别名探针
//   0x0010_0000           : 主程序 .main        0x0018_0000 : 结果区（+0x100 MAGIC）
//   0x001F_FF00           : TB 邮箱（写 1 ⇒ TB 改写 Flash 可变字）
//   ★ 板级口径 = 0x0 起 128 MiB 全遍历；此处为**仿真缩减窗口**（iverilog 实测
//     ≈4.0–4.6 k 拍/秒（本机实测，取决于访存密度）⇒ 128 MiB 全遍历需数百小时量级）
//     ——缩减的是窗口大小，不是模式集。
//
//------------------------------------------------------------------------------
// 四、判据（全部 fail-closed；任一不满足 ⇒ 打印含 FAIL 的行 + $fatal，rc≠0）
//------------------------------------------------------------------------------
//   C0  映像自检：boot[0]/boot[16]/main[0]/main[末字] 与反汇编一致；非零字足量
//   C1  复位后**首笔 AXI 读地址 = 0x1C00_0000**（程序确实从 XIP 取指启动）
//   C2  TIMEOUT_CYCLES 内见到完成标志 MAGIC（程序跑到终点；超时 ⇒ FAIL）
//   C3  程序自报窗口字数 == TB 参数 WINDOW_WORDS（两侧口径不许分叉）
//   C4  XIP：两个 pass 的结果分别 == 0x111 / 0x222，XIP_OK==1；且 TB 确实
//       改写过 Flash（未改写 ⇒ 测试空跑 ⇒ FAIL）
//   C5  7 个模式的 {写,读,错} 计数逐项 == 期望（错数必须 0；写/读数不符即 FAIL）
//   C6  全局合计 {写,读,错} == 期望合计；首个错例记录必须为空
//   C7  AXI 交叉核对：TB 统计的 DDR3 区（[0,1 MiB)）AR/AW 事务数 == 程序软计数
//       + 探针访问数（软件计数必须与总线行为一致）
//   C8  核内截获：AXI 上 CLINT/PLIC 窗口的事务数必须 == 0（"绝不发 AXI"）
//   C9  探针不变：写 CLINT 前后的 DDR3 探针逐字相等（CLINT 写没落到默认从设备）
//   C10 CLINT 正向证据：mtimecmp 低/高字与 msip 都能写进去并原样读回
//   C11 未登记地址访问数 == 0
//   ★ 唯一成功行 = TB_M3_DDR3: PASS（整行，恰好一次）；失败路径只打印含 FAIL 的行
//
//------------------------------------------------------------------------------
// 五、反证开关（默认 0 = 正常回归口径；开开关后**必须** FAIL，08 §8.5）
//------------------------------------------------------------------------------
//   DISABLE_XIP_BYPASS=1     : force 掉 XIP 直连旁路的**两处判定**（取指侧
//                              fetch_unit.uncached + L1I 内部 l1i.xip_bypass，
//                              后者使 L1I 拒绝服务 XIP 地址）⇒ XIP 取指真的走
//                              L1I ⇒ 第二遍命中陈旧行（0x111 版）⇒ C4 必红。
//                              （只关前者会死锁，见 §五 说明）
//   DISABLE_MMIO_INTERCEPT=1 : force 掉 lsu 内 mmio_route 的 CLINT 命中判定
//                              ⇒ CLINT 访问落 AXI/默认从设备 ⇒ C8/C9 必红。
//   DISABLE_FLASH_MUTATION=1 : TB 侧**不改写** Flash 可变字（自检开关：证明
//                              "C4 依赖这次改写"，不改写时 C4 必红）。
//   复现命令（从仓库根；$R = rtl 源集合，见 scripts/regress.sh）：
//     R="$(find rtl -name '*.v' | sort)"
//     iverilog -g2012 -I rtl/pkg -I . -s tb_m3_ddr3 -o /tmp/m3.vvp $R sim/unit/tb_m3_ddr3.sv
//     vvp /tmp/m3.vvp                                          # 正常 ⇒ 唯一成功行
//     vvp /tmp/m3.vvp +DISABLE_XIP_BYPASS=1                    # 反证①（XIP 旁路关）
//     vvp /tmp/m3.vvp +DISABLE_MMIO_INTERCEPT=1                # 反证②（MMIO 截获关）
//     vvp /tmp/m3.vvp +DISABLE_FLASH_MUTATION=1                # 自检（TB 不改 Flash）
//   ★ 两种开关方式**等价**（都支持，任一为 1 即生效）：
//       ① vvp 运行期 plusarg ： vvp <vvp> +DISABLE_XIP_BYPASS=1
//       ② iverilog 编译期参数： iverilog … -P tb_m3_ddr3.DISABLE_XIP_BYPASS=1 …
//   ★ 参数名里含 "BY"+"PASS" 字样 ⇒ **禁止**把参数名打进仿真输出（regress.sh 的
//     "成功标记出现次数 == 1"判据是按字面统计的），本例只打印中文标签。
//
//------------------------------------------------------------------------------
// 六、风格/红线
//------------------------------------------------------------------------------
//   · TESTBENCH（不可综合）：存储体/AXI 从设备/变异开关用 always/force 建模是必需；
//   · 无 FPGA 原语、无 Vivado IP 依赖 ⇒ iverilog 回归自洽（AGENT.md §4 红线 1/2）；
//   · 本文件的 AXI 逻辑是**从设备行为模型（验证件）**，不是设计侧代码
//     （红线 4 的边界判据针对可综合 RTL，见 08 §7.1）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_m3_ddr3 #(
    // ---- 时钟/复位 ----
    parameter integer CLK_HALF_NS        = 5,        // 半周期 5 ns ⇒ 10 ns
    parameter integer RESET_CYCLES       = 20,       // 复位保持拍数
    // ---- 判定参数 ----
    // 超时拍数：实测程序 808347 拍跑完（本机 iverilog 实测 ≈4.0–4.6 k 拍/秒 ⇒ 约 178–203 s）；
    //   取 1.2e6 拍（≈1.5 倍余量）：即使程序挂死，超时判定也在 ~260-300 s 内落到 $fatal，
    //   不依赖 scripts/regress.sh 的 TB_TIMEOUT=300 s 兜底（fail-closed）
    parameter integer TIMEOUT_CYCLES     = 1200000,
    parameter integer DIAG_PERIOD        = 100000,   // 进度打印周期（诊断）
    // ---- 窗口口径（★ 必须与 sim/unit/prog/ddr3_memtest.S 的 .equ 一致；
    //      C3 会核对程序自报值 ⇒ 两侧分叉必红）----
    parameter integer WINDOW_WORDS       = 4096,     // 模式遍历窗口 = 16 KiB
    parameter integer PAGE_REGION_WORDS  = 262144,   // 页专项覆盖区 = 1 MiB（256 页）
    parameter integer SUB_WORDS          = 256,      // 字节/半字专项 = 1 KiB
    parameter integer PAGES              = PAGE_REGION_WORDS/1024,  // 页数（1 MiB ⇒ 256）
    // ---- DDR3 模型大小（平台 128 MiB 的低位片段）----
    parameter integer DRAM_WORDS         = 524288,   // 2 MiB
    parameter integer FLASH_WORDS        = 1024,     // 4 KiB
    // ---- 反证开关（§五；默认 0 = 正常回归口径）----
    parameter integer DISABLE_XIP_BYPASS    = 0,
    parameter integer DISABLE_MMIO_INTERCEPT= 0,
    parameter integer DISABLE_FLASH_MUTATION = 0
) ();

    //==========================================================================
    // 0. 地址/期望值常量
    //==========================================================================
    localparam [31:0] FLASH_BASE   = `RV32GC_XIP_BASE;        // 0x1C00_0000
    localparam [31:0] XIP_ENTRY    = 32'h1C00_0040;           // XIP 子程序入口
    localparam integer MUT_WORD_IDX= 16;                      // = 0x40/4（32 B 行首）
    localparam [31:0] MUT_INSN_OLD = 32'h1110_0593;           // addi a1,x0,0x111
    localparam [31:0] MUT_INSN_NEW = 32'h2220_0593;           // addi a1,x0,0x222
    localparam [31:0] BOOT_W0      = 32'h0010_02B7;           // lui t0,0x00100
    localparam [31:0] MAIN_BASE    = 32'h0010_0000;           // .main
    localparam [31:0] MAIN_W0      = 32'h0018_0C37;           // lui s8,0x180
    localparam [31:0] MAIN_WLAST   = 32'h0000_8067;           // ret（rec_err 末字）
    localparam [31:0] RES_BASE     = 32'h0018_0000;           // 结果区
    localparam [31:0] MAILBOX      = 32'h001F_FF00;           // TB 邮箱
    localparam [31:0] DDR_MASK     = DRAM_WORDS*4 - 1;        // 混叠掩码（2 MiB-1）
    localparam [31:0] PAGE_REGION_BYTES = PAGE_REGION_WORDS*4;// 1 MiB
    localparam [31:0] WIN_BYTES    = WINDOW_WORDS*4;          // 16 KiB
    // CLINT/PLIC 窗口
    localparam [31:0] CLINT_BASE   = `RV32GC_CLINT_BASE;
    localparam [31:0] CLINT_LIMIT  = `RV32GC_CLINT_BASE + `RV32GC_CLINT_SIZE;
    localparam [31:0] PLIC_LO      = `RV32GC_PLIC_HIT_LO;
    localparam [31:0] PLIC_HI      = `RV32GC_PLIC_HIT_HI;
    // 结果区字段偏移（与 .S §三 一一对应）
    localparam [31:0] R_WINWORDS=32'h00, R_XIP1=32'h04, R_XIP2=32'h08, R_XIP_OK=32'h0C,
                       R_TOTW=32'h10, R_TOTR=32'h14, R_TOTE=32'h18, R_MODETAB=32'h20,
                       R_FE_ADDR=32'h80, R_FE_EXP=32'h84, R_FE_ACT=32'h88,
                       R_FE_MODE=32'h8C, R_PB0=32'h90, R_PB1=32'h94, R_PB2=32'h98,
                       R_PA0=32'h9C, R_PA1=32'hA0, R_PA2=32'hA4, R_CLO=32'hA8,
                       R_CHI=32'hAC, R_CMSIP=32'hB0, R_CLINT_OK=32'hB4, R_MAGIC=32'h100;
    localparam [31:0] MAGIC_VAL = 32'h5A5A_A5A5;
    localparam [31:0] XIP_V1 = 32'h0000_0111, XIP_V2 = 32'h0000_0222;
    localparam [31:0] P0_VAL = 32'h5A5A_1111, P1_VAL = 32'h5A5A_2222,
                      P2_VAL = 32'h5A5A_3333;
    localparam [31:0] CM_LO = 32'hDEAD_BEEF, CM_HI = 32'h0BAD_F00D, MSIP_VAL = 32'd1;
    localparam [31:0] RESP_OKAY = `RV32GC_AXI_RESP_OKAY;
    // 各模式访问次数期望（与 .S 的循环结构严格对应）
    localparam integer E_M0W = WINDOW_WORDS, E_M0R = WINDOW_WORDS,   // 0x00
                       E_M1W = WINDOW_WORDS, E_M1R = WINDOW_WORDS,   // 0xFF
                       E_M2W = WINDOW_WORDS, E_M2R = WINDOW_WORDS,   // 0x55
                       E_M3W = WINDOW_WORDS, E_M3R = WINDOW_WORDS,   // 0xAA
                       E_M4W = WINDOW_WORDS, E_M4R = WINDOW_WORDS,   // 地址相关
                       E_M5W = 2*PAGES,      E_M5R = 2*PAGES,        // 页首/页尾
                       E_M6W = SUB_WORDS + 4*SUB_WORDS,              // 清零 + 4×sb
                       E_M6R = 5*SUB_WORDS;                          // 5 个读回 pass
    localparam integer E_TOTW = E_M0W+E_M1W+E_M2W+E_M3W+E_M4W+E_M5W+E_M6W;
    localparam integer E_TOTR = E_M0R+E_M1R+E_M2R+E_M3R+E_M4R+E_M5R+E_M6R;
    localparam integer PROBE_WR = 3, PROBE_RD = 6;   // CLINT 探针：3 写 + 3+3 读
    //   ★ 遍历窗口 [0,WIN_BYTES) 内的访问还包含 M5 页专项落在窗口前几页上的
    //     页首/页尾（= 2 字 × 窗口内页数）——M0..M4/M6 全在窗口内，M5 跨全 1 MiB。
    localparam integer E_WIN_PAGES = WIN_BYTES/4096;
    localparam integer E_M5W_WIN   = 2*E_WIN_PAGES;
    localparam integer E_WINW = E_M0W+E_M1W+E_M2W+E_M3W+E_M4W+E_M6W+E_M5W_WIN;
    localparam integer E_WINR = E_M0R+E_M1R+E_M2R+E_M3R+E_M4R+E_M6R+E_M5W_WIN;

    //==========================================================================
    // 1. 程序映像（真源 = sim/unit/prog/ddr3_memtest.S；两侧逐字一致）
    //==========================================================================
    localparam integer BOOT_LEN = 32;
    localparam integer MAIN_LEN = 431;

    reg [31:0] boot_prog [0:BOOT_LEN-1];
    reg [31:0] main_prog [0:MAIN_LEN-1];
    initial begin
    // ---- .boot（Flash/XIP 窗口 0x1C00_0000；32 字 = 128 B）----
        boot_prog[ 0] = 32'h001002b7; boot_prog[ 1] = 32'h00028067; boot_prog[ 2] = 32'h00000000; boot_prog[ 3] = 32'h00000000;
        boot_prog[ 4] = 32'h00000000; boot_prog[ 5] = 32'h00000000; boot_prog[ 6] = 32'h00000000; boot_prog[ 7] = 32'h00000000;
        boot_prog[ 8] = 32'h00000000; boot_prog[ 9] = 32'h00000000; boot_prog[10] = 32'h00000000; boot_prog[11] = 32'h00000000;
        boot_prog[12] = 32'h00000000; boot_prog[13] = 32'h00000000; boot_prog[14] = 32'h00000000; boot_prog[15] = 32'h00000000;
        boot_prog[16] = 32'h11100593; boot_prog[17] = 32'h00b6a023; boot_prog[18] = 32'h00468693; boot_prog[19] = 32'h00170713;
        boot_prog[20] = 32'h00100313; boot_prog[21] = 32'h00670463; boot_prog[22] = 32'h00008067; boot_prog[23] = 32'h002003b7;
        boot_prog[24] = 32'hf0038393; boot_prog[25] = 32'h0063a023; boot_prog[26] = 32'h01000e13; boot_prog[27] = 32'hfffe0e13;
        boot_prog[28] = 32'hfe0e1ee3; boot_prog[29] = 32'h1c0002b7; boot_prog[30] = 32'h04028293; boot_prog[31] = 32'h00028067;

    // ---- .main（DDR3 0x0010_0000；431 字 = 1724 B）----
        main_prog[  0] = 32'h00180c37; main_prog[  1] = 32'h00180bb7; main_prog[  2] = 32'h020b8b93; main_prog[  3] = 32'h00180537;
        main_prog[  4] = 32'h001805b7; main_prog[  5] = 32'h14058593; main_prog[  6] = 32'h00052023; main_prog[  7] = 32'h00450513;
        main_prog[  8] = 32'hfeb54ce3; main_prog[  9] = 32'h000012b7; main_prog[ 10] = 32'h005c2023; main_prog[ 11] = 32'h00000413;
        main_prog[ 12] = 32'h00000493; main_prog[ 13] = 32'h00000913; main_prog[ 14] = 32'h001806b7; main_prog[ 15] = 32'h00468693;
        main_prog[ 16] = 32'h00000713; main_prog[ 17] = 32'h1c0002b7; main_prog[ 18] = 32'h04028293; main_prog[ 19] = 32'h000280e7;
        main_prog[ 20] = 32'h11100313; main_prog[ 21] = 32'h004c2383; main_prog[ 22] = 32'h008c2e03; main_prog[ 23] = 32'h22200e93;
        main_prog[ 24] = 32'h00000f13; main_prog[ 25] = 32'h00639663; main_prog[ 26] = 32'h01de1463; main_prog[ 27] = 32'h00100f13;
        main_prog[ 28] = 32'h01ec2623; main_prog[ 29] = 32'h00000b13; main_prog[ 30] = 32'h00000993; main_prog[ 31] = 32'h00000a13;
        main_prog[ 32] = 32'h00000a93; main_prog[ 33] = 32'h000045b7; main_prog[ 34] = 32'h00000793; main_prog[ 35] = 32'h00000513;
        main_prog[ 36] = 32'h00f52023; main_prog[ 37] = 32'h00f52223; main_prog[ 38] = 32'h00f52423; main_prog[ 39] = 32'h00f52623;
        main_prog[ 40] = 32'h01050513; main_prog[ 41] = 32'h00498993; main_prog[ 42] = 32'hfeb544e3; main_prog[ 43] = 32'h00000513;
        main_prog[ 44] = 32'h00052803; main_prog[ 45] = 32'h001a0a13; main_prog[ 46] = 32'h00f80663; main_prog[ 47] = 32'h00050893;
        main_prog[ 48] = 32'h5dc000ef; main_prog[ 49] = 32'h00450513; main_prog[ 50] = 32'hfeb544e3; main_prog[ 51] = 32'h013ba023;
        main_prog[ 52] = 32'h014ba223; main_prog[ 53] = 32'h015ba423; main_prog[ 54] = 32'h00cb8b93; main_prog[ 55] = 32'h01340433;
        main_prog[ 56] = 32'h014484b3; main_prog[ 57] = 32'h01590933; main_prog[ 58] = 32'h00100b13; main_prog[ 59] = 32'h00000993;
        main_prog[ 60] = 32'h00000a13; main_prog[ 61] = 32'h00000a93; main_prog[ 62] = 32'h000045b7; main_prog[ 63] = 32'hfff00793;
        main_prog[ 64] = 32'h00000513; main_prog[ 65] = 32'h00f52023; main_prog[ 66] = 32'h00f52223; main_prog[ 67] = 32'h00f52423;
        main_prog[ 68] = 32'h00f52623; main_prog[ 69] = 32'h01050513; main_prog[ 70] = 32'h00498993; main_prog[ 71] = 32'hfeb544e3;
        main_prog[ 72] = 32'h00000513; main_prog[ 73] = 32'h00052803; main_prog[ 74] = 32'h001a0a13; main_prog[ 75] = 32'h00f80663;
        main_prog[ 76] = 32'h00050893; main_prog[ 77] = 32'h568000ef; main_prog[ 78] = 32'h00450513; main_prog[ 79] = 32'hfeb544e3;
        main_prog[ 80] = 32'h013ba023; main_prog[ 81] = 32'h014ba223; main_prog[ 82] = 32'h015ba423; main_prog[ 83] = 32'h00cb8b93;
        main_prog[ 84] = 32'h01340433; main_prog[ 85] = 32'h014484b3; main_prog[ 86] = 32'h01590933; main_prog[ 87] = 32'h00200b13;
        main_prog[ 88] = 32'h00000993; main_prog[ 89] = 32'h00000a13; main_prog[ 90] = 32'h00000a93; main_prog[ 91] = 32'h000045b7;
        main_prog[ 92] = 32'h555557b7; main_prog[ 93] = 32'h55578793; main_prog[ 94] = 32'h00000513; main_prog[ 95] = 32'h00f52023;
        main_prog[ 96] = 32'h00f52223; main_prog[ 97] = 32'h00f52423; main_prog[ 98] = 32'h00f52623; main_prog[ 99] = 32'h01050513;
        main_prog[100] = 32'h00498993; main_prog[101] = 32'hfeb544e3; main_prog[102] = 32'h00000513; main_prog[103] = 32'h00052803;
        main_prog[104] = 32'h001a0a13; main_prog[105] = 32'h00f80663; main_prog[106] = 32'h00050893; main_prog[107] = 32'h4f0000ef;
        main_prog[108] = 32'h00450513; main_prog[109] = 32'hfeb544e3; main_prog[110] = 32'h013ba023; main_prog[111] = 32'h014ba223;
        main_prog[112] = 32'h015ba423; main_prog[113] = 32'h00cb8b93; main_prog[114] = 32'h01340433; main_prog[115] = 32'h014484b3;
        main_prog[116] = 32'h01590933; main_prog[117] = 32'h00300b13; main_prog[118] = 32'h00000993; main_prog[119] = 32'h00000a13;
        main_prog[120] = 32'h00000a93; main_prog[121] = 32'h000045b7; main_prog[122] = 32'haaaab7b7; main_prog[123] = 32'haaa78793;
        main_prog[124] = 32'h00000513; main_prog[125] = 32'h00f52023; main_prog[126] = 32'h00f52223; main_prog[127] = 32'h00f52423;
        main_prog[128] = 32'h00f52623; main_prog[129] = 32'h01050513; main_prog[130] = 32'h00498993; main_prog[131] = 32'hfeb544e3;
        main_prog[132] = 32'h00000513; main_prog[133] = 32'h00052803; main_prog[134] = 32'h001a0a13; main_prog[135] = 32'h00f80663;
        main_prog[136] = 32'h00050893; main_prog[137] = 32'h478000ef; main_prog[138] = 32'h00450513; main_prog[139] = 32'hfeb544e3;
        main_prog[140] = 32'h013ba023; main_prog[141] = 32'h014ba223; main_prog[142] = 32'h015ba423; main_prog[143] = 32'h00cb8b93;
        main_prog[144] = 32'h01340433; main_prog[145] = 32'h014484b3; main_prog[146] = 32'h01590933; main_prog[147] = 32'h00400b13;
        main_prog[148] = 32'h00000993; main_prog[149] = 32'h00000a13; main_prog[150] = 32'h00000a93; main_prog[151] = 32'h00000513;
        main_prog[152] = 32'h00010f37; main_prog[153] = 32'h00100f93; main_prog[154] = 32'ha5a507b7; main_prog[155] = 32'h01051e93;
        main_prog[156] = 32'h010ede93; main_prog[157] = 32'h01d7e7b3; main_prog[158] = 32'h01e50eb3; main_prog[159] = 32'h000045b7;
        main_prog[160] = 32'h01d5d463; main_prog[161] = 32'h00058e93; main_prog[162] = 32'h00f52023; main_prog[163] = 32'h00478793;
        main_prog[164] = 32'h00450513; main_prog[165] = 32'h00198993; main_prog[166] = 32'hffd548e3; main_prog[167] = 32'hffff8f93;
        main_prog[168] = 32'hfc0f94e3; main_prog[169] = 32'h00000513; main_prog[170] = 32'h00100f93; main_prog[171] = 32'ha5a507b7;
        main_prog[172] = 32'h01051e93; main_prog[173] = 32'h010ede93; main_prog[174] = 32'h01d7e7b3; main_prog[175] = 32'h01e50eb3;
        main_prog[176] = 32'h000045b7; main_prog[177] = 32'h01d5d463; main_prog[178] = 32'h00058e93; main_prog[179] = 32'h00052803;
        main_prog[180] = 32'h001a0a13; main_prog[181] = 32'h00f80663; main_prog[182] = 32'h00050893; main_prog[183] = 32'h3c0000ef;
        main_prog[184] = 32'h00478793; main_prog[185] = 32'h00450513; main_prog[186] = 32'hffd542e3; main_prog[187] = 32'hffff8f93;
        main_prog[188] = 32'hfa0f9ee3; main_prog[189] = 32'h013ba023; main_prog[190] = 32'h014ba223; main_prog[191] = 32'h015ba423;
        main_prog[192] = 32'h00cb8b93; main_prog[193] = 32'h01340433; main_prog[194] = 32'h014484b3; main_prog[195] = 32'h01590933;
        main_prog[196] = 32'h00500b13; main_prog[197] = 32'h00000993; main_prog[198] = 32'h00000a13; main_prog[199] = 32'h00000a93;
        main_prog[200] = 32'h10000593; main_prog[201] = 32'h00001f37; main_prog[202] = 32'h00000513; main_prog[203] = 32'h00000613;
        main_prog[204] = 32'ha5a507b7; main_prog[205] = 32'h00c7e7b3; main_prog[206] = 32'h00f52023; main_prog[207] = 32'h00198993;
        main_prog[208] = 32'hfff7c813; main_prog[209] = 32'h01e50333; main_prog[210] = 32'hff032e23; main_prog[211] = 32'h00198993;
        main_prog[212] = 32'h01e50533; main_prog[213] = 32'h00160613; main_prog[214] = 32'hfcb64ce3; main_prog[215] = 32'h00000513;
        main_prog[216] = 32'h00000613; main_prog[217] = 32'ha5a507b7; main_prog[218] = 32'h00c7e7b3; main_prog[219] = 32'h01e50333;
        main_prog[220] = 32'h00052803; main_prog[221] = 32'h001a0a13; main_prog[222] = 32'h00f80663; main_prog[223] = 32'h00050893;
        main_prog[224] = 32'h31c000ef; main_prog[225] = 32'hfff7c793; main_prog[226] = 32'hffc32803; main_prog[227] = 32'h001a0a13;
        main_prog[228] = 32'h00f80663; main_prog[229] = 32'hffc30893; main_prog[230] = 32'h304000ef; main_prog[231] = 32'h01e50533;
        main_prog[232] = 32'h00160613; main_prog[233] = 32'hfcb640e3; main_prog[234] = 32'h013ba023; main_prog[235] = 32'h014ba223;
        main_prog[236] = 32'h015ba423; main_prog[237] = 32'h00cb8b93; main_prog[238] = 32'h01340433; main_prog[239] = 32'h014484b3;
        main_prog[240] = 32'h01590933; main_prog[241] = 32'h00600b13; main_prog[242] = 32'h00000993; main_prog[243] = 32'h00000a13;
        main_prog[244] = 32'h00000a93; main_prog[245] = 32'h00004537; main_prog[246] = 32'hc0050513; main_prog[247] = 32'h000045b7;
        main_prog[248] = 32'h00052023; main_prog[249] = 32'h00450513; main_prog[250] = 32'h00198993; main_prog[251] = 32'hfeb54ae3;
        main_prog[252] = 32'h01100393; main_prog[253] = 32'h02200e13; main_prog[254] = 32'h03300e93; main_prog[255] = 32'h08400f13;
        main_prog[256] = 32'h00004537; main_prog[257] = 32'hc0050513; main_prog[258] = 32'h00750023; main_prog[259] = 32'h01c500a3;
        main_prog[260] = 32'h01d50123; main_prog[261] = 32'h01e501a3; main_prog[262] = 32'h00450513; main_prog[263] = 32'h00498993;
        main_prog[264] = 32'hfeb544e3; main_prog[265] = 32'h00004537; main_prog[266] = 32'hc0050513; main_prog[267] = 32'h000045b7;
        main_prog[268] = 32'h843327b7; main_prog[269] = 32'h21178793; main_prog[270] = 32'h00052803; main_prog[271] = 32'h001a0a13;
        main_prog[272] = 32'h00f80663; main_prog[273] = 32'h00050893; main_prog[274] = 32'h254000ef; main_prog[275] = 32'h00450513;
        main_prog[276] = 32'hfeb544e3; main_prog[277] = 32'h00004537; main_prog[278] = 32'hc0050513; main_prog[279] = 32'h000045b7;
        main_prog[280] = 32'h02200793; main_prog[281] = 32'h00154803; main_prog[282] = 32'h001a0a13; main_prog[283] = 32'h00f80663;
        main_prog[284] = 32'h00150893; main_prog[285] = 32'h228000ef; main_prog[286] = 32'h00450513; main_prog[287] = 32'hfeb544e3;
        main_prog[288] = 32'h00004537; main_prog[289] = 32'hc0050513; main_prog[290] = 32'h000045b7; main_prog[291] = 32'hf8400793;
        main_prog[292] = 32'h00350803; main_prog[293] = 32'h001a0a13; main_prog[294] = 32'h00f80663; main_prog[295] = 32'h00350893;
        main_prog[296] = 32'h1fc000ef; main_prog[297] = 32'h00450513; main_prog[298] = 32'hfeb544e3; main_prog[299] = 32'h00004537;
        main_prog[300] = 32'hc0050513; main_prog[301] = 32'h000045b7; main_prog[302] = 32'h000087b7; main_prog[303] = 32'h43378793;
        main_prog[304] = 32'h00255803; main_prog[305] = 32'h001a0a13; main_prog[306] = 32'h00f80663; main_prog[307] = 32'h00250893;
        main_prog[308] = 32'h1cc000ef; main_prog[309] = 32'h00450513; main_prog[310] = 32'hfeb544e3; main_prog[311] = 32'h00004537;
        main_prog[312] = 32'hc0050513; main_prog[313] = 32'h000045b7; main_prog[314] = 32'hffff87b7; main_prog[315] = 32'h43378793;
        main_prog[316] = 32'h00251803; main_prog[317] = 32'h001a0a13; main_prog[318] = 32'h00f80663; main_prog[319] = 32'h00250893;
        main_prog[320] = 32'h19c000ef; main_prog[321] = 32'h00450513; main_prog[322] = 32'hfeb544e3; main_prog[323] = 32'h013ba023;
        main_prog[324] = 32'h014ba223; main_prog[325] = 32'h015ba423; main_prog[326] = 32'h00cb8b93; main_prog[327] = 32'h01340433;
        main_prog[328] = 32'h014484b3; main_prog[329] = 32'h01590933; main_prog[330] = 32'h5a5a12b7; main_prog[331] = 32'h11128293;
        main_prog[332] = 32'h00004337; main_prog[333] = 32'h00532023; main_prog[334] = 32'h5a5a22b7; main_prog[335] = 32'h22228293;
        main_prog[336] = 32'h00004337; main_prog[337] = 32'h00430313; main_prog[338] = 32'h00532023; main_prog[339] = 32'h5a5a32b7;
        main_prog[340] = 32'h33328293; main_prog[341] = 32'h0000c337; main_prog[342] = 32'hff830313; main_prog[343] = 32'h00532023;
        main_prog[344] = 32'h00004337; main_prog[345] = 32'h00032383; main_prog[346] = 32'h087c2823; main_prog[347] = 32'h00004337;
        main_prog[348] = 32'h00430313; main_prog[349] = 32'h00032383; main_prog[350] = 32'h087c2a23; main_prog[351] = 32'h0000c337;
        main_prog[352] = 32'hff830313; main_prog[353] = 32'h00032383; main_prog[354] = 32'h087c2c23; main_prog[355] = 32'h1f0042b7;
        main_prog[356] = 32'hdeadce37; main_prog[357] = 32'heefe0e13; main_prog[358] = 32'h01c2a023; main_prog[359] = 32'h1f0042b7;
        main_prog[360] = 32'h00428293; main_prog[361] = 32'h0badfe37; main_prog[362] = 32'h00de0e13; main_prog[363] = 32'h01c2a023;
        main_prog[364] = 32'h1f0002b7; main_prog[365] = 32'h00100e13; main_prog[366] = 32'h01c2a023; main_prog[367] = 32'h1f0042b7;
        main_prog[368] = 32'h0002a383; main_prog[369] = 32'h0a7c2423; main_prog[370] = 32'h1f0042b7; main_prog[371] = 32'h00428293;
        main_prog[372] = 32'h0002a383; main_prog[373] = 32'h0a7c2623; main_prog[374] = 32'h1f0002b7; main_prog[375] = 32'h0002a383;
        main_prog[376] = 32'h0a7c2823; main_prog[377] = 32'h00004337; main_prog[378] = 32'h00032383; main_prog[379] = 32'h087c2e23;
        main_prog[380] = 32'h00004337; main_prog[381] = 32'h00430313; main_prog[382] = 32'h00032383; main_prog[383] = 32'h0a7c2023;
        main_prog[384] = 32'h0000c337; main_prog[385] = 32'hff830313; main_prog[386] = 32'h00032383; main_prog[387] = 32'h0a7c2223;
        main_prog[388] = 32'h00100293; main_prog[389] = 32'h090c2303; main_prog[390] = 32'h09cc2383; main_prog[391] = 32'h00730463;
        main_prog[392] = 32'h00000293; main_prog[393] = 32'h094c2303; main_prog[394] = 32'h0a0c2383; main_prog[395] = 32'h00730463;
        main_prog[396] = 32'h00000293; main_prog[397] = 32'h098c2303; main_prog[398] = 32'h0a4c2383; main_prog[399] = 32'h00730463;
        main_prog[400] = 32'h00000293; main_prog[401] = 32'h0a8c2303; main_prog[402] = 32'hdeadc3b7; main_prog[403] = 32'heef38393;
        main_prog[404] = 32'h00730463; main_prog[405] = 32'h00000293; main_prog[406] = 32'h0acc2303; main_prog[407] = 32'h0badf3b7;
        main_prog[408] = 32'h00d38393; main_prog[409] = 32'h00730463; main_prog[410] = 32'h00000293; main_prog[411] = 32'h0b0c2303;
        main_prog[412] = 32'h00100393; main_prog[413] = 32'h00730463; main_prog[414] = 32'h00000293; main_prog[415] = 32'h0a5c2a23;
        main_prog[416] = 32'h008c2823; main_prog[417] = 32'h009c2a23; main_prog[418] = 32'h012c2c23; main_prog[419] = 32'h5a5aa337;
        main_prog[420] = 32'h5a530313; main_prog[421] = 32'h106c2023; main_prog[422] = 32'h0000006f; main_prog[423] = 32'h00091a63;
        main_prog[424] = 32'h091c2023; main_prog[425] = 32'h08fc2223; main_prog[426] = 32'h090c2423; main_prog[427] = 32'h096c2623;
        main_prog[428] = 32'h00190913; main_prog[429] = 32'h001a8a93; main_prog[430] = 32'h00008067;
    end

    //==========================================================================
    // 2. 时钟 / 复位
    //==========================================================================
    reg clk;
    reg aresetn;

    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    integer rst_cnt;
    initial begin
        aresetn = 1'b0;
        for (rst_cnt = 0; rst_cnt < RESET_CYCLES; rst_cnt = rst_cnt + 1) @(posedge clk);
        @(negedge clk);                    // 负沿释放：避免与 posedge 竞争
        aresetn = 1'b1;
    end

    //==========================================================================
    // 3. DUT ↔ TB 的 AXI4 连线
    //==========================================================================
    wire [3:0]  arid, arlen;
    wire [31:0] araddr;
    wire [2:0]  arsize, arprot;
    wire [1:0]  arburst, arlock;
    wire [3:0]  arcache;
    wire        arvalid, arready;

    wire [3:0]  rid;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rlast, rvalid, rready;

    wire [3:0]  awid, awlen;
    wire [31:0] awaddr;
    wire [2:0]  awsize, awprot;
    wire [1:0]  awburst, awlock;
    wire [3:0]  awcache;
    wire        awvalid, awready;

    wire [3:0]  wid;
    wire [31:0] wdata;
    wire [3:0]  wstrb;
    wire        wlast, wvalid, wready;

    wire [3:0]  bid;
    wire [1:0]  bresp;
    wire        bvalid, bready;

    wire        ws_valid;
    wire [31:0] rf_rdata;
    wire [31:0] debug0_wb_pc;
    wire [3:0]  debug0_wb_rf_wen;
    wire [4:0]  debug0_wb_rf_wnum;
    wire [31:0] debug0_wb_rf_wdata;

    //==========================================================================
    // 4. DUT：rtl/top/core_top.v（48 端口逐字契约，08 §4.1；rtl 只读）
    //==========================================================================
    core_top u_dut (
        .aclk              (clk),
        .intrpt            (8'h00),            // M3 不做中断（CLINT 写不触发：mie=0）
        .aresetn           (aresetn),

        .arid              (arid),
        .araddr            (araddr),
        .arlen             (arlen),
        .arsize            (arsize),
        .arburst           (arburst),
        .arlock            (arlock),
        .arcache           (arcache),
        .arprot            (arprot),
        .arvalid           (arvalid),
        .arready           (arready),

        .rid               (rid),
        .rdata             (rdata),
        .rresp             (rresp),
        .rlast             (rlast),
        .rvalid            (rvalid),
        .rready            (rready),

        .awid              (awid),
        .awaddr            (awaddr),
        .awlen             (awlen),
        .awsize            (awsize),
        .awburst           (awburst),
        .awlock            (awlock),
        .awcache           (awcache),
        .awprot            (awprot),
        .awvalid           (awvalid),
        .awready           (awready),

        .wid               (wid),
        .wdata             (wdata),
        .wstrb             (wstrb),
        .wlast             (wlast),
        .wvalid            (wvalid),
        .wready            (wready),

        .bid               (bid),
        .bresp             (bresp),
        .bvalid            (bvalid),
        .bready            (bready),

        .ws_valid          (ws_valid),
        .break_point       (1'b0),
        .infor_flag        (1'b0),
        .reg_num           (5'd0),
        .rf_rdata          (rf_rdata),
        .debug0_wb_pc      (debug0_wb_pc),
        .debug0_wb_rf_wen  (debug0_wb_rf_wen),
        .debug0_wb_rf_wnum (debug0_wb_rf_wnum),
        .debug0_wb_rf_wdata(debug0_wb_rf_wdata)
    );

    //==========================================================================
    // 5. 存储体与地址译码（DDR3 默认从设备 + Flash + CLINT/PLIC 混叠）
    //==========================================================================
    reg [31:0] flash [0:FLASH_WORDS-1];
    reg [31:0] ram   [0:DRAM_WORDS-1];

    //   Flash 主窗口 PA[31:20]==0x1C0；别名窗口 PA[31:16]==0x1FE8（同一片存储体）
    function is_flash_main;  input [31:0] a;
        begin is_flash_main = (a >= FLASH_BASE) &&
                              (a < FLASH_BASE + 4*FLASH_WORDS); end endfunction
    function is_flash_alias; input [31:0] a;
        begin is_flash_alias = (a[31:16] == `RV32GC_SPI_HIT_VAL); end endfunction
    function is_flash;       input [31:0] a;
        begin is_flash = is_flash_main(a) || is_flash_alias(a); end endfunction
    function is_ram;         input [31:0] a;
        begin is_ram = (a < DRAM_WORDS*4); end endfunction
    function is_clint;       input [31:0] a;
        begin is_clint = (a >= CLINT_BASE) && (a < CLINT_LIMIT); end endfunction
    function is_plic;        input [31:0] a;
        begin is_plic = (a >= PLIC_LO) && (a < PLIC_HI); end endfunction
    // 平台 axi_mux 的默认从设备（addr_hit[0] = ~|addr_hit[4:1]）地址混叠：
    //   0x1F00_xxxx / 0x1F10_xxxx 落到 DDR3 从设备；该从设备只认低位地址
    //   ⇒ 混叠地址 = addr & (128 MiB-1)；TB 只建模低 2 MiB（2 MiB | 128 MiB）
    //   ⇒ 等价于 addr & (DRAM_WORDS*4-1)。这是"不截获即静默数据损坏"的可观测面。
    function [31:0] alias_idx; input [31:0] a;
        begin alias_idx = (a & DDR_MASK) >> 2; end endfunction

    // 组合读：未写过的字节按 0 返回（x 传播会让取指"看似有指令"）
    function [31:0] mem_read;
        input [31:0] a;
        reg [31:0] w;
        begin
            if (is_ram(a))                       w = ram[alias_idx(a)];
            else if (is_flash_main(a))           w = flash[(a - FLASH_BASE) >> 2];
            else if (is_flash_alias(a))          w = flash[((a & 32'h0000_FFFF) >> 2) % FLASH_WORDS];
            else if (is_clint(a) || is_plic(a))  w = ram[alias_idx(a)];   // 默认从设备混叠
            else                                 w = 32'h0000_0000;
            mem_read = { (^w[31:24] === 1'bx) ? 8'h00 : w[31:24],
                         (^w[23:16] === 1'bx) ? 8'h00 : w[23:16],
                         (^w[15: 8] === 1'bx) ? 8'h00 : w[15: 8],
                         (^w[ 7: 0] === 1'bx) ? 8'h00 : w[ 7: 0] };
        end
    endfunction

    // 可观测计数
    reg [31:0] ar_count, aw_count, r_beat_count, w_beat_count;
    reg [31:0] ddr_ar_count, ddr_aw_count;         // [0,1 MiB) 数据区事务
    reg [31:0] win_ar_count, win_aw_count;         // [0,16 KiB) 遍历窗口事务
    reg [31:0] clint_ar_count, clint_aw_count;     // 违规：CLINT 窗口上总线
    reg [31:0] plic_ar_count,  plic_aw_count;      // 违规：PLIC 窗口上总线
    reg [31:0] unknown_rd_count, unknown_wr_count;
    reg [31:0] flash_rd_count;
    reg        first_ar_seen;
    reg [31:0] first_ar_addr;
    reg        flash_mut_seen;
    integer    commit_count;

    // AXI 写：按 wstrb 落字节；CLINT/PLIC 按平台默认从设备混叠；邮箱触发 Flash 改写
    task automatic do_write;
        input [31:0] a;
        input [31:0] d;
        input [3:0]  strb;
        reg [31:0] idx;
        begin
            if (is_ram(a)) begin
                idx = alias_idx(a);
                if (strb[0]) ram[idx][ 7: 0] = d[ 7: 0];
                if (strb[1]) ram[idx][15: 8] = d[15: 8];
                if (strb[2]) ram[idx][23:16] = d[23:16];
                if (strb[3]) ram[idx][31:24] = d[31:24];
            end else if (is_clint(a) || is_plic(a)) begin
                // 平台默认从设备混叠：**这就是静默数据损坏的后果**（见 §二）
                idx = alias_idx(a);
                if (strb[0]) ram[idx][ 7: 0] = d[ 7: 0];
                if (strb[1]) ram[idx][15: 8] = d[15: 8];
                if (strb[2]) ram[idx][23:16] = d[23:16];
                if (strb[3]) ram[idx][31:24] = d[31:24];
                $display("[tb_m3_ddr3] 违规：CLINT/PLIC 写发到 AXI addr=0x%08h data=0x%08h（混叠落 DDR3 0x%08h）",
                         a, d, (a & DDR_MASK));
            end else if (is_flash(a)) begin
                $display("[tb_m3_ddr3] 警告：对 Flash/XIP 窗口的写被忽略 addr=0x%08h", a);
            end else begin
                unknown_wr_count = unknown_wr_count + 1;
                if (unknown_wr_count <= 8)
                    $display("[tb_m3_ddr3] 警告：未登记区域写被忽略 addr=0x%08h data=0x%08h strb=%b",
                             a, d, strb);
            end
            // ---- TB 邮箱：程序写 1 ⇒ 运行中改写 Flash 可变字（XIP 旁路反证的激励）----
            if ((a == MAILBOX) && (d == 32'h1) && !flash_mut_seen) begin
                flash_mut_seen = 1'b1;
                if (!mut_flash_off) begin
                    flash[MUT_WORD_IDX] = MUT_INSN_NEW;
                    $display("[tb_m3_ddr3] TB 邮箱触发：Flash 可变字 @0x%08h 0x%08h -> 0x%08h",
                             XIP_ENTRY, MUT_INSN_OLD, MUT_INSN_NEW);
                end else begin
                    $display("[tb_m3_ddr3] 反证开关 DISABLE_FLASH_MUTATION=1：**不改写** Flash 可变字");
                end
            end
        end
    endtask

    //==========================================================================
    // 6. AXI4 从设备（单笔在途；AR→R 逐拍 INCR 多 beat；AW/W→B；读延迟 1 拍）
    //==========================================================================
    reg        arready_r, rd_active, rd_pend;
    reg [31:0] rd_addr_q;
    reg [3:0]  rd_len_q, rd_id_q;
    reg [4:0]  rd_cnt_q;

    reg        awready_r, wr_pend, bvalid_r;
    reg [31:0] aw_addr_q;
    reg [3:0]  aw_len_q, aw_id_q;
    reg [4:0]  w_cnt_q;

    assign arready = arready_r;
    assign rid     = rd_id_q;
    assign rdata   = mem_read(rd_addr_q);
    assign rresp   = RESP_OKAY;
    assign rvalid  = rd_active;
    assign rlast   = (rd_cnt_q[3:0] == rd_len_q);

    assign awready = awready_r;
    assign wready  = wr_pend & ~bvalid_r;
    assign bid     = aw_id_q;
    assign bresp   = RESP_OKAY;
    assign bvalid  = bvalid_r;

    wire ar_fire = arvalid & arready;
    wire r_fire  = rvalid & rready;
    wire aw_fire = awvalid & awready;
    wire w_fire  = wvalid & wready;
    wire b_fire  = bvalid & bready;

    integer i;
    initial begin
        // 存储体上电清零 + 程序映像载入（复位保持期内完成）
        for (i = 0; i < DRAM_WORDS;  i = i + 1) ram  [i] = 32'h0;
        for (i = 0; i < FLASH_WORDS; i = i + 1) flash[i] = 32'h0;
        for (i = 0; i < BOOT_LEN;   i = i + 1) flash[i] = boot_prog[i];
        for (i = 0; i < MAIN_LEN;   i = i + 1) ram[(MAIN_BASE >> 2) + i] = main_prog[i];
    end

    // 提交观测（诊断：证明核在真跑指令）
    initial commit_count = 0;
    always @(posedge clk) begin
        if (aresetn && ws_valid) commit_count = commit_count + 1;
    end

    //==========================================================================
    // 7. 反证开关（只读 force；正常回归口径下不生效）
    //--------------------------------------------------------------------------
    //  (a) DISABLE_XIP_BYPASS=1：force 掉 fetch_unit 的 XIP 旁路判定（uncached=0）
    //      ⇒ 取指走 L1I：XIP 行被填入 I-Cache ⇒ 运行中改 Flash 后第二遍取到
    //        陈旧行（0x111 版）⇒ C4 必红（08 §8.5 第 1 行）。
    //  (b) DISABLE_MMIO_INTERCEPT=1：force 掉 lsu 内 mmio_route 的 CLINT 命中判定
    //      ⇒ route_o 变 ROUTE_AXI / no_axi=0 ⇒ CLINT 访问发到 AXI 并（按平台
    //        默认从设备混叠）改写 DDR3 探针 ⇒ C8/C9 必红（08 §8.5 第 2 行）。
    //  开关取值 = max(编译期 -P 参数, 运行期 +plusarg)（见文件头 §五）
    //==========================================================================
    integer pa_x, pa_m, pa_f;
    reg     mut_xip_on, mut_mmio_on, mut_flash_off;
    initial begin
        mut_xip_on    = (DISABLE_XIP_BYPASS     != 0);
        mut_mmio_on   = (DISABLE_MMIO_INTERCEPT != 0);
        mut_flash_off = (DISABLE_FLASH_MUTATION != 0);
        if ($value$plusargs("DISABLE_XIP_BYPASS=%d", pa_x))     mut_xip_on    = (pa_x != 0);
        if ($value$plusargs("DISABLE_MMIO_INTERCEPT=%d", pa_m)) mut_mmio_on   = (pa_m != 0);
        if ($value$plusargs("DISABLE_FLASH_MUTATION=%d", pa_f)) mut_flash_off = (pa_f != 0);
    end

    initial begin
        @(posedge aresetn);
        //  ★ XIP 旁路在本设计里有**两处独立判定**，关掉必须同时关（实测结论）：
        //    ① fetch_unit.uncached（取指侧旁路判定）—— 关掉后取指请求变成"可缓存"；
        //    ② l1i.xip_bypass（L1I 内部对 XIP 地址的**拒绝服务**判定，l1i.v:112
        //       `access = cs_req & ~xip_bypass`）—— 只关 ① 时 L1I 既不命中也不缺失、
        //       也不发行填充（acc_q 恒 0）⇒ 取指**永久死锁**（实测：1200000 拍内
        //       提交=0、AR=0；见交付说明的变异实验记录）。两处都关掉，L1I 才会真正
        //       缓存 XIP 行 ⇒ 第二遍取到**陈旧行**（0x111 版）⇒ C4 判红。
        if (mut_xip_on) begin
            force u_dut.u_fetch_unit.uncached = 1'b0;
            force u_dut.u_l1i.xip_bypass      = 1'b0;
        end
        if (mut_mmio_on) force u_dut.u_lsu.u_mmio_route.clint_hit = 1'b0;
    end

    always @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            arready_r <= 1'b1;  rd_active <= 1'b0;  rd_pend <= 1'b0;
            rd_addr_q <= 32'h0; rd_len_q  <= 4'h0;  rd_id_q <= 4'h0; rd_cnt_q <= 5'h0;
            awready_r <= 1'b1;  wr_pend   <= 1'b0;  bvalid_r <= 1'b0;
            aw_addr_q <= 32'h0; aw_len_q  <= 4'h0;  aw_id_q <= 4'h0; w_cnt_q <= 5'h0;
            ar_count <= 0; aw_count <= 0; r_beat_count <= 0; w_beat_count <= 0;
            ddr_ar_count <= 0; ddr_aw_count <= 0;
            win_ar_count <= 0; win_aw_count <= 0;
            clint_ar_count <= 0; clint_aw_count <= 0;
            plic_ar_count <= 0; plic_aw_count <= 0;
            unknown_rd_count <= 0; unknown_wr_count <= 0; flash_rd_count <= 0;
            first_ar_seen <= 1'b0; first_ar_addr <= 32'h0; flash_mut_seen <= 1'b0;
        end else begin
            // ---- 读通道 ----
            if (ar_fire) begin
                ar_count <= ar_count + 32'd1;
                rd_addr_q <= araddr;  rd_len_q <= arlen;  rd_id_q <= arid;  rd_cnt_q <= 5'd0;
                arready_r <= 1'b0;                       // 单笔在途
                rd_pend   <= 1'b1;                       // 1 拍读延迟
                if (!first_ar_seen) begin
                    first_ar_seen <= 1'b1;
                    first_ar_addr <= araddr;
                    $display("[tb_m3_ddr3] 首笔 AR: addr=0x%08h len=%0d size=%0d burst=%b cache=%b id=%0d",
                             araddr, arlen, arsize, arburst, arcache, arid);
                end
                // ---- 按地址区间分类计数 ----
                if (is_clint(araddr))                    clint_ar_count <= clint_ar_count + 32'd1;
                else if (is_plic(araddr))                plic_ar_count  <= plic_ar_count  + 32'd1;
                else begin
                    if (araddr < PAGE_REGION_BYTES) begin
                        ddr_ar_count <= ddr_ar_count + 32'd1;
                        if (araddr < WIN_BYTES) win_ar_count <= win_ar_count + 32'd1;
                    end
                    if (is_flash(araddr)) flash_rd_count <= flash_rd_count + 32'd1;
                    if (!is_ram(araddr) && !is_flash(araddr))
                        unknown_rd_count <= unknown_rd_count + 32'd1;
                end
            end else if (rd_pend) begin
                rd_pend   <= 1'b0;
                rd_active <= 1'b1;
            end else if (r_fire) begin
                r_beat_count <= r_beat_count + 32'd1;
                if (rd_cnt_q[3:0] == rd_len_q) begin
                    rd_active <= 1'b0;
                    arready_r <= 1'b1;                   // 释放：可接下一笔
                end else begin
                    rd_cnt_q  <= rd_cnt_q + 5'd1;
                    rd_addr_q <= rd_addr_q + 32'd4;      // INCR
                end
            end

            // ---- 写通道（B 被收下后才放开下一笔 AW，避免 wready 死锁）----
            if (aw_fire) begin
                aw_count  <= aw_count + 32'd1;
                aw_addr_q <= awaddr;  aw_len_q <= awlen;  aw_id_q <= awid;
                w_cnt_q   <= 5'd0;    wr_pend  <= 1'b1;   awready_r <= 1'b0;
                if (is_clint(awaddr))                    clint_aw_count <= clint_aw_count + 32'd1;
                else if (is_plic(awaddr))                plic_aw_count  <= plic_aw_count  + 32'd1;
                else begin
                    if (awaddr < PAGE_REGION_BYTES) begin
                        ddr_aw_count <= ddr_aw_count + 32'd1;
                        if (awaddr < WIN_BYTES) win_aw_count <= win_aw_count + 32'd1;
                    end
                    if (!is_ram(awaddr) && !is_flash(awaddr))
                        unknown_wr_count <= unknown_wr_count + 32'd1;
                end
            end

            if (w_fire) begin
                w_beat_count <= w_beat_count + 32'd1;
                do_write(aw_addr_q + {w_cnt_q, 2'b00}, wdata, wstrb);
                if (wlast) begin
                    wr_pend  <= 1'b0;
                    bvalid_r <= 1'b1;
                end else begin
                    w_cnt_q <= w_cnt_q + 5'd1;
                end
            end

            if (b_fire) begin
                bvalid_r  <= 1'b0;
                awready_r <= 1'b1;
            end
        end
    end

    //==========================================================================
    // 8. 辅助函数/任务
    //==========================================================================
    // 定长串左对齐（打印用；iverilog 不支持 %-0s）
    //   ★ 标签一律用 **纯 ASCII 且 ≤ 30 字符**：字符串经端口传递到 [8*32-1:0] 会被
    //     截断（多字节中文会被切断成乱码），故诊断文本一律"标签 ASCII + 中文正文
    //     直接写在 $display 字面量里"（字面量不受端口位宽限制）。
    function [8*32-1:0] lj;
        input [8*32-1:0] s;
        integer k, n;
        reg [8*32-1:0] t;
        begin
            t = s; n = 0;
            for (k = 0; k < 32; k = k + 1) begin
                if (t[8*32-1 -: 8] != 8'h00) n = n + 1;
                t = t << 8;
            end
            lj = s << (8*(32 - n));
        end
    endfunction

    // 结果区读（按字节偏移；统一走 DDR3 从设备模型）
    function [31:0] res_rd; input [31:0] off;
        begin res_rd = ram[(RES_BASE + off) >> 2]; end endfunction
    function [31:0] dram_rd; input [31:0] a;
        begin dram_rd = ram[alias_idx(a)]; end endfunction

    integer fails;
    task automatic chk32;
        input [31:0]  got;
        input [31:0]  exp;
        input [8*32-1:0] label;
        begin
            if (got !== exp) begin
                fails = fails + 1;
                $display("[tb_m3_ddr3] mismatch %0s: got=0x%08h exp=0x%08h => FAIL", label, got, exp);
            end else begin
                $display("[tb_m3_ddr3]   OK %0s = 0x%08h", label, got);
            end
        end
    endtask

    task automatic chkint;
        input integer got;
        input integer exp;
        input [8*32-1:0] label;
        begin
            if (got !== exp) begin
                fails = fails + 1;
                $display("[tb_m3_ddr3] mismatch %0s: got=%0d exp=%0d => FAIL", label, got, exp);
            end else begin
                $display("[tb_m3_ddr3]   OK %0s = %0d", label, got);
            end
        end
    endtask

    // 模式计数表核对（模式号 / 名称 / 期望写 / 期望读）
    integer mw, mr, me;
    task automatic chk_mode;
        input integer midx;
        input [8*32-1:0] mname;
        input integer ew;
        input integer er;
        begin
            mw = res_rd(R_MODETAB + midx*12 + 0);
            mr = res_rd(R_MODETAB + midx*12 + 4);
            me = res_rd(R_MODETAB + midx*12 + 8);
            $display("[tb_m3_ddr3] mode %0d %0s: wr=%0d(exp %0d) rd=%0d(exp %0d) err=%0d",
                     midx, mname, mw, ew, mr, er, me);
            if (mw !== ew) begin
                fails = fails + 1;
                $display("[tb_m3_ddr3] mode %0d write count mismatch => FAIL", midx);
            end
            if (mr !== er) begin
                fails = fails + 1;
                $display("[tb_m3_ddr3] mode %0d read count mismatch => FAIL", midx);
            end
            if (me !== 0) begin
                fails = fails + 1;
                $display("[tb_m3_ddr3] mode %0d has %0d errors => FAIL", midx, me);
            end
        end
    endtask

    //==========================================================================
    // 9. 主流程：C0 映像自检 → 复位 → 等完成标志 → 逐项判据
    //==========================================================================
    integer prog_nonzero, wait_cnt, jdx;
    reg     magic_seen, timed_out;

    initial begin
        fails       = 0;
        magic_seen  = 1'b0;
        timed_out   = 1'b0;
        wait_cnt    = 0;

        $display("========================================================================");
        $display("[tb_m3_ddr3] 开始：DDR3 遍历窗口=%0d 字(%0d B) 页专项区=%0d 字(%0d B)",
                 WINDOW_WORDS, WIN_BYTES, PAGE_REGION_WORDS, PAGE_REGION_BYTES);

        //----------------------------------------------------------------------
        // C0：程序映像自检（防"空/错镜像"假通过）
        //----------------------------------------------------------------------
        prog_nonzero = 0;
        for (jdx = 0; jdx < MAIN_LEN; jdx = jdx + 1)
            if (main_prog[jdx] != 32'h0) prog_nonzero = prog_nonzero + 1;
        if ((boot_prog[0] !== BOOT_W0) || (boot_prog[MUT_WORD_IDX] !== MUT_INSN_OLD) ||
            (main_prog[0] !== MAIN_W0) || (main_prog[MAIN_LEN-1] !== MAIN_WLAST) ||
            (prog_nonzero < 400) || (flash[MUT_WORD_IDX] !== MUT_INSN_OLD)) begin
            $display("[tb_m3_ddr3] C0 映像自检异常：boot[0]=0x%08h boot[16]=0x%08h main[0]=0x%08h main[末]=0x%08h 非零=%0d ⇒ FAIL",
                     boot_prog[0], boot_prog[MUT_WORD_IDX], main_prog[0],
                     main_prog[MAIN_LEN-1], prog_nonzero);
            $fatal(1, "TB_M3_DDR3 IMAGE");
        end
        $display("[tb_m3_ddr3] C0 映像自检 OK：flash %0d 字 + main %0d 字（非零 %0d；可变字@+0x40=0x%08h）",
                 BOOT_LEN, MAIN_LEN, prog_nonzero, MUT_INSN_OLD);

        //----------------------------------------------------------------------
        // 等复位释放
        //----------------------------------------------------------------------
        @(posedge aresetn);
        @(posedge clk);

        // 反证开关的**生效值**（编译期 -P 或运行期 +plusarg；只打印中文标签，
        //   参数名里含 "BY"+"PASS" 字样，禁止进输出——见文件头 §五）
        $display("[tb_m3_ddr3] 反证开关生效值：XIP 直连旁路关闭=%0d  核内 MMIO 截获关闭=%0d  Flash 改写关闭=%0d",
                 mut_xip_on, mut_mmio_on, mut_flash_off);

        //----------------------------------------------------------------------
        // C2：等完成标志（超时 ⇒ FAIL，fail-closed）
        //----------------------------------------------------------------------
        while (!magic_seen && (wait_cnt < TIMEOUT_CYCLES)) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
            if (res_rd(R_MAGIC) === MAGIC_VAL) magic_seen = 1'b1;
            if ((DIAG_PERIOD > 0) && ((wait_cnt % DIAG_PERIOD) == 0)) begin
                $display("[tb_m3_ddr3] 进度: 拍=%0d 提交=%0d AR=%0d AW=%0d DDR_AR=%0d DDR_AW=%0d CLINT_AR=%0d CLINT_AW=%0d",
                         wait_cnt, commit_count, ar_count, aw_count,
                         ddr_ar_count, ddr_aw_count, clint_ar_count, clint_aw_count);
                $display("[tb_m3_ddr3]   结果区观测: 窗口字数=%0d XIP1=0x%08h XIP2=0x%08h XIP_OK=%0d 模式0写=%0d 模式6写=%0d Flash已改=%0d",
                         res_rd(R_WINWORDS), res_rd(R_XIP1), res_rd(R_XIP2), res_rd(R_XIP_OK),
                         res_rd(R_MODETAB+0), res_rd(R_MODETAB+6*12), flash_mut_seen);
            end
        end
        if (!magic_seen) begin
            timed_out = 1'b1;
            $display("[tb_m3_ddr3] C2 超时 %0d 拍未见完成标志 MAGIC（实得=0x%08h）⇒ FAIL",
                     TIMEOUT_CYCLES, res_rd(R_MAGIC));
            $display("[tb_m3_ddr3] 超时现场：提交=%0d AXI(AR=%0d AW=%0d) DDR(AR=%0d AW=%0d) 结果区(窗口字数=%0d XIP1=0x%08h XIP2=0x%08h Flash已改=%0d)",
                     commit_count, ar_count, aw_count, ddr_ar_count, ddr_aw_count,
                     res_rd(R_WINWORDS), res_rd(R_XIP1), res_rd(R_XIP2), flash_mut_seen);
            if (mut_xip_on)
                $display("[tb_m3_ddr3] 提示：XIP 直连旁路被开关关闭；本设计里 L1I 对 XIP 地址的拒绝服务判定若也被关掉才会真正缓存 XIP 行");
            $fatal(1, "TB_M3_DDR3 TIMEOUT");
        end
        for (jdx = 0; jdx < 20; jdx = jdx + 1) @(posedge clk);   // 让最后几笔落盘
        $display("[tb_m3_ddr3] C2 完成标志 MAGIC 已见到（拍=%0d 提交=%0d）", wait_cnt, commit_count);

        //----------------------------------------------------------------------
        // C1：首笔取指地址 = 复位向量（XIP 窗口）
        //----------------------------------------------------------------------
        if (!first_ar_seen || (first_ar_addr !== `RV32GC_RESET_PC)) begin
            fails = fails + 1;
            $display("[tb_m3_ddr3] C1 首笔 AR 异常（seen=%b addr=0x%08h 期望=0x%08h）⇒ FAIL",
                     first_ar_seen, first_ar_addr, `RV32GC_RESET_PC);
        end else begin
            $display("[tb_m3_ddr3] C1 首笔取指地址 = 0x%08h（= RESET_PC/XIP 窗口）OK", first_ar_addr);
        end

        //----------------------------------------------------------------------
        // C3：窗口口径两侧一致
        //----------------------------------------------------------------------
        chkint(res_rd(R_WINWORDS), WINDOW_WORDS, "C3 win_words_reported");

        //----------------------------------------------------------------------
        // C4：XIP 旁路（运行中改 Flash ⇒ 第二遍必须看到新内容）
        //----------------------------------------------------------------------
        chk32(res_rd(R_XIP1), XIP_V1, "C4 xip_pass1_val");
        chk32(res_rd(R_XIP2), XIP_V2, "C4 xip_pass2_val_after_edit");
        chk32(res_rd(R_XIP_OK), 32'd1, "C4 xip_ok_flag");
        chk32(flash[MUT_WORD_IDX], MUT_INSN_NEW, "C4 flash_mut_word_final");
        if (!flash_mut_seen) begin
            fails = fails + 1;
            $display("[tb_m3_ddr3] C4 未观察到邮箱写入 ⇒ Flash 未被改写、测试空跑 ⇒ FAIL");
        end

        //----------------------------------------------------------------------
        // C5：逐模式计数（写/读/错），并打印计数表
        //----------------------------------------------------------------------
        $display("[tb_m3_ddr3] ---- 模式计数表（软件侧显式计数 vs TB 期望）----");
        chk_mode(0, lj("0x0000_0000"), E_M0W, E_M0R);
        chk_mode(1, lj("0xFFFF_FFFF"), E_M1W, E_M1R);
        chk_mode(2, lj("0x5555_5555"), E_M2W, E_M2R);
        chk_mode(3, lj("0xAAAA_AAAA"), E_M3W, E_M3R);
        chk_mode(4, lj("addr[15:0]"),  E_M4W, E_M4R);
        chk_mode(5, lj("4KB-page-head-tail"), E_M5W, E_M5R);
        chk_mode(6, lj("byte-halfword"),    E_M6W, E_M6R);

        //----------------------------------------------------------------------
        // C6：全局合计 + 首个错例记录（无错时四字必须为 0）
        //----------------------------------------------------------------------
        chkint(res_rd(R_TOTW), E_TOTW, "C6 total_writes");
        chkint(res_rd(R_TOTR), E_TOTR, "C6 total_reads");
        chkint(res_rd(R_TOTE), 0,      "C6 total_errors");
        //   ★ 错例三要素（08 §8.4 要求"打印首个错地址、期望、实读"）：无论有无错都
        //     打印一行原始记录（程序把**第一个**错例落在这四个字里，见 .S §三）。
        $display("[tb_m3_ddr3] 首个错例记录：mode=%0d addr=0x%08h 期望=0x%08h 实读=0x%08h（错数=0 时这四字必须为 0）",
                 res_rd(R_FE_MODE), res_rd(R_FE_ADDR), res_rd(R_FE_EXP), res_rd(R_FE_ACT));
        chk32(res_rd(R_FE_ADDR), 32'h0, "C6 first_err_addr(0)");
        chk32(res_rd(R_FE_EXP),  32'h0, "C6 first_err_exp(0)");
        chk32(res_rd(R_FE_ACT),  32'h0, "C6 first_err_act(0)");
        chk32(res_rd(R_FE_MODE), 32'h0, "C6 first_err_mode(0)");

        //----------------------------------------------------------------------
        // C7：软硬件交叉核对（程序软计数 == AXI 事务数）
        //----------------------------------------------------------------------
        $display("[tb_m3_ddr3] ---- AXI 交叉核对（[0,%0d B) DDR3 区）----", PAGE_REGION_BYTES);
        $display("[tb_m3_ddr3] AXI: AR=%0d AW=%0d R拍=%0d W拍=%0d；窗口内 AR=%0d AW=%0d；Flash 读=%0d",
                 ddr_ar_count, ddr_aw_count, r_beat_count, w_beat_count,
                 win_ar_count, win_aw_count, flash_rd_count);
        chkint(ddr_aw_count, E_TOTW + PROBE_WR, "C7 ddr_axi_aw=sw_wr+probe");
        chkint(ddr_ar_count, E_TOTR + PROBE_RD, "C7 ddr_axi_ar=sw_rd+probe");
        chkint(win_aw_count, E_WINW, "C7 win_axi_aw");
        chkint(win_ar_count, E_WINR, "C7 win_axi_ar");

        //----------------------------------------------------------------------
        // C8：核内截获 —— CLINT/PLIC 绝不发 AXI（08 §6.6）
        //----------------------------------------------------------------------
        $display("[tb_m3_ddr3] AXI 违规计数：CLINT AR=%0d AW=%0d；PLIC AR=%0d AW=%0d",
                 clint_ar_count, clint_aw_count, plic_ar_count, plic_aw_count);
        if ((clint_ar_count != 0) || (clint_aw_count != 0) ||
            (plic_ar_count != 0)  || (plic_aw_count != 0)) begin
            fails = fails + 1;
            $display("[tb_m3_ddr3] C8 核内 MMIO 截获失效：CLINT/PLIC 事务发到了 AXI（CLINT AR=%0d AW=%0d PLIC AR=%0d AW=%0d）⇒ FAIL",
                     clint_ar_count, clint_aw_count, plic_ar_count, plic_aw_count);
        end else begin
            $display("[tb_m3_ddr3] C8 CLINT/PLIC 访问全部核内截获（AXI 事务数 0）OK");
        end

        //----------------------------------------------------------------------
        // C9：探针不变（CLINT 写不得落到 DDR3 默认从设备）
        //----------------------------------------------------------------------
        $display("[tb_m3_ddr3] ---- CLINT 写前后 DDR3 探针（CLINT 别名地址）----");
        chk32(res_rd(R_PB0), P0_VAL, "C9 probe0_before_clint");
        chk32(res_rd(R_PB1), P1_VAL, "C9 probe1_before_clint");
        chk32(res_rd(R_PB2), P2_VAL, "C9 probe2_before_clint");
        chk32(res_rd(R_PA0), P0_VAL, "C9 probe0_after_clint");
        chk32(res_rd(R_PA1), P1_VAL, "C9 probe1_after_clint");
        chk32(res_rd(R_PA2), P2_VAL, "C9 probe2_after_clint");
        chk32(dram_rd(32'h0000_4000), P0_VAL, "C9 ddr3_4000_final");
        chk32(dram_rd(32'h0000_4004), P1_VAL, "C9 ddr3_4004_final");
        chk32(dram_rd(32'h0000_BFF8), P2_VAL, "C9 ddr3_bff8_final");
        chk32(res_rd(R_CLINT_OK), 32'd1, "C9_C10 clint_selftest_ok");

        //----------------------------------------------------------------------
        // C10：CLINT 正向证据（写进去的值能原样读回 ⇒ 截获路径真的在服务）
        //----------------------------------------------------------------------
        chk32(res_rd(R_CLO),   CM_LO,    "C10 clint_mtimecmp_lo");
        chk32(res_rd(R_CHI),   CM_HI,    "C10 clint_mtimecmp_hi");
        chk32(res_rd(R_CMSIP), MSIP_VAL, "C10 clint_msip");

        //----------------------------------------------------------------------
        // C11：未登记地址访问
        //----------------------------------------------------------------------
        chkint(unknown_rd_count, 0, "C11 unknown_rd");
        chkint(unknown_wr_count, 0, "C11 unknown_wr");

        //----------------------------------------------------------------------
        // 汇总
        //----------------------------------------------------------------------
        $display("------------------------------------------------------------------------");
        $display("[tb_m3_ddr3] 汇总: 拍=%0d 提交=%0d 不符项=%0d", wait_cnt, commit_count, fails);
        $display("[tb_m3_ddr3] AXI 总计: AR=%0d AW=%0d R拍=%0d W拍=%0d 首AR=0x%08h",
                 ar_count, aw_count, r_beat_count, w_beat_count, first_ar_addr);
        $display("------------------------------------------------------------------------");

        if (fails == 0) begin
            $display("TB_M3_DDR3: PASS");                 // ★ 唯一成功行
            $finish;
        end else begin
            $display("[tb_m3_ddr3] %0d 项判据不符（XIP/MMIO 反证开关打开时属预期）⇒ 本 TB 无兜底成功文案",
                     fails);
            $fatal(1, "TB_M3_DDR3 FAIL");
        end
    end

endmodule
