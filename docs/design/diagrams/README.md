# 设计图（Graphviz）

本目录是 CPU 的**结构图与数据通路图**源码（`.dot`）与渲染产物（`.svg`）。修改 `.dot` 后重新渲染：

```bash
cd docs/design/diagrams
for f in *.dot; do dot -Tsvg "$f" -o "${f%.dot}.svg"; done
# 需要 PNG 时：
for f in *.dot; do dot -Tpng -Gdpi=140 "$f" -o "${f%.dot}.png"; done
```

| 文件 | 内容 | 对应文档 |
|---|---|---|
| `cpu-block.dot` | CPU 整体结构图（前端/后端/存储/特权/总线） | `../00-overview.md` |
| `pipeline.dot` | 流水级划分与各级功能、乱序反馈、重定向路径 | `../01-pipeline.md` |
| `bpu.dot` | 锦标赛分支预测器结构（Gshare + 局部 + 选择器 + BTB/RAS + 更新路径） | `../02-branch-predictor.md` |
| `ooo-datapath.dot` | 乱序数据通路（重命名/ROB/发射队列/PRF/执行单元/LSQ/写回） | `../05-ooo.md` |
| `mem-subsystem.dot` | 存储层次、Sv32 MMU、非缓存通道、AXI 与平台设备 | `../03-cache.md`、`../06-bus-axi.md` |

> 依赖：`graphviz`（`dot`）。当前环境已安装（`/usr/bin/dot`）。
