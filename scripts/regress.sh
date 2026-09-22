#!/usr/bin/env bash
#==============================================================================
# scripts/regress.sh —— 顶层回归入口（L0 单元测试全量跑）【未捕获即失败】
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
# 用法 : ./scripts/regress.sh
# 范围 : 遍历 sim/unit/tb_*.sv（当前 19 个；清单以实际 `ls` 为准，不硬编码、不白名单）
#        —— 每个 TB 取**文件内第一个 `module` 名**作编译顶层（-s），把 rtl/**/*.v 全量编入
#           （与综合脚本同一份源码集合，避免手工维护 per-TB 依赖表导致真源分叉），
#           统一带 `-I rtl/pkg -I <repo>` 编译（RTL 内混用裸名与 rtl/pkg/… 两种 include 写法，
#           统一 include 路径天然兼容，无需按 TB 排除）。
#        产物 : sim/unit/<tb>.vvp（*.vvp 已在 .gitignore 第 40 行忽略）
#        日志 : mktemp 目录；全绿自动清理，失败/跳过时保留并打印路径（不污染仓库）
#
# 判据（每个 TB，**任一不满足 ⇒ 立即非零退出**；脚本自身**绝不**输出任何含 PASS 字样的
#       兜底文案——失败路径的诊断文字一律避开该字样）：
#   ① iverilog 编译成功（rc==0）。仅当编译失败原因**全部**是"待落盘集成件"缺失
#      （RV32_REGRESS_PENDING_MODULES：core_top / sim_mem_model / uart_ser_decoder，
#        见 08 §3.2 M1 集成件）时，才允许 `SKIP:` + WARN 显式降级；其余一律判失败。
#   ② vvp 运行退出码 == 0（timeout 兜底，超时=非零 ⇒ 失败；08 §8.1 第 5 条）
#   ③ 输出中**恰好一行**整行命中该 TB 源码里提取到的 PASS 锚点（`grep -cxF`；08 §8.1 第 4 条）
#   ④ 输出中成功标记出现次数 == 1（唯一）
#   ⑤ 输出中 FAIL 字样出现次数 == 0
#   锚点提取（不硬编码映射）：从 TB 源码扫 `NAME: PASS`，只保留 NAME 去掉一个 `_UNIT` 后
#   等于 `TB 文件基名大写` 的那个（这就是"TB 名 + TB 内实际锚点"双重判定）：
#       tb_lsu.sv         → TB_LSU: PASS          （无 _UNIT 后缀）
#       tb_fetch_unit.sv  → TB_FETCH_UNIT_UNIT:PASS（双 _UNIT，TB 源码如此）
#       tb_fpu_cmp_cvt.sv → TB_FPU_CMP_CVT_UNIT:PASS（顶层 tb_fpu_cmp_cvt，锚点带 _UNIT）
#   源码里若出现 0 个或多于 1 个候选锚点 ⇒ 判失败（fail-closed，不允许猜）。
#
# 汇总 : `REGRESS: <通过数>/<发现总数> PASS` —— **仅在"发现的 TB 全部运行且全绿"时**打印这一行
#         （此时 通过数 == 发现总数，即任务要求的 `REGRESS: N/N PASS`）。
#   ★ 有任何跳过 ⇒ **不打印任何带 PASS 的汇总行**，改为 `REGRESS: 部分完成 p/total（…未覆盖）`
#     + 每项一条 `SKIP:` 原因 —— 有意设计：杜绝把"部分运行"读成"全绿"（AGENT.md §0.6 教训）。
#   ★ 跳过只是"依赖尚未落盘"的显式降级（如集成 TB 依赖 rtl/top/core_top.v）：退出码默认 0
#     （warn 语义）；需要"跳过即失败"时置 RV32_REGRESS_STRICT_SKIP=1（退出码 3）。
#   ★ 退出码：0 = 全绿或"有跳过但非严格模式"；1 = 任一 TB 判失败（立即退出）；3 = 严格模式有跳过。
#
# 依据 : AGENT.md §0.6（未捕获即失败）、§3.2（回归脚本纪律）；docs/design/08-baseline-5stage.md
#        §8.1（单元测试入口与纪律：起始 fail、兜底文案禁 PASS、显式计数、正则成对、timeout、
#        可独立审查）、§3.2（scripts/regress.sh = 顶层回归入口）。
# 依赖 : scripts/env.sh（工具链/路径唯一真源，本脚本必须能 source 到它）
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# 0. 仓库根 + 统一环境（唯一真源）
#------------------------------------------------------------------------------
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
ENV_SH="${REPO_ROOT}/scripts/env.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -r "$ENV_SH" ] || die "缺少 ${ENV_SH}（工具链环境真源），无法继续"
# shellcheck source=./env.sh
. "$ENV_SH"

IV="${RV32_IVERILOG:-}"; VVP="${RV32_VVP:-}"
SIM_UNIT_DIR="${RV32_SIM_UNIT_DIR:-${REPO_ROOT}/sim/unit}"
[ -n "$IV" ]  && [ -x "$IV" ]  || die "未找到 iverilog（AGENT.md §2 环境事实：已安装）"
[ -n "$VVP" ] && [ -x "$VVP" ] || die "未找到 vvp（iverilog 运行时）"
command -v timeout >/dev/null 2>&1 || die "未找到 timeout（coreutils）；08 §8.1 要求每条测试加超时兜底"

TB_TIMEOUT="${TB_TIMEOUT:-300}"                 ;# 单个 TB 运行超时（秒）
#   ★ T5（2026-09-20，**只放宽墙钟兜底，不放松任何判据**）：
#     `tb_m3_ddr3` 是**集成级** TB（DDR3 全遍历 7 模式 + XIP 可变指令 + CLINT/AXI 判定），
#     它自带 `TIMEOUT_CYCLES = 1 200 000` 拍的**自身**预算（挂死即在 ~1 350 s 落到
#     `$fatal`，与本变量无关 ⇒ fail-closed 语义不变）。而 T4（FPU 内部 8 级流水，
#     +6 687 FF）把 iverilog 的仿真吞吐从 ≈2 185 拍/s 压到 ≈890 拍/s ⇒ 该 TB 在通用
#     300 s 墙钟下**必然**被 kill（实测为"非功能失败"：0 行 FAIL、进度/计数/结果区
#     观测全部符合预期，只是没跑完）。
#     故**按 TB 名**只给这一个 TB 单独的墙钟兜底；其余 22 个 TB 仍守 `TB_TIMEOUT`
#     （300 s）——保持"多数 TB 挂死能快速暴露"的纪律。
#     两个值都可用环境变量覆盖（TB_TIMEOUT / TB_TIMEOUT_TB_M3_DDR3）。
TB_TIMEOUT_TB_M3_DDR3="${TB_TIMEOUT_TB_M3_DDR3:-1800}"
#   ★ T6（2026-09-21，2B-2）：`tb_back2_lockstep` 是"双核（2A 顺序核 + front4/back2 乱序核）
#     同映像跑三组程序并与 Spike 黄金轨迹逐条比对"的**集成级** TB：
#       · 单程序约 400~3000 拍，但 iverilog 吞吐受两核 + 大阵列（ROB 128×416 bit、
#         6×16 项 uop 队列、PRF 96×32）影响，实测 ~300~800 拍/s；
#       · 其自身有 CYC_LIMIT=200000 拍的**内部**预算（超限即判 C3 失败，与本变量无关）；
#       · 通用 300 s 墙钟在"程序卡住"时会在跑到内部预算前把它 kill（非功能失败表征）。
#     故按名给它单独的墙钟兜底；**只放宽墙钟、不放松任何判据**（判据仍是 C1–C5 + 锚点唯一）。
#     `tb_back2_ipc` 是纯后端直驱短仿真（~3200 拍），保持通用档即可。
TB_TIMEOUT_TB_BACK2_LOCKSTEP="${TB_TIMEOUT_TB_BACK2_LOCKSTEP:-900}"
#   按 TB 名取墙钟兜底（默认 TB_TIMEOUT；tb_m3_ddr3 用放宽容口）。
tb_timeout_for() {
    case "$1" in
        tb_m3_ddr3)         printf '%s' "$TB_TIMEOUT_TB_M3_DDR3" ;;
        tb_back2_lockstep)  printf '%s' "$TB_TIMEOUT_TB_BACK2_LOCKSTEP" ;;
        *)                  printf '%s' "$TB_TIMEOUT" ;;
    esac
}
STRICT_SKIP="${RV32_REGRESS_STRICT_SKIP:-0}"    ;# 1 = 有跳过即判失败
# 显式依赖表（仅用于"依赖尚未落盘 ⇒ 跳过并 WARN"的显式降级），形如：
#     RV32_REGRESS_EXTRA_DEPS="tb_core_top:rtl/top/core_top.v tb_x:tests/x.svh"
# 说明：当前 sim/unit 下全部 TB 均自包含（TB 清单以实际 glob 为准，脚本不硬编码数量：
#       20:53 时为 19 个，20:57 起随并行交付的 tb_fpu.sv 自动变为 20 个）
#       ⇒ 本表默认空 ⇒ **默认全跑、零跳过**。它存在只是为了将来集成 TB（如 tb_core_top）
#       落进 sim/unit 时，能在脚本里"显式跳过并 warn"而不是悄悄红。
TB_EXTRA_DEPS="${RV32_REGRESS_EXTRA_DEPS:-}"
# 允许"显式跳过"的待落盘集成件（编译期 Unknown module type 命中这些名字才降级为 SKIP）
PENDING_MODULES="${RV32_REGRESS_PENDING_MODULES:-core_top sim_mem_model uart_ser_decoder}"

#------------------------------------------------------------------------------
# 1. 收集 TB 清单与 RTL 源集合（任一为空 ⇒ 立即失败，不"跑 0 个然后 PASS"）
#------------------------------------------------------------------------------
shopt -s nullglob
tbs=( "${SIM_UNIT_DIR}"/tb_*.sv )
shopt -u nullglob
[ "${#tbs[@]}" -gt 0 ] || die "sim/unit 下没有 tb_*.sv（目录：${SIM_UNIT_DIR}）"

mapfile -t rtl_srcs < <(rv32_rtl_sources)
[ "${#rtl_srcs[@]}" -gt 0 ] || die "rtl/**/*.v 为空（目录：${RV32_RTL_DIR}）；无 DUT 可编"

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rv32-regress.XXXXXX")"
finalize() {
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -rf "$LOG_DIR"
    else
        printf 'REGRESS: 日志保留在 %s（失败诊断用）\n' "$LOG_DIR" >&2
    fi
    return 0
}
trap finalize EXIT

printf '== regress.sh：REPO_ROOT=%s\n' "$REPO_ROOT"
printf '== regress.sh：TB 目录=%s（发现 %d 个 tb_*.sv）\n' "$SIM_UNIT_DIR" "${#tbs[@]}"
printf '== regress.sh：RTL 源=%d 个 rtl/**/*.v；iverilog=%s\n' "${#rtl_srcs[@]}" "$IV"
printf '== regress.sh：iverilog 版本=%s\n' "$( { "$IV" -V 2>&1 || true; } | sed -n '1p' )"
printf '== regress.sh：单 TB 超时=%ss（★ T5：tb_m3_ddr3 用放宽档 %ss，其余守默认）；日志目录=%s\n' \
       "$TB_TIMEOUT" "$TB_TIMEOUT_TB_M3_DDR3" "$LOG_DIR"

#------------------------------------------------------------------------------
# 2. 逐 TB：取顶层/锚点 → 编译 → 运行 → 判据
#------------------------------------------------------------------------------
n_total=0; n_run=0; n_pass=0; n_skip=0
skipped_notes=(); passed_names=()

# 从 TB 源码取**第一个** `module <名>`（= 该 TB 的编译顶层）；awk 一次性扫描，避免
# `sed | head` 早退在 pipefail 下产生非零状态导致 set -e 误触发。
tb_top_module() {
    awk '
        !done && match($0, /^[[:space:]]*module[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/^[[:space:]]*module[[:space:]]+/, "", s)
            print s; done = 1; exit
        }
    ' "$1"
}

# 从 TB 源码提取唯一 PASS 锚点（见文件头"锚点提取"口径）；每行一个候选，交给调用方计数。
tb_pass_anchors() {
    awk -v want="$2" '
        {
            line = $0
            while (match(line, /[A-Z][A-Z0-9_]*: ?PASS/)) {
                cand = substr(line, RSTART, RLENGTH)
                sub(/: ?PASS$/, "", cand)
                base = cand
                sub(/_UNIT$/, "", base)
                if (base == want) found[cand] = 1
                line = substr(line, RSTART + RLENGTH)
            }
        }
        END { for (k in found) print k }
    ' "$1"
}

# TB 显式依赖检查：命中且文件缺失 ⇒ 回显缺失路径（相对仓库根）
tb_missing_declared_dep() {
    local stem="$1" entry path
    for entry in $TB_EXTRA_DEPS; do
        case "$entry" in
            "${stem}:"*) path="${entry#*:}"
                         [ -e "${REPO_ROOT}/${path}" ] || { printf '%s' "$path"; return 0; } ;;
        esac
    done
    return 0
}

for tb in "${tbs[@]}"; do
    n_total=$((n_total + 1))
    stem="$(basename -- "$tb" .sv)"
    stem_upper="$(printf '%s' "$stem" | tr 'a-z' 'A-Z')"
    clog="${LOG_DIR}/${stem}.compile.log"
    rlog="${LOG_DIR}/${stem}.run.log"
    vvp_out="${SIM_UNIT_DIR}/${stem}.vvp"

    # ---- 2.1 顶层模块名 ----
    top="$(tb_top_module "$tb")"
    if [ -z "$top" ]; then
        printf 'FAIL: %s —— TB 源码内找不到 `module` 声明（无法确定编译顶层）\n' "$stem"
        exit 1
    fi

    # ---- 2.2 PASS 锚点（TB 名 + TB 内实际锚点 双重判定）----
    mapfile -t anchors < <(tb_pass_anchors "$tb" "$stem_upper")
    if [ "${#anchors[@]}" -ne 1 ]; then
        printf 'FAIL: %s —— TB 源码内 PASS 锚点不唯一（期望 1 个，实测 %d 个）\n' \
               "$stem" "${#anchors[@]}"
        exit 1
    fi
    anchor="${anchors[0]}"
    anchor_key="${anchor%: PASS}"        ;# 诊断只打锚点主体，失败路径不出现成功标记字样
    anchor_line="${anchor_key}: PASS"    ;# TB 成功路径的**整行**原文（判据③ 用整行精确匹配）

    # ---- 2.3 显式依赖（尚未落盘 ⇒ SKIP + WARN）----
    miss_dep="$(tb_missing_declared_dep "$stem")"
    if [ -n "$miss_dep" ]; then
        n_skip=$((n_skip + 1))
        skipped_notes+=( "${stem}（依赖未落盘：${miss_dep}）" )
        printf '[%2d/%2d] %-22s SKIP  —— 依赖未落盘：%s（WARN）\n' \
               "$n_total" "${#tbs[@]}" "$stem" "$miss_dep"
        continue
    fi

    # ---- 2.4 编译（-s 顶层；RTL 全量编入；统一 include 路径）----
    if ! "$IV" "${RV32_IV_FLAGS[@]}" -o "$vvp_out" -s "$top" "${rtl_srcs[@]}" "$tb" >"$clog" 2>&1; then
        # 编译失败：仅当缺失模块**全部**属"待落盘集成件"时降级为 SKIP，否则判失败
        missing_mods="$( { grep -oE 'Unknown module type: [A-Za-z_$][A-Za-z0-9_$]*' "$clog" || true; } \
                         | sed 's/.*: //' | LC_ALL=C sort -u || true)"
        all_pending=1
        if [ -z "$missing_mods" ]; then
            all_pending=0
        else
            while IFS= read -r m; do
                [ -n "$m" ] || continue
                case " ${PENDING_MODULES} " in
                    *" ${m} "*) : ;;
                    *) all_pending=0 ;;
                esac
            done <<< "$missing_mods"
        fi
        if [ "$all_pending" -eq 1 ]; then
            n_skip=$((n_skip + 1))
            skipped_notes+=( "${stem}（待落盘集成件缺失：$(printf '%s' "$missing_mods" | tr '\n' ' ')）" )
            printf '[%2d/%2d] %-22s SKIP  —— 待落盘集成件缺失：%s（WARN）\n' \
                   "$n_total" "${#tbs[@]}" "$stem" "$(printf '%s' "$missing_mods" | tr '\n' ' ')"
            continue
        fi
        printf -- '--- FAIL: %s（iverilog 编译失败，顶层 %s）---\n' "$stem" "$top"
        printf '    编译日志尾部（已滤除成功标记字样的行）：\n'
        { grep -v 'PASS' "$clog" || true; } | tail -n 20 | sed 's/^/      /'
        printf 'REGRESS: FAIL at %s\n' "$stem"
        exit 1
    fi

    # ---- 2.5 运行（timeout 兜底；rc 用 `|| rc=$?` 取，避免 set -e 抢跑）----
    #   ★ T5：兜底秒数**按 TB 名**取（tb_m3_ddr3 用放宽档，其余 300 s），
    #     并把实际生效值打进 FAIL 诊断，避免"看到 124 却不知超时档是多少"。
    tb_to="$(tb_timeout_for "$stem")"
    rc=0
    timeout "$tb_to" "$VVP" "$vvp_out" >"$rlog" 2>&1 || rc=$?
    n_run=$((n_run + 1))

    n_anchor_line="$(grep -cxF "$anchor_line" "$rlog" || true)"            ;# 整行精确命中次数
    n_mark_occ="$( { grep -o 'PASS' "$rlog" || true; } | wc -l )"          ;# 成功标记出现次数
    n_fail_occ="$(grep -c 'FAIL' "$rlog" || true)"                         ;# FAIL 字样行数
    # 兜底为 0：任何计数取空（grep 未命中/读文件失败）都必须落到"不满足判据"，绝不放行
    n_anchor_line="${n_anchor_line:-0}"; n_mark_occ="${n_mark_occ:-0}"; n_fail_occ="${n_fail_occ:-0}"

    reason=""
    if [ "$rc" -ne 0 ]; then
        reason="运行退出码=${rc}（期望 0；124 = 超时 ${tb_to}s）"
    elif [ "$n_anchor_line" -ne 1 ]; then
        reason="锚点 ${anchor_key} 整行命中 ${n_anchor_line} 次（期望 1）"
    elif [ "$n_mark_occ" -ne 1 ]; then
        reason="成功标记出现 ${n_mark_occ} 次（期望 1，唯一性判据）"
    elif [ "$n_fail_occ" -ne 0 ]; then
        reason="FAIL 字样出现 ${n_fail_occ} 行（期望 0）"
    fi

    if [ -n "$reason" ]; then
        printf -- '--- FAIL: %s（%s）---\n' "$stem" "$reason"
        printf '    顶层=%s 锚点=%s  rc=%s 整行命中=%s 成功标记=%s FAIL行=%s\n' \
               "$top" "$anchor_key" "$rc" "$n_anchor_line" "$n_mark_occ" "$n_fail_occ"
        # 诊断增强：把命中 FAIL 的 token 归类打印（例如 TB 把已知偏差记为 `XFAIL`），
        # **只作证据、不放行**——判据⑤ 仍按字面 FAIL 计数（父 Agent 口径：零 FAIL 字样）。
        fail_tokens="$( { grep -oE '[A-Za-z_]*FAIL[A-Za-z_]*' "$rlog" || true; } \
                        | LC_ALL=C sort | uniq -c | tr -s ' ' | tr '\n' ' ' )"
        printf '    FAIL 字样来源统计：%s\n' "${fail_tokens:-<无>}"
        printf '    运行输出尾部（已滤除成功标记字样的行）：\n'
        { grep -v 'PASS' "$rlog" || true; } | tail -n 20 | sed 's/^/      /'
        printf '    完整日志：%s\n' "$rlog"
        printf 'REGRESS: FAIL at %s\n' "$stem"
        exit 1
    fi

    n_pass=$((n_pass + 1))
    passed_names+=( "$stem" )
    printf '[%2d/%2d] %-22s top=%-24s PASS  锚点=%s（整行命中 %s 次，FAIL 0 行）\n' \
           "$n_total" "${#tbs[@]}" "$stem" "$top" "$anchor_key" "$n_anchor_line"
done

#------------------------------------------------------------------------------
# 3. 汇总（语义：**只有"发现的 TB 全部运行且全绿"才打印带 PASS 的汇总行**；
#    有任何跳过 ⇒ 只打印"部分完成/未覆盖"，绝不出现 PASS 字样，杜绝部分运行被读成全绿）
#------------------------------------------------------------------------------
printf '== regress.sh：总数=%d 运行=%d 通过=%d 跳过=%d 失败=0\n' \
       "$n_total" "$n_run" "$n_pass" "$n_skip"
if [ "${#passed_names[@]}" -gt 0 ]; then
    printf 'REGRESS: 已通过 TB 清单（%d 个）= %s\n' "${#passed_names[@]}" "${passed_names[*]}"
fi
if [ "$n_skip" -gt 0 ]; then
    for note in "${skipped_notes[@]}"; do
        printf 'SKIP: %s\n' "$note"
    done
    printf 'REGRESS: WARN %d 个 TB 被显式跳过（原因见上），本次覆盖不全\n' "$n_skip"
    if [ "$STRICT_SKIP" = "1" ]; then
        printf 'REGRESS: 失败（RV32_REGRESS_STRICT_SKIP=1：存在跳过即判失败）\n'
        exit 3
    fi
    printf 'REGRESS: 部分完成 %d/%d（已运行项全绿；%d 项跳过 ⇒ 未覆盖）\n' \
           "$n_pass" "$n_total" "$n_skip"
    exit 0
fi
printf 'REGRESS: %d/%d PASS\n' "$n_pass" "$n_total"
exit 0
