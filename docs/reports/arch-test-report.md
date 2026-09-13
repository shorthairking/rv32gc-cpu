# riscv-arch-test (ACT4) survey for an RV32GC + M/S/U + Sv32 Verilog core

Tree surveyed: `/home/shorthair/dsh/rv32-cpu/riscv-arch-test`
Commit: `80d563374ffb2eba59aae5c7a575ad5e92e78a1d` (branch `act4`, 2026-09-12), `CHANGELOG.md` head says **ACT 4.1.0 (2026-09-03)**.
All findings below were read from that tree; every command in the recipes was executed (see §9).

> **First, the single most important correction to the briefing.** This is the **ACT4** framework, not the old `riscof`-based one. There is **no** `RISCV_GCC` / `RISCV_OBJCOPY` / `RISCV_PREFIX` / `TARGET_ARCH` / `TEST_SUITE` / `RISCV_SIM` environment-variable build interface, no per-suite generated Makefiles, no `config/spike/*.yaml` used as a signature generator, and no stored reference signatures. Instead:
> * the build driver is `uv`/`mise` + a Python framework (`framework/src/act/`) driven by `Makefile`;
> * the DUT is described by a **UDB YAML + `test_config.yaml` + `rvmodel_macros.h` + `link.ld` + `sail.json`** config directory;
> * **all** expected results come from the **Sail** model (`sail_riscv_sim`), never from stored files;
> * tests are compiled *self-checking*, i.e. the reference signature is baked into each ELF as data, and the ELF itself prints `RVCP-SUMMARY: TEST PASSED/FAILED`.
>
> The old 3.x layout (with `RISCV_GCC` etc.) still exists on the remote branch `old-framework-3.x`; this checkout is on `act4`.

---

## 1. Overall layout

```
riscv-arch-test/
├── Makefile                    # ACT4 build entry point (307 lines)
├── run_tests.py                # runs built ELFs through any simulator command
├── pyproject.toml              # uv workspace: framework, generators/coverage, generators/testgen
├── uv.lock, .mise.toml, .python-version (3.14)
├── README.md                   # the authoritative setup doc (408 lines)
├── AGENTS.md                   # repo conventions (generated files, terminology, commands)
├── config/                     # DUT / reference-model configs: cores, imperas, qemu, sail, spike, whisper
├── coverpoints/                # coverpoint definitions (SVH + norm YAML)  — 558 files
├── docs/                       # DeveloperGuide.md, memory_map.md, tsbi-changes.md, underflow.md, ctp/ (AsciiDoc)
├── framework/                  # the `act` Python package (build driver)
├── generators/                 # `testgen` (test generators) + `coverage` (covergroupgen)
├── templates/                  # (referenced by Makefile TEMPLATEDIR; absent in this checkout)
├── tests/                      # test sources: env/, rv32i/, rv32e/, rv64i/, rv64e/, priv/
├── testplans/                  # CSV test plans (unprivileged) + priv/ (vector-only)
└── tests-dev/                  # 5 hand-written development files, not part of the build
```

### 1.1 `tests/`

| path | contents |
|---|---|
| `tests/env/` | the whole test runtime: `riscv_arch_test.h`, `rvtest_setup.h`, `rvtest_macros.h`, `signature.h`, `rvtest_trap_handler.h`, `check_defines.h`, `derived_config.h`, `encoding.h`, `sail_macros.h`, `utils.h`, `c_test*.{h,S,c}` |
| `tests/rv32i/` | 57 extension/group directories, **641 `.S` files** total |
| `tests/rv32e/`, `tests/rv64e/`, `tests/rv64i/` | the E and RV64 counterparts (irrelevant for RV32GC) |
| `tests/priv/` | 22 privileged directories, **361 `.S` files** |

`tests/rv32i/` subdirectories (file counts = `.S` files):

```
I 39   M 8    F 78   D 104   Misalign 5   MisalignF 2   MisalignD 2   MisalignZca 4
Zaamo 9   Zabha 18  Zacas 2   ZacasZabha 2   Zalrsc 2   Zba 3   Zbb 18  Zbc 3
Zbkb 12   Zbkc 2   Zbkx 2   Zbs 8   Zca 26   Zcb 7   ZcbM 1   ZcbZbb 3   Zcd 4   Zcf 4
Zcmop 8   ZfaD 17  ZfaF 7   ZfaZfh 9   ZfaZfhD 7   ZfaZvfh 1   Zfbfmin 6
Zfh 85    ZfhD 30  Zfhmin 6  ZfhminD 6
Zicbom 3  Zicbop 3  Zicboz 1  Zicntr 2  Zicond 2  Zicsr 6  Zifencei 1
Zihintntl 4  ZihintntlZca 4  Zihintpause 1  Zihpm 2  Zimop 40
Zknd 2   Zkne 2   Zknh 10  Zksed 2  Zksh 2  Zmmul 4
```

Groups relevant to **RV32GC** (I+M+A+F+D+C+Zicsr+Zifencei): `I`, `M`, `F`, `D`, `Zaamo`, `Zalrsc`, `Zca`, `Zcd`, `Zcf`, `Zicsr`, `Zifencei`, `Misalign`, `MisalignF`, `MisalignD`, `MisalignZca`, plus optional `Zmmul` (implied by M), `Zicntr`, `Zihintpause`, `Zihintntl`, `Zicond`, `Zcb`/`Zb*`/`Zk*`/`Zfh*`/`Zfa*` (only if you implement them).
`Zcf` is **RV32-only** (single-precision compressed loads/stores) and does apply to your core.

Representative file names (the group prefix is part of the name, note the dots):

```
tests/rv32i/I/I-add-00.S              tests/rv32i/M/M-mul-00.S
tests/rv32i/F/F-fadd.s-00.S           tests/rv32i/D/D-fadd.d-00.S
tests/rv32i/Zca/Zca-c.add-00.S        tests/rv32i/Zcd/Zcd-c.fld-00.S
tests/rv32i/Zcf/Zcf-c.flw-00.S        tests/rv32i/Zaamo/Zaamo-amoadd.w-00.S
tests/rv32i/Zalrsc/Zalrsc-lr.w-00.S   tests/rv32i/Zicsr/Zicsr-csrrw-00.S
tests/rv32i/Zifencei/Zifencei-fence.i-00.S
tests/rv32i/Misalign/Misalign-lh-00.S
```

### 1.2 `testplans/*.csv`

One CSV per **unprivileged** extension group. Columns: `Instruction,Type,RV32,RV64,<coverpoint columns…>` (see `AGENTS.md` and `testplans/I.csv:1`). `Type` must match a registered formatter in `generators/testgen/src/testgen/formatters/types/`; coverpoint column names must match registered generators in `generators/testgen/src/testgen/coverpoints/`.

Relevant for RV32GC: `testplans/I.csv`, `M.csv`, `F.csv`, `D.csv`, `Zicsr.csv`, `Zifencei.csv`, `Zaamo.csv`, `Zalrsc.csv`, `Zca.csv`, `Zcd.csv`, `Zcf.csv`, `Zcb.csv`, `ZcbM.csv`, `Misalign.csv`, `MisalignF.csv`, `MisalignD.csv`, `MisalignZca.csv`, `Zmmul.csv` (and the optional `Zicntr/Zihpm/Zicond/Zbb/…` ones only if implemented).

`testplans/priv/` contains only vector privileged plans (`ExceptionsVf.csv`, `ExceptionsVfmin.csv`, `ExceptionsVls.csv`, `ExceptionsVx.csv`, `MisalignV.csv`, `SsstrictV.csv`) — **non-vector privileged tests are not CSV-driven**; they are Python-generated (see §5).

### 1.3 `framework/`

`framework/src/act/` is the build framework (the `act` CLI, `framework/pyproject.toml:31`). Key modules:

| file | role |
|---|---|
| `act.py` | CLI (`act <config…> --workdir --test-dir --jobs --extensions --exclude`) |
| `select_tests.py` | filters tests by UDB extensions/params and `include_priv_tests` (`select_tests.py:91-114`) |
| `parse_test_constraints.py` | parses the `START_TEST_CONFIG`/`END_TEST_CONFIG` YAML header of every `.S`/`.c` |
| `parse_udb_config.py` | generates `extensions.txt`, `rvtest_config.h`, `rvtest_config.svh`, `rvmodel_macros.svh` from UDB (needs Ruby/Bundler + the `udb` gem) |
| `build_plan.py` | the per-test DAG: `sig.elf → .sig (ref model) → .results → .elf` (`build_plan.py:118-316`) |
| `config.py` | `test_config.yaml` parsing; `RefModelType` = `sail` \| `spike` (`config.py:22-34`) |
| `toolchain.py` | GCC/Clang flag construction + `-march` capability probing |
| `sig_modify.py` | turns the reference model's `.sig` into an assembler-includable `.results` (`sig_modify.py:15-34`) |
| `trap_report.py`, `coverreport.py`, `sail_to_rvvi.py` | debug/coverage helpers |
| `fcov/` | SystemVerilog functional-coverage testbench (`riscv_arch_test.sv`, `rvviTrace.sv`, `RISCV_coverage_*.svh`) |
| `data/Gemfile`, `data/Gemfile.lock` | the UDB gem dependency |

### 1.4 "signature convention", `RVMODEL_*`, `model_test.h`

* The signature convention lives in `tests/env/signature.h` + `tests/env/rvtest_setup.h` — **not** in `framework/`.
* `model_test.h` **does not exist** in ACT4. Its replacement is the DUT-supplied **`rvmodel_macros.h`** (one per config dir, e.g. `config/cores/cvw/cvw-rv64gc/rvmodel_macros.h`), plus the UDB-generated `rvtest_config.h`.
* There is no `RVMODEL_HALT` in the sources; the modern names are **`RVMODEL_HALT_PASS`** and **`RVMODEL_HALT_FAIL`** (§3).

---

## 2. How a test is built

### 2.1 Tool prerequisites (`README.md:29-168`, `Makefile:85-113`)

* `make`, `git`
* **`uv` or `mise`** (`Makefile:88-105` errors out otherwise), Python **3.10+**
* **Ruby + Bundler + the UDB gem** — required for every real `make` target (`Makefile:107-113`; `framework/src/act/data/Gemfile`). This is *not* optional in this revision.
* GCC ≥ 15 or Clang ≥ 20 (`framework/src/act/config.py:168-171, 223-240`)
* **`sail_riscv_sim` version 0.13.1 exactly** (`framework/src/act/config.py:169, 174-194`) — needed to produce reference signatures
* optional: `spike` (alternative ref model) or QEMU/Whisper/Imperas for *running* ELFs

### 2.2 Makefile targets and variables (this replaces `RISCV_GCC`-style variables)

`Makefile:6-56` (variables), `Makefile:118-161` (`make help`), `Makefile:166-221` (targets):

| variable | meaning | default |
|---|---|---|
| `CONFIG_FILES` | space-separated `test_config.yaml` paths to build | `config/spike/spike-rv32-max/test_config.yaml config/spike/spike-rv64-max/test_config.yaml` (`Makefile:9`) |
| `WORKDIR` | output root; ELFs land in `$WORKDIR/<name>/elfs` | `work` (`Makefile:34`) |
| `EXTENSIONS` | comma-separated group filter | empty = all (`Makefile:16`) |
| `EXCLUDE_EXTENSIONS` | negative filter | `SdtrigSm,SdtrigS,SdtrigU` (`Makefile:17`) |
| `JOBS` | parallel jobs (`0` = auto) | from `-j`/CPU count (`Makefile:52`) |
| `DEBUG=True` | emit `.elf.objdump`, `.sig.log`, `.sig.trap_report` | off |
| `FAST=True` | skip objdump | off |
| `CLEAN_INTERMEDIATES=True` | delete `work/<cfg>/build/` after success | off |
| `VERBOSE=True` | implies DEBUG, JOBS=1, prints every command | off |
| `COVERAGE`, `COVERAGE_SIMULATOR` | coverage build (questa/vcs) | — |

Targets:

```bash
make help                                   # list targets/vars
make tests                                  # generate .S + coverpoints only (no compiler, no Sail)
make                                        # default: elfs for CONFIG_FILES (spike rv32-max + rv64-max)
CONFIG_FILES=<cfg>/test_config.yaml make -j"$(nproc)"     # build ELFs for one DUT config
EXTENSIONS=I,M make tests                   # restrict generation
make clean                                  # remove work/ artifacts
make <config-dir-name>                      # auto-generated from config/**/run_cmd.txt (e.g. make spike-rv32-max)
./run_tests.py "$(cat config/…/run_cmd.txt)" work/<cfg>/elfs    # run already-built ELFs
```

There is **no** way to build one single test through `make`. `make elfs` compiles every test selected by the UDB config. To build a lone test you either use the manual recipe in §9 or run the `act` CLI with `EXTENSIONS=<group>` (one group ≈ a handful-to-a-hundred tests).

### 2.3 The internal per-test pipeline (`framework/src/act/build_plan.py:118-316`)

```
tests/<…>/<test>.S
  ├─1. <test>.sig.elf   : gcc … -DSIGNATURE                                   (line 199-219)
  ├─2. <test>.sig       : sail_riscv_sim --config sail.json
  │                        --test-signature=<test>.sig --signature-granularity 4 <test>.sig.elf
  │                                                                           (line 84-110, 236-246)
  ├─3. <test>.results   : python process_signature_file() → ".word 0x…" lines (sig_modify.py)
  └─4. <test>.elf       : gcc … -DRVTEST_SELFCHECK -DSIGNATURE_FILE="<test>.results" -DXLEN=32
                                                                              (line 277-299)
```

Exact compile prefix used (`build_plan.py:165-175, 186-190, 204-210, 278-291`), with `xlen=32` (`mabi = ilp32`):

```
<compiler_exe> -Wl,--no-warn-rwx-segments
  -I<dut_include_dir> -T<linker_script> -O0 -g -mcmodel=medany -nostdlib
  -I<repo>/tests/env -I$WORKDIR/<config>/build
  <march flags> -mabi=ilp32
  -DSIGNATURE  [-DSAIL_CLINT_BASE_ADDRESS=0x… -DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=0x…]
  -DTEST_FLEN=<32|64|128> '-DTEST_FILE="<test>.S"'
  -o <out> <test>.S
```
and for the final ELF: `-DRVTEST_SELFCHECK -DSIGNATURE_FILE="<test>.results" -DXLEN=32` (or `-DRVTEST_NOSIG` when the test needs no signature).

`march_flags()` for GCC + assembly emits `-march=rv32i -Xassembler -march=<full test MARCH>` (`toolchain.py:130-133`).

### 2.4 `riscv32-unknown-elf` vs `riscv32-unknown-linux-gnu`

The framework only cares that `compiler_exe`/`objdump_exe` exist and that GCC ≥ 15 (`config.py:223-240`). Every documented config uses `riscv64-unknown-elf-*`, but the build is `-nostdlib`/`-mabi=ilp32` bare-metal, so a **linux-gnu cross toolchain works**: it was used successfully for every command in §9 of this report (`riscv32-unknown-linux-gnu-gcc` 16.1.0 from `/opt/riscv`). No libc, no dynamic linker, no `INTERP` segment is pulled in (verified: `readelf -d` reports "no dynamic section").

### 2.5 `docs/` inventory

| file | build/run relevance |
|---|---|
| `docs/DeveloperGuide.md` (54 kB) | **relevant**: test hierarchy, YAML header keys (`REQUIRED_EXTENSIONS`, `MARCH`, `params`), CSV/coverpoint authoring rules |
| `docs/memory_map.md` (13 kB) | **relevant**: section layout (`.text.init`, `.text.rvtest`, `.rodata/.data/.bss`, stack, `.text.rvmodel`) — needed to write `link.ld` |
| `docs/tsbi-changes.md` | **relevant for privileged tests**: the T-SBI (test-SBI) conversion; how priv tests request M-mode operations via `ecall` instead of mode-hopping |
| `docs/underflow.md` (26 kB) | coverage/underflow bookkeeping; incidental |
| `docs/ctp/src/*.adoc` (~45 files), `docs/crd/`, `docs/pages/index.html` | the Certification Test Plan and CRD; docs-only, built with Docker/Antora (`cd docs/ctp && make`) |

---

## 3. The verification harness contract

### 3.1 Signature region

* `begin_signature` / `end_signature` are **globals in `.data`**, emitted by `RVTEST_SIG_SETUP` (`tests/env/rvtest_setup.h:857-917`):

```asm
.macro RVTEST_SIG_SETUP
  .p2align 4
  .global begin_signature
  begin_signature:
  .global rvtest_sig_begin
  rvtest_sig_begin:
    #ifdef RVTEST_NOSIG
      …compat labels only…
    #elif defined(RVTEST_SELFCHECK)
      signature_base:
        #include SIGNATURE_FILE          // ← the reference values, assembled as data
    #else                                // "SIGNATURE mode" (the .sig.elf build)
      signature_base:
        CANARY
        .fill SIGUPD_COUNT*(SIG_STRIDE>>2),4,0xdeadbeef
      final_sig_offset_canary:  FINAL_SIG_OFFSET_CANARY
      final_sig_offset:         .fill (REGWIDTH>>2),4,0xdeadbeef
      final_trap_sig_offset_canary: FINAL_TRAP_OFFSET_CANARY
      final_trap_sig_offset:    .fill (REGWIDTH>>2),4,0xdeadbeef
      tsig_begin_canary:        TRAP_CANARY
      trap_sigptr:              .fill TRAP_SIGUPD_COUNT*(SIG_STRIDE>>2),4,0xdeadbeef
      sig_end_canary:           CANARY
    #endif
  …
  .global end_signature
  end_signature:
  RVMODEL_DATA_SECTION
.endm
```

* Each check writes **one word** (`SIG_STRIDE = TEST_FLEN/8 = 4` bytes for RV32) and advances the pointer (`tests/env/signature.h:20-44`):

```c
#ifdef RVTEST_SELFCHECK                      // final ELF: compare against preloaded reference
  #define RVTEST_SIGUPD(_SIG_PTR,_LINK_REG,_TEMP_REG,_R,_INST_PTR,_STR_PTR) \
    LREG _TEMP_REG, 0(_SIG_PTR) ;\
    beq  _TEMP_REG, _R, 1f      ;\
    jal  _LINK_REG, failedtest_##_LINK_REG##_##_TEMP_REG ;\
    RVTEST_WORD_PTR _INST_PTR ; RVTEST_WORD_PTR _STR_PTR ;\
    1: addi _SIG_PTR, _SIG_PTR, SIG_STRIDE
#else                                        // .sig.elf: store the observed value
  #define RVTEST_SIGUPD(…) SREG _R, 0(_SIG_PTR) ; … addi _SIG_PTR, _SIG_PTR, SIG_STRIDE
#endif
```

* Region length is `end_signature - begin_signature`; it is **fixed at compile time** from the test's `#define SIGUPD_COUNT n` (test header, e.g. `tests/rv32i/I/I-add-00.S:19` → `#define SIGUPD_COUNT 402`; privileged tests additionally define `TRAP_SIGUPD_COUNT`, default 15000 in `tests/env/check_defines.h:16-18`).
* At the end of the test, `RVTEST_CODE_END` (1) verifies the *number* of signature updates by comparing `DEFAULT_SIG_REG - signature_base` against `final_sig_offset` (`rvtest_setup.h:113-154`), (2) checks the trap-signature offset (`rvtest_setup.h:156-200`), then (3) calls `RVMODEL_HALT_PASS`/`RVMODEL_HALT_FAIL` (`rvtest_setup.h:341-347`).

**What this means for you: you do NOT have to dump and compare a signature yourself.** The ELF does the comparison internally; your testbench only has to (a) let the program run, (b) collect console output, (c) observe pass/fail termination. Signature comparison is still useful as a *fallback/debug* path and is what the framework's own reference flow uses (§4).

### 3.2 HALT/IO macros the DUT must provide

Mandatory (`tests/env/check_defines.h:34-51`):

| macro | required? | meaning |
|---|---|---|
| `RVMODEL_HALT_PASS` | **yes** (`check_defines.h:39-41`) | terminate with pass indication; must not return |
| `RVMODEL_HALT_FAIL` | **yes** (`check_defines.h:43-45`) | terminate with fail indication; must not return |
| `RVMODEL_IO_WRITE_STR(_R1,_R2,_R3,_STR_PTR)` | **yes** (`check_defines.h:48-50`) | print NUL-terminated string; may be an empty stub |
| `RVMODEL_DATA_SECTION` | **yes** (`check_defines.h:34-36`) | emits `.tohost`/`.fromhost` (or equivalent) after the signature |
| `RVMODEL_INTERRUPT_LATENCY`, `RVMODEL_TIMER_INT_SOON_DELAY` | **yes** (`check_defines.h:74-79`) | delay tuning for interrupt tests |
| `RVMODEL_SET_MEXT_INT`, `RVMODEL_CLR_MEXT_INT` | **yes** (`check_defines.h:89-95`) | external interrupt control |
| `RVMODEL_MSIP_ADDRESS` *or* `RVMODEL_SET_MSW_INT`+`RVMODEL_CLR_MSW_INT` | one of them (`check_defines.h:103-117`) | machine software interrupt |
| `RVMODEL_SET_SEXT_INT`, `RVMODEL_CLR_SEXT_INT` | required when `S_SUPPORTED` (`check_defines.h:120-133`) | supervisor external interrupt |
| `RVMODEL_IO_INIT(_R1,_R2,_R3)` | optional | console bring-up |
| `RVMODEL_BOOT`, `RVMODEL_BOOT_TO_MMODE` | optional | pre-test boot code |
| `RVMODEL_ACCESS_FAULT_ADDRESS` | optional | address that must access-fault |
| `RVMODEL_MTIME_ADDRESS`, `RVMODEL_MTIMECMP_ADDRESS` | optional | CLINT |
| `RVMODEL_INVISIBLE_TRAP_HANDLER(...)` | optional | trap-and-emulate support |
| `RVMODEL_MAX_CYCLES_PER_TIMER_TICK` | optional, default 1 (`check_defines.h:81-83`) | — |

Note the `_M` variants (`RVMODEL_CLR_*_INT_M`) default to their non-`_M` counterpart (`check_defines.h:97-101` etc.).

Canonical DUT example: `config/cores/cvw/cvw-rv64gc/rvmodel_macros.h` (a PC16550 UART + PLIC/CLINT implementation; `cvw-rv32gc/rvmodel_macros.h` is a symlink to it). Canonical Sail-reference example: `tests/env/sail_macros.h` — included instead of the DUT macros for the `.sig.elf` build (`tests/env/riscv_arch_test.h:12-14`), it redefines halt/IO/interrupts to Sail's HTIF + simple-interrupt-generator. Note it **requires** `-DSAIL_CLINT_BASE_ADDRESS` and `-DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS` (`sail_macros.h:15-21`), which the framework derives from `sail.json` (`build_plan.py:67-81`).

Concrete halt implementations:

```c
// DUT flavor (config/cores/cvw/cvw-rv64gc/rvmodel_macros.h:31-49)
#define RVMODEL_HALT_PASS  li x1, 1 ; la t0, tohost ; write_tohost_pass: ; sw x1,0(t0) ; sw x0,4(t0) ; self_loop_pass: ; j self_loop_pass
// Sail flavor (tests/env/sail_macros.h:55-73)
#define RVMODEL_HALT_PASS  li x1, 1 ; la t0, tohost ; write_tohost_pass: ; sw x1,0(t0) ; sw x0,4(t0) ; j write_tohost_pass
```

### 3.3 What **your** testbench must implement (the contract)

1. **Load and start the ELF**: entry point is the global `rvtest_entry_point`, which must be the reset vector (`link.ld:11` `ENTRY(rvtest_entry_point)`). It runs `RVMODEL_BOOT` (via `rvmodel_boot`, `rvtest_setup.h:52-53`) and the framework's M-mode boot (`RVTEST_BOOT_TO_MMODE`, `rvtest_setup.h:925+`) which programs `mtvec`, does the canary self-test, initialises registers and jumps to the test body.
2. **Memory map** must match `link.ld` and `sail.json`: default RAM base `0x80000000` (`config/cores/cvw/cvw-rv64gc/link.ld:2-5`); the ELF uses **three LOAD segments** (`.text.init/.text.rvtest`, `.data/.tohost`, `.text.rvmodel`) — observed in §9.
3. **A termination channel**: whatever `RVMODEL_HALT_PASS/FAIL` writes. Convention = a `tohost` word in `.tohost` (`RVMODEL_DATA_SECTION`): `1` = pass, `3` = fail. Your testbench should watch that address and stop the simulation with the corresponding status. A magic-address MMIO write or a `$finish`/`ebreak`-based scheme works equally well — just keep the macro and the testbench in sync.
4. **A console** if you want the pass/fail and the failure diagnostics: implement `RVMODEL_IO_WRITE_STR` over any byte-writable device (the examples assume an NS16550 at `0x10000000`). The messages you must recognise:
   * `RVCP-SUMMARY: TEST PASSED - Test File "<name>.S"`
   * `RVCP-SUMMARY: TEST FAILED - Test File "<name>.S"` (followed by PC / failing instruction / register / expected / actual)
   * `RVCP-SUMMARY: TEST SIGRUN - Test File "<name>.S"` → the ELF was built without `RVTEST_SELFCHECK` (not self-checking).
   The strings are emitted in `tests/env/rvtest_failure_code.h:2274` (`TEST PASSED`), `:2276` (`TEST SIGRUN`), `:2281` (`TEST FAILED`), and the doubled `TEST_FILE` expansion starts at `:2278`; `run_tests.py:22, 186-194` greps exactly this format.
   `RVMODEL_IO_WRITE_STR` may be a no-op stub if you prefer to rely on `tohost` alone.
5. **Interrupt/CLINT support** for the interrupt tests: `mtime`/`mtimecmp`/`msip` addresses, plus your external-interrupt controller. If you skip interrupts, expect those specific tests to fail/hang — build with `EXTENSIONS` excluding them, or accept the failures.
6. **Trap/mret/sret** for privileged tests (§5).
7. **Optional signature dump for debug**: extract `[begin_signature, end_signature)` from memory at halt and diff against `*.results`/`*.sig`. `run_tests.py` does **not** do this; the ELF self-checks instead.

### 3.4 `run_tests.py` (the runner you can reuse)

`run_tests.py:237-336` runs every `*.elf` under a directory with a command you supply (ELF path appended), writes `logs/<test>.log` and `summary.log`, and treats a test as failed if the exit code is non-zero, or the log contains `TEST FAILED`/`SIGRUN`, or no `RVCP-SUMMARY` line appears (`run_tests.py:186-194`). Placeholders: `{debug:...}` (only expanded with `--debug`), `__TRACEFILE__`, `__SUMMARYFILE__`. Per-test timeout default 300 s.

Example for your own simulator (mirrors `config/cores/cvw/cvw-rv32gc/run_cmd.txt:1`):

```bash
./run_tests.py "vvp -n /path/to/simv +elf" work/mycore/elfs
```

---

## 4. How reference signatures are produced — and whether you need spike/sail

* **Produced at build time, never stored.** `framework/src/act/build_plan.py:84-110` (`_ref_model_sig_cmd`) builds either
  * Sail: `sail_riscv_sim --config <cfg>/sail.json --test-signature=<t>.sig --signature-granularity 4 <t>.sig.elf`, or
  * Spike: `spike --isa=<hardcoded rv32/rv64 max string> +signature=<t>.sig +signature-granularity=4 <t>.sig.elf`.
  The flags come from `framework/src/act/config.py:28-34`; the spike ISA strings are hardcoded in `config.py:40-72` (there is no "spike config" file — `config/spike/<cfg>/` directories are only `test_config.yaml` + UDB YAML + `sail.json` + `run_cmd.txt` for *running* ELFs).
* `config/spike/`, `config/sail/`, `config/qemu/` are **DUT/reference configurations** (which compiler, which ref model, which memory map, how to run) — they are not signature stores. `config/spike/spike-rv32-max/test_config.yaml:4` says `ref_model_exe: sail_riscv_sim`; the `spike` executable appears only in `run_cmd.txt` files.
* A reference model is **mandatory at ELF-build time**. There is no offline signature cache: `work/` is git-ignored (`.gitignore`), does not exist, and no `.sig`/`.results`/`.elf` file exists anywhere in the tree (verified with `find`).
* Requirements to do this yourself:
  * Python **3.10+** and **`uv` or `mise`** (`Makefile:85-105`) — **not installed here**;
  * **Ruby + Bundler + UDB gem** (`Makefile:107-113`, `framework/src/act/parse_udb_config.py:43-95`); first use runs `bundle install`, which needs **network**;
  * **`sail_riscv_sim` 0.13.1 exactly** (`config.py:169`), downloaded from GitHub releases (network).
* The tree's `uv.lock` and `framework/pyproject.toml` pin the Python deps (`pydantic>=2.12.5`, `pyjson5>=2`, `rich>=14.3.4`, `ruamel-yaml>=0.18.16`, `typer>=0.23.1`).
* `run_tests.py` needs **only the Python standard library** — usable today.
* `generators/` (`testgen`, `coverage`) generate test sources and SV covergroups; they do **not** produce signatures. `make tests` regenerates `tests/rv32i/*` etc. and only needs `uv`/`mise` (no compiler, no Sail) — `README.md:350-352`.
* Note: the generated `.S` files **are checked in** (`git ls-files tests/ | wc -l` = 1995, all 641 `tests/rv32i/**` and all 361 `tests/priv/**` are tracked), so a plain `git clone` gives you the test sources without running the generators.

**In this sandbox (`/opt/riscv` only): `uv`, `mise`, `ruby`, `bundle`, `sail_riscv_sim` and `spike` are all absent, and there is no network access.** Therefore the ACT4 `make` path cannot run here, and genuine Sail-produced reference signatures cannot be generated here. §9 gives the hand-rolled, network-free substitute (which produces a *correct but degenerate* reference: it replays the signature-generating ELF's own initial values).

---

## 5. Privileged tests

`tests/priv/` — 22 directories, **361 `.S` files**. Counts and content:

| dir | files | covers |
|---|---|---|
| `Sv/` | 134 | Sv32 (31), Sv39/Sv48/Sv57 (rest): satp access, PTE permission bits (R/W/X/U/G/RSW/DAU), A/D updates, misaligned superpages, `mstatus.MPRV/MXR/SUM`, Smode/Umode page faults, `sfence.vma` |
| `SvPMP/` | 16 | PMP applied on physical addresses and on PTE fetches (4 are `sv32*`) |
| `SvPMPZicbo/` | 32 | PMP × cache-block ops under Sv (8 are `sv32*`) |
| `SvZicbo/` | 24 | `cbo.*` exceptions/behaviour under Sv (6 are `sv32*`) |
| `Svade/`, `Svadu/`, `SvaduPMP/` | 8 each | A/D-bit faulting vs hardware update (2 each are `sv32*`) |
| `Svbare/` | 3 | Svbare + `sfence.vma` illegality |
| `Svinval/` | 2 | `sinval.vma`, `sfence.w.inval`, `sfence.inval.ir` |
| `Svnapot/`, `Svpbmt/` | 12 each | NAPOT PTEs, PBMT (all `sv64`/Sv39+ → **RV64-only in practice**) |
| `ExceptionsSv/`, `ExceptionsSvZaamo/`, `ExceptionsSvZalrsc/` | 8 / 6 / 6 | page faults for loads/stores/AMO/LR-SC in S and U mode (4/3/3 are `sv32*`) |
| `PMPSm/` | 38 | **machine-mode PMP**: cfg A/TOR/NA4/NAPOT, XWR matrix, lock bits, priority, grain, `pmpaddr` upper bits |
| `PMPS/`, `PMPU/` | 11 each | PMP behaviour viewed from S / U mode, `mstatus.MPRV` interactions |
| `PMPF/` | 1 | PMP + F extension |
| `PMPZaamo/`, `PMPZalrsc/` | 1 each | PMP checks on AMO / LR-SC |
| `PMPZca/` | 15 | PMP checks on compressed loads/stores |
| `PMPZicbo/` | 4 | PMP checks on `cbo.*`/prefetch |

**RV32-relevant count: 153 of 361** (all `sv32*` files plus every privileged test whose header does not require `Sv39/Sv48/Sv57`), verified by scanning the `REQUIRED_EXTENSIONS` headers.

**What is *not* present in this revision** — important gap for you: there are **no** generated `.S` tests for
* machine/supervisor/user CSR suites (`Sm`, `S`, `U`, `Sm1p13`, `Smstateen`, `Sstc`, `Ssccptr`, `Sstvala`, `Sstvecd`, `Sscounterenw`, `Smdbltrp`, `Smrnmi`, …),
* interrupt suites (`InterruptsSm`, `InterruptsS`, `InterruptsU`, `InterruptsSSm`, `InterruptsSstc`),
* `ExceptionsSm`, `ExceptionsS`, `ExceptionsU`, `ExceptionsF`, `ExceptionsZc`, `Endian*`, `MisalignV` (vector), `Ssstrict*`, `Sdtrig*`, `Zawrs*`, `Zicntr*`, `ZicsrF`, `Zkr*`, `Smmpm/Ssnpm/Smnpm`, `Zicfilp/Zicfiss`, `Zama16b`, `Za64rs`.

Those suites have **generators** (`generators/testgen/src/testgen/priv/extensions/`, e.g. `U.py`, `S.py`, `Sm.py`, `InterruptsSm.py`, `ZicntrSm.py`, `SsstrictSm.py`, `ZicsrF.py`, `Smstateen.py`, ~60 files) and **coverpoints** (`coverpoints/priv/Sm_coverage.svh`, `InterruptsSm_coverage.svh`, `S_coverage.svh`, `U_coverage.svh`, …), and `make tests` would materialize them — but they are not in `tests/` in this checkout. So today you can verify PMP, Sv32/Sv39 MMU, exceptions and (with the vector/other configs disabled) the unprivileged ISA; you **cannot** today run ready-made machine-CSR/interrupt/trap-delegation tests.

Also note `AGENTS.md`: *"Unprivileged tests do not install trap handlers and can infinite-loop on traps. Tests that may trap should use the privileged-test style."* — so an unexpected trap in an unprivileged test hangs rather than failing.

### How privileged tests differ in build/run

* Same two-pass build, same macros. Differences are in the assembly header and body:
  * `#define STANDARD_SM_SUPPORTED` (from `rvtest_config.h` / DUT macros, e.g. `config/cores/cvw/cvw-rv64gc/rvmodel_macros.h:10`) makes `RVTEST_BEGIN/CODE_END` instantiate full M/S/H/V **trap prologs, handlers, epilogs and save areas** (`rvtest_setup.h:101-111, 225-232`; `tests/env/rvtest_trap_handler.h`), with a trap-signature region.
  * Many current tests still start with `#define BOOT_TO_MMODE` (marked `// TODO: Remove BOOT_TO_MMODE when converting this test to T-SBI`, e.g. `tests/priv/Sv/sv32_satp_access_test.S:34-35`, `tests/priv/PMPSm/PMPSm_cfg_XWR_all-01-00.S:27`) — i.e. the test boots in M-mode. Newer ones use **T-SBI**: the test boots into its own mode and asks the M-mode handler via `ecall` (see `docs/tsbi-changes.md`).
  * Tests that expect traps declare an expected trap count and use `TRAP_SIGUPD` (`signature.h:63-92`); the trap signature region is compared like the main one.
  * `include_priv_tests: false` in `test_config.yaml` drops every test whose requirements are only satisfiable with `Sm`/`S`/`U` (`framework/src/act/select_tests.py:18, 73-78, 101-103`).
* Running them is identical to unprivileged: run the ELF, read `tohost`/console.

**Sv32 specifics for your core**: the Sv32 tests program `satp` themselves and build their own page tables (`RVTEST_DATA_END` reserves `rvtest_Sroot_pg_tbl`, `rvtest_setup.h:824-839`). Your hardware must implement `satp.MODE=Sv32`, `sfence.vma`, `mstatus.MPRV/MXR/SUM`, Svade-or-Svadu semantics exactly as your `sail.json` declares.

---

## 6. Coverpoints

`coverpoints/` (558 files) is the *specification* side; `tests/` is the generated artifact side.

| dir | files | what it is |
|---|---|---|
| `coverpoints/norm/*.yaml` (161) | one per suite | **normative-rule → coverpoint mapping**, generated from the ISA manual. Each entry names a manual rule and the coverpoint bin that covers it, e.g. `coverpoints/norm/I.yaml:5-6` maps `rv32i_xreg_sz` to `I_add_cg/{cp_rs1, cp_rs2, cp_rd, cr_rs1_rs2_edges}`; `coverpoints/norm/Sm.yaml:18-20` maps `misa_acc` to `Sm_mcsr_cg/cp_mcsr_access/misa`; `coverpoints/norm/InterruptsSm.yaml:5` maps `mepc_op` to `InterruptsSm/cp_priority` |
| `coverpoints/priv/*.svh` (206) | SystemVerilog `covergroup`s for privileged suites |
| `coverpoints/unpriv/*.svh` (174) | same for unprivileged suites (`I_coverage.svh`, `D_coverage.svh`, …) |
| `coverpoints/general/*.svh` (5) | shared coverpoints (`RISCV_coverage_standard_coverpoints.svh`, PMM, Sdtrig, Ssstrict helpers) |
| `coverpoints/coverage/*.svh` (4) | sampling/config scaffolding used by `framework/src/act/fcov/` |
| `coverpoints/param/*.yaml` (8) | parameter constraints (`Sm.yaml`, `Misalign.yaml`, `Zicntr.yaml`, …) |

**How to use them as a checklist without running coverage:**
1. For an instruction/group, read `coverpoints/norm/<Group>.yaml` → gives you the normative rules and the exact bin names.
2. The bin names map 1:1 to testcase labels in the generated tests: `tests/rv32i/I/I-add-00.S:35-39` has label `I_add_cg_cp_rs1_b0` for coverpoint `cp_rs1` bin `b0`, and a companion string `.string "\"test: 359; cg: I_add_cg; cp: cmp_rd_rs2; bin: b30\""` at the end of the file. So `grep -c "^I_add_cg_" tests/rv32i/I/I-add-00.S` enumerates the bins actually exercised.
3. Full SV coverage needs Questa/VCS (`make coverage`, `framework/src/act/fcov/`), reports in `work/<config>/reports/<suite>_summary.txt` — out of scope for a Verilog/Verilator-core verification flow.

---

## 7. What is **not** suitable for RV32GC, and how many tests apply

Not applicable (will not be selected if your UDB config is honest):
* `tests/rv64*`, `tests/rv32e`, `tests/rv64e` — wrong XLEN/base.
* `tests/rv32i/Zfa*`, `Zfh*`, `Zfbfmin`, `Zk*` (crypto), `Zimop`, `Zcmop`, `Zabha`, `Zacas`, `Zicbo*`, `Zicond`, `Zihpm`, `Zbc`, `Zba`, `Zbb`, `Zbs`, `Zcb*`, `Zbkb/Zbkc/Zbkx` — only if you implement them.
* `tests/priv/Svnapot`, `Svpbmt` — require Sv39+ (`REQUIRED_EXTENSIONS` contain `Sv39/Sv48/Sv57`); the Sv32 portions of `SvZicbo`, `SvPMPZicbo`, `SvaduPMP` need `Zicbom/Zicboz/Zicbop` and/or `Svadu`.
* Vector (`V`, `Zv*`) — no `tests/**/V*` files exist (git-ignored) and every `V*` generator/coverpoint is irrelevant.
* Hypervisor (`H`, `H*` dirs in `coverpoints/priv`, `rvtest_macros_hypervisor.h`) — `tests/env/riscv_arch_test.h:7` even `#undef H_SUPPORTED` unconditionally.

**Counts (`.S` files):**

| scope | count |
|---|---|
| all unprivileged tests | 641 (`tests/rv32i`) + 113 (`tests/rv32e`) + 713 (`tests/rv64i`) + 148 (`tests/rv64e`) |
| all privileged tests | 361 |
| **RV32GC core ISA groups** (`I39 + M8 + F78 + D104`) | **229** |
| **RV32GC + C/Zicsr/Zifencei** (`+Zca26 +Zcd4 +Zcf4 +Zicsr6 +Zifencei1`) | **270** |
| **RV32GC + A** (`+Zaamo9 +Zalrsc2`) | **281** |
| **+ misaligned-access suites** (`+Misalign5 +MisalignF2 +MisalignD2 +MisalignZca4`) | **294** |
| optional bit-manip/crypto/FP16 groups (not in RV32GC) | 351 |
| **privileged, RV32-relevant (Sv32 + non-Sv39/48/57)** | **153** |
| **total directly applicable to your core** | **≈ 447** (294 unpriv + 153 priv) |

(Arithmetic: 229 + 37 + 11 + 13 = 290; the four `Misalign*` groups add 13 more → 294. 290 + 351 = 641, the full `tests/rv32i` count.)

---

## 8. Building with the `/opt/riscv` toolchain

Available: `/opt/riscv/bin/riscv32-unknown-linux-gnu-{gcc,as,ld,objdump,nm,readelf,objcopy}` — `gcc (g6afcc4f6d) 16.1.0`, target `riscv32-unknown-linux-gnu`, defaults:

```
-mabi=  ilp32d
-march= rv32imafdc_zicsr_zifencei_zmmul_zaamo_zalrsc_zca_zcd_zcf
```

**Yes, it can build the tests.** Confirmed: GCC 16 ≥ the framework's required GCC 15 (`framework/src/act/config.py:170`), and `-march=help`/`as -march=help` list every extension the tests need (`i m a f d c zicsr zifencei zmmul zaamo zalrsc zca zcd zcf zcb zba zbb zbc zbs zfa zfh zicond zicntr zihintpause zihintntl …`). All groups in §9 compiled and linked with it.

Appropriate values:

| purpose | `-march` | `-mabi` |
|---|---|---|
| integer-only tests (`I`, `Zicsr`, `Zifencei`, `Zaamo`, `Zalrsc`, `Zca`, `Misalign`, PMP, Sv32 priv) | `rv32i_zicsr_zifencei` (+`_zaamo_zalrsc`/`_zca` per test header) | `ilp32` |
| `M` | `rv32im_zicsr_zifencei` | `ilp32` |
| `F`, `Zcf` | `rv32if_zicsr_zifencei` (+`_zcf`) | `ilp32f` or `ilp32` |
| `D`, `Zcd` | `rv32ifd_zicsr_zifencei` (+`_zcd`) | `ilp32d` or `ilp32` |
| whole core / custom code | `rv32imafdc_zicsr_zifencei_zmmul_zaamo_zalrsc_zca_zcd_zcf` | `ilp32d` |
| maximal, incl. extensions the tests may use | `rv32imafdc_zicsr_zifencei_zicntr_zihintpause_zihintntl_zicond_zmmul_zaamo_zalrsc_zca_zcb_zcd_zcf` | `ilp32d` |

Caveat for the ACT4 flow: `-mabi` is chosen by the framework as `ilp32`/`ilp32e` (`build_plan.py:186`), which is fine for both integer and FP tests (it only affects C code and register-save conventions; the tests are assembly). When using the `act` framework, `compiler_exe`/`objdump_exe` in `test_config.yaml` must point at `riscv32-unknown-linux-gnu-gcc`/`-objdump` (or be on `PATH`); `framework/src/act/toolchain.py:99-133` will probe the assembler's `-march` support and emit `-march=rv32i -Xassembler -march=<test MARCH>` for assembly tests — which is exactly what the manual recipe does.

---

## 9. Verified end-to-end recipe (no ACT4 framework needed)

Everything below was executed in this session inside `/tmp/atest-scratch` (writable scratch; the source tree was not modified). It uses only the `/opt/riscv` toolchain, `bash`, `make` and `python3` (stdlib).

### 9.1 Why a hand-rolled recipe

`uv`, `mise`, `ruby`, `bundle`, `sail_riscv_sim` and `spike` are **not installed**, and there is no network, so `make` cannot run. The manual recipe reproduces `framework/src/act/build_plan.py`'s two-pass compile exactly, substituting a stdlib Python extractor for the reference model.

### 9.2 One-time setup (`/tmp/atest-scratch/rv32gc/`)

```bash
mkdir -p /tmp/atest-scratch/rv32gc && cd /tmp/atest-scratch/rv32gc
SRC=/home/shorthair/dsh/rv32-cpu/riscv-arch-test

# (a) linker script: reuse the CVW example, edit RAM_ORIGIN/TEST_BASE/NUM_HARTS for your core
cp $SRC/config/cores/cvw/cvw-rv64gc/link.ld .

# (b) rvmodel_macros.h  -> your DUT's HALT/IO/interrupt macros (normally DUT-authored)
# (c) rvtest_config.h   -> normally UDB-generated; hand-write the *_SUPPORTED + UDB_* set
#     both files are reproduced in /tmp/atest-scratch/rv32gc/ and in §9.6
```

Two traps that cost real debugging time:
* `UDB_MTVEC_BASE_ALIGNMENT_*` must be **byte alignments that are powers of two** (`4`, `64`), not the exponents used by `sail.json`'s `base_alignment`; otherwise the assembler fails with `rvtest_trap_handler.h:1293: Error: alignment not a power of 2`.
* `-DTEST_FILE` must reach the preprocessor **with quotes**: `'-DTEST_FILE="I-add-00.S"'`, because `rvtest_failure_code.h:2278` does `.ascii TEST_FILE`. Without quoting: `Error: junk at end of line, first unrecognized character is 'I'`.
* `rvtest_config.h` must define the `*_SUPPORTED` macros. Without `F_SUPPORTED`/`V_SUPPORTED`/`ZICNTR_SUPPORTED`, `tests/rv32i/Zicsr/Zicsr-csrrw-00.S:50` hits `#error no CSR known for testing`; without `F_SUPPORTED`, FP tests leave `failedtest_fp_x5_x4` undefined at link time.

### 9.3 Exact commands — RV32I test and privileged Sv32 test

```bash
cd /tmp/atest-scratch/rv32gc
SRC=/home/shorthair/dsh/rv32-cpu/riscv-arch-test
CC=riscv32-unknown-linux-gnu-gcc

# ---------- ONE RV32I TEST ----------
# pass 1: signature-generating ELF
$CC -Wl,--no-warn-rwx-segments \
    -I. -I$SRC/tests/env -Tlink.ld \
    -O0 -g -mcmodel=medany -nostdlib -nostartfiles \
    -march=rv32i -Xassembler -march=rv32i_zicsr_zifencei -mabi=ilp32 \
    -DSIGNATURE \
    -DSAIL_CLINT_BASE_ADDRESS=0x2000000 \
    -DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=0xc000000 \
    -DTEST_FLEN=32 '-DTEST_FILE="I-add-00.S"' \
    -o I-add-00.sig.elf $SRC/tests/rv32i/I/I-add-00.S

# pass 1b: reference signature. WITH Sail:  sail_riscv_sim --config <cfg>/sail.json \
#            --test-signature=I-add-00.sig --signature-granularity 4 I-add-00.sig.elf
#          then:  python3 -c "import sys;sys.path.insert(0,'$SRC/framework/src');\
#                 from act.sig_modify import process_signature_file;process_signature_file(__import__('pathlib').Path('I-add-00.sig'),32)"
#          Without a reference model, use the stdlib extractor:
python3 /tmp/atest-scratch/extract_sig.py I-add-00.sig.elf I-add-00.results 32

# pass 2: self-checking ELF (this is what you run on the DUT)
$CC -Wl,--no-warn-rwx-segments \
    -I. -I$SRC/tests/env -Tlink.ld \
    -O0 -g -mcmodel=medany -nostdlib -nostartfiles \
    -march=rv32i -Xassembler -march=rv32i_zicsr_zifencei -mabi=ilp32 \
    -DRVTEST_SELFCHECK '-DSIGNATURE_FILE="I-add-00.results"' -DXLEN=32 \
    -DTEST_FLEN=32 '-DTEST_FILE="I-add-00.S"' \
    -o I-add-00.elf $SRC/tests/rv32i/I/I-add-00.S

# ---------- ONE PRIVILEGED TEST (Sv32, uses trap machinery) ----------
$CC -Wl,--no-warn-rwx-segments -I. -I$SRC/tests/env -Tlink.ld \
    -O0 -g -mcmodel=medany -nostdlib -nostartfiles \
    -march=rv32i -Xassembler -march=rv32i_zicsr_zifencei -mabi=ilp32 \
    -DSIGNATURE -DSAIL_CLINT_BASE_ADDRESS=0x2000000 \
    -DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=0xc000000 \
    -DTEST_FLEN=32 '-DTEST_FILE="sv32_satp_access_test.S"' \
    -o sv32_satp_access_test.sig.elf $SRC/tests/priv/Sv/sv32_satp_access_test.S
python3 /tmp/atest-scratch/extract_sig.py sv32_satp_access_test.sig.elf sv32_satp_access_test.results 32
$CC -Wl,--no-warn-rwx-segments -I. -I$SRC/tests/env -Tlink.ld \
    -O0 -g -mcmodel=medany -nostdlib -nostartfiles \
    -march=rv32i -Xassembler -march=rv32i_zicsr_zifencei -mabi=ilp32 \
    -DRVTEST_SELFCHECK '-DSIGNATURE_FILE="sv32_satp_access_test.results"' -DXLEN=32 \
    -DTEST_FLEN=32 '-DTEST_FILE="sv32_satp_access_test.S"' \
    -o sv32_satp_access_test.elf $SRC/tests/priv/Sv/sv32_satp_access_test.S
```

A parameterised wrapper for bulk use is at `/tmp/atest-scratch/build_one_test.sh` (`build_one_test.sh <test.S> <outdir> <march> <mabi>`), and the signature extractor at `/tmp/atest-scratch/extract_sig.py`.

### 9.4 Observed output (reproduced twice, including from a clean directory)

```
$ ./build_one_test.sh .../tests/rv32i/I/I-add-00.S /tmp/atest-scratch/fresh rv32i_zicsr_zifencei ilp32
I-add-00.sig.elf: begin_signature=0x80016dd0 end_signature=0x80025ea0 -> 61648 bytes (15412 .word entries) -> /tmp/atest-scratch/fresh/I-add-00.results
built /tmp/atest-scratch/fresh/I-add-00.sig.elf , /tmp/atest-scratch/fresh/I-add-00.results , /tmp/atest-scratch/fresh/I-add-00.elf
[exit 0]

$ ./build_one_test.sh .../tests/priv/Sv/sv32_satp_access_test.S /tmp/atest-scratch/fresh rv32i_zicsr_zifencei ilp32
sv32_satp_access_test.sig.elf: begin_signature=0x8000bdf0 end_signature=0x8000bf60 -> 368 bytes (92 .word entries) -> /tmp/atest-scratch/fresh/sv32_satp_access_test.results
built /tmp/atest-scratch/fresh/sv32_satp_access_test.sig.elf , /tmp/atest-scratch/fresh/sv32_satp_access_test.results , /tmp/atest-scratch/fresh/sv32_satp_access_test.elf
[exit 0]
```

ELF properties of the result (bare-metal, static, correct entry):

```
Class: ELF32   Type: EXEC   Machine: RISC-V   Entry point address: 0x80000000
LOAD 0x001000 0x80000000 …  R E     ( .text.init + .text.rvtest )
LOAD 0x00a000 0x8000c000 …  RW      ( .data + .tohost )
LOAD 0x024000 0x80046000 …  R E     ( .text.rvmodel )
readelf -d  ->  There is no dynamic section in this file.
nm -> begin_signature 0x80016dd0   end_signature 0x80025ea0   rvtest_entry_point 0x80000000
```

The self-check and signature builds have **identical symbol addresses** (`begin_signature`/`end_signature` match between `I-add-00.sig.elf` and `I-add-00.elf`), confirming the framework's layout invariant.

Signature-region layout recovered by the extractor (RV32I test): first word `0x6f5ca309` (the dynamic `CANARY`), `0xdeadbeef` filler, then at word 405/408/411 the labelled regions:

```
405: final_sig_offset:            (preceded by final_sig_offset_canary 0x172d8e4b)
408: final_trap_sig_offset:       (preceded by final_trap_sig_offset_canary 0xf50f117a)
411: trap_sigptr:                 (preceded by trap_canary 0xd3a91f6c)
15415: sig_end_canary:            (final word 0xd3a91f6c)
```
which matches `framework/src/act/sig_modify.py:18-20`.

### 9.5 Spot-check: every RV32GC-relevant group compiles

```
Zaamo-amoadd.w-00     rv32imafdc_zicsr_zifencei/ilp32d      OK
Zca-c.add-00          rv32i_zicsr_zifencei_zca/ilp32        OK
Zalrsc-lr.w-00        rv32i_zicsr_zifencei_zalrsc/ilp32     OK
Zifencei-fence.i-00   rv32i_zicsr_zifencei/ilp32            OK
M-mul-00              rv32im_zicsr_zifencei/ilp32          OK
Misalign-lh-00        rv32i_zicsr_zifencei/ilp32            OK
D-fadd.d-00           rv32ifd_zicsr_zifencei/ilp32d         OK   (after adding F/D_SUPPORTED)
F-fadd.s-00           rv32if_zicsr_zifencei/ilp32f          OK
Zcd-c.fld-00          rv32ifd_zicsr_zifencei_zcd/ilp32d     OK
Zcf-c.flw-00          rv32if_zicsr_zifencei_zcf/ilp32f      OK
MisalignD-fld-00      rv32ifd_zicsr_zifencei/ilp32d         OK
Zicsr-csrrw-00        rv32i_zicsr_zifencei/ilp32            OK   (after adding F_SUPPORTED)
PMPZca_aligned_napot-00 rv32i_zicsr_zifencei_zca/ilp32      OK
PMPSm_cfg_XWR_all-01-00 (priv)                             OK
sv32_satp_access_test (priv, sig + self-check)             OK
```

### 9.6 Minimal `rvtest_config.h` and `rvmodel_macros.h` used

See `/tmp/atest-scratch/rv32gc/rvtest_config.h` and `/tmp/atest-scratch/rv32gc/rvmodel_macros.h`. Essentials of the former: `UDB_MXLEN 32`, `M_SUPPORTED`, `S_SUPPORTED`, `U_SUPPORTED`, `STANDARD_SM_SUPPORTED`, `F_SUPPORTED`, `D_SUPPORTED`, `ZCA_SUPPORTED`, `ZICNTR_SUPPORTED`, `ZIFENCEI_SUPPORTED`, `SV32_SUPPORTED`, `UDB_NUM_PMP_ENTRIES 16`, `UDB_NUM_USABLE_PMP_ENTRIES 16`, `UDB_PMP_{NAPOT,TOR}_SUPPORTED`, `UDB_PMP_GRANULARITY 4`, `UDB_MTVEC_BASE_ALIGNMENT_DIRECT 4`, `UDB_MTVEC_BASE_ALIGNMENT_VECTORED 64`, `UDB_STVEC_BASE_ALIGNMENT_VECTORED 4`, `UDB_TIME_CSR_IMPLEMENTED 1`. The latter: `RVMODEL_DATA_SECTION` (`tohost`/`fromhost`), `RVMODEL_HALT_PASS`/`FAIL` (write 1/3 to `tohost`, spin), NS16550 `RVMODEL_IO_INIT`/`RVMODEL_IO_WRITE_STR` at `0x10000000`, `RVMODEL_ACCESS_FAULT_ADDRESS 0`, `RVMODEL_INTERRUPT_LATENCY 10`, `RVMODEL_TIMER_INT_SOON_DELAY 1000`, CLINT addresses, and `RVMODEL_SET/CLR_MEXT_INT`, `RVMODEL_SET/CLR_SEXT_INT`.

**Honest limitation:** because no reference model is installable here, `*.results` was derived from the `.sig.elf`'s own initial region, so the self-checking ELF currently encodes `CANARY` + `0xdeadbeef` for the not-yet-executed tail. For a real verification run you must produce `*.results` from a correct reference model (Sail, or `spike +signature=…`, or QEMU + a signature dump), otherwise tests will report `TEST FAILED` at the first mismatching check and print a bogus expected value. The *build* pipeline itself is fully verified.

---

## 10. Verification harness contract (what your testbench must implement)

Minimum viable harness for `work/<cfg>/elfs/**/*.elf`:

1. **ELF loader**: parse `ELF32`/RISC-V/`EXEC`, honour `p_vaddr`/`p_paddr`, load all `PT_LOAD` segments into a memory model with at least the `link.ld` RAM region (default `0x80000000`, ≥ 64 MiB in the examples), set `PC = e_entry` (`0x80000000`). No dynamic linking, no libc, no `.init_array` — nothing else is needed.
2. **Termination observation**: watch the `tohost` symbol address (found from `.symtab`, or fixed by your `RVMODEL_DATA_SECTION`) for a store of `1` (pass) / `3` (fail); stop the sim with that status. Equivalently, implement `RVMODEL_HALT_*` as a write to a magic MMIO address your testbench decodes (`$finish`), or as an `ebreak` if your core traps to a testbench-visible halt.
3. **Console**: capture stores to your UART/console model so the `RVCP-SUMMARY:` lines (and the failure diagnostics) are visible. Buffer per test and grep with `run_tests.py`'s regex `RVCP-SUMMARY: TEST (PASSED|FAILED|SIGRUN) - Test File ".*"`.
4. **Timeout/watchdog**: unprivileged tests do **not** install trap handlers and can spin forever on an unexpected trap; also `RVMODEL_HALT_*` implementations end in an infinite `j self_loop`, so the simulator must stop on the `tohost` write, not on completion. Give each test an instruction/time budget.
5. **Reset state matching your config**: `misa`/`mstatus` reset values, `mhartid = 0`, `mtvec` alignment (your `UDB_MTVEC_BASE_ALIGNMENT_*`), PMP entry count and granularity, `satp` mode support (Sv32), and `mtime`/`mtimecmp` behaviour must agree with `rvtest_config.h` + `sail.json` + the UDB YAML, otherwise "expected" values disagree with the reference and tests fail spuriously. This is the #1 documented cause of failures (`README.md:375-381`).
6. **Interrupt support** if you want the interrupt tests: `msip`/`mtimecmp` memory-mapped registers and an external interrupt source with the addresses in your `rvmodel_macros.h`, plus a cycle-to-tick relationship consistent with `RVMODEL_MAX_CYCLES_PER_TIMER_TICK`/`RVMODEL_INTERRUPT_LATENCY`.
7. **Optional but recommended — signature dumping**: on halt, read `[begin_signature, end_signature)` and diff against the `.sig`/`.results`; useful to find the *first* diverging word and to cross-check a gold model (`spike`/`sail` if you later install one). `framework/src/act/trap_report.py` can decode the trap-signature region.
8. **Batch driver**: reuse `run_tests.py` for parallelism, logging (`logs/`, `summary.log`), and exit-code/summary interpretation: `./run_tests.py "<your sim invocation>" work/<cfg>/elfs`.

---

## 11. Uncertainties / things to verify

1. **No reference model available here.** Real `*.sig`/`*.results` need `sail_riscv_sim` 0.13.1 (exact version enforced at `framework/src/act/config.py:169`) or `spike` with `+signature=`. Nothing is stored in the tree; `work/` does not exist. Verify on a machine with network: install mise/uv + Ruby/Bundler, then `CONFIG_FILES=<your cfg>/test_config.yaml make -j$(nproc)`.
2. **`uv`/`mise`/Ruby/Bundler are absent here**, so the official ACT4 flow (`make`, `act`, `testgen`, UDB validation) could not be exercised at all. The Makefile *hard-errors* without them (`Makefile:104, 111`).
3. **`config/spike/spike-rv32-max/` is incomplete as a buildable config** in this checkout: it has `test_config.yaml`, `sail.json`, the UDB YAML and `run_cmd.txt`, but **no `link.ld`, no `rvmodel_macros.h`, no `rvtest_config.h`** (the CVW and QEMU configs do have them). Use `config/cores/cvw/cvw-rv32gc/` as your template — it is the closest published RV32GC + Sv32 + M/S/U example.
4. **`generate_build_plan` uses `config.dut_include_dir / "sail.json"`** (`build_plan.py:94, 571`) and `_sail_platform_defines` requires `platform.clint.supported == true` and `platform.simple_interrupt_generator.supported == true` in that file (`build_plan.py:43-64`) — your `sail.json` must keep those devices even if your DUT has no CLINT.
5. **Machine-CSR / interrupt / S-U CSR / `Sm` suites are not present as `.S` files** in this revision (§5), only their generators and coverpoints. If you need them, run `make tests` (needs uv/mise) or port the generators' output; do not assume `tests/priv/` is complete.
6. **`make tests` regenerates tracked files**; `AGENTS.md` says `tests/rv32i`, `tests/rv32e`, `tests/rv64i`, `tests/rv64e`, `coverpoints/unpriv`, `coverpoints/coverage` are generated-but-checked-in and CI verifies they are unchanged. Running generators inside this shared workspace could dirty 1995 tracked files — do it in a copy.
7. **`UDB_*` macro semantics beyond the ones I exercised** (e.g. `UDB_MTVEC_MODES_0/1`, `UDB_TIME_CSR_IMPLEMENTED`, `UDB_PMP_*`, `SV32_SUPPORTED` vs `S1P12P0_SUPPORTED`) were validated only by "the suite compiles and the layout is stable". The UDB-generated `rvtest_config.h` is authoritative — hand-written values must be re-checked against your real UDB config, and `sail.json` must describe the *same* machine.
8. **`eval`/permission risks in the recipe**: `-Xassembler -march=…` is required for assembly tests (`toolchain.py:130-133`); the second `-march` for `as` must include `_zicsr_zifencei` even when the test `MARCH` header omits them (e.g. `PMPSm` uses `rv${XLEN}i_zicsr_zifencei`, expanded to 32 by the framework — if you script it, substitute `${XLEN}` yourself).
9. **`riscv32-unknown-linux-gnu` vs the documented `riscv64-unknown-elf`**: verified working for these tests, but the framework's `check_compiler_version` (`config.py:223-240`) and `mabi` selection (`build_plan.py:186`) were not exercised. Set `compiler_exe: riscv32-unknown-linux-gnu-gcc`, `objdump_exe: riscv32-unknown-linux-gnu-objdump` in `test_config.yaml` and re-verify if you later run the real framework.
10. **`templates/` is missing** from this checkout although `Makefile:71` sets `TEMPLATEDIR := templates` — nothing in the current `Makefile` recipes references it, but regenerate/verify before relying on it.
11. **Coverage (SV functional coverage) needs Questa/VCS** and a lockstep RVVI trace (`framework/src/act/fcov/`, `sail_to_rvvi.py`); it is not usable with plain Icarus/Verilator without significant work. Treat `coverpoints/` as a checklist, not as an executable flow.
12. **The count "RV32GC-relevant ≈ 447"** is derived from directory names and `REQUIRED_EXTENSIONS` headers; the authoritative selection is done by UDB extension matching (`select_tests.py:91-114`). Build with your real UDB config to get the exact list (`work/<cfg>/extensions.txt`).
