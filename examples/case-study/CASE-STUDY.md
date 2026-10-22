# 案例：把一个字段改名，两种搜法差在哪

这是一个可复现的对照实验。目标改动：把已上线的 `applicant_name` 改名为 `applicant_full_name`（表列、实体、对外 JSON 字段一起改）。这类"看起来很小"的改动，是影响面分析最典型的场景。

- 样例工程：[`repo/`](repo/)（14 个文件，Spring Boot + MyBatis + Vue + 迁移脚本）
- 场景抽象自一个真实的 Spring Boot + MyBatis + Vue 项目，标识符已替换，陷阱结构保持原样
- 全部数字都是在这个目录上实测得到的，命令见文末

## 方法

1. **普通搜索**：`grep -rn "applicant_name"`，大小写敏感 —— 和多数人改名前做的第一件事一样
2. **工具**：`.\scripts\scan-refs.ps1 -Root examples/case-study/repo -Symbol applicant_name`
3. **人工判定**：逐条标记为"必须同步 / 建议同步 / 误报"

## 结果对比

| | 普通 grep | 本工具 |
|---|---:|---:|
| 命中行 | 11 | 33 |
| 涉及文件 | 7 | 12 |
| camelCase 形态的命中 | 0 | 23 |

**差距几乎全部来自命名风格。** 工具把 `applicant_name` 派生成了 6 种写法，其中 `applicantName` 一种就贡献了 23 处命中；而 grep 的字面量是 snake_case，对 Java / TypeScript / Vue 里的驼峰写法一无所知。

## grep 看得见、但只是冰山一角的那些

```
Order.java:14              @TableField("applicant_name")          ← 列映射
OrderMapper.xml:8          applicant_name AS applicantName        ← 查询列 + 别名
OrderMapper.xml:10         WHERE applicant_name LIKE ...          ← 查询条件
V12__order_applicant.sql:2 ADD COLUMN applicant_name              ← 已执行的迁移
```

这四处是最容易被想到的，也是 grep 一定能命中的。

## 工具多找出来的（grep 全部漏掉）

| 位置 | 内容 | 为什么危险 |
|---|---|---|
| `OrderVo.java:12` | `@JsonProperty("applicantName")` | 对外 JSON 契约，改名即破坏前端 |
| `OrderMapper.java:11` | `@Param("applicantName") String applicantName` | MyBatis 参数名与 XML `#{applicantName}` 隐式绑定，改名不报错但查不出数据 |
| `Order.java:15,19,21` | 字段与 getter/setter | 与 `@TableField` 靠注解关联，没有编译期约束 |
| `index.vue:12` | `dataIndex: 'applicantName'` | 前端表格列 key，后端改名后这一列静默变空 |
| `order.ts:5,8,9` | interface 字段、函数参数、请求参数 | 前后端契约靠人手对齐 |
| `application.yml:2` | `applicant-name:` 配置键 | kebab 形态，grep 搜 snake 一样搜不到 |

## 人工确认结果

33 条命中，逐条判断后：

| 判定 | 数量 | 说明 |
|---|---:|---|
| 必须同步 | 29 | 改了不同步就会坏（编译错、静默空值、契约破坏） |
| 建议同步 | 3 | 注释、javadoc、测试方法名，不改不报错但会误导后来人 |
| 误报 | 1 | 见下 |

有代表性的判定：

| 命中 | 判定 | 理由 |
|---|---|---|
| `Order.java:14` `@TableField("applicant_name")` | 必须 | 实体与列的绑定，改名后写入静默失败 |
| `OrderMapper.java:11` `@Param("applicantName")` | 必须 | XML 里 `#{applicantName}` 靠名字匹配，编译不报错 |
| `OrderVo.java:12` `@JsonProperty` | 必须 | 对外字段名，属于跨端契约 |
| `index.vue:12` `dataIndex` | 必须 | 不改则整列空白，且不抛异常 |
| `V12__order_applicant.sql:2` | 必须 | 但不能改这个文件——迁移已执行，要新增一版迁移 |
| `application.yml:2` `applicant-name` | 建议 | 与字段同源的配置键，语义上应一起改 |
| `OrderService.java:21` 注释 | 建议 | 不是引用，但会误导 |
| `rollback_2025.sql:2` `old_applicant_name` | **误报** | 是另一个历史表的另一个字段，只是包含子串 |

## 误报

1. **跨字段的子串命中**：`old_applicant_name`（`legacy/db/rollback_2025.sql:2`）。工具按"同源命名"报为 L3，实际是历史表的另一个字段。
   这是**可接受误报**：多给一条让人确认，比漏掉强；但报告里必须标清楚"这条要人工判断"。
2. **注释与 javadoc 被当成代码引用**：`OrderService.java:21`、`OrderVo.java:6` 落在 L1。工具不做注释剔除，只按语法位置粗分。两条，占比不高。

## 漏报（这部分比命中数更重要）

| 漏报 | 原因 | 影响 |
|---|---|---|
| `docs/api.md` 里 2 处 `applicant_name` | `.md` 不在扫描扩展名内 | grep 找得到、工具找不到。文档是给人看的，漏了不会立刻出事 |
| `DynamicColumnBuilder` 的 `COL_PREFIX + "_name"` | 列名运行时拼接，没有完整字面量 | **两种方法都找不到**，属于静态分析的原理性盲区 |
| 数据库里已执行的 DDL / 视图 / 存储过程 | 不在仓库里 | 工具只能提示"这个迁移不能改"，看不到库内依赖 |
| 另一个仓库里的引用 | 前端若是独立 repo，只扫后端就看不到 | 本次把前端放在同一目录才扫到 |
| L2 同源命名超过 200 条 | 输出截断，会标 `⚠ 有层级截断` | 本次未触发（同源命名远少于 200） |

## 这个案例能说明什么，不能说明什么

**能说明的**：在"改字段名"这类变更里，跨命名风格的引用是主要盲区；把变体一起扫，能把 23 处 camelCase 引用从"想不到"变成"列在眼前"。

**不能说明的**：

- 不能推出"工具比 grep 好 N 倍"这种结论。样本只有一个，且是刻意构造的
- 没有证据表明它能降低线上事故率。这只做过单项目验证，没有对照组
- 33 条命中仍然需要人来判断，工具只负责把范围收窄

**它的定位**：把"该看哪里"从无限搜索压缩成一张带行号的清单。判断、取舍、以及决定哪些可以不改，仍然是人来做。

## 复现

```powershell
# 1. 普通搜索
Get-ChildItem examples/case-study/repo -Recurse -File |
  Select-String -Pattern 'applicant_name' -CaseSensitive

# 2. 工具
.\scripts\scan-refs.ps1 -Root examples/case-study/repo -Symbol applicant_name

# 3. 只看统计
.\scripts\scan-refs.ps1 -Root examples/case-study/repo -Symbol applicant_name -Json |
  ConvertFrom-Json | ForEach-Object { $_.results[0].count }
```

预期：grep 11 行 / 7 文件；工具 33 处（L1=15, L2=12, L3=6）/ 12 文件。
