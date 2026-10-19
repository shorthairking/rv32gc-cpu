#!/usr/bin/env bash
#==============================================================================
# sim/functional/run.sh —— 正确行为功能回归**总入口**（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二）
# 用法 : ./sim/functional/run.sh            # 默认固定完整清单（唯一"完整阶段"口径）
#        RV32_FUNCTIONAL_DIR=... RV32_FUNCTIONAL_MANIFEST=... ./sim/functional/run.sh
#                                          # 自定义子集/隔离夹具 ⇒ 按 CUSTOM 标记，不代表完整阶段通过
#
# 目标 : 按清单逐个调用独立功能包脚本，用 "rc + 唯一整行锚点 + 缺例 + 零 FAIL + 零旧错误复现标记"
#        五条 fail-closed 判据给出入口级结论。本入口不做 RTL 级判定，也不替代
#        scripts/regress.sh（原 33 TB 单元回归）。
#
# 清单 : ${RV32_FUNCTIONAL_MANIFEST}（默认 ${RV32_FUNCTIONAL_DIR}/manifest.tsv）；格式见清单头注。
#        ★ 默认清单固定、非空；空清单/缺列/锚点不符/重名一律判失败，绝不把空集当成功。
#        ★ 未落盘的包 ≡ **缺例 ⇒ 明确失败**，不允许 SKIP；母 Agent 后续分派补齐。
#        ★ 不创建"永远 PASS 占位"包；每包必须自判正确期望。
#
# 入口类型（防"子集冒充完整阶段通过"）：
#        · DEFAULT（未覆盖 RV32_FUNCTIONAL_DIR / RV32_FUNCTIONAL_MANIFEST，且 realpath 与
#          sim/functional 及其 manifest.tsv 一致）⇒ 成功汇总前缀 `FUNCTIONAL:`
#        · CUSTOM（任一被自定义/指向别处）⇒ 成功汇总前缀 `FUNCTIONAL_CUSTOM:`，
#          并在输出中明确标注"不代表完整阶段通过"；**绝不**输出 `FUNCTIONAL: N/N 包 PASS`。
#        · 任何空集/清单非法/失败路径都不打印任何成功聚合行。
#
# 脚本路径安全（防软链接逃逸）：
#        · 清单只接受 FUNC_DIR 下的**相对**路径、且不含 `..` 分量；
#        · 再对 FUNC_DIR 与实际脚本做 realpath 规范化并校验包含关系：
#          文件软链接逃逸、父目录软链接逃逸、断链一律拒绝；**合法目录内**脚本（含指向
#          目录内目标的软链接）正常执行。
#
# 产物 : 每次运行独占一个目录（默认 ${RV32_BUILD_DIR}/functional/runner 之下，build/ 已忽略）：
#            <RUN_DIR>/logs/<pkg>.log        每包 stdout+stderr 全文（成功/失败都保留）
#            <RUN_DIR>/pkg/<pkg>/            该包私有产物目录（经 RV32_FUNCTIONAL_PKG_OUT_DIR 传入）
#        可用 RV32_FUNCTIONAL_OUT_DIR 改产物根；根下由 mktemp 新建唯一子目录 ⇒ 并发不互覆。
#        本入口不删除任何目录（不做 cleanup）。
#
# 判据（每包；任一不满足即该包失败；聚合失败 ⇒ 入口 rc=1）：
#   ① 脚本 realpath 规范化后仍位于 FUNC_DIR 内、且存在、且为普通文件（否则："缺例"/"逃逸"）
#   ② `timeout <T> bash <脚本>` 的 rc == 0（PASS 之后非零同样失败；124 = 超时）
#   ③ 输出中**恰好一行**整行等于该包锚点（`grep -cxF`；0 次=缺锚点，>1 次=多锚点，均失败）
#   ④ 输出中 FAIL 字样出现 0 次
#   ⑤ 输出中 DEFECT_REPRODUCED（冻结审计的"旧错误已复现"标记）出现 0 次：
#      复现旧缺陷 **不是** 修复通过；合法 FUNCTIONAL_* 锚点也不能抵消该标记。
# 汇总 : 全部包成功 ⇒ `<AGG>: N/N 包 PASS`（N = 清单包数，**不是**向量数）且 rc=0；
#        否则 ⇒ 只打印失败明细 + `<AGG>: 失败 X / 共 N 包`，**不打印任何成功聚合行**，rc=1。
#
# 依据 : AGENT.md §0.6（未捕获即失败）；docs/design/08-baseline-5stage.md §8.1（入口纪律）；
#        NEXT_SESSION.md §2.1 F0（fail-closed、输出隔离/留档、缺例不可 SKIP）；
#        sim/audit/global-2026-10-18/07-test-infrastructure.md §发现1/2/7 与 §REPORT:219
#        （DEFECT_REPRODUCED 的 exit0 ≠ DUT 正确）。
# 依赖 : scripts/env.sh（工具链/路径唯一真源）
#==============================================================================
set -euo pipefail

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
ENV_SH="${REPO_ROOT}/scripts/env.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
fail() { printf 'FAIL: %s\n' "$*"; }
# 逻辑性失败（清单缺失/为空/无有效条目 ≡ 缺例）：打印 FAIL 并 rc=1，与"操作不可继续"的
# die（缺 env.sh、产物根非法等）区分，便于日志锚定。
fail_exit() { fail "$*"; exit 1; }

[ -r "$ENV_SH" ] || die "缺少 ${ENV_SH}（工具链环境真源），无法继续"
# shellcheck source=../scripts/env.sh
. "$ENV_SH"

command -v timeout  >/dev/null 2>&1 || die "未找到 timeout（coreutils）；每包必须有墙钟兜底"
command -v readlink >/dev/null 2>&1 || die "未找到 readlink（coreutils）；需规范化脚本 realpath"

#------------------------------------------------------------------------------
# 0a. 解析 FUNC_DIR / 清单，并判定入口类型（DEFAULT vs CUSTOM）
#------------------------------------------------------------------------------
DEFAULT_FUNC_DIR="$(cd -- "$SCRIPT_DIR" && pwd -P)"
FUNC_DIR_RAW="${RV32_FUNCTIONAL_DIR:-$SCRIPT_DIR}"
FUNC_DIR="$(cd -- "$FUNC_DIR_RAW" 2>/dev/null && pwd -P)" \
    || fail_exit "包目录不存在或不可进入：${FUNC_DIR_RAW}"
[ -n "$FUNC_DIR" ] || fail_exit "包目录无法规范化：${FUNC_DIR_RAW}"

MANIFEST="${RV32_FUNCTIONAL_MANIFEST:-${FUNC_DIR}/manifest.tsv}"
DEFAULT_MANIFEST="${DEFAULT_FUNC_DIR}/manifest.tsv"
manifest_real="$(readlink -f -- "$MANIFEST" 2>/dev/null || true)"
if [ "$FUNC_DIR" = "$DEFAULT_FUNC_DIR" ] && [ "$manifest_real" = "$DEFAULT_MANIFEST" ]; then
    AGG="FUNCTIONAL"
    ENTRY_KIND="DEFAULT"
    ENTRY_NOTE="默认固定完整清单（sim/functional/manifest.tsv）"
else
    AGG="FUNCTIONAL_CUSTOM"
    ENTRY_KIND="CUSTOM"
    ENTRY_NOTE="自定义 FUNC_DIR/MANIFEST 子集或隔离夹具 —— 不代表完整阶段通过"
fi

OUT_ROOT="${RV32_FUNCTIONAL_OUT_DIR:-${RV32_BUILD_DIR}/functional/runner}"
PKG_TIMEOUT="${RV32_FUNCTIONAL_PKG_TIMEOUT:-900}"

#------------------------------------------------------------------------------
# 0b. 分配本次运行的独占目录（所有生成物只在 build/ 下的运行根内）
#------------------------------------------------------------------------------
case "$OUT_ROOT" in
    /*) : ;;
    *)  die "RV32_FUNCTIONAL_OUT_DIR 必须是绝对路径（当前值：${OUT_ROOT}）" ;;
esac
mkdir -p -- "$OUT_ROOT" || die "无法创建功能回归产物根：${OUT_ROOT}"
RUN_DIR="$(mktemp -d "${OUT_ROOT}/functional-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")" \
    || die "无法在 ${OUT_ROOT} 下分配唯一 run 目录"
case "$RUN_DIR" in
    "${OUT_ROOT%/}"/*) : ;;
    *) die "mktemp 返回的运行目录不在产物根下：${RUN_DIR}（产物根 ${OUT_ROOT}）" ;;
esac
LOG_DIR="${RUN_DIR}/logs"; PKG_OUT_ROOT="${RUN_DIR}/pkg"
mkdir -p -- "$LOG_DIR" "$PKG_OUT_ROOT" || die "无法创建本次运行目录：${RUN_DIR}"

# 成功/失败都保留并打印目录（入口级证据不随 rc0 删除；本入口不删除任何目录）。
finalize() {
    local rc=$?
    printf '%s: 本次运行目录=%s（日志目录=%s；成功/失败均保留）\n' \
           "$AGG" "$RUN_DIR" "$LOG_DIR" >&2
    return 0
}
trap finalize EXIT

printf '== functional/run.sh：REPO_ROOT=%s\n' "$REPO_ROOT"
printf '== functional/run.sh：入口类型=%s（%s）\n' "$ENTRY_KIND" "$ENTRY_NOTE"
printf '== functional/run.sh：包目录=%s（raw=%s）\n' "$FUNC_DIR" "$FUNC_DIR_RAW"
printf '== functional/run.sh：清单=%s\n' "$MANIFEST"
printf '== functional/run.sh：单包超时=%ss；本次 run 目录=%s\n' "$PKG_TIMEOUT" "$RUN_DIR"

#------------------------------------------------------------------------------
# 1. 读清单（空清单/格式非法 ⇒ 直接失败；不继续）
#    —— 解析加入临时数组，全部校验通过后才执行，避免"边读边跑"。
#------------------------------------------------------------------------------
[ -f "$MANIFEST" ] || fail_exit "清单不存在：${MANIFEST}（缺清单 ≡ 缺例，判失败）"
[ -s "$MANIFEST" ] || fail_exit "清单为空：${MANIFEST}（空清单不是成功）"

pkg_scripts=(); pkg_anchors=(); pkg_descs=()
n_bad=0
while IFS=$'\t' read -r script anchor desc || [ -n "${script:-}" ]; do
    script="${script%$'\r'}"; anchor="${anchor%$'\r'}"; desc="${desc%$'\r'}"
    case "$script" in ''|\#*) continue ;; esac           # 空行/注释
    if [ -z "${anchor:-}" ]; then
        fail "清单行缺锚点列（脚本='${script}'）；格式：<脚本>\t<锚点>\t<说明>"
        n_bad=$((n_bad + 1)); continue
    fi
    # 脚本路径安全校验（第一层）：必须相对 FUNC_DIR、无 .. 分量、无绝对路径。
    case "$script" in
        ''|/*|..|../*|*/../*|*/..)
            fail "清单脚本路径非法（必须为 FUNC_DIR 下相对路径、不含 .. 分量）：'${script}'"
            n_bad=$((n_bad + 1)); continue ;;
    esac
    # 锚点约定校验：FUNCTIONAL_<脚本基名（去 .sh，去 test_ 前缀，大写/非字母数字→_）>: PASS
    base="$(basename -- "$script")"
    stem="${base%.sh}"
    [ "$stem" != "$base" ] || { fail "清单脚本必须以 .sh 结尾：'${script}'"; n_bad=$((n_bad + 1)); continue; }
    conv="${stem#test_}"
    conv="$(printf '%s' "$conv" | tr 'a-z' 'A-Z' | sed 's/[^A-Z0-9_]/_/g')"
    want="FUNCTIONAL_${conv}: PASS"
    if [ "$anchor" != "$want" ]; then
        fail "锚点与约定不符（脚本='${script}'）：期望 '${want}'，清单给 '${anchor}'"
        n_bad=$((n_bad + 1)); continue
    fi
    pkg_scripts+=( "$script" ); pkg_anchors+=( "$anchor" ); pkg_descs+=( "${desc:-}" )
done < "$MANIFEST"

if [ "$n_bad" -gt 0 ]; then
    printf '%s: 清单校验失败 %d 处；共 %d 个包条目 ⇒ 入口失败\n' \
           "$AGG" "$n_bad" "${#pkg_scripts[@]}"
    exit 1
fi
n_total="${#pkg_scripts[@]}"
[ "$n_total" -gt 0 ] || fail_exit "清单 ${MANIFEST} 无有效包条目（空集判失败，不是成功）"

# 重名/重复锚点检查（有重复 ⇒ 判失败，避免"调了哪个包"不可判定）。
for ((i = 0; i < n_total; i++)); do
    for ((j = i + 1; j < n_total; j++)); do
        if [ "${pkg_scripts[i]}" = "${pkg_scripts[j]}" ]; then
            fail "清单脚本重复：${pkg_scripts[i]}"; exit 1
        fi
        if [ "${pkg_anchors[i]}" = "${pkg_anchors[j]}" ]; then
            fail "清单锚点重复：${pkg_anchors[i]}"; exit 1
        fi
    done
done

printf '== functional/run.sh：清单包数=%d（报告包数，不虚报向量数）\n' "$n_total"

#------------------------------------------------------------------------------
# 2. 逐包执行 + fail-closed 判定
#------------------------------------------------------------------------------
n_pass=0; n_fail=0; failed_names=()

for ((i = 0; i < n_total; i++)); do
    script="${pkg_scripts[i]}"; anchor="${pkg_anchors[i]}"; desc="${pkg_descs[i]}"
    base="$(basename -- "$script")"; stem="${base%.sh}"
    pkg_path="${FUNC_DIR}/${script}"
    plog="${LOG_DIR}/${stem}.log"
    pkg_out="${PKG_OUT_ROOT}/${stem}"
    idx=$((i + 1))

    mkdir -p -- "$pkg_out" || { fail "${script} —— 无法创建包产物目录：${pkg_out}"; exit 1; }

    # ---- 2.1 realpath 包含校验（第二层；拒绝文件/父目录软链接逃逸与断链）----
    pkg_real="$(readlink -f -- "$pkg_path" 2>/dev/null || true)"
    if [ -z "$pkg_real" ]; then
        printf -- '--- FAIL: %s（脚本路径无法规范化：断链或父目录缺失 %s）---\n' "$script" "$pkg_path"
        n_fail=$((n_fail + 1)); failed_names+=( "$script(路径不可规范化)" )
        continue
    fi
    case "$pkg_real" in
        "${FUNC_DIR%/}"/*) : ;;
        *)  printf -- '--- FAIL: %s（realpath 逃出包目录：%s -> %s）---\n' \
                   "$script" "$pkg_path" "$pkg_real"
            n_fail=$((n_fail + 1)); failed_names+=( "$script(realpath逃逸)" )
            continue ;;
    esac

    # ---- 2.2 缺例 / 非普通文件（未落盘 ⇒ 失败，绝不 SKIP）----
    if [ ! -e "$pkg_real" ]; then
        printf -- '--- FAIL: %s（缺例：脚本未落盘 %s）---\n' "$script" "$pkg_path"
        n_fail=$((n_fail + 1)); failed_names+=( "$script(缺例)" )
        continue
    fi
    if [ ! -f "$pkg_real" ]; then
        printf -- '--- FAIL: %s（不是普通文件：%s）---\n' "$script" "$pkg_path"
        n_fail=$((n_fail + 1)); failed_names+=( "$script(非普通文件)" )
        continue
    fi

    # ---- 2.3 执行（timeout 兜底；rc 用 `|| rc=$?` 取，避免 set -e 抢跑）----
    rc=0
    ( export RV32_FUNCTIONAL_RUN_DIR="$RUN_DIR" \
             RV32_FUNCTIONAL_PKG_NAME="$stem" \
             RV32_FUNCTIONAL_PKG_OUT_DIR="$pkg_out"
      timeout "$PKG_TIMEOUT" bash "$pkg_real" ) >"$plog" 2>&1 || rc=$?

    n_anchor="$(grep -cxF "$anchor" "$plog" || true)"
    n_fail_occ="$(grep -c 'FAIL' "$plog" || true)"
    n_defect="$(grep -c 'DEFECT_REPRODUCED' "$plog" || true)"
    n_anchor="${n_anchor:-0}"; n_fail_occ="${n_fail_occ:-0}"; n_defect="${n_defect:-0}"

    reason=""
    if [ "$rc" -ne 0 ]; then
        reason="rc=${rc}（期望 0；124 = 超时 ${PKG_TIMEOUT}s）"
    elif [ "$n_anchor" -ne 1 ]; then
        reason="锚点整行命中 ${n_anchor} 次（期望 1；'${anchor}'）"
    elif [ "$n_fail_occ" -ne 0 ]; then
        reason="FAIL 字样出现 ${n_fail_occ} 行（期望 0）"
    elif [ "$n_defect" -ne 0 ]; then
        reason="出现旧错误复现标记 DEFECT_REPRODUCED ${n_defect} 行（复现旧缺陷 ≠ 修复通过）"
    fi

    if [ -n "$reason" ]; then
        printf -- '--- FAIL: %s（%s）---\n' "$script" "$reason"
        printf '    说明=%s\n' "${desc:-<无>}"
        printf '    顶层输出尾部（已滤除成功标记字样的行）：\n'
        { grep -v 'PASS' "$plog" || true; } | tail -n 20 | sed 's/^/      /'
        printf '    完整日志：%s\n' "$plog"
        n_fail=$((n_fail + 1)); failed_names+=( "$script" )
        continue
    fi

    n_pass=$((n_pass + 1))
    printf '[%2d/%2d] %-32s PASS  锚点=%s（整行命中 1 次，FAIL 0 行，DEFECT_REPRODUCED 0 行）\n' \
           "$idx" "$n_total" "$script" "${anchor%: PASS}"
done

#------------------------------------------------------------------------------
# 3. 汇总（有失败 ⇒ 聚合行不含 PASS，rc=1；全绿才打印 N/N 包 PASS；
#    CUSTOM 入口的成功汇总前缀为 FUNCTIONAL_CUSTOM，绝不冒充完整阶段 FUNCTIONAL:）
#------------------------------------------------------------------------------
printf '== functional/run.sh：入口类型=%s 包数=%d 通过=%d 失败=%d\n' \
       "$ENTRY_KIND" "$n_total" "$n_pass" "$n_fail"
if [ "$n_fail" -ne 0 ]; then
    printf '%s: 失败包清单（%d 个）= %s\n' "$AGG" "${#failed_names[@]}" "${failed_names[*]}"
    printf '%s: 失败 %d / 共 %d 包 —— 功能回归未全部通过（缺例/逃逸/rc/锚点/FAIL/旧标记 见上）\n' \
           "$AGG" "$n_fail" "$n_total"
    exit 1
fi
printf '%s: %d/%d 包 PASS\n' "$AGG" "$n_pass" "$n_total"
exit 0
