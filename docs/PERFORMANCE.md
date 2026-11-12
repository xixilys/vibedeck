# VibeDeck 性能基线（2026-11-12）

目标是让常驻菜单栏监控在**不减少功能**的前提下降低 CPU 与内存。以下数字来自同一份真实缓存
（`~/.config/vibedeck/usage-daily.json`，约 43 MB，19.6 万条 7 天内记录、50.4 万个冻结桶）上的
`--bench-history` 与 `--bench-live`，Apple Silicon，`swiftc -O`。

| 指标 | 重构前 | 重构后 |
| --- | ---: | ---: |
| 点账本行数 | 699,198 | 195,155 |
| 冷启动峰值 RSS | 1.50 GB | 1.05 GB |
| 稳定后 physical footprint | ~1.41 GB | ~0.44 GB |
| 第 2 次 2 分钟扫描 CPU | 5.0–6.8 s | 0.4–2.8 s（通常 <1.5 s；赶上冻结批次约 2.5 s） |
| 历史采集单独空闲 CPU | ~5.7% | ~2.4% |
| 自测 | 通过 | 通过（`--selftest`） |

## 关键改动

1. **冻结历史不再复制进点账本。** 7 天前的请求按 `FrozenBucket` 保存，但过去还会为每个桶再造一个
   `AccountUsagePoint`（50 万行 × 240 B）。现在用 `AccountUsage.HistoricalGroupBuilder` 流式聚合为
   账号/来源/币种的终身总计，再合并进 `AccountUsageSnapshot`，额度窗口仍只看最近 7 天的点账本。
2. **冻结与 timing 清理按批执行。** 每有 1 条记录越过 7 天边界就重建 70 万点快照，是空闲 CPU 的主要来源。
   现在边界后保留 1 小时宽限，timing 清理 10 分钟一次。
3. **内容代数 + 价格/汇率/远端状态指纹。** 没有账目变化时直接复用上一份快照，不再每 2 分钟复制账本；
   价格表、汇率、远端状态或跨天仍会强制重建。
4. **点账本复用。** 没有文件产生新点时，直接按引用复用上一份 `[AccountUsagePoint]`（COW），不复制 47 MB。
5. **缓存读写显式 `autoreleasepool`。** 解压后的 140 MB plist 与保存时的 190 MB 编码/压缩缓冲及时归还，
   稳定 footprint 从 ~620 MB 降到 ~440 MB。
6. **远端账号覆盖只遍历本次新记录。** 原先每 5 分钟把 12 万条历史记录重新扫一遍。
7. **SwiftUI 视图拆分。** `AccountQuotaGrid.tile` 与 `GlassBars` 拆成小子视图，既解决 `-O` 类型检查超时，
   也让 5 秒刷新只 diff 局部子树（去掉了 ring 的 `AnyView`）。

## 验证

- `VibeDeck --selftest`：全部纯函数、缓存增量、权限、价格重算自测通过。
- `VibeDeck --bench-history 3`：点账本 195k；第 2/3 次扫描 CPU 0.4–2.8 s。
- `VibeDeck --debug-quota`：同一份缓存下账号累计与重构前一致
  （openai `466863 req / 66,983,913,198 tok`，Codex `35213 req / 6,634,313,164 tok`）。
- `VibeDeck --render-panel`：总览、订阅、账号详情均正常渲染，账号详情仍显示终身累计。
