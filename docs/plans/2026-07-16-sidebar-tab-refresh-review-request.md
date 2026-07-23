# 侧栏 Tab 刷新卡顿修复 Review 说明

## 基本信息

- 分支：`fix/sidebar-tab-refresh-stalls`
- Commit：`addb22c0 fix: prevent sidebar stalls during tab changes with many bookmarks`
- 基线：`34b905f5`
- 主要范围：侧栏 Tab section 刷新、通用 Diffable Outline planner/snapshot/view，以及相关回归测试

## 一、问题

当侧栏包含约 495 个 bookmark 节点时，新建、关闭、排序普通 Tab，以及点击 pinned item（会新建或激活对应 Tab），都会在主线程出现明显卡顿。

修复前的日志显示：

| 场景 | Outline 节点数 | 完整刷新次数 | Planner operations | 同步刷新总耗时 |
|---|---:|---:|---:|---:|
| 点击 pinned item（新建或激活对应 Tab） | 497 | 3 | `0 + 0 + 0` | `432.481 ms` |
| 新建普通 Tab | 497 → 498 | 2 | `1 + 0` | `284.556 ms` |
| 关闭普通 Tab | 498 → 497 | 2 | `1 + 0` | `284.866 ms` |
| 普通 Tab 排序 | 498 | 2 | `1 + 0` | `295.491 ms` |
| 小数据量下新建 Tab | 7 → 8 | 2 | `1 + 0` | `6.126 ms` |

这说明卡顿与 Tab 数量关系不大，主要随共享 outline 中的 bookmark 节点数量增长。

其中：

- Pinned item 点击流程的多次 publication 在侧栏边界上都是结构 no-op，但每次仍执行完整 snapshot validation 和 diff planning。
- 普通 Tab 新建、关闭、排序通常包含一次真实结构刷新，以及一次完全重复的 no-op 刷新。
- Snapshot 构建约为 `1 ms`，AppKit operation apply 通常低于 `4 ms`，并不是主要瓶颈。

## 二、原因

### 1. Tab section 的等价 publication 没有在消费端过滤

`TabSectionController.refreshTabItems` 每次收到 `normalTabs`、group 或 split publication 后，都会重新生成 tab section items，并通知 `SidebarTabListViewController`。

修复前即使以下内容都未变化，也会进入完整刷新：

- Root item 的有序 ID。
- Root item 的对象 identity。
- Group membership。
- Split pane membership。

### 2. Tab-only 更新被放大为整棵 bookmark tree 的 diff

侧栏使用一个共享 snapshot，同时包含：

- Bookmark rows。
- Bookmark/Tab separator。
- 普通 Tab、Tab Group、Split Pair rows。

因此一次 tab section 通知会把约 495 个无关 bookmark 节点一起送入 validation 和 planner。即使最终 operations 为 0，完整遍历和排序仍发生在主线程。

### 3. Snapshot validation 和 planner 存在重复工作

修复前一次有效的 `reloadWith` 会发生：

1. View 验证新的 snapshot。
2. Planner 再验证旧 snapshot。
3. Planner 再验证新 snapshot。

同时：

- `orderedNodeIDs` 在一次 validation 中被重复排序。
- Sibling diff 的 parent 候选包含 root 和全部节点，大量没有 children 的 bookmark leaf 也参与无效遍历。
- Structural operation、same-parent move、replacement safety 分别重复计算并排序这组 sibling parent IDs。

在约 498 个节点时，planner 本身约消耗 `120-130 ms`，是主要同步耗时来源。

### 4. Review 过程中发现两个既有 correctness 边界问题

这两个问题不是本次性能优化新引入，但本次优化加强了对 planner 和 snapshot validation contract 的依赖，因此一并修复。

#### Replacement 与 sibling 结构变化组合

原 planner 只检查 replacement 在新旧 snapshot 中的 index 相同，没有考虑 replacement 前面已经执行的 remove/insert 会改变实时 index。

例如：

```text
old: [a, proxy(old), b]
new: [b, proxy(new)]

operations:
remove(a, index: 0)
replace(proxy, index: 1)
```

删除 `a` 后，index 1 已经指向 `b`。继续执行 replacement 会操作错误的 sibling，可能导致 outline 与 data source 不一致，甚至触发 AppKit consistency exception。

#### Snapshot validation 接受 orphan node

原 validation 会接受“`parentID` 存在，但没有出现在 parent 的 `childIDs` 中”的节点。

当下一帧把同一个 orphan 加入 `childIDs` 时，节点 ID、parentID 和对象 identity 都可能保持不变，planner 会错误返回空 plan，但 data source 已经增加一行。

## 三、修改方式

### 1. 增加 Tab section no-op fast path

`TabSectionChange` 新增 `rootItemsChanged`，同时比较：

- 有序 item IDs。
- 有序对象 identities。

对象 identity 必须参与判断，因为同 ID、新对象在 diffable 语义中属于 replacement，不能当作 no-op。

当 `rootItemsChanged == false` 时，不再调用 `refreshAllItems`，但仍保留必要的轻量更新：

- 更新 active/focusing selection。
- 更新 `visibleBookmarkTabs`。
- 更新 floating new-tab visibility。
- 对 affected groups 做定向 member rebinding。
- 对 affected splits 做定向 pane rebinding。
- 更新 new-tab cleanup visibility。
- 清理已经关闭 Tab 对应的 floating bookmark proxy。

当 root ID、顺序或对象 identity 发生变化时，继续走原有完整 diffable snapshot 路径。

### 2. 减少 planner 的机械重复工作

- 每次 validation 只排序一次 `orderedNodeIDs`。
- 每次 plan 只计算一次需要参与 sibling diff 的 parent IDs，并跳过 old/new 两侧都没有 children 的 leaf 节点。
- Parent 集合仍同时考虑 old/new 两侧存在 children 的节点，保留 first-child insertion、last-child removal、reorder 和 cross-parent move 的覆盖。

### 3. 对已验证 snapshot 使用 prevalidated planner

`DiffableOutlineView` 增加 validated-state 跟踪：

- 新 snapshot 在更新 data source 前仍必须验证一次。
- 旧 snapshot 只有在来自上一笔成功接受的 validated request 时才可信。
- 满足上述条件时使用 `planValidated`，避免 planner 再验证 old/new snapshot。
- `resetDiffableSnapshot` 注入的 snapshot 明确标记为 untrusted，下一次 apply 继续走 checked planner fallback。
- Invalid snapshot 仍在 data source mutation 前被拒绝。

### 4. 修复 replacement operation 的 index 安全问题

对于包含 `highestReplaced` 的直接 parent：

- 按实际执行顺序重放 structural removes 和 inserts。
- 验证重放后的 sibling ID 列表是否等于新 snapshot。
- 如果无法到达新结构，返回 `.unsafe` 并走现有 `reloadData` fallback。
- Replacement 与同 parent move 共存时继续保守返回 `.unsafe`。

该实现不会无条件回退：replacement 后方安全的尾部新增或删除仍保持 incremental，避免 floating proxy 与普通 Tab 新建/关闭组合退化为全量刷新。

### 5. 收紧 orphan validation

对于任何没有从 roots/childIDs 引用到的节点：

- 先保留 cycle 检查，维持稳定诊断顺序。
- 非 cycle 节点统一返回 `.unreachableNode`。

不会在 `planValidated` 内恢复 validation；合法 snapshot 的性能优化保持不变。

### 6. 保留性能日志

现有日志前缀完整保留：

```text
[PHI_DEBUG][PIN_CLICK][BM][SIDEBAR_REFRESH]
```

新增或保留的关键字段包括：

- `trigger`、`refreshReason`、window/trace ID。
- `itemIDsChanged`、`itemIdentitiesChanged`。
- `affectedGroups`、`affectedSplits`。
- Snapshot、validation、planner、AppKit apply、completion 耗时。
- `validationMode=checked|prevalidated`。
- `action=skip-outline-refresh`。

日志只存在于 DEBUG 路径，不影响 Release 行为。

## 四、影响范围

### 直接影响

- 侧栏普通 Tab、Pinned Tab、Tab Group、Split Pair 的刷新路由。
- `DiffableOutlineSnapshot` 的非法结构判断。
- `DiffableOutlineDiffPlanner` 的 validation、replacement 和 sibling operation 规划。
- `DiffableOutlineView` 对 accepted snapshot 的信任状态管理。

### 不涉及

- 不修改 Chromium/Phi bridge 的 Tab 生命周期或 publication 次数。
- 不修改 BrowserState 的 Tab、Group、Split 数据模型。
- 不修改 bookmark 的存储、排序或展开状态语义。
- 不恢复旧的手工 root insert/remove/move 路径。
- 不引入新的全局状态或并行 snapshot 架构。

### 性能与兼容性取舍

- 等价 tab section publication 从完整 outline diff 降为轻量 UI/lifecycle 更新。
- 合法、已验证 snapshot 避免 planner 内的重复 validation。
- Replacement 与 sibling operation 只有在 operation replay 无法证明安全时才回退 `reloadData`。
- 更严格的 orphan validation 只会拒绝原本就不满足树结构 contract 的 snapshot。

## 五、验证结果

### Post-fix 运行日志

在 497-498 个 outline 节点下：

| 指标 | 修复前 | 修复后 | 改善 |
|---|---:|---:|---:|
| 新建普通 Tab 的累计同步 outline refresh | `284.556 ms` | `17.196 ms` | `94.0%` |
| 首次真实刷新 `syncTotalMs` | `147.124 ms` | `17.196 ms` | `88.3%` |
| Diffable `totalMs` | `145.837 ms` | `16.153 ms` | `88.9%` |
| Planner `totalMs` | `122.968 ms` | `3.783 ms` | `96.9%` |
| Planner `diffCoreMs` | `90.863 ms` | `3.780 ms` | `95.8%` |
| 首次刷新 `totalToPostReloadMs` | `317.311 ms` | `47.072 ms` | `85.2%` |

普通 Tab 新建：

- 一次真实结构刷新正常执行。
- 后续重复 publication 命中 `skip-outline-refresh`。
- Planner 报告 `validationMode=prevalidated`，planner-side old/new validation 为 0。

点击 pinned item（新建/激活对应 Tab）：

- 本次日志中四次等价 publication 全部命中 `skip-outline-refresh`。
- 没有进入 snapshot validation 或 planner。
- 记录到的 tab-section 与 selection 工作合计约 `0.175 ms`。

仍待补充：

- 大 bookmark 数据量下关闭普通 Tab 的 post-fix 日志。
- 大 bookmark 数据量下普通 Tab 排序的 post-fix 日志。

### 自动化测试覆盖

新增或扩展的测试覆盖：

- Tab root IDs、顺序和对象 identity 比较。
- No-op fast path 的 selection 与 `visibleBookmarkTabs` 更新。
- Same-ID 新对象仍进入完整 diffable replacement。
- Parent 获得 first child、失去 last child。
- Replacement + sibling remove/insert 的 unsafe fallback。
- Replacement 后方安全 insert/remove 仍保持 incremental。
- Orphan snapshot validation 和 orphan-to-linked transition。
- `resetDiffableSnapshot` 后继续使用 checked planner。
- View fallback、reentrant reload 和既有 replacement/move 行为。

目前尚未完成 behavior-level 自动化覆盖的 fast-path 副作用包括：

- Affected group/split 的定向 cell rebinding。
- New-tab cleanup 与 floating new-tab visibility。
- Floating bookmark proxy cleanup。

现有 post-fix 日志中的 `affectedGroups=0`、`affectedSplits=0`，因此这些边界仍需要后续定向测试或手工验证。当前自动化行为测试已经覆盖 selection、`visibleBookmarkTabs` 和 same-ID replacement。

提交前已通过 `git diff --check` 和修改 Swift 文件的 parser 检查。最终修改后的 Xcode build/test 需要由本机非 sandbox 环境或 CI 再确认。

## 六、风险与 Review 重点

建议重点 Review 以下边界：

1. `rootItemsChanged` 是否完整表达了 outline root replacement contract，尤其是同 ID、新对象场景。
2. Fast path 是否保留 selection、visible bookmarks、group/split rebinding 和 cleanup 生命周期工作。
3. `currentSnapshotIsValidated` 是否只在 accepted/reset 路径上正确切换。
4. Replacement sibling operation replay 是否严格匹配实际 remove → move → insert → replace 的执行顺序。
5. `.unsafe` fallback 是否只覆盖无法证明安全的组合，不会让普通新增/关闭退化为全量 reload。
6. 更严格的 orphan validation 是否只影响非法 snapshot。

## 七、Review 结论建议

本次修改保持了现有 sidebar/diffable ownership，不改变上游 publication 和数据模型。运行日志已经验证 pinned item 点击流程与普通 Tab 新建场景的主要性能收益；correctness review 中发现的 replacement index 和 orphan validation 问题也已补齐保护与回归测试。

合并前建议完成：

- 最终 Xcode build 和 focused tests。
- 大 bookmark 数据量下 close/reorder 的 post-fix 复测。
