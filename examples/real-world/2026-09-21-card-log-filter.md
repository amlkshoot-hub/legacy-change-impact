# 真实案例：当工具没帮上忙时

这是一份回溯分析报告，对象是一个真实项目里的已合并提交。**所有标识符已替换**（包名、类名、表名、仓库名），报告结构、行号位置与结论保持原样。

- 改动内容：卡日志去重 + 审批人按角色过滤
- 规模：2 文件，+109 / −4
- 分析方式：`scan-refs.ps1 -Diff 3f2a9c1~1` + 人工补扫

放这个案例的目的是记录**边界**：上一个案例（[case-study](../case-study/CASE-STUDY.md)）说明工具擅长什么，这个说明它不擅长什么。

---

## 一、变更锚点

| # | 符号 | 类型 | 说明 |
|---|---|---|---|
| 1 | `resolveEligibleUserIds` | 新私有方法 | 按角色解析候选人 userId |
| 2 | `splitCsv` | 新私有方法 | 逗号串拆分 |
| 3 | `filterDuplicateReceiveLogs` | 新私有方法 | 过滤重复领用日志 |
| 4 | `isReceiveLog` | 新私有方法 | 判定领用日志 |
| 5 | `isReceiveConfirmationLog` | 新私有方法 | 判定签收日志 |
| 6 | `GET /card/application/approver/list` | 接口 | 新增 3 个可选参数 |
| 7 | `queryOperationLogs` | 既有方法 | 分页方式改变 |

## 二、影响面

### 工具给出的结果

5 个锚点、10 处命中，**全部 L1**，零 L2、零 L3。

| 位置 | 内容 |
|---|---|
| `admin/.../CardApplicationApproverController.java:82,92` | `resolveEligibleUserIds` 调用与定义 |
| `admin/.../CardApplicationApproverController.java:93,94,129` | `splitCsv` 两处调用与定义 |
| `modules/demo/.../CardServiceImpl.java:606,614` | `filterDuplicateReceiveLogs` 调用与定义 |
| 同上 `:623,643` | `isReceiveConfirmationLog` |
| 同上 `:632,638` | `isReceiveLog` |

全部是新增私有方法，编译期闭环。**工具在 Java 侧没有发现任何需要牵连修改的地方**——这个结论是对的。

### 人工补扫出来的（工具看不见）

| 级别 | 位置 | 影响 | 证据 |
|---|---|---|---|
| **P1** | `CardServiceImpl.java:593-608` | 分页从数据库下沉到内存：`selectVoPage` → `selectVoList` + `TableDataInfo.build(list, page)`，该卡全部日志一次性载入 | `operationLogMapper.selectVoList(lqw)` |
| **P1** | 同上 `:594` | `backfillOperationLogsFromBorrowRecords(cardId)` 每次调用都执行，且内部会 `insertOperationLog`。翻页 N 次 = 回填 N 次 + 全量查询 N 次 | 方法体内有 `insertOperationLog(...)` |
| **P1** | `CardServiceImpl.java:618-626` | 去重按 `opAt` **毫秒值相等**配对：时间差 1ms 就漏去重；同一毫秒内多条领用会被一起删 | `confirmedAt.add(log.getOpAt().getTime())` |
| **P1** | `CardServiceImpl.java:638-650` | 判定依赖中文文案：`opName.endsWith("领用")`、`contains("签收领卡")`。文案一改，过滤静默失效 | 见第三节 |
| **P1** | `CardApplicationApproverController.java:99-101` | `roleId` 非空时，`roleNames`/`roleKeys` 被**静默忽略**；而前端三个都传 | `if (roleId != null) { ... } else { ... }` |
| **P2** | `CardServiceImpl.java:603-604` | `total` 语义变化：从 SQL count（含被滤掉的重复领用）变为过滤后条数。前端日志抽屉直接用它分页 | `TableDataInfo.build(pageList, list.size())` |
| **P2** | `CardServiceImpl.java:603` | 新增 `orderByDesc(getId)` 兜底：同一 `opAt` 的顺序从"不确定"变为按 id 倒序 | — |

### 跨仓库契约（工具完全看不到，人工确认无问题）

- 接口新增参数：`roleId`、`roleNames`、`roleKeys`
- 前端仓库 `src/views/workflow/task/component/UserSelectModal.vue:118-126` **已经传了这三个参数**（`roleNames.join(',')`）
- 结论：契约同步，不构成风险。**但这是另一个 git 仓库，工具扫不到**

## 三、P1 详述

**1) 分页下沉到内存**

```java
List<CardOperationLogVo> visibleLogs = filterDuplicateReceiveLogs(
    operationLogMapper.selectVoList(lqw)      // 全量
);
TableDataInfo.build(visibleLogs, pageQuery.build())
```

`build(List, IPage)` 的实现是 `CollUtil.page(current-1, size, list)` 再取 `list.size()` 作 total。查询条件有 `eq(cardId)` 兜底，单卡日志通常几十到几百条，可以接受。真正的放大点在于 `backfillOperationLogsFromBorrowRecords`：每次翻页都会先做一次回填写入。

**2) 去重的时间戳匹配**

```java
if (isReceiveConfirmationLog(log) && log.getOpAt() != null) {
    confirmedAt.add(log.getOpAt().getTime());
}
...
.filter(log -> !(isReceiveLog(log) && confirmedAt.contains(log.getOpAt().getTime())))
```

只按毫秒时间戳配对，没有用业务主键。若领用与签收相差 1 毫秒，重复不会被去掉；若同一毫秒有两条不同的领用，会被一起删掉。

**3) 中文文案依赖**

`opName` 由文案拼接产生，已确认一处写入点：

```java
case "RECEIVE" -> StringUtils.defaultIfBlank(operatorName, "未知用户") + "领用";   // 1257 行
```

`endsWith("领用")` 因此成立。但 `contains("签收领卡")` 在本仓库**找不到对应的写入点**——要么签收日志由别的模块或外部系统写入，要么这是个永远不会命中的防御分支。这一点需要确认。

## 四、回归清单

| # | 操作 | 预期结果 | 覆盖 | 类型 |
|---|---|---|---|---|
| 1 | 取一张日志超过 10 条（>1 页）的卡，打开日志抽屉 | 总数 = 过滤后的条数；第 2 页显示第 11–20 条 | P2 | 手工 |
| 2 | 找一张同时有"领用"与"签收"日志的卡 | 只显示签收那条 | 修复目标 | 手工 |
| 3 | 构造领用与签收时间戳相差 1ms 的数据 | 两条都显示（**已知不完整**，记录在案） | P1 | 手工 |
| 4 | 构造同一毫秒有两条不同领用的数据 | 校验是否被误删 | P1 | 手工 |
| 5 | 审批人选择器：只选角色名（不选 roleId） | 按角色名过滤，返回该角色下的用户 | P1 | 手工 |
| 6 | 审批人选择器：同时传入 roleId 与 roleNames | 校验实际只按 roleId 过滤，是否符合产品预期 | P1 | 手工 |
| 7 | 角色名含逗号的租户数据 | 校验 `splitCsv` 是否拆错 | P1 | 手工 |
| 8 | 打开任意一张卡的历史日志（旧数据） | 过滤规则不误伤、不报错 | P1 | 手工 |

**无自动化测试可用**：工具明确报告"未找到相关测试文件"，该模块没有对应用例（全仓库只有 4 个 `*Test.java`）。以上 8 条全部需要手工执行。

## 五、回滚点

- 代码：单 commit，`git revert` 即可；无 schema 变更
- 数据：改动只涉及查询与新增参数，不写入新数据；`backfillOperationLogsFromBorrowRecords` 是既有逻辑，回滚不影响已回填的数据
- 前端：无需回滚（新增参数为可选，旧后端会忽略未知参数）

## 六、未验证项

| 项 | 原因 | 验证方式 |
|---|---|---|
| 线上 `opAt` 是否会出现同毫秒的领用+签收 | 无数据权限 | 按 card_id + 秒分组统计 `card_operation_log` |
| `contains("签收领卡")` 是否有真实写入点 | 本仓库只找到过滤侧 | 全库搜该文案，并问签收流程负责人 |
| 是否还有其他消费方调用该接口 | 只查了前端仓库 | 网关访问日志 |
| 单卡日志量的分布 | 无数据权限 | 统计 `count(*) group by card_id` 的分位数 |

## 七、工具表现评估

**对这次改动，工具的边际价值接近于零。**

- 它找到的 10 处命中，`grep -n` 同样能找到，因为都是新增的、唯一的私有方法名
- 它正确地显示了"没有相关测试文件"——这条有用，但一条 grep 也能得出
- 真正会出事的地方（分页语义、时间戳配对、中文文案、roleId 优先级），**静态扫描完全无感**

**这个结果本身是有价值的**：它说明工具擅长的是"改名字 / 改表 / 改配置"这类**跨命名空间**的变更（见 [case-study](../case-study/CASE-STUDY.md)），而"新增私有方法"型的改动，它给的是一张差不多空的图——这时候报告应该老实说"没有牵连"，而不是硬凑。

**耗时**：工具扫描 15 秒（885 个文件）；人工补扫与判定约 25 分钟。
