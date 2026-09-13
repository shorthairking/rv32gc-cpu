# chiplab ↔ new RV32-GC CPU: the CPU/platform integration contract

Survey of `/home/shorthair/dsh/rv32-cpu/chiplab` (Loongson "chiplab" LA32R agile-development
platform: SoC demo + IP library + sim/FPGA flows) performed **read-only**; the only file
created is this report.

All statements below are traceable to a `path:line` citation. Where a fact is inferred
(not literally readable in the tree) it is marked **[inferred]**; everything unverifiable is
collected in §13 "Uncertainties / things to verify".

Environment assumed by the tree: `CHIPLAB_HOME` must point at the chiplab root
(`docs/Quick-Start.md:65-67`, `sims/verilator/run_prog/Makefile:214-221`).

---

## 1. `IP/myCPU/` — current state, and every CPU top-level reference in the tree

### 1.1 The directory is empty

```
$ ls -la IP/myCPU/
total 8
drwxr-xr-x  2 shorthair shorthair 4096 Sep 12 23:42 .
drwxr-xr-x 14 shorthair shorthair 4096 Sep 12 23:42 ..
```

`IP/myCPU/` contains **zero files** in this checkout.

### 1.2 Why: it is an un-initialised git submodule

`chiplab/.gitmodules`:

```
[submodule "IP/myCPU"]
	path = IP/myCPU
	url = https://gitee.com/loongson-edu/open-la500.git
```

* `git ls-tree HEAD IP/` shows `160000 commit aa3bde1f3e720e71c2c78d6b81930d797b810149	IP/myCPU`
  → the reference core is pinned to `open-la500` commit `aa3bde1`.
* `git submodule status` prints `-aa3bde1f3e…  IP/myCPU` — the leading `-` means **not
  checked out**.
* `.gitignore` contains **no** rule for `IP/myCPU` (its only CPU-ish entries are
  `sims/verilator/run_prog/{log,obj,obj_dir,tmp,output,config-*.mak}`), i.e. the submodule,
  not a gitignore rule, is the mechanism.

### 1.3 Every reference to `myCPU` / `mycpu` / `core_top` / CPU top-level names

| File:line | What it says | Effect |
|---|---|---|
| `.gitmodules:1-3` | submodule path/url | supplies the reference core (open-la500) |
| `chip/config-generator.mak:5` | `MYCPU=y` | enables CPU sources in sim builds |
| `chip/config-generator.mak:13` | `MYCPU_SRC=${CHIPLAB_HOME}/IP/myCPU` | **the CPU source directory variable** |
| `sims/verilator/run_prog/Makefile:64-67` | `VERILATOR_INCLUDE += -y ${MYCPU_SRC}` / `VERILATOR_SRC += ${MYCPU_SRC}/*.v` | all `IP/myCPU/*.v` are compiled; the dir is a Verilog module search dir |
| `sims/verilator/run_random/Makefile:66-68` | same | same for random tests |
| `sims/iverilog/run_prog/Makefile:15-18` | `-I ${MYCPU_SRC}` / `${MYCPU_SRC}/*.v` | same for the (legacy) iverilog flow |
| `docs/Quick-Start.md:69-70` | "`IP/myCPU`中存放的是处理器核代码，对外的接口和核顶层模块名称固定" — *the external interface and the core top-level module name are fixed* | the contract |
| `docs/Quick-Start.md:72-131` | the canonical `module core_top(...)` declaration (see §11) | the contract |
| `nscscc_readme.md:105-106` | same statement + same declaration at `nscscc_readme.md:108-167` | the contract |
| `nscscc_readme.md:178` | "【myCPU加入】首先确保已经替换 `IP/myCPU` 中的处理器核代码" | FPGA flow step 1 |
| `docs/Quick-Start.md:141` | "添加处理器核代码后，可直接开始综合。若选择添加 chiplab 中的参考核，注意添加 `myCPU/IP` 下的 xilinx IP" | FPGA: add the core sources by hand; reference core also needs its own Xilinx IP |
| `sims/verilator/README_DIFF.md:14,17,19` and `docs/Simulation/difftest.md:14,17,19` | "`mycpu_top.v`中实例化了 `difftest.v` 中定义的 module" … "详细使用案例可参考本仓库中 `IP/myCPU/mycpu_top.v`" | the **reference** core top *file* is `IP/myCPU/mycpu_top.v` |
| `software/README.md` §3 | refers to "myCPU" generically in the verilator/FPGA how-tos | — |
| `fpga/nscscc-team/run_vivado/create_project.tcl:30-35` | `add_files -scan_for_includes ../../../IP/myCPU` + `glob … IP/myCPU/xilinx_ip/*/*.xci[x]` | only the *nscscc-team* project has a Tcl that auto-adds the CPU dir |
| `chip/soc_demo/sim/soc_top.v:340` | `core_top cpu` | **simulation** SoC CPU instance (name `cpu`) |
| `chip/soc_demo/loongson/soc_top.v:723` | `core_top cpu_mid` | 龙芯实验箱 FPGA SoC instance |
| `chip/soc_demo/Baixin/soc_top.v:692` | `core_top cpu_mid` | Baixin board |
| `chip/soc_demo/nexys4ddr/soc_top.v:477` | `core_top cpu_mid` | Nexys4-DDR board |
| `chip/soc_demo/nscscc-team/soc_top.v:529` | `core_top u_cpu` | 龙芯杯 competition SoC |

**Findings**

* The *file* names inside `IP/myCPU/` are free (`*.v`, top file conventionally
  `mycpu_top.v`); the **module name must be exactly `core_top`** and its port list must
  match §11. Every SoC variant instantiates `core_top` with the same port names.
* Nothing in the two FPGA `.xpr` projects references `IP/myCPU` (see §5.3) — the CPU is
  added manually, i.e. a brand-new RV32 core needs no `IP/myCPU` submodule dependency; you
  can simply drop your RTL there (or anywhere) and add it to the project.
* `chip/soc_demo/sim/*` is the SoC used by **both** simulators (`CURRENT_DESIGN_TOP=soc_demo`,
  `chip/config-generator.mak:2-4`), so the CPU instance name for sim is `cpu`, while the
  FPGA SoCs use `cpu_mid` / `u_cpu`. Any hierarchical `$display`/testbench poke must match.

---

## 2. `chip/soc_demo/loongson/soc_top.v` and `config.h`

### 2.1 Module and board-level ports

`chip/soc_demo/loongson/soc_top.v:34-115`:

```verilog
34: `include "config.h"
36: module soc_top(
37:     input         resetn,
38:     input         clk,
...
41:     output [15:0] led,          // 42-49: led_rg0/1, num_csn, num_a_g, switch, btn_key_*
52:     inout  [15:0] ddr3_dq, …    // 52-65: DDR3 (16-bit) interface
69:     input         mtxclk_0, …   // 67-84: MII MAC + MIIM + phy_rstn
87:     input         EJTAG_TRST, … // 86-91: EJTAG
94:     inout         UART_RX, UART_TX,      // 93-95: 16550 UART (板载串口)
98:     input         UART_RX2, output UART_TX2,  // 97-99: debug UART
102:    output        NAND_CLE, …   // 101-108: NAND
111:    output        SPI_CLK, …    // 110-114: SPI flash
115: );
```

Board clock input is 100 MHz (`fpga/loongson/soc_up.xdc:6`), reset is the button `resetn`
(active-low, `fpga/loongson/soc_up.xdc:9`).

### 2.2 The CPU instance — the exact integration point

`chip/soc_demo/loongson/soc_top.v:722-776`:

```verilog
722: // cpu
723: core_top cpu_mid(
724:   .aclk             (cpu_clk),
725:   .intrpt           ({3'b0, int_out[4:0]}),  //232 only 5bit
726:   //.nmi              (1'b1),
728:   .aresetn          (cpu_aresetn  ),
729:   .arid         (m0_arid[3:0] ),   … .arready (m0_arready ),   // 729-738  AR
739:   .rid          (m0_rid[3:0]  ),   … .rready  (m0_rready  ),   // 739-744  R
745:   .awid         (m0_awid[3:0] ),   … .awready (m0_awready ),   // 745-754  AW
755:   .wid          (m0_wid[3:0]  ),   … .wready  (m0_wready  ),   // 755-760  W
761:   .bid          (m0_bid[3:0]  ),   … .bready  (m0_bready  ),   // 761-764  B
766:   .ws_valid     (ws_valid     ),
767:   .break_point  (break_point  ),
768:   .infor_flag   (infor_flag   ),
769:   .reg_num      (reg_num      ),
770:   .rf_rdata     (rf_rdata     ),
772:   .debug0_wb_pc        (debug_wb_pc      ),
773:   .debug0_wb_rf_wen    (debug_wb_rf_wen  ),
774:   .debug0_wb_rf_wnum   (debug_wb_rf_wnum ),
775:   .debug0_wb_rf_wdata  (debug_wb_rf_wdata)
776: );
```

The width macros come from `chip/soc_demo/loongson/config.h`
(`\`LID 4`, `\`Lawaddr 32`, `\`Lawlen 4`, `\`Lawsize 3`, `\`Lawburst 2`, `\`Lawlock 2`,
`\`Lawcache 4`, `\`Lawprot 3`, `\`Lwdata/\`Lrdata` = 128/64/32 by `AXI128`/`AXI64`/none,
`\`Lwstrb/\`Lstrb` = 16/8/4, `\`Lbresp/\`Lrresp` = 2).

### 2.3 AXI topology around the CPU (loongson FPGA SoC)

```
core_top cpu_mid  ──AR/R──▶ axi_2x1_mux (Xilinx AXI Crossbar, read-only use)  ──┐
      │  (m0_*)                            ▲ S01 = debug_sram (UART download)   │ m1_*
      └──AW/W/B────────────────────────────────────────────────────────────────┐ │
                                                                               ▼ ▼
                                            axi_clock_converter_0 (cpu_clk → aclk)
                                                             │  m0_async_*
                                                             ▼
                     axi_slave_mux  (IP/AMBA/axi_mux_syn.v, `SLV_MUX_5`, 5 slaves)
        s0 ─▶ axi_interconnect_0 S00 ─▶ M00 ─▶ mig_axi_32 (DDR3, 32-bit AXI, 27-bit addr)
        s1 ─▶ spi_flash_ctrl  (0x1fe8_xxxx | 0x1c0x_xxxx)
        s2 ─▶ axi2apb (APB_DEV) ─▶ UART16550 (0x1fe0_xxxx) + NAND (0x1fe7_xxxx)
        s3 ─▶ confreg          (0x1fd0_xxxx)
        s4 ─▶ ethernet_top MAC (0x1ff0_xxxx)
                     axi_interconnect_0 also has S01 = MAC master, S02 = DMA (64-bit) ─▶ M00 MIG
```

Evidence / line numbers:

| Block | Lines |
|---|---|
| `axi_2x1_mux u_axi_2x1_mux` (Xilinx IP) | `chip/soc_demo/loongson/soc_top.v:779-898` — `S00_AXI_*` = CPU `m0_*` (779-821, **only AR/R is wired; `S00_AXI_AWVALID` tied `1'b0` at 812**), `S01_AXI_*` = `uart_*` (823-861, also AR/R only), `M00_AXI_*` = `m1_*` (863-898, **AR/R only**) |
| `axi_clock_converter_0 AXI_CLK_CONVERTER` | `…:905-966` — write path `.s_axi_awaddr(m0_awaddr)` (907), read path `.s_axi_araddr(m1_araddr)` (927); `s_axi_aclk=cpu_clk` (947), `m_axi_aclk=aclk` (960) |
| `axi_slave_mux AXI_SLAVE_MUX` | `…:992-1220`; `spi_boot(1'b1)` at 995; `axi_s_aclk(aclk)` at 1219 |
| `spi_flash_ctrl SPI` | `…:1223-1278`, `spi_addr(16'h1fe8)` at 1227 |
| `confreg CONFREG` | `…:1281-1345` (ACLK = `aclk`) |
| `ethernet_top ETHERNET_TOP` | `…:1348-1448` |
| `clk_pll_33 clk_pll_33` | `…:1460-1467` |
| `clk_wiz_0 clk_pll_1` | `…:1469-1473` |
| `axi_interconnect_0 mig_axi_interconnect` (3 slaves → 1 master) | `…:1501-1663`; `S01` = `mac_m_*`, `S02` = `dma0_*`, `M00` = `mig_*` |
| `mig_axi_32 mig_axi` | `…:1665-1740`, `.s_axi_awaddr(mig_awaddr[26:0])` at 1701, `.ui_clk(c1_clk0)` at 1690 |
| `debug_top u_debug_top` / `debug_sram u_debug_sram` | `…:664-683` / `…:685-720` |

**Critical consequence of `axi_2x1_mux`:** the CPU's **write** channel goes *straight* into
`axi_clock_converter_0`, while its **read** channel is arbitrated against the debug-UART
loader (`debug_sram`). A new CPU therefore only needs one AXI master port with the normal
5 channels; it must not assume the AW and AR paths have identical latency/ordering
semantics.

### 2.4 Clocking and reset (loongson)

```verilog
1460: clk_pll_33  clk_pll_33
1463:   .clk_out1(cpu_clk),   //50MHz   <-- CPU clock (and CPU-side AXI clock)
1464:   .clk_out2(uncore_clk),//33MHz   <-- platform "uncore" clock
1466:   .clk_in1(clk)         //100MHz board clock
1469: clk_wiz_0  clk_pll_1
1471:     .clk_out1(c1_clk_ref_i),  //200MHz  <-- DDR3 MIG reference clock
1472:     .clk_in1(clk)             //100MHz
1477: assign aclk = uncore_clk;            // = 33 MHz, the SoC AXI clock
```

Reset chain (`chip/soc_demo/loongson/soc_top.v:600-610`):

```verilog
600: reg cpu_aresetn_1;
601: reg cpu_aresetn_2;
603: wire cpu_aresetn;
605: always @(posedge cpu_clk) begin
606:     cpu_aresetn_1 <= aresetn;
607:     cpu_aresetn_2 <= cpu_aresetn_1;
608: end
610: assign cpu_aresetn = cpu_aresetn_2;
```

`aresetn` (declared `wire` at `…:117`) is **not** assigned by an `assign`; it is driven by
the Xilinx interconnect's reset output port `axi_interconnect_0 .S00_AXI_ARESET_OUT_N (aresetn)`
at `…:1504`. So: board `resetn` → interconnect → `aresetn` → 2-FF sync → **CPU `aresetn`**.

### 2.5 Interrupts

```verilog
593: //interrupt
597: assign int_out = {1'b0,dma_int,nand_int,spi_inta_o,uart0_int,mac_int};
598: assign int_n_i = ~int_out;
```
and at the CPU: `.intrpt({3'b0, int_out[4:0]})` (`…:725`).

| `intrpt` bit | Source | Notes |
|---|---|---|
| `[0]` | `mac_int` (Ethernet) | |
| `[1]` | `uart0_int` (16550) | the only source in the **simulation** SoC too (`chip/soc_demo/sim/soc_top.v:305`: `assign interrupt = {6'b0, uart0_int, 1'b0};`) |
| `[2]` | `spi_inta_o` (SPI flash) | |
| `[3]` | `nand_int` | |
| `[4]` | `dma_int` | |
| `[7:5]` | `0` | |

There is **no NMI, no timer wire**: the LoongArch timer lives inside `confreg`
(`TIMER_ADDR`) and the CPU handles it through its own CSR/timer logic. An RV32 core must
map these 5 lines itself (e.g. to `mip`/custom IRQ controller) and must implement its own
timer (e.g. `mtime`) or reuse the confreg timer register by polling.

### 2.6 Devices wired to the CPU-side AXI

* **confreg** (`…:1281-1345`): LEDs, RGB LEDs, 7-segment, switches, buttons, timer, CR0-CR7,
  DMA order register. Instance name in the *sim* SoC is `confreg` (hierarchically referenced
  by the testbench, see §4.7).
* **UART16550** via `axi2apb`/`apb_dev_top_with_nand` (`…:1840-1870`); `UART_RX/TX` are
  `inout` with tristate enables (`…:582-591`); debug UART is `UART_RX2/TX2` driven by
  `debug_top` (`…:667,680`).
* **NAND** (`IP/APB_DEV/NAND/nand.v` through `apb_dev_top_with_nand.v`) — see §9.
* **SPI flash** (`IP/SPI/godson_sbridge_spi.v`, `spi_flash_ctrl`) — see §9.
* **MAC** (`IP/MAC/ethernet_top.v`) — AXI slave at `0x1ff0_xxxx` **and** AXI master (S01 of
  `axi_interconnect_0`).
* **DMA** (`IP/DMA/dma.v`, instance near `…:1730-1780`) — AXI master, 64-bit data, S02 of
  `axi_interconnect_0`.
* **Debug** (`IP/DEBUG/debug_top.v` + `debug_sram.v`) — a second AXI **read** master that
  fetches instruction words downloaded over `UART_RX2` (used by the "在线调试系统", §8).
* **No SRAM / ram_wrap** exists in the loongson SoC: its `s0` (default decode) slave is the
  DDR3 interconnect. `ram_wrap/` exists only in `chip/soc_demo/nscscc-team/ram_wrap/`.

### 2.7 The `config.h` macros that matter

`chip/soc_demo/loongson/config.h`:

```verilog
33: `define FREQ 32'd33000000            // reported by confreg FREQ_ADDR (0x1fd0_f030)
57: `ifdef AXI128 / `elsif AXI64 / `else   → `Lwdata  = 128 / 64 / 32
65: …                                      → `Lwstrb  = 16 / 8 / 4
95: …                                      → `Lrdata  = 128 / 64 / 32
113:…                                      → `LDATA   = 128 / 64 / 32
```

`AXI64`/`AXI128` are **not** defined for the FPGA project and are `n` in
`chip/config-generator.mak:10-11`; the sim Makefiles only add `-DAXI64/-DAXI128` when those
variables are `y` (`sims/verilator/run_prog/Makefile:185-193`, `sims/iverilog/run_prog/Makefile:54-62`).
**Default = AXI32.** The Xilinx IP in the loongson project is configured 32-bit
(`IP/xilinx_ip/2023.2/axi_2x1_mux/axi_2x1_mux.xci:13-30` → `S00/M00_AXI_DATA_WIDTH = 32`,
`AXI_ADDR_WIDTH = 32`; `IP/xilinx_ip/2023.2/axi_interconnect_0/axi_interconnect_0.xci`
→ `S00 = 32`, `S01 = 32`, `S02 = 64` (the DMA), `M00 = 32`).

Other macros: `Lconfbus 10`, `Lconfret 9`, `Lconfbusreg 64`, `Lconfbusaddr 16`,
`ORDER_REG_ADDR 16'h1160` (commented out in the loongson copy, active in
`chip/soc_demo/sim/config.h:40`). The only difference between
`chip/soc_demo/sim/config.h` and `chip/soc_demo/loongson/config.h` is that one line
(`ORDER_REG_ADDR`).

---

## 3. The AXI contract the CPU must satisfy

### 3.1 One master port, AXI3-style, 32-bit, 4-bit IDs

* **One** AXI master port (`m0_*` in the FPGA SoC, `cpu_*` in the sim SoC); a **single**
  AR/AW/R/W/B channel set. There is no second port, no `cpu_axi_*`-named port, and the names
  `m0_*`/`cpu_*` are *internal wires*, not CPU port names.
* **IDs**: `arid/awid/wid/rid/bid` are **4 bits each** (`config.h \`LID 4`; the interfaces in
  the SoC are declared `m0_arid[3:0]`, `m1_arid[3:0]`, `uart_arid`, and
  `IP/xilinx_ip/2023.2/axi_interconnect_0/…` reports `ID_WIDTH = 4`). Active ID count is the
  CPU's own choice; the platform never synthesises IDs.
* **Data**: 32-bit (`wdata`/`rdata`), `wstrb` 4 bits, in the default (AXI64=n, AXI128=n)
  configuration.
* **Len**: the *documented* CPU port is `[7:0]` (AXI4 width) but **every SoC wire is 4 bits**
  (`config.h \`Lawlen 4`, `\`Larlen 4`; `m0_arlen`, `axi_s_arlen`, bridge `m_arlen[3:0]`).
  Connecting an 8-bit port keeps only the low 4 bits, so **bursts must never exceed 16 beats
  (len ≤ 15)**. See §13.
* **Lock**: `[1:0]` in the CPU-facing wires (`\`Lawlock 2`), but the Xilinx crossbar /
  clock converter / MIG take 1 bit (AXI4) — bit 1 is dropped. Use `lock = 2'b00`.
* **Cache/Prot**: `arcache/awcache [3:0]`, `arprot/awprot [2:0]` are forwarded unchanged to
  every slave (`IP/AMBA/axi_mux_syn.v:537-640`), so they *are* meaningful to observe but no
  platform logic acts on them.
* **Responses**: all Loongson slaves drive `bresp/rresp = 2'b00`
  (`IP/CONFREG/confreg_syn.v:311-312`), so the CPU must not rely on error responses to detect
  unmapped accesses.
* **`burst`**: the `soc_axi_sram_bridge` handles FIXED/INCR/WRAP with per-beat address
  increment (`IP/AXI_SRAM_BRIDGE/soc_axi_sram_bridge.v:65-169`); `INCR` with `len ≤ 15` is the
  safe choice.

### 3.2 Clock domain

The CPU-side AXI runs on **`cpu_clk` (50 MHz)**:
`axi_2x1_mux .INTERCONNECT_ACLK/.S00_AXI_ACLK (cpu_clk)` (`…:781,783`) and
`axi_clock_converter_0 .s_axi_aclk (cpu_clk)` (`…:947`). The rest of the SoC (`axi_slave_mux`,
confreg, SPI, APB/UART/NAND, MAC) runs on **`aclk` = `uncore_clk` = 33 MHz** (`…:1219, 1282,
1226, 1477`). DDR3/AXI-interconnect/DMA/MAC-master side runs on the MIG `ui_clk`
(= `c1_clk0`, 100 MHz — see §10).

The RTL simulation has **no** clock converter (the sim SoC has no `axi_clock_converter_0`;
`chip/soc_demo/sim/soc_top.v` connects `soc_axi_delay_rand` straight into `axi_slave_mux`),
so a CPU that assumes one clock domain will simulate fine but must respect the 50↔33 MHz
crossing on hardware (the converter is in the design and is transparent, but the CPU's AXI
must be a proper AXI — no combinational dependencies across handshakes).

### 3.3 No uncached port, no split I/D port

`grep -rn "uncached|_acache|_wcache|dev_"` over `IP/`, `chip/` finds only the `*cache`
AXI signal names (`awcache/arcache`) — there is **no** `uncached`, `acache`, `wcache`,
`dev_*` port or slave category anywhere in the platform. Cacheability is the CPU's own
business (LA32R uses CRMD/DMW and CACOP; RV32-GC must decide via PMA/PMP and drive
`arcache/awcache` meaningfully if it wants the DDR path treated as cacheable). The platform
neither checks nor uses them.

### 3.4 Summary of the AXI "musts" for RV32-GC

1. Exactly one AXI master, AXI3-ish attribute widths, 32-bit data, 4-bit ID, ≤16-beat INCR bursts.
2. Drive `awvalid/wvalid/arvalid` only after reset (active-low `aresetn`).
3. Emit **physical** addresses: the FPGA decoder compares `addr[31:16]` against
   `0x1fd0/0x1fe0/0x1fe7/0x1fe8/0x1ff0` and `addr[31:20]` against `0x1c0`
   (`IP/AMBA/axi_mux_syn.v:854-860, 946-951`). The simulation decoder additionally accepts
   the kseg1 aliases `0xbfd0_xxxx`/`0xbfaf_xxxx` because it compares only bits `[28:16]`
   (`IP/AMBA/axi_mux_sim.v:854-861, 947-956`) — do not rely on that on hardware.
4. No read/write ordering assumptions between the muxed read path and the direct write path.

---

## 4. Simulation flow

### 4.1 What is simulated

Both simulators build the **`chip/soc_demo/sim`** SoC, not the loongson one
(`chip/config-generator.mak:2-4`):

```make
2: CURRENT_DESIGN_TOP=soc_demo
4: TOP_SOC_SRC=${CHIPLAB_HOME}/chip/${CURRENT_DESIGN_TOP}/sim
```

`chip/soc_demo/sim/soc_top.v:7-11` has parameters `BUS_WIDTH=32, DATA_WIDTH=64,
CPU_WIDTH=32` (the testbenches override `DATA_WIDTH` to 32) and its port list
(`…:12-47`) is: `aresetn, aclk, enable_delay, random_seed[22:0]`, `debug0_wb_*`
(optional `debug1_wb_*` under `CPU_2CMT`), `led/led_rg0/led_rg1/num_csn/num_a_g/switch/
btn_*`, `sram_{raddr,rdata,ren,waddr,wdata,wen}` (**external** memory), `UART_RX`, `UART_TX`.

Inside it: `core_top cpu` (`…:340-401`), `soc_axi_delay_rand delay` (`…:403-490`),
`axi_slave_mux AXI_SLAVE_MUX` (`…:493-723`, `spi_boot(1'b0)` at 496, s1/s4 tied off),
`axi2apb_misc APB_DEV` (UART only, `…:726-809`), `soc_axi_sram_bridge sram_axi_ram`
(s0 → external SRAM, `…:867-919`), `soc_axi_sram_bridge conf_axi_ram` + `confreg confreg`
(s3 → confreg, `…:812-864, 921-950`).

### 4.2 `chip/config-generator.mak` (the single CPU-selection file)

```make
1: #CHIPLAB_HOME="your chiplab pwd address"
2: CURRENT_DESIGN_TOP=soc_demo
3: SOC_TOP_NAME=soc_top
4: TOP_SOC_SRC=${CHIPLAB_HOME}/chip/${CURRENT_DESIGN_TOP}/sim
5: MYCPU=y
6: BRIDGE=n
7: CONFREG=y
8: AXI_RAND=y
9: AXI_SRAM=y
10: AXI64=n
11: AXI128=n
12: CPU_2CMT=n
13: MYCPU_SRC=${CHIPLAB_HOME}/IP/myCPU
```

The verilator `run_prog/Makefile:57-62` **symlinks** it into the run directory
(`ln -sf ../../../chip/config-generator.mak ./`) and includes it; so *CPU selection =
"whatever `*.v` is in `${CHIPLAB_HOME}/IP/myCPU`"*, gated by `MYCPU=y`. There is **no**
`CPU_DIR` variable; the only knob is `MYCPU_SRC` in this file.
The iverilog Makefile `include`s `config-generator.mak` **without** creating the symlink
(`sims/iverilog/run_prog/Makefile:13`), so you must copy/symlink it there yourself.

### 4.3 verilator `run_prog` — exact commands

```bash
export CHIPLAB_HOME=/home/shorthair/dsh/rv32-cpu/chiplab
mkdir -p $CHIPLAB_HOME/toolchains/nemu           # needed for difftest (see 4.6)
cd $CHIPLAB_HOME/sims/verilator/run_prog
./configure.sh --run func/func_lab19             # or --run hello_world / dhrystone / linux / …
make                                             # = verilator + testbench + soft_compile + run
# partial rebuild after RTL changes:
make verilator testbench simulation_run_prog
gtkwave log/func/func_lab19_log/simu_trace.fst   # waveform (DUMP_FST=1 by default)
```

What `make` does (`sims/verilator/run_prog/Makefile`):

```make
231: verilator ${VERILATOR_INCLUDE} ${WAVEOPTION} --savable --threads ${THREAD} -O3 -Wno-fatal \
       -DSIMU -DSIMULATION=1 -Wall --trace -cc ${VFLAGS} ${SIMU_TOP_NAME}.v ${DIFFTEST}.v ${VERILATOR_SRC}
232: $(MAKE) -C ${OBJ_DIR} -f "V${SIMU_TOP_NAME}.mk"
240: g++ -O3 -pthread -DCACHE_SEED=0 -DVL_THREADED -DRESET_VAL=… -DRESET_SEED=… ${CFLAGS} ${INCLUDE} … -o output -lz -ldl
195: VFLAGS += -DDIFFTEST_EN
```
with `SIMU_TOP=../testbench`, `SIMU_TOP_NAME=simu_top`, `DIFFTEST=difftest`, and
`ALL_VERILATOR_SRC += ../testbench/*.v chip/soc_demo/sim/*.v`.

`configure.sh` (`sims/verilator/run_prog/configure.sh`) writes `config-software.mak`
(`RUN_SOFTWARE`, `TRACE_COMP`, `SIMU_TRACE`, `RUN_FUNC`/`RUN_C`, `DUMP_VCD/FST`, …) and
`config.log`; `--run` accepts `func/func_lab3 func_lab4 func_lab6 func_lab7 func_lab8
func_lab9 func_lab14 func_lab15 func_lab19 func_advance fireye/A0 B2 C0 D1 I2 my_program
memset dhrystone coremark linux rtthread lacc c_prg/*` (`configure.sh:8-16, 250-485`).
Runtime parameters live in `sims/verilator/run_prog/Makefile_run` (`DUMP_WAVEFORM`,
`TIME_LIMIT`, `BUS_DELAY`, `END_PC=1c000010`, fork/lightSSS settings) and are passed as CLI
flags to `./output` (`Makefile_run:23`).

Top-level Verilog name for the verilator testbench: **`simu_top`**
(`sims/verilator/testbench/simu_top.v:1`), whose ports are `aclk, aresetn, enable_delay,
random_seed, ram_*, debug0_wb_*, num_data, open_trace, num_monitor, confreg_uart_data,
write_uart_valid, uart_ctr_bus[127:0], uart_rx, uart_tx, led…` (`…:21-75`).

### 4.4 verilator `run_random`

`sims/verilator/run_random/` uses the same SoC/CPU sources with `-DRAND_TEST`
(`Makefile_run:176-179` in run_prog; analogous in run_random), config in
`config-random.mak` (`LA32=y`, `TRACE_COMP=y`, `DEAD_CLOCK_SIZE=10000`, …), random sequences
from `software/random_res/` (must be downloaded and unzipped by hand — `docs/Simulation/verilator.md:145-150`),
results in `log/*-result.txt`. `docs/Simulation/verilator.md:141-144` explicitly says: if you
do **not** wire the difftest signals, set `TRACE_COMP=n` in `config-random.mak` first.

### 4.5 iverilog `run_prog` (legacy, partially stale)

```bash
export CHIPLAB_HOME=/home/shorthair/dsh/rv32-cpu/chiplab
cd $CHIPLAB_HOME/sims/iverilog/run_prog
ln -sf ../../../chip/config-generator.mak .     # NOT done automatically
make compile                                     # iverilog … -o simv
mkdir -p obj && cp <built test>/obj/inst_ram.mif obj/    # see caveat below
make run                                         # ./simv
make wave                                        # gtkwave test.vcd (needs DUMP=n → no VCD!)
```

Exact compile line (`sims/iverilog/run_prog/Makefile:70-80`):

```make
73: iverilog -DSIMU ${VFLAGS} ${CFLAGS} -Diverilog=1 -g2012 ${VERILATOR_INCLUDE} ${VERILATOR_SRC} -s ${SIMU_TOP_NAME} -o simv
76: 	make -C ../../../software/func/${RUN_SOFTWARE}
77: 	mv ../../../software/func/${RUN_SOFTWARE}/obj ./
80: 	./simv
```

Testbench: `sims/iverilog/testbench/testbench.v`, module **`tb`**, `CLK_PERIOD = 2` ns,
`BUS_WIDTH=DATA_WIDTH=CPU_WIDTH=32`, instantiating `soc_top` (`…:101-146`) and driving the
external `sram_*` array `mem_inst_temp[262143:0]` (1 MiB) loaded from **`obj/inst_ram.mif`**
(`…:25-39`); memories are written with `ram_waddr[7:0]/[15:8]/…` (`…:77-99`, note the
testbench writes the *address* value, a known quirk).

Caveats (all verifiable in the tree):
* `-DSIMU` is defined but `-DDIFFTEST_EN` is **not**, and `difftest.v` is not compiled — the
  CPU must guard its `Difftest*` instances with `` `ifdef DIFFTEST_EN `` (§4.6).
* `Makefile:76` points at `software/func/${RUN_SOFTWARE}`; that path does **not** exist in
  this revision (the tests live in `software/examples/func/…`), so the `software` target and
  therefore `make all` fail. Build the test manually and copy `obj/inst_ram.mif` to
  `sims/iverilog/run_prog/obj/`, then run `make compile run`.
* `config-software.mak` ships `RUN_SOFTWARE=func_lab3`, `DUMP=n` (so `make wave` has no VCD).
* `testbench.v:9` does `` `define CPU soc.cpu `` and line 153 pokes
  `` `CPU.wb_stage.ws_excp && `CPU.wb_stage.ws_excp_num[5] `` — a **hard hierarchical
  dependency on the internal signals of the reference LA32 core**. For a new RV32 core this
  will not elaborate as-is: either keep an equivalent `wb_stage.ws_excp/ws_excp_num` pair, or
  edit the testbench to use `debug0_wb_pc`/the confreg instead (recommended — the docs
  themselves say "当前仅支持 verilator", `docs/Quick-Start.md:133`).
* The Icarus flow has no difftest, no golden trace, and no bus-delay model.

### 4.6 What the verilator/difftest flow demands from the CPU

`sims/verilator/testbench/difftest.v` defines 7 modules that the **CPU itself must
instantiate** (`sims/verilator/README_DIFF.md:13-19`, `docs/Simulation/difftest.md:13-19`):

| Module | Purpose | Key inputs |
|---|---|---|
| `DifftestInstrCommit` (`difftest.v:67-89`) | per-retired-instruction record | `clock, coreid, index, valid, pc[63:0], instr[31:0], skip, is_TLBFILL, TLBFILL_index[4:0], is_CNTinst, timer_64_value[63:0], wen, wdest[7:0], wdata[63:0], csr_rstat, csr_data[31:0]` |
| `DifftestExcpEvent` (`:101-114`) | exception/interrupt | `excp_valid, eret, intrNo[31:0], cause[31:0], exceptionPC[63:0], exceptionInst[31:0]` |
| `DifftestTrapEvent` (`:125-137`) | **unused — tie `valid=0`** (`README_DIFF.md:51`) | |
| `DifftestStoreEvent` (`:148-161`) | store compare | `index, valid[7:0], storePAddr[63:0], storeVAddr[63:0], storeData[63:0]` |
| `DifftestLoadEvent` (`:171-182`) | load compare | `index, valid[7:0], paddr[63:0], vaddr[63:0]` |
| `DifftestCSRRegState` (`:215-252`) | LA32 CSR file (crmd, prmd, euen, ecfg, estat, era, badv, eentry, tlbidx, tlbehi, tlbelo0/1, asid, pgdl, pgdh, save0-3, tid, tcfg, tval, ticlr, llbctl, tlbrentry, dmw0/1) | |
| `DifftestGRegState` (`:290-333`) | 32 GPRs | |

These feed DPI-C functions implemented in `sims/verilator/testbench/interface.cpp` →
`difftest.cpp`. `sims/verilator/run_prog/Makefile:195` adds `-DDIFFTEST_EN`, so guard the
instantiations with `` `ifdef DIFFTEST_EN ``.

The reference model is LA32 NEMU, loaded from
**`$CHIPLAB_HOME/toolchains/nemu/la32r-nemu-interpreter-so`** (spelled with **two** r's in
code: `sims/verilator/testbench/nemuproxy.cpp:15-24`; the docs write `la32-nemu-interpreter-so`
at `toolchains/README.md`). Without it, `difftest` aborts at start (`exit(1)`).
⇒ *For an RV32 core the LA32R NEMU reference is useless*: run with `--disable-trace-comp`
(`configure.sh:136-139` sets `TRACE_COMP=n`) so `TRACE_COMP` is not defined and the NEMU
`.so` is not opened.

### 4.7 How a program is loaded, how the sim ends, how pass/fail is reported

* **Load**: the C++ RAM model reads `tmp/ram.dat`, built by concatenating the software build's
  `obj/rom.vlog` (`sims/verilator/run_prog/Makefile:304-306`), then `Makefile_run:23` runs
  `../output …`. The CPU starts at **`FIRST_INST_ADDRESS 0x1c000000`**
  (`sims/verilator/testbench/include/common.h:8-10`).
* **Sim RAM model**: `ram.cpp:236-253` maps `(addr & 0xff000000) == 0x1c000000` directly, and
  every other address through `addr & 0x07ffffff`; the model is sparse/sectioned
  (`ram.h:26-33`: 256 tags × 1 MiB pages).
* **End of simulation**: when the **retired PC** equals `END_PC`. `END_PC` is compile-time in
  `sims/verilator/testbench/include/difftest.h:20-27` (`RUN_FUNC → 0x1c000130`,
  `RUN_C → 0x1c000548`, `RAND_TEST → 0x9c005000`, else `0x123`) using the difftest commit PC,
  and in `include/golden_trace.h:17-22` (`RUN_FUNC → 0x1c000100`, `RUN_C → 0x0`) using
  `top->debug0_wb_pc`; a runtime override `--end-pc` comes from `Makefile_run:7`
  (`END_PC=1c000010`). Comparisons: `golden_trace.h:229-234`, `difftest.cpp:107,143`.
* **Pass/fail** is reported by `golden_trace.h:407-425`: it watches the confreg NUM register
  and prints `Number %d Functional Test Point PASS!!!` / `Error(%d)!! occurred in number %d`,
  ending with `====PASS!====` or `Fail!!! Total %d errors!` (`golden_trace.h:470-479`).
* The "commit" event that drives all of this is gated on
  `debug0_wb_rf_wen != 0 && debug0_wb_rf_wnum != 0` (`golden_trace.h:213`) — a write to `x0`
  is invisible to the trace machinery.
* Software end protocol (LA32R source, for reference): `software/examples/func/func_src/start.S:86-96`
  places `test_finish` at `.org 0x200` (i.e. `0x1c000200`):
  ```
  test_finish:
      addi.w    t0, t0, 1        # t0 == 0 for PASS, 1 for FAIL (set in start.S test_end)
      LI        (t2, UART_ADDR)  # 0xbfd0ff10 (or 0xbfafff10) = confreg virtual UART
      st.w      zero, t2, 0      # write 0 -> latches/flushes the virtual-UART character
      nop
      b   1f
  .org 0x230
  1:  syscall 0x11               # SYS exception: the conventional "test over" trap
  ```
  and `start.S` `test_end` writes the RGB LEDs: `LED_RG0=LED_RG1=1` (green) on PASS,
  `=2` (red) on FAIL (see §6.4).

---

## 5. FPGA flow — `fpga/loongson/**`

### 5.1 `Makefile` and `configure.sh`

`fpga/loongson/Makefile:1-26`: includes `config-software.mak`, symlinks
`../../chip/config-generator.mak`, and `soft_compile` runs
`make -C ${LAB_HOME}/software/${soft} script` (note: uses `LAB_HOME`, **not**
`CHIPLAB_HOME`, and a `script` target — both are stale relative to the current software tree).
`fpga/loongson/configure.sh` only writes `RUN_SOFTWARE`/`RUN_FUNC` into
`config-software.mak`; accepted values: `func/func_lab3..9`, `coremark`, `dhrystone`
(`configure.sh:57-92`). There is **no** synthesis/bitstream target in the Makefile — the
Makefile is only a software-side helper. Synthesis is driven from the Vivado project.

### 5.2 `fpga/loongson/soc_up.xdc` (summary)

* `set_property PACKAGE_PIN AC19 [get_ports clk]`, `CLOCK_DEDICATED_ROUTE BACKBONE`,
  **`create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]`**
  → **board clock 100 MHz** (`soc_up.xdc:4-6`). It does **not** say 33 MHz.
* `resetn` pin `Y3` (`:9`).
* Pins for `led[15:0]` (`:12-27`), `led_rg0/1` (`:30-33`), `num_csn[7:0]`/`num_a_g[6:0]`
  (`:36-51`), `switch[7:0]` (`:55-62`), `btn_key_col/row`, `btn_step` (`:65-76`),
  SPI (`SCK P20, CS R20, MISO P19, MOSI N18`, `:79-82`), MII MAC + MIIM (`:85-103`),
  `UART_RX F23 / UART_TX H19` (`:106-109`), debug UART `M25/P25` (`:112-115`),
  NAND (`:118-131`), EJTAG (`:134-138`).
* IOSTANDARD `LVCMOS33` for everything except DDR3 (DDR3 pins come from the MIG `.prj`:
  `IP/xilinx_ip/2023.2/mig_axi_32_loongson/mig_a.prj:44-…`, SSTL15/DIFF_SSTL15).
* Additional clocks: `create_clock -period 40.000` for `mrxclk_0`/`mtxclk_0` (25 MHz, `:194-195`);
  false paths between `clk_pll_i`, `clk_out1/2_clk_pll_33`, `mrxclk_0`, `mtxclk_0`
  (`:197-205`).
* **No pin constraint for the CPU** — the CPU is internal; only `soc_top`'s ports are pinned.
* The 33 MHz figure lives in the PLL IP, not in the XDC: `clk_pll_33` `CLKOUT2_REQUESTED_OUT_FREQ = 33.000`
  (`IP/xilinx_ip/2023.2/clk_pll_33/clk_pll_33.xci:90,349,370`), `CLKOUT1 = 50.000`.

### 5.3 The two committed Vivado projects

| Property | `fpga/loongson/2019.2/system_run.xpr` | `fpga/loongson/2023.2/system_run.xpr` |
|---|---|---|
| Vivado version | `Vivado v2019.2 (64-bit)` (line 2) | `Vivado v2023.2 (64-bit)` (line 2) |
| Part | **`xc7a200tfbg676-2`** (line 10, and repeated on every `Run` element) | **`xc7a200tfbg676-2`** (line 11) |
| Top module | `soc_top` — both `sources_1` (line 452) and `sim_1` (line 474 / 546,568) | `soc_top` (`sources_1` 546 / `sim_1` 568) |
| Active sim set | `sim_1` | `sim_1` |

Source/IP file list (identical in both, only the `IP/xilinx_ip/{2019.2,2023.2}` prefix and
the `.xci` vs `.xcix` split differ):

```
../soc_up.xdc
chip/soc_demo/loongson/soc_top.v          (from ../../../chip/soc_demo/loongson/)
chip/soc_demo/loongson/config.h
IP/AMBA/axi2apb.v, IP/AMBA/axi_mux_syn.v
IP/APB_DEV/apb_dev_top_with_nand.v, apb_mux2.v, nand_module.v
IP/APB_DEV/NAND/nand.v
IP/APB_DEV/URT/{uart_top,uart_regs,uart_receiver,uart_transmitter,uart_rfifo,uart_tfifo,raminfr,uart_sync_flops}.v
IP/APB_DEV/URT/uart_defines.h
IP/CONFREG/confreg_syn.v
IP/DEBUG/{debug_top.v,debug_sram.v}
IP/DMA/dma.v
IP/MAC/{ethernet_top,mac_top,mac,mac_axi,mac2axi,maccsr2axi,macdata2axi,csr,dma,bd,rc,tc,rlsm,tlsm,rfifo,tfifo,rstc,utility}.v
IP/SPI/godson_sbridge_spi.v
IP/xilinx_ip/<ver>/{axi_2x1_mux/axi_2x1_mux.xci, axi_clock_converter_0/axi_clock_converter_0.xcix,
    axi_interconnect_0/axi_interconnect_0.xci, clk_pll_33/clk_pll_33.xci,
    clk_wiz_0_loongson/clk_wiz_0.xci, dpram_512x32/dpram_512x32.xci,
    mig_axi_32_loongson/{mig_axi_32.xci,mig_a.prj},
    sram_128x22, sram_128x32, sram_128x64, sram_32x52bit}
```

**Neither `.xpr` contains a single `IP/myCPU` entry, and neither contains any testbench file**
(so "Run Simulation" would fall back to whatever `sim_1` contains — the SoC itself).

**Part numbers elsewhere** (for completeness): `fpga/Baixin/system_run/system_run.xpr` →
`xc7a200tfbg676-2`; `fpga/nexys4ddr/system_run/system_run.xpr` → `xc7a100tcsg324-1`
(`fpga/nexys4ddr/readme.md` says Nexys 4 DDR has no NAND controller and uses SPI flash
`s25fl128sxxxxxx0-spi-x1_x2_x4`).

### 5.4 Project generation: GUI, not Tcl (for this board)

* `fpga/loongson/` contains **no `.tcl` file at all**; the only Tcl scripts in the repo live
  under `fpga/nscscc-team/run_vivado/` (`create_project.tcl`, `bit.tcl`, `vio.tcl`,
  `jtag_axi_master.tcl`, `run_allbench.tcl`, `run_func_test.tcl`).
* Therefore the supported (and only) path for the 龙芯实验箱 board is: **open
  `fpga/loongson/20xx.2/system_run.xpr` in the Vivado GUI, `Add Sources` your CPU RTL (and any
  Xilinx IP it needs), then run synthesis/implementation/generate bitstream**
  (`docs/Quick-Start.md:139-143`).
* For a CLI/scripted rebuild you can either (a) `open_project fpga/loongson/2023.2/system_run.xpr`
  after adding files once, or (b) copy the pattern of `fpga/nscscc-team/run_vivado/create_project.tcl`
  (which does `create_project`, `add_files`, `add_files -scan_for_includes ../../../IP/myCPU`,
  `glob IP/myCPU/xilinx_ip/*/*.xci[x]`, `add_files ../soc_up.xdc`,
  `set_property top soc_top`) and adapt the file list from §5.3. **No such script exists for
  fpga/loongson today.**
* The stale testbenches: `fpga/{loongson,Baixin,nexys4ddr}/testbench/{mycpu_tb.v,tb_top.v}`
  are byte-identical copies of the 龙芯杯 testbench — they define `module tb_top` and
  instantiate **`soc_lite_top`** (e.g. `fpga/loongson/testbench/mycpu_tb.v:43,69`), which does
  not exist in these SoC variants, and they poke
  `soc_lite.confreg.num_data/num_monitor`. They cannot be used for the loongson SoC as-is.

### 5.5 Bitstream download / board bring-up (operational)

`docs/FPGA_run_linux/linux_run.md`:
* Program `gzrom.bin` (PMON) or `u-boot.bin` **into the SPI flash** first (§8/§9); the
  programmer bitstream `programmer_by_uart.bit` is downloaded like any bitstream, then the
  binary is pushed over the serial port with **xmodem at 230400 baud** (`flash.md:17-21`).
* Download the SoC bitstream with Vivado **Open Hardware Manager** (`linux_run.md:12-14`).
* Serial console for PMON/u-boot/Linux: **115200 8N1** (`linux_run.md:17,29,41,73,96`).
* PMON: `ifconfig dmfe0 10.90.50.44`, `ping …`, `load tftp://<srv>/vmlinux`, then
  `g console=ttyS0,115200 rdinit=sbin/init`; u-boot: `setenv ipaddr/serverip`,
  `tftpboot 0xa3000000 vmlinux`, `bootelf 0xa3000000 bootcmd` (`linux_run.md:52-175`).
  Note `0xa3000000` is kseg1 → physical `0x03000000`, i.e. **DDR3**.
* NAND: `mtd_erase /dev/mtd0r`, `devcp tftp://… /vmlinux /dev/mtd0`,
  `set mtdparts nand-flash:50M@0(kernel)ro,-(rootfs)`, `set al /dev/mtd0`
  (`linux_run.md:98-133`).

---

## 6. CONFREG (`IP/CONFREG/**`)

### 6.1 Two implementations — pick the right one

| File | Used by | Interface | Address base used by its decode |
|---|---|---|---|
| `IP/CONFREG/confreg_sim.v` (module `confreg`, `:104-131`) | verilator + iverilog (`sims/*/Makefile` explicitly compile `confreg_sim.v` only) | SRAM-like: `conf_ren, conf_wen[DATA_WIDTH/8-1:0], conf_raddr[BUS_WIDTH-1:0], conf_waddr, conf_wdatain[DATA_WIDTH-1:0], conf_rdata` + `timer_clk` | `0x1fd0_xxxx` (special FREQ page) / low 16 bits for everything else |
| `IP/CONFREG/confreg_syn.v` (module `confreg`, `:43-106`) | Vivado (listed in both `.xpr`) | **AXI slave** (`s_awid[3:0], s_awaddr[31:0], …, s_wstrb[3:0], s_rdata[31:0]`) + `aclk/aresetn` | low 16 bits of `buf_addr` |

`chip/soc_demo/nscscc-team/CONFREG/confreg.v` is a third copy used only by the 龙芯杯 SoC.

### 6.2 Register maps

**`confreg_sim.v` (active defines, `:77-102`)** — this is what the simulation uses, and it
matches the default (`#ifndef nscscc`) software header
`software/examples/func/func_lab3/include/cpu_cde.h:4-30` exactly:

| Offset (16-bit) | Full physical (base `0x1FD0_0000`) | Software symbol | Meaning |
|---|---|---|---|
| `0x8000 + 0x10*n`, n=0..7 | `0x1FD0_8000`…`0x1FD0_8070` | `CONFREG_CR0..CR7` | 8 free 32-bit scratch regs (also used by DMA order protocol) |
| `0xf020` | `0x1FD0_F020` | `LED_ADDR` | 16 single-colour LEDs (`led[15:0]`), R/W |
| `0xf030` | `0x1FD0_F030` | `LED_RG0_ADDR` **and** `FREQ_ADDR` | **write → RGB0 value; read → `FREQ`** (33 000 000) — the read is only taken when `conf_raddr[28:16]==0x1fd0` (`:171-176`) |
| `0xf040` | `0x1FD0_F040` | `LED_RG1_ADDR` | RGB1 value (`1`=green, `2`=red) |
| `0xf050` | `0x1FD0_F050` | `NUM_ADDR` | 7-segment display value; **the testbench watches this for PASS/FAIL** |
| `0xf060` | `0x1FD0_F060` | `SWITCH_ADDR` | `{24'd0, switch[7:0]}`, read-only |
| `0xf070` | `0x1FD0_F070` | `BTN_KEY_ADDR` | keypad matrix, read-only |
| `0xf080` | `0x1FD0_F080` | `BTN_STEP_ADDR` | step buttons, read-only |
| `0xf090` | `0x1FD0_F090` | `SW_INTER_ADDR` | bit-interleaved switches, read-only |
| `0xe000` | `0x1FD0_E000` | `TIMER_ADDR` | CPU-writable start value; free-running +1 every `timer_clk` (`:242-298`); `timer_r2` is readable |
| `0xff00` | `0x1FD0_FF00` | `IO_SIMU_ADDR` | byte-swapped 32-bit I/O mirror (`:312-320`) |
| `0xff10` | `0x1FD0_FF10` | `VIRTUAL_UART_ADDR` | **write byte → "fake UART" character** (captured by the TB into `uart_output.txt`) |
| `0xff20` | `0x1FD0_FF20` | `SIMU_FLAG_ADDR` | read-back of `{32{SIMULATION}}` → **`0xFFFF_FFFF` in simulation** (reset value, never written: `:300-306`); the "am I in simulation" magic |
| `0xff30` | `0x1FD0_FF30` | `OPEN_TRACE_ADDR` | trace-compare enable, default 1 (`:325-337`) |
| `0xff40` | `0x1FD0_FF40` | `NUM_MONITOR_ADDR` | `num_monitor` enable, default 1 (`:340-352`) |

**`confreg_syn.v` (FPGA, defines `:33-42`)** — offsets are **different**:

| Offset | Full physical | Meaning |
|---|---|---|
| `0x0000 + 4*n`, n=0..7 | `0x1FD0_0000`…`0x1FD0_001C` | `cr00..cr07` (`:250-268`; note `buf_addr[15:2]==0..7`) |
| `0x1160` | `0x1FD0_1160` | `ORDER_REG_ADDR` (DMA order register) |
| `0xf000` | `0x1FD0_F000` | `led[15:0]` |
| `0xf004` / `0xf008` | `0x1FD0_F004/F008` | `led_rg0` / `led_rg1` |
| `0xf010` | `0x1FD0_F010` | `num_data` (7-seg) |
| `0xf020` / `0xf024` / `0xf028` | … | `switch` / `btn_key` / `btn_step` (read-only) |
| `0xf030` | `0x1FD0_F030` | `FREQ` read-back (`config.h \`FREQ`) |
| `0xe000` | `0x1FD0_E000` | `timer` (free-running, CPU-writable) |

* Base address in the SoC address map: **`0x1FD0_0000`** (decoded by
  `IP/AMBA/axi_mux_syn.v:858`, `axi_mux_sim.v:858-859`); software normally uses the kseg1
  alias **`0xBFD0_0000`**.
* ⚠️ The CR-register offsets differ between sim (`0x8000+0x10n`) and FPGA (`0x0000+4n`), while
  both software headers use `0xbfd0_8000+0x10n`. Consequence: CR scratch writes work in
  simulation but are silently ignored on the FPGA. See §13.

### 6.3 How a CPU writes to CONFREG

1. CPU issues a normal AXI write/read to `0x1FD0_xxxx` (or the kseg1 alias `0xBFD0_xxxx`).
2. `axi_slave_mux` routes it to slave `s3` (`IP/AMBA/axi_mux_syn.v:858,949`).
3. FPGA: `confreg_syn.v` is the AXI slave (single-outstanding, `s_wready` handshake,
   `\`FREQ` returned for `FREQ_ADDR`).
   Simulation: `soc_axi_sram_bridge` converts it into `conf_ren/conf_wen + conf_raddr/
   conf_waddr/conf_wdatain` (`chip/soc_demo/sim/soc_top.v:812-864`) and `confreg_sim.v`
   decodes the **low 16 bits** (`:213-220`, `:250`), which is why the kseg1 alias also works
   in simulation.
4. Read data has one cycle of latency inside `confreg_sim` (`:160-162`).

### 6.4 The "magic values" used by test programs

* **Virtual UART** (`0x1FD0_FF10` / `0xBFD0_FF10`): writing a byte prints it. The verilator TB
  exposes `soc.confreg.confreg_uart_data`/`write_uart_valid` through `simu_top.v:78-83` and
  logs to `uart_output.txt` (fake UART) and `uart_output.txt.real` (16550 UART).
* **`SIMU_FLAG_ADDR` (`0x1FD0_FF20`)** reads `0xFFFF_FFFF` in simulation because the build
  defines `-DSIMULATION=1` (`sims/verilator/run_prog/Makefile:231`) and the reset value is
  `{32{SIMULATION}}` (`confreg_sim.v:300-306`) — this is the "running under simulation"
  magic.
* **`NUM_ADDR` (`0x1FD0_F050`)**: the functional test writes its test-point counter here; the
  C++ testbench compares it against the previous value and prints
  `Number N Functional Test Point PASS!!!` / `Error(...) occurred in number N`
  (`golden_trace.h:407-425`).
* **`LED_RG0/LED_RG1`** (`0x1FD0_F030/F040`): `1` = green = PASS, `2` = red = FAIL —
  written by `software/examples/func/func_src/start.S` `test_end` (§4.7).
* **End-of-simulation**: *not* a memory magic. The TB ends on **PC match** against `END_PC`
  (compile-time or `--end-pc`, §4.7); the program's `test_finish` writes 0 to the virtual UART
  and then executes `syscall 0x11` at `0x1c000230`
  (`software/examples/func/func_src/start.S:86-96`).

---

## 7. The SoC memory map (explicit table)

Decode sources: `IP/AMBA/axi_mux_syn.v:854-860,946-951` (FPGA),
`IP/AMBA/axi_mux_sim.v:854-861,947-956` (sim), `IP/APB_DEV/apb_mux2.v:155-160`,
`IP/SPI/godson_sbridge_spi.v:189-192`, `software/bsp/env/*.lds`,
`software/examples/func/func_lab3/include/cpu_cde.h:4-30`.

| Region | Physical address | Size / decode | Slave (`axi_slave_mux`) | Used by software as | Notes |
|---|---|---|---|---|---|
| **DDR3 SDRAM** | `0x0000_0000`–`0x07FF_FFFF` (128 MiB) | **default**: any address not matching the 4 special ranges; MIG sees `addr[26:0]` | `s0` → `axi_interconnect_0` S00 → `mig_axi_32` (32-bit AXI, 27-bit addr) | `0x8xxx_xxxx`/`0xaxxx_xxxx` (kseg0/kseg1, phys 0x0…) — e.g. u-boot `tftpboot 0xa3000000` | MT41J64M16 (1 Gb, 16-bit) ⇒ 128 MiB; **all other addresses alias here** |
| **SPI flash XIP window** | `0x1C00_0000`–`0x1C0F_FFFF` | `addr[31:20]==12'h1c0` (**FPGA mux only**; absent in the sim mux) | `s1` → `spi_flash_ctrl` | PMON / u-boot boot code (`gzrom.bin`, `uboot.bin` in SPI flash) | flash offset = `addr[23:0]` (`godson_sbridge_spi.v:192`) |
| **CONFREG** | `0x1FD0_0000`–`0x1FD0_FFFF` | `addr[31:16]==16'h1fd0` (sim also `addr[28:16]==0x1faf`) | `s3` | `0xBFD0_xxxx` (kseg1) | §6 |
| **UART 16550** | `0x1FE0_0000`–`0x1FE0_3FFF`, registers at **`0x1FE0_01E0`** | `addr[31:16]==0x1fe0` → APB; `apb_addr[19:14]==0` → UART | `s2` → `axi2apb` → `apb_dev_top_with_nand` | `UART_BASE = 0xbfe001e0` | 8-bit APB device, 115200 8N1 |
| **NAND controller** | `0x1FE0_4000`–`0x1FE7_FFFF` (hardware: any APB access with `apb_addr[19:14]!=0`; **software uses `0x1FE7_8000`**), reachable via AXI only when `addr[31:16]∈{0x1fe0,0x1fe7}` | `apb1_req = !apb0_req` (`apb_mux2.v:156`) | `s2` | PMON/u-boot `mtd0` (`0x1fe78000`) | **FPGA only** — the simulation SoC compiles `apb_dev_top_no_nand.v` |
| **SPI flash controller regs** | `0x1FE8_0000`–`0x1FE8_000F` | `addr[31:16]==0x1fe8` in mux + `buf_addr[31:4]==0x1fe8000` & `len==0` in the IP | `s1` | flash programming/XIP control | `spi_addr(16'h1fe8)` at `soc_top.v:1227` |
| **MAC (ethernet_top)** | `0x1FF0_0000`–`0x1FF0_FFFF` | `addr[31:16]==0x1ff0` | `s4` | PMON/u-boot `dmfe0`, Linux | also an AXI **master** (S01 of `axi_interconnect_0`) |
| **DMA** | (master only) | — | S02 of `axi_interconnect_0` | device→memory transfers | 64-bit AXI master |
| **Simulation SRAM** | `0x1C00_0000`–`0x1CFF_FFFF` mapped directly, everything else masked with `0x07FF_FFFF` | `ram.cpp:236-253`; RTL side is `soc_axi_sram_bridge` on `s0` | `s0` in the **sim** mux | program+data (`separate.lds`: ISRAM `0x1C00_0000` 512 K, DSRAM `0x1C08_0000` 512 K; func tests use `single.lds`/`bin.lds` = `0x1C00_0000`) | 1 MiB RTL-visible (`mem_inst_temp[262143:0]`, `ram_raddr[19:2]`), sparse C++ model above that |

Software linker scripts: `software/bsp/env/separate.lds:4-7`
(`isram 0x1c000000 len 512K`, `dsram 0x1c080000 len 512K`),
`software/bsp/env/single.lds:6` (`sram 0x1c000000 len 1024K`),
`software/examples/func/func_lab3/bin.lds:8` (`. = 0x1c000000`),
`software/bsp/env/qemu.lds:6-7` (`0xa0300000` — QEMU only).

---

## 8. Docs — the operational facts

`docs/Quick-Start.md`
* Env var: `export CHIPLAB_HOME="your own chiplab pwd address"` (`:65-67`).
* CPU selection: drop your core into `IP/myCPU`; module name and interface are fixed (`:69-125`).
* Simulation: `cd $CHIPLAB_HOME/sims/verilator/run_prog` → `./configure.sh --run func/func_lab16`
  → `make` → `gtkwave log/func/func_lab16_log/simu_trace.vcd` (`:132-137`, and
  `sims/verilator/README.md:5-11`); "当前仅支持 verilator" (`:133`).
* Synthesis: open `loongson/20*.2/system_run.xpr` or `Baixin/system_run/system_run.xpr`, add
  the core code, synthesize; the CPU input clock defaults to 33 MHz and is set by the
  `clk_pll_33` Xilinx IP output, and you must keep `config.h`'s `FREQ` in sync (`:139-142`).
* Board boot: flash → PMON/u-boot → TFTP kernel; `./ub.sh`, `cd pgms`, `./context1 10` (`:143-158`).
* FAQ: fix `VERILATOR_HOME` in `sims/verilator/run/Makefile` if verilator is installed
  elsewhere (`:159-166`).
* Third-party tools: `sudo apt install verilator gtkwave` (verilator ≥ 4.224) (`:58`),
  `export CHIPLAB_HOME=…` (`:67`).

`docs/Simulation/verilator.md`
* Tool requirements: `sudo apt install verilator gtkwave`, verilator ≥ 4.224 (`:21`,
  `Quick-Start.md:56-59`); NEMU required for difftest (`:21`).
* `configure.sh` options in full (`:44-72`), `Makefile_run` runtime options (`:79-91`),
  `make` = `verilator` + `testbench` + `soft_compile` + `simulation_run_prog` (`:96-100`),
  `make clean` / `clean_all` / `clean_soft` (`:102-115`).
* Partial rebuild: **`make verilator testbench simulation_run_prog`** (`:117-120`).
* Outputs: `log/simu_trace.txt`, `mem_trace.txt`, `simu_trace.fst`, `uart_output.txt`
  (fake UART), `uart_output.txt.real` (real UART) (`:121-131`); `obj/main.elf`, `obj/test.s`.
* Waveform: `gtkwave simu_trace.fst` (`:134`); enable with `DUMP_WAVEFORM=1` in `Makefile_run`
  (`:27-36`). If `ctrl-c`'d, only `simu_trace.txt` survives in `tmp/` (`:136`).
* Simulation speed tips: newer verilator, fix `UNOPT`/`UNOPTFLAT`, use `--threads` for big
  designs, disable `--output-pc-info`, disable waveform dumping (`:217-224`).
* Debug tip: watch `simu_top.v`'s `ram*` signals to check the AXI requests/data (`:215`).

`docs/Simulation/difftest.md` + `sims/verilator/README_DIFF.md`
* The CPU instantiates the `Difftest*` modules defined in `difftest.v`; the reference is
  la32-nemu (`README_DIFF.md:5-7`); all GPRs and CSRs except `estat` are compared; store
  PAddr/data mismatch aborts immediately (`:5`).
* Signal-by-signal description of each `Difftest*` module (`difftest.md:21-87`), including the
  advice to delay some signals by one cycle (`:19`) and to tie `DifftestTrapEvent.valid = 0`
  (`:51`).
* Customisation: `compare_mask` in `difftest.cpp` / `DIFFTEST_NR_REG` (`difftest.md:91`).

`docs/Simulation/lightsss.md`
* lightSSS waveform-forking requires verilator > 5.016 and `std=c++14` (`:8-13`);
  enable with `FORK_CHILD=1` + `DUMP_WAVEFORM=0` in `Makefile_run`; the split/tail waveform
  features are disabled when it is on (`:15-25`).
* Tunables `--fork-interval`, `--slot-size`, `--wait-interval` (`:26-31`).

`docs/Debug/debug.md` (UART-based online debug, `Python3 + pyserial`)
* `python3 debug.py` (⚠️ **no `debug.py` exists anywhere in this tree** — only
  `chip/soc_demo/nscscc-team/uart_debug/uart_downloader.py`; the debugger script lives in the
  external `chiplab-tools` release).
* Commands: `trace/t <pc>`, `list`, `break/b <pc>`, `step [n]`, `continue/c`,
  `infor <n>|all`, `infom <addr> [addr2]` (`:3-13`); commands 4-10 require a breakpoint first (`:16`).
* Signals the core must provide: `debug_pc`, `debug_num`, `debug_data`, `ws_valid`,
  `break_point`, `infor_flag`, `reg_num`, `rf_rdata`; semantic requirements: `break_point`
  must stop the core in the same cycle; `rf_rdata` must be valid in the same cycle as
  `infor_flag`+`reg_num` (`:18-31`). Commands 1-2 only need the first three (`:31`).
* Host setup needs `python3`, `pyserial`, and a TTL-level USB-serial adapter (`:34-35`).

`docs/FPGA_run_linux/flash.md` / `linux_run.md` — see §5.5.

---

## 9. NAND / flash / SPI / MAC / DMA inventory

| Device | IP | Present in | Interface | Software access |
|---|---|---|---|---|
| **NAND flash controller** | `IP/APB_DEV/NAND/nand.v` (module `NAND_top`) wrapped by `IP/APB_DEV/nand_module.v` and `IP/APB_DEV/apb_dev_top_with_nand.v` | FPGA (loongson, Baixin); **not** in sim (`apb_dev_top_no_nand.v`); explicitly removed on Nexys4-DDR (`fpga/nexys4ddr/readme.md`) | APB, 20-bit addr, 8-bit data; `nand_type=2'h2` (1 Gbit) in the nscscc SoC; 4 chip enables, ready/interrupt | PMON/u-boot `mtd` (`0x1fe78000`), Linux MTD; "128 MB NandFlash as a disk" (`linux_run.md:98-133`) |
| **SPI flash controller** | `IP/SPI/godson_sbridge_spi.v` (module `spi_flash_ctrl`) | FPGA only | AXI slave (`0x1fe8_xxxx`, 16 B of registers, single-beat only: `io_hit` requires `buf_len==0`) + XIP read window | boot code in SPI flash (PMON/u-boot); programming over UART with `programmer_by_uart.bit` @230400 baud |
| **MAC / Ethernet** | `IP/MAC/*` (`ethernet_top`, `mac_top`, `mac`, `csr`, `dma`, `rc`, `tc`, `rlsm`, `tlsm`, …) + `mii_to_rmii_v2_0` IP | FPGA | AXI slave at `0x1ff0_xxxx` **and** AXI master (S01 of `axi_interconnect_0`) | PMON `dmfe0`, `ifconfig`, `ping`, `load tftp://…`, `tftpboot` |
| **DMA** | `IP/DMA/dma.v` | FPGA | 64-bit AXI master (S02 of `axi_interconnect_0`); APB master path into `apb_mux2` for NAND | driven by confreg `ORDER_REG_ADDR`/CR regs; used for NAND↔memory transfers |
| **Debug (UART) engine** | `IP/DEBUG/debug_top.v` + `debug_sram.v` | FPGA | second AXI **read** master into `axi_2x1_mux` S01 (`uart_*`), plus `UART_RX2/TX2` | §8 `debug.md`; `uart_downloader.py` for the 龙芯杯 variant |
| **ram_wrap / SRAM** | `chip/soc_demo/nscscc-team/ram_wrap/{axi_wrap_ram,axi_wrap_ddr,fpga_sram_dp,fpga_sram_sp,cache_sram}.v` | 龙芯杯 SoC only | — | **not present in the loongson SoC or in `chip/soc_demo/sim`** (sim uses `IP/AXI_SRAM_BRIDGE/soc_axi_sram_bridge.v` instead) |

---

## 10. Clock frequencies

| Clock | Value | Evidence |
|---|---|---|
| Board `clk` input | **100 MHz** | `fpga/loongson/soc_up.xdc:6` (`create_clock -period 10.000`) |
| `clk_pll_33.clk_out1` → **`cpu_clk`** (CPU + CPU-side AXI) | **50 MHz** | `soc_top.v:1463` comment `//50MHz`; `IP/xilinx_ip/{2019.2,2023.2}/clk_pll_33/clk_pll_33.xci` `CLKOUT1_REQUESTED_OUT_FREQ=50.000` |
| `clk_pll_33.clk_out2` → `uncore_clk` → **`aclk`** (platform AXI: mux, confreg, SPI, APB, MAC) | **33 MHz** | `soc_top.v:1464,1477`; xci `CLKOUT2_REQUESTED_OUT_FREQ=33.000` / `C_CLKOUT2_OUT_FREQ=33.00000` |
| `clk_wiz_0` (= `clk_wiz_0_loongson` IP) `clk_out1` → `c1_clk_ref_i` (DDR3 MIG reference) | **200 MHz** | `soc_top.v:1469-1473`; `IP/xilinx_ip/2023.2/clk_wiz_0_loongson/clk_wiz_0.xci:35,87` (`PRIM_IN_FREQ 100`, `CLKOUT1_REQUESTED_OUT_FREQ 200`) |
| MIG `ui_clk` = `c1_clk0` (DDR3 AXI domain, `axi_interconnect_0`, DMA, MAC master) | **100 MHz** | `IP/xilinx_ip/2023.2/mig_axi_32_loongson/mig_axi_32.xci`: `C0_FREQ_HZ = 100.0`, `FREQ_HZ = 100000000`, `C_S_AXI_ADDR_WIDTH = 27`, `C_S_AXI_DATA_WIDTH = 32`; DDR3 tCK 2500 ps with 4:1 PHY ratio (`mig_a.prj`: `TimePeriod 2500`, `PHYRatio 4:1`) |
| `mtxclk_0` / `mrxclk_0` (MII) | **25 MHz** | `soc_up.xdc:194-195` (`-period 40.000`) |
| Simulation | no absolute frequency (`CLK_PERIOD 2` ns in `sims/iverilog/testbench/testbench.v:3`; verilator toggles aclk once per `EVAL`, `testbench.cpp:103`) | |
| `\`FREQ` (software-visible, `confreg` `0x1FD0_F030`) | **33 000 000** | `chip/soc_demo/loongson/config.h:33` (`\`define FREQ 32'd33000000`) |
| Software `CORE_CLOCKS_PER_SEC` | **33 000 000** (overridable; `weak` symbol) | `software/bsp/drivers/confreg_time.c:6-8` |
| Software `CONFREG_CLOCKS_PER_SEC` | **100 000 000** | `software/bsp/drivers/confreg_time.c:7` |

⚠️ In this revision the CPU clock is **50 MHz** while `FREQ`/`CORE_CLOCKS_PER_SEC` still say
33 MHz (the 33 MHz is the *uncore*/AXI clock). `docs/Quick-Start.md:142` tells you to keep
them consistent. See §13.

---

## 11. CPU port list table (the `core_top` contract)

Compiled from `docs/Quick-Start.md:72-131` / `nscscc_readme.md:108-167` (canonical declaration,
32-bit AXI) cross-checked against every instantiation
(`chip/soc_demo/sim/soc_top.v:340-401` with its direction comments,
`chip/soc_demo/loongson/soc_top.v:723-776`, `Baixin:692-…`, `nexys4ddr:477-…`,
`nscscc-team:529-…`). Widths are for the **default AXI32** configuration.

| # | Signal | Dir (CPU view) | Width | Meaning / platform connection |
|---|---|---|---|---|
| 1 | `aclk` | in | 1 | CPU clock = `cpu_clk` (50 MHz on the loongson board) |
| 2 | `aresetn` | in | 1 | active-low reset, synchronized to `aclk` (`cpu_aresetn`) |
| 3 | `intrpt` | in | 8 | interrupt lines; loongson `{3'b0,dma,nand,spi,uart,mac}`; sim `{6'b0,uart,1'b0}`. Docs declare `[7:0]`; the FPGA comment says "232 only 5bit" (`soc_top.v:725`) |
| 4 | `arid` | out | 4 | read address ID (`\`LID`) |
| 5 | `araddr` | out | 32 | read address (physical) |
| 6 | `arlen` | out | 8 (docs) / wire is 4 | read burst length; **keep ≤ 15 beats** |
| 7 | `arsize` | out | 3 | read burst size (2 = 4 bytes for words) |
| 8 | `arburst` | out | 2 | `2'b01` = INCR recommended |
| 9 | `arlock` | out | 2 | use `2'b00` (Xilinx side uses only bit 0) |
| 10 | `arcache` | out | 4 | forwarded to all slaves, not interpreted |
| 11 | `arprot` | out | 3 | forwarded, not interpreted |
| 12 | `arvalid` | out | 1 | |
| 13 | `arready` | in | 1 | |
| 14 | `rid` | in | 4 | read ID echo |
| 15 | `rdata` | in | 32 | read data (64 with `AXI64`, 128 with `AXI128`) |
| 16 | `rresp` | in | 2 | all platform slaves return `2'b00` |
| 17 | `rlast` | in | 1 | |
| 18 | `rvalid` | in | 1 | |
| 19 | `rready` | out | 1 | |
| 20 | `awid` | out | 4 | write address ID |
| 21 | `awaddr` | out | 32 | write address (physical) |
| 22 | `awlen` | out | 8 (docs) / wire is 4 | write burst length; **keep ≤ 15 beats** |
| 23 | `awsize` | out | 3 | |
| 24 | `awburst` | out | 2 | INCR recommended |
| 25 | `awlock` | out | 2 | use `2'b00` |
| 26 | `awcache` | out | 4 | |
| 27 | `awprot` | out | 3 | |
| 28 | `awvalid` | out | 1 | |
| 29 | `awready` | in | 1 | |
| 30 | `wid` | out | 4 | write data ID (AXI3-style; ignored by Xilinx IP) |
| 31 | `wdata` | out | 32 | |
| 32 | `wstrb` | out | 4 | |
| 33 | `wlast` | out | 1 | |
| 34 | `wvalid` | out | 1 | |
| 35 | `wready` | in | 1 | |
| 36 | `bid` | in | 4 | write response ID |
| 37 | `bresp` | in | 2 | always `2'b00` on this platform |
| 38 | `bvalid` | in | 1 | |
| 39 | `bready` | out | 1 | |
| 40 | `break_point` | in | 1 | debug: stop the core immediately when high; sim SoC ties `1'b0`, FPGA drives it from `debug_top` |
| 41 | `infor_flag` | in | 1 | debug: register-read request |
| 42 | `reg_num` | in | 5 | debug: register index |
| 43 | `ws_valid` | out | 1 | debug: "current instruction valid" |
| 44 | `rf_rdata` | out | 32 | debug: register value; must be valid in the same cycle as `infor_flag`/`reg_num` |
| 45 | `debug0_wb_pc` | out | 32 | committed instruction PC — **the testbench's primary observation point** (trace, END_PC detection, dead-clock watchdog) |
| 46 | `debug0_wb_rf_wen` | out | 4 (docs) / 1 (sim SoC, iverilog TB) | register write enable; the testbench treats "commit" as `wen != 0 && wnum != 0` |
| 47 | `debug0_wb_rf_wnum` | out | 5 | register index |
| 48 | `debug0_wb_rf_wdata` | out | 32 | register write data |
| 49-52 | `debug1_wb_*` | out | as above | only if `` `CPU_2CMT `` is defined (`config-generator.mak:12` = `n`) |

Notes:
* The documents declare `debug0_wb_rf_wen` as `[3:0]` while the sim SoC and the iverilog
  testbench declare it as a 1-bit wire (`chip/soc_demo/sim/soc_top.v:16`,
  `sims/iverilog/testbench/testbench.v:51`) — a 4-bit port connected to a 1-bit wire keeps
  only bit 0. Declaring it `[3:0]` (as the docs do) is the safer choice: bit 0 carries the
  valid signal.
* `intrpt[7:5]` are unused; `nmi` is commented out in every SoC (`soc_top.v:726`).
* There is **no** `cpu_axi_*` port naming convention anywhere: the platform wires are
  `m0_*` (FPGA SoC, pre-mux), `m1_*` (post-mux), `m0_async_*` (post clock-converter),
  `cpu_*` (sim SoC), and `s0_*`/`s1_*`… (slave mux outputs). The CPU must use exactly the
  names in the table above.

---

## 12. What an RV32-GC core must do differently (summary of consequences)

1. **Top module**: name it `core_top`, file name free, place the `*.v` in `IP/myCPU/`.
2. **ISA mismatch**: everything in the platform's software (`software/**`, PMON, u-boot,
   Linux) and the difftest reference (la32-nemu) is **LA32R**, not RV32. For an RV32 core you
   must write your own bare-metal tests (or use the RV arch-test suite) and run with
   `--disable-trace-comp`.
3. **Loader/boot**: the sim loader writes the program image at `FIRST_INST_ADDRESS =
   0x1c000000` and your core must fetch its first instruction there (or you must add a
   loader/ROM path). On the loongson FPGA, `0x1c000000` is the **SPI-flash XIP window**, and
   DDR3 is at physical `0x00000000` — so an RV32 program intended for the board must be
   linked for DDR (e.g. `0x8000_0000`/`0xa000_0000` kseg) and loaded by JTAG/TFTP.
4. **Timebase**: the platform has only the `confreg` free-running timer at `0x1FD0_E000`
   (write = set, read = count) — there is no RISC-V `mtime`/`mtimecmp`.
5. **Interrupts**: 5 raw lines (MAC, UART, SPI, NAND, DMA) into `intrpt`; no PLIC/CLINT.
6. **Debug interface**: implement `ws_valid/break_point/infor_flag/reg_num/rf_rdata` if you
   want the UART debugger; `debug0_wb_*` is mandatory for the verilator flow to observe
   commits at all.
7. **Difftest**: either port `Difftest*` instantiations (guarded by `` `ifdef DIFFTEST_EN ``)
   and point `--diff` at an RV32 reference, or run with the trace comparison disabled.

---

## 13. Uncertainties / things to verify

1. **`arlen`/`awlen` width conflict.** The documented CPU port is `[7:0]`
   (`docs/Quick-Start.md:80,98`), but every SoC wire is 4 bits (`config.h`: `\`Lawlen 4`,
   `\`Larlen 4`; `m0_arlen`, `axi_s_arlen`, `soc_axi_sram_bridge.m_arlen[3:0]`). The reference
   `core_top` is not present, so its real declaration could not be checked. **Verify by
   elaborating**, and keep bursts ≤ 16 beats either way.
2. **`debug0_wb_rf_wen` width** is `[3:0]` in the docs but a 1-bit wire in the sim SoC and in
   the iverilog TB. Bit 0 must carry the enable.
3. **CPU clock vs `FREQ`.** `cpu_clk` is 50 MHz in this revision while `\`FREQ` (`config.h:33`)
   and `CORE_CLOCKS_PER_SEC` (`confreg_time.c:8`) say 33 MHz (= the uncore/AXI clock). The
   docs say the core clock defaults to 33 MHz. Any cycle-count-based test will be off by 1.5×
   until you fix `FREQ` (and/or the `clk_pll_33` output).
4. **CONFREG register offsets differ between sim and FPGA**: CR0..CR7 are at `0x8000+0x10n` in
   `confreg_sim.v` but at `0x0000+4n` in `confreg_syn.v`, while the software headers use
   `0xbfd08000+0x10n`. Consequence: CR scratch accesses work in simulation and silently do
   nothing on the FPGA. Also, in `confreg_sim.v`, `FREQ_ADDR == LED_RG0_ADDR == 0xf030`, so a
   *read* of `0x1fd0f030` returns `FREQ` (33 MHz) rather than the RGB0 value.
5. **kseg1 alias handling differs between the sim and FPGA address decoders**: the sim mux
   accepts `0xbfd0_xxxx`/`0xbfaf_xxxx` for confreg (`[28:16]` compare) but *not* `0xbfe0_xxxx`
   for the UART (`[31:16]` compare); the FPGA mux accepts only physical `0x1fd0/0x1fe0/…`.
   **Emit physical addresses.** `0xbfe001e0` (the software's `UART_BASE`) will therefore only
   work if the core strips the kseg1 alias. This could not be verified against the reference
   core (submodule absent). Test with a store/load to `0x1FE0_01E0` early.
6. **`END_PC` values are inconsistent** across the tree: `difftest.h` (`0x1c000130` func /
   `0x1c000548` C), `golden_trace.h` (`0x1c000100` / `0x0`), `Makefile_run` (`1c000010`),
   `fpga/*/testbench` (`0xbfc00100`, stale). Which one terminates a given test must be
   checked at run time (use `--end-pc`).
7. **`fpga/loongson/Makefile` and `configure.sh` are stale**: they use `LAB_HOME` and a
   `make … script` target that the current `software/examples/**` Makefiles do not provide,
   and `sims/iverilog/run_prog/Makefile:76` still points at the old `software/func/` layout.
   The iverilog flow also requires a manual `ln -sf ../../../chip/config-generator.mak .`.
8. **iverilog testbench is coupled to the reference core internals**
   (`` `define CPU soc.cpu `` / `soc.cpu.wb_stage.ws_excp_num[5]`,
   `sims/iverilog/testbench/testbench.v:9,153`). It cannot be used unmodified with a new core.
9. **`fpga/{loongson,Baixin,nexys4ddr}/testbench/*.v` are wrong for their own SoCs** (they
   instantiate `soc_lite_top`, the 龙芯杯 SoC). No usable in-tree Vivado testbench exists for
   the loongson SoC.
10. **No Tcl project-generation script exists for `fpga/loongson`**; only the committed `.xpr`
    (GUI workflow). §5.4 sketches how to write one from the `nscscc-team` template.
11. **`dma0_wdata/dma0_rdata` are declared 64-bit in `soc_top.v:428,448`** and connected to
    `axi_interconnect_0` `S02` (which the XCI indeed configures as 64-bit) — consistent, but
    worth remembering that the DMA is the only 64-bit AXI master; the CPU path is 32-bit.
12. **`aresetn` is driven by the Xilinx interconnect's `S00_AXI_ARESET_OUT_N` output**
    (`soc_top.v:1504`), not by an explicit synchronizer in the SoC. Behaviour at
    power-up/bitstream load (before the interconnect releases it) was not simulated here.
13. **Xilinx IP metadata oddity**: `mig_axi_32.xci` declares `CLK_REF_I.FREQ_HZ = 100 MHz`
    while the SoC feeds it 200 MHz from `clk_wiz_0` (`soc_top.v:1471`). The MIG was built for
    a 200 MHz ref clock (`mig_a.prj`), so the metadata appears stale; verify no timing/DRC
    surprises in Vivado 2025.2.
14. **Vivado 2025.2 compatibility is untested here**: the tree only ships 2019.2 and 2023.2
    projects and 2019.2/2023.2 IP. Opening the 2023.2 `.xpr` in 2025.2 will trigger an IP
    upgrade; the MIG/AXI IP regeneration must be validated on the actual machine.
15. **`docs/Debug/debug.md` refers to `python3 debug.py`, which does not exist in the tree**
    (only `chip/soc_demo/nscscc-team/uart_debug/uart_downloader.py`); it comes from the
    external `chiplab-tools` release.
16. **NAND base address**: the hardware selects NAND for *any* APB access with
    `apb_addr[19:14] != 0` (`apb_mux2.v:156`), i.e. `0x1FE0_4000–0x1FE7_FFFF`, and the AXI mux
    only forwards `0x1FE0_xxxx`/`0x1FE7_xxxx`. `0x1FE7_8000` is the PMON/Linux-visible base;
    the internal register offsets (which of `nand.v`'s command/address/data registers lives at
    which 4-byte offset) were not decoded in detail.
17. **`toolchains/` is empty** (only `README.md`): no LA32R GCC, no NEMU `.so`, no picolibc.
    Simulation of the *existing* software, and difftest, cannot run until those are
    downloaded (`toolchains/README.md`). For RV32 you will need a RISC-V toolchain
    (e.g. `riscv64-unknown-elf-gcc -march=rv32…​`) and your own linker script.
18. **`software/examples/**` programs are LA32R** (`.word`-encoded LA32 instructions,
    `csrwr`, `cacop`, `syscall 0x11`). None of them can be reused to exercise an RV32 core.
