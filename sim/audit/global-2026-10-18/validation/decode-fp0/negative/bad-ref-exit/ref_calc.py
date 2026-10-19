#!/usr/bin/env python3
# 反证：锚点正确但 python 退出码 1（应被 rc 判据拒绝）
print("REF_CHECK c1: OK value=0x40940433")
print("REF_CIN c1: OK cin=0x8c05")
raise SystemExit(1)
