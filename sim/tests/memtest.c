/*=============================================================================
 * memtest.c —— 0x0001_0000 起 64 KiB 读写校验（字节 / 半字 / 字 / 非对齐字）
 *
 *   编译：-march=rv32i -mabi=ilp32 -nostdlib -nostartfiles（无 libgcc）
 *   → 只用移位/加减/异或，不用除法、取模、64 位运算、浮点
 *
 *   通过：返回 0；失败：打印诊断信息并返回 1
 *===========================================================================*/

#define VUART (*(volatile unsigned char *)0x1FAFFF10u)

#define BASE  0x00010000u          /* 64 KiB 测试区起点 */
#define BYTE_N  (16u * 1024u)      /* [0x10000, 0x14000) 字节  */
#define HALF_N  (8u  * 1024u)      /* [0x14000, 0x18000) 半字  */
#define WORD_N  (4u  * 1024u)      /* [0x18000, 0x1C000) 字    */
#define MISC_N  16u                /* [0x1C000, 0x1C040) 走 1 */
#define UNAL_OFF 0x100u            /* 非对齐字测试偏移 */

static void putc_(char c)
{
    VUART = (unsigned char)c;
}

static void puts_(const char *s)
{
    while (*s)
        VUART = (unsigned char)*s++;
}

static void puthex(unsigned v)
{
    static const char hexd[] = "0123456789abcdef";
    int sh;

    puts_("0x");
    for (sh = 28; sh >= 0; sh -= 4)
        putc_(hexd[(v >> (unsigned)sh) & 0xFu]);
}

static int fail(const char *what, unsigned addr, unsigned got, unsigned exp)
{
    puts_("MEMTEST FAIL: ");
    puts_(what);
    puts_(" @ ");
    puthex(addr);
    puts_(" got ");
    puthex(got);
    puts_(" exp ");
    puthex(exp);
    putc_('\n');
    return 1;
}

int main(void)
{
    volatile unsigned char  *pb = (volatile unsigned char  *)(BASE);
    volatile unsigned short *ph = (volatile unsigned short *)(BASE + BYTE_N);
    volatile unsigned       *pw = (volatile unsigned       *)(BASE + BYTE_N + HALF_N * 2u);
    volatile unsigned       *pm = (volatile unsigned       *)(BASE + BYTE_N + HALF_N * 2u + WORD_N * 4u);
    volatile unsigned       *pu;
    unsigned i, v, got;

    puts_("memtest: 64 KiB @0x00010000\n");

    /* ---- 1) 字节：写 ---- */
    for (i = 0; i < BYTE_N; i++)
        pb[i] = (unsigned char)((i * 7u + 0x35u) & 0xFFu);
    /* ---- 1) 字节：校验 ---- */
    for (i = 0; i < BYTE_N; i++) {
        v = (i * 7u + 0x35u) & 0xFFu;
        got = pb[i];
        if (got != v)
            return fail("byte", BASE + i, got, v);
    }

    /* ---- 2) 半字：写 + 校验 ---- */
    for (i = 0; i < HALF_N; i++)
        ph[i] = (unsigned short)(((i << 4) ^ 0x5A5Au) & 0xFFFFu);
    for (i = 0; i < HALF_N; i++) {
        v = ((i << 4) ^ 0x5A5Au) & 0xFFFFu;
        got = ph[i];
        if (got != v)
            return fail("half", BASE + BYTE_N + i * 2u, got, v);
    }

    /* ---- 3) 字：写 + 校验 ---- */
    for (i = 0; i < WORD_N; i++)
        pw[i] = (i * 0x01010101u) ^ 0xA5A5A5A5u;
    for (i = 0; i < WORD_N; i++) {
        v = (i * 0x01010101u) ^ 0xA5A5A5A5u;
        got = pw[i];
        if (got != v)
            return fail("word", BASE + BYTE_N + HALF_N * 2u + i * 4u, got, v);
    }

    /* ---- 4) 走 1 图案（相邻位不串扰）---- */
    for (i = 0; i < MISC_N; i++)
        pm[i] = 1u << i;
    for (i = 0; i < MISC_N; i++) {
        v = 1u << i;
        got = pm[i];
        if (got != v)
            return fail("walk1", BASE + BYTE_N + HALF_N * 2u + WORD_N * 4u + i * 4u, got, v);
    }

    /* ---- 5) 非对齐字访问（+1/+2/+3，跨字边界，硬件拆分或异常由核决定）---- */
    {
        volatile unsigned char *puc = (volatile unsigned char *)(BASE + BYTE_N + HALF_N * 2u + WORD_N * 4u + UNAL_OFF);
        unsigned off;

        /* 先把 8 字节邻域置成已知图案 */
        for (i = 0; i < 8u; i++)
            puc[i] = (unsigned char)(0xC0u + i);

        for (off = 1; off <= 3u; off++) {
            pu = (volatile unsigned *)(BASE + BYTE_N + HALF_N * 2u + WORD_N * 4u + UNAL_OFF + off);
            v = 0x11223344u + off;
            *pu = v;
            got = *pu;
            if (got != v)
                return fail("unaligned-word", (unsigned)pu, got, v);
        }

        /* 非对齐字写不得越界：off=1..3 只覆盖 +1..+6，故 +0 与 +7 必须保持原图案 */
        got = puc[0];
        if (got != 0xC0u)
            return fail("unaligned-guard-lo", (unsigned)puc, got, 0xC0u);
        got = puc[7];
        if (got != 0xC7u)
            return fail("unaligned-guard-hi", (unsigned)(puc + 7u), got, 0xC7u);
    }

    puts_("memtest: all patterns OK\n");
    return 0;
}
