#!/usr/bin/env python3
#==============================================================================
# sim/unit/prog/gen_front4_int_data.py —— 由 ELF + Spike 日志生成 TB 内嵌数据
#==============================================================================
# 用法（真源命令见 sim/unit/prog/front4_int.S 头注）：
#   python3 sim/unit/prog/gen_front4_int_data.py <elf> <spike-log> > sim/unit/prog/front4_int_data.svh
#
# 输入：
#   ① ELF            —— 用 objcopy -O verilog 临时转出"地址 + 字节流"（小端、按地址递增）；
#   ② Spike 日志     —— `--log-commits --log=<file>` 的行，形如：
#                       `core   0: 3 0x80000000 (0x80002137) x2  0x80002000`
#                       提取**架构提交 PC 序列** = 黄金轨迹（TB 逐条比对）。
#
# 输出（被 sim/unit/tb_front4_integration.sv `include）：
#   · task automatic load_front4_int_image;  … 逐字写入 TB 的 DDR 存储体（wr32）
#   · task automatic load_front4_int_golden; … 填充黄金 PC 数组 g_pc[0..g_npc-1]
#
# ★ 生成端**强校固定程序身份**：entry=0x80000000、21 个映像字（sha256）、
#   248 条 PC、首 PC=0x80000000、末 PC=0x80000050、PC 序列 sha256。
#   空/截断/自旋/错程序日志一律非 0 退出且**不输出 .svh**（防空金/短金静默变绿）。
#   工具/超时/独占临时根/ELF/日志 sha 记录在 GEN_META 与生成头注释中。
#   若程序/黄金确需变更：必须用同一 front4_int.S 走真实 ELF+Spike，先给母
#   hash/逐 PC 等价证明，**不得**为迎合错误 DUT 手改 g_pc。
#==============================================================================
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

EXPECT_N = 248
EXPECT_ENTRY = 0x80000000
EXPECT_LAST = 0x80000050
EXPECT_WORDS = 21
EXPECT_MAX_GOLD = 1024
EXPECT_IMG_SHA256 = "e50c3a288e582fb7b68b6748684c942d9cb728eab07ed03f9d2a0556e9feb96c"
EXPECT_PC_SHA256 = "a2b5c9c671726e1d84cfac24e92e9615309bbb83b496c78454f5b6303a4dfca2"
TOOL_TIMEOUT_S = 120


def die(reason: str) -> int:
    print("GEN_FAIL reason=%s" % reason, file=sys.stderr)
    return 1


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tool_version(tool: str) -> str:
    try:
        r = subprocess.run([tool, "--version"], capture_output=True, text=True,
                           timeout=TOOL_TIMEOUT_S, check=False)
        lines = (r.stdout or r.stderr).splitlines()
        return lines[0].strip() if lines else "unknown"
    except Exception as exc:  # noqa: BLE001 - metadata only
        return "version_error:%s" % exc


def parse_elf_image(elf: str, tmpdir: str, meta: dict) -> dict:
    objcopy = os.environ.get("RV32_OBJCOPY") or shutil.which(
        "riscv32-unknown-linux-gnu-objcopy") or shutil.which("objcopy")
    readelf = os.environ.get("RV32_READELF") or shutil.which(
        "riscv32-unknown-linux-gnu-readelf") or shutil.which("readelf")
    if not objcopy or not os.access(objcopy, os.X_OK):
        raise RuntimeError("objcopy_missing")
    if not readelf or not os.access(readelf, os.X_OK):
        raise RuntimeError("readelf_missing")
    meta["objcopy"] = os.path.realpath(objcopy)
    meta["readelf"] = os.path.realpath(readelf)
    meta["objcopy_version"] = tool_version(objcopy)
    meta["readelf_version"] = tool_version(readelf)

    hdr = subprocess.run([readelf, "-h", elf], capture_output=True, text=True,
                         timeout=TOOL_TIMEOUT_S, check=False)
    meta["readelf_rc"] = str(hdr.returncode)
    m = re.search(r"Entry point address:\s*0x([0-9a-fA-F]+)", hdr.stdout)
    if hdr.returncode != 0 or not m:
        raise RuntimeError("elf_header_parse_failed")
    entry = int(m.group(1), 16)
    meta["entry"] = "0x%08x" % entry
    if entry != EXPECT_ENTRY:
        raise RuntimeError("elf_entry=%s expect=0x%08x" % (meta["entry"], EXPECT_ENTRY))

    hexpath = os.path.join(tmpdir, "image.hex")
    r = subprocess.run([objcopy, "-O", "verilog", elf, hexpath],
                       capture_output=True, text=True, timeout=TOOL_TIMEOUT_S, check=False)
    meta["objcopy_rc"] = str(r.returncode)
    if r.returncode != 0 or not os.path.isfile(hexpath) or os.path.getsize(hexpath) == 0:
        raise RuntimeError("objcopy_failed rc=%d" % r.returncode)

    words = {}
    cur = None
    byte_idx = 0
    with open(hexpath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            if line.startswith("@"):
                cur = int(line[1:], 16)
                byte_idx = 0
                continue
            if cur is None:
                raise RuntimeError("hex_address_missing")
            for tok in line.split():
                b = int(tok, 16) & 0xFF
                a = cur + byte_idx
                w = a & ~3
                words[w] = words.get(w, 0) | (b << (8 * (a & 3)))
                byte_idx += 1
    return words


def parse_spike_pcs(logp: str) -> list:
    pat = re.compile(r"^core\s+\d+:\s+\d+\s+0x([0-9a-fA-F]+)")
    pcs = []
    with open(logp, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = pat.match(line)
            if m:
                pcs.append(int(m.group(1), 16))
    return pcs


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: gen_front4_int_data.py <elf> <spike-log>", file=sys.stderr)
        return 2
    elf, logp = sys.argv[1], sys.argv[2]
    if not os.path.isfile(elf) or os.path.getsize(elf) == 0:
        return die("elf_missing_or_empty path=%s" % elf)
    if not os.path.isfile(logp) or os.path.getsize(logp) == 0:
        return die("spike_log_missing_or_empty path=%s" % logp)

    tmp_root = os.environ.get("RV32_GEN_TMPROOT") or None
    tmpdir = tempfile.mkdtemp(prefix="front4_gen_", dir=tmp_root)
    meta = {
        "elf": os.path.realpath(elf),
        "elf_sha256": sha256_file(elf),
        "elf_bytes": str(os.path.getsize(elf)),
        "spike_log": os.path.realpath(logp),
        "spike_log_sha256": sha256_file(logp),
        "spike_log_bytes": str(os.path.getsize(logp)),
        "timeout_s": str(TOOL_TIMEOUT_S),
        "tmp_root": tmpdir,
    }
    try:
        try:
            words = parse_elf_image(elf, tmpdir, meta)
        except Exception as exc:  # noqa: BLE001 - fail closed with reason
            return die("elf_image_failed detail=%s" % exc)

        if len(words) != EXPECT_WORDS:
            return die("image_words=%d expect=%d" % (len(words), EXPECT_WORDS))
        if not words or min(words) != EXPECT_ENTRY:
            return die("image_base=0x%08x expect=0x%08x"
                       % (min(words) if words else 0, EXPECT_ENTRY))
        img_txt = "".join("%08x %08x\n" % (a, words[a]) for a in sorted(words))
        img_sha = hashlib.sha256(img_txt.encode()).hexdigest()
        meta["image_sha256"] = img_sha
        if img_sha != EXPECT_IMG_SHA256:
            return die("image_sha256=%s expect=%s" % (img_sha, EXPECT_IMG_SHA256))

        try:
            pcs = parse_spike_pcs(logp)
        except Exception as exc:  # noqa: BLE001
            return die("spike_log_parse_failed detail=%s" % exc)
        if len(pcs) == 0:
            return die("pc_count=0 (empty/truncated/foreign log)")
        if len(pcs) != EXPECT_N:
            return die("pc_count=%d expect=%d (empty/truncated/foreign log)"
                       % (len(pcs), EXPECT_N))
        if len(pcs) > EXPECT_MAX_GOLD:
            return die("pc_count=%d exceeds MAX_GOLD=%d" % (len(pcs), EXPECT_MAX_GOLD))
        if pcs[0] != EXPECT_ENTRY:
            return die("pc_first=0x%08x expect=0x%08x" % (pcs[0], EXPECT_ENTRY))
        if pcs[-1] != EXPECT_LAST:
            return die("pc_last=0x%08x expect=0x%08x (no success termination identity)"
                       % (pcs[-1], EXPECT_LAST))
        pc_txt = "".join("%08x\n" % p for p in pcs)
        pc_sha = hashlib.sha256(pc_txt.encode()).hexdigest()
        meta["pc_sha256"] = pc_sha
        if pc_sha != EXPECT_PC_SHA256:
            return die("pc_sha256=%s expect=%s (wrong program/spin/truncated log)"
                       % (pc_sha, EXPECT_PC_SHA256))

        # ---- 只有全部强校通过后才允许输出 ----
        out = []
        out.append("// ==== 自动生成（不要手改）：sim/unit/prog/gen_front4_int_data.py ====")
        out.append("// 源：sim/unit/prog/front4_int.S（+ front4_int.ld）+ Spike --log-commits 黄金轨迹")
        for k in ("elf", "elf_sha256", "spike_log", "spike_log_sha256", "objcopy",
                  "objcopy_version", "readelf", "readelf_version", "timeout_s",
                  "tmp_root", "image_sha256", "pc_sha256", "entry"):
            out.append("// GEN_%s=%s" % (k.upper(), meta.get(k, "unset")))
        out.append("// 程序映像：%d 个字；黄金轨迹：%d 条提交 PC" % (len(words), len(pcs)))
        out.append("")
        out.append("task automatic load_front4_int_image;")
        out.append("    begin")
        for a in sorted(words):
            out.append("        wr32(32'h%08x, 32'h%08x);" % (a, words[a]))
        out.append("    end")
        out.append("endtask")
        out.append("")
        out.append("task automatic load_front4_int_golden;")
        out.append("    integer gi;")
        out.append("    begin")
        out.append("        g_npc = %d;" % len(pcs))
        out.append("        for (gi = 0; gi < g_npc; gi = gi + 1) g_pc[gi] = 32'h0;")
        for i, pc in enumerate(pcs):
            out.append("        g_pc[%d] = 32'h%08x;" % (i, pc))
        out.append("    end")
        out.append("endtask")
        out.append("")
        print("\n".join(out))
        for k in ("elf", "elf_sha256", "spike_log", "spike_log_sha256", "image_sha256",
                  "pc_sha256", "objcopy", "readelf", "timeout_s", "tmp_root"):
            print("GEN_META %s=%s" % (k, meta.get(k, "unset")), file=sys.stderr)
        return 0
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
