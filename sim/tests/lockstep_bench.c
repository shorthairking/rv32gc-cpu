/* lockstep_bench.c —— 纯计算锁步基准（无任何 MMIO）
 *
 * 用途：给 scripts/lockstep.sh 做"Spike 提交轨迹 vs 本核提交轨迹"的长程比对。
 * 为什么需要它：arch-test 的自校验镜像会让 Spike 在 UART 处访问错误退出，memtest
 * 早期就会打印；本程序只用内存与算术，Spike 能一路执行到 6000+ 条提交。
 *
 * 约束（与 sim/tests/build.sh 一致）：-march=rv32i、-nostdlib，故不得用乘除/取模/64 位运算。
 * 布局：用 link_hi.ld 链接到 0x8000_0000，与 Spike 的 -m0x80000000:... 一致。
 * 结束：crt0 会把返回值写到 0x1FAFFF00（Spike 会在最后一步访问错误退出，比对只取前缀）。
 */
static unsigned data[128];

int main(void)
{
    unsigned i = 0, j = 0, acc = 0x12345678u;

    for (i = 0; i < 64u; i = i + 1u) {
        unsigned v = (i << 7) ^ (i << 3) ^ i;
        data[i] = v + 0x9e3779b9u;
    }
    for (j = 0; j < 48u; j = j + 1u) {
        for (i = 0; i < 64u; i = i + 1u) {
            unsigned v = data[i];
            acc = (acc + v) ^ (acc << 5);
            acc = acc + (v >> 3) + (i ^ j);
            if ((acc & 7u) == 3u) acc = acc ^ 0x9e3779b9u;
            data[i] = v + acc;
        }
    }
    return (int)(acc & 0xffu);
}
