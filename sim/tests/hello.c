/*=============================================================================
 * hello.c —— 最小裸机测试：向仿真虚拟串口打印一行，返回 0
 *   0x1FAF_FF10 = CONFREG 仿真窗口 VIRTUAL_UART（写一字节 → TB 打印）
 *   见 docs/kb/01-chiplab-platform.md §4 / docs/kb/07-sim-debug.md
 *===========================================================================*/

#define VUART (*(volatile unsigned char *)0x1FAFFF10u)

int main(void)
{
    static const char msg[] = "Hello RV32GC\n";
    const char *p = msg;

    while (*p)
        VUART = (unsigned char)*p++;

    return 0;
}
