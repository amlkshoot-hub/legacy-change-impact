# legacy-change-impact

> 改老代码之前，先摸清会炸到哪。

[![verify](https://github.com/amlkshoot-hub/legacy-change-impact/actions/workflows/verify.yml/badge.svg)](https://github.com/amlkshoot-hub/legacy-change-impact/actions/workflows/verify.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A skill for AI coding agents: before modifying legacy code, map the references a plain symbol search tends to miss — string mappings, config keys, migrations, cross-language naming — then produce a graded impact report with a regression checklist.

当前版本 **v1.0.0**（[更新记录](CHANGELOG.md)）

---

## 问题

在老项目里把一个字段名改掉，编译照样通过，测试也绿，然后线上静默出错。

原因往往不在 import 里，而在这些地方：

- `@TableName("user_profile")` 这种字符串映射
- MyBatis XML 里手写的 `FROM user_profile`
- 配置文件的 key、`*.properties`、`*.yml`
- 已经执行过的迁移脚本
- 定时任务名、消息 topic、缓存 key
- 前端硬编码的接口路径、表格列 key

很多人在动手前会先搜一次符号名——这是我在若干真实项目里反复看到的模式，不是严格统计。问题不在于搜得不认真，而在于**搜的字面量和代码里的写法往往不是同一种**：你搜 `applicant_name`，而 Java、TypeScript、Vue 里写的是 `applicantName`。

这个技能就是补这个缺口：把常见的命名变体一起扫，再按"改了会不会报错"分层呈现。

## 一个可复现的案例

[`examples/case-study/`](examples/case-study/CASE-STUDY.md) 里有一个 14 个文件的 Spring Boot + MyBatis + Vue 样例，演示把 `applicant_name` 改名会发生什么。实测结果：

| | 普通 `grep -rn "applicant_name"` | 本工具 |
|---|---:|---:|
| 命中 | 11 行 / 7 文件 | 33 处 / 12 文件 |
| 其中 camelCase 形态 | 0 | 23 |

人工逐条判定后：**29 处必须同步、3 处建议同步、1 处误报**，另有 **5 类漏报**被明确记录（文档、运行时拼接、库内对象、跨仓库引用、输出截断）。

案例文档把误报和漏报都列了出来，也写清了"这个案例能说明什么、不能说明什么"：[CASE-STUDY.md](examples/case-study/CASE-STUDY.md)

## 它做什么

五步流程，产出三样东西：

1. **拆锚点** —— 把"我要改什么"拆成 3~8 个可搜索的符号（或从 git diff 自动提取）
2. **三层扫描** —— 见下表，脚本负责"找得到"
3. **补扫隐式引用** —— 反射、DI、ORM 约定、序列化、调度，脚本扫不到的部分
4. **定级** —— P0 静默出错 / P1 运行才崩 / P2 编译即红 / P3 无影响
5. **产出** —— 影响面表（带 `file:line` 证据）+ 可执行回归清单 + 回滚点

| 层 | 内容 | 改了通常怎样 |
|---|---|---|
| **L1** | 普通代码里的引用 | 多数在编译或启动时就报错 |
| **L2** | 字符串内引用、同源命名 | 常不报错，**静默出错** |
| **L3** | sql / yml / xml 等数据契约 | 回滚成本通常更高；问题常落在别的系统或历史数据上 |

在案例里被漏掉的引用集中在 L2/L3。这只说明这两层**更容易被漏**，不构成比例结论，也不代表 L1 不会出事。

## 快速开始

需要 PowerShell 5.1 或 7（Windows 自带），git 可选。

```powershell
# 固定版本（推荐，行为可预期）
git clone --branch v1.0.0 https://github.com/amlkshoot-hub/legacy-change-impact.git
cd legacy-change-impact

.\scripts\scan-refs.ps1 -Root .\examples\demo-repo -Symbol user_profile,nick_name
```

不用准备真实项目，`examples/demo-repo` 里埋了常见的坑，直接能看到效果。输出样例见 [`examples/sample-output.txt`](examples/sample-output.txt)。

用你自己的仓库：

```powershell
.\scripts\scan-refs.ps1 -Root D:\code\your-legacy-project -Symbol 旧函数名,表名
```

**符号只写一个就够。** 脚本会自动派生命名变体：

| 输入 | 自动一起扫 |
|---|---|
| `WlwCardApplication` | `wlw_card_application`、`wlw-card-application`、`WLW_CARD_APPLICATION`、`wlwCardApplication`、`wlwcardapplication` |

于是给一个 Java 类名，往往能带出表名、迁移脚本和 MyBatis XML 里的引用——在案例里，这一步把 23 处 grep 看不见的驼峰引用翻了出来。

### 只知道改了什么文件？

那就别猜符号，直接让脚本从 git diff 里提取：

```powershell
.\scripts\scan-refs.ps1 -Root D:\code\your-project -Diff HEAD~1   # 某个提交范围
.\scripts\scan-refs.ps1 -Root D:\code\your-project -Diff working  # 当前未提交的改动
.\scripts\scan-refs.ps1 -Root D:\code\your-project -Diff staged   # 已暂存
```

它会从 diff 里提取被改动的类名、函数名、方法名、表名、注解字符串和配置键（最多 12 个，只从可扫描的文件类型里取），再按同一套三层规则扫描。适合"拉了个分支改了几个方法，想知道影响了谁"。

### 该跑哪些测试

扫描结束会输出一段"建议执行的回归"：命中里出现的测试文件、按命名约定推测且**真实存在**的测试类，以及可直接执行的命令：

```
建议命令: mvn -q -Dtest=OrderServiceTest test
```

想连历史改动一起看（哪个文件被反复改，风险更高）：

```powershell
.\scripts\scan-refs.ps1 -Root D:\code\your-project -Symbol 表名 -Git
```

`-Git` 会遍历提交历史，大仓库要跑几分钟，建议先出底稿再补。

## 安装成技能

把这个目录放进你使用的 AI 助手的技能目录即可，格式是标准的 `SKILL.md`：

| 环境 | 位置 |
|---|---|
| Claude Code | `~/.claude/skills/legacy-change-impact/` |
| 其他支持 SKILL.md 的助手 | 各自的技能目录 |
| 临时使用 | 直接告诉助手 `SKILL.md` 的路径 |

## 产出长什么样

```
[user_profile]  命中 13 处   L3=2  L2=8  L1=3
  L3 数据/配置契约（回滚成本高，重点看）
    migrations\0007_profile.sql:1
      ALTER TABLE user_profile ADD COLUMN nick_name VARCHAR(64);
  L2 字符串内引用（不报错，静默出错）
    app\models.py:2 [str]
      __tablename__ = "user_profile"
  L1 静态引用（编译器会报）
    app\models.py:1 [var:UserProfile]
      class UserProfile:
```

注意最后一行：只输入了 `user_profile`，脚本通过变体也命中了 `UserProfile` 类。

完整样例见 [`examples/sample-output.txt`](examples/sample-output.txt)，报告模板见 [`references/report-template.md`](references/report-template.md)。

## 自动化验证

```powershell
pwsh -File .\tests\run-tests.ps1
```

9 项断言，覆盖：SKILL.md 元数据、变体派生与大小写去重、camelCase 命中、三层分类、测试文件存在性、diff 文件类型过滤、CRLF 行尾、JSON 结构、失败退出码。

CI 在 Windows 上分别用 **pwsh 7** 和 **Windows PowerShell 5.1** 各跑一遍（[verify.yml](.github/workflows/verify.yml)）。

## 设计原则

| 原则 | 具体做法 |
|---|---|
| 要证据 | 每条结论必须带 `file:line`，没有证据的不进报告 |
| 不猜 | 判断不了就标"未验证"并给验证步骤，不写"可能""大概" |
| 只分析 | 不改代码、不重构、不擅自跑测试，用户没问就不提 |
| 不说废话 | 回归清单必须能执行，"测试相关功能正常"这种一律不收 |
| 承认边界 | 命中被截断、目录没覆盖，必须写进报告的未验证项 |

## 边界：它不声称什么

- **不替代测试。** 它只把"该看哪里"缩小，不验证行为是否正确
- **不覆盖运行时拼装的表名/列名**（如 `"applicant_" + suffix`）、数据库内的视图和存储过程、以及另一个仓库里的引用
- **不保证降低事故率。** 只有单项目验证，没有对照实验，也没有统计样本
- **不判断代码质量**，不建议重构。用户没问就不提
- 命中需要人工确认。案例里 33 条命中就有 1 条误报、3 条只是"建议同步"

## 已知限制

- 大仓库（>2 万文件）建议按模块子目录分段扫
- `-Git` 的 `git log -S` 在大仓库上很慢
- L2 的"同源命名"默认上限 200 条，超出会截断并在输出里标 `⚠ 有层级截断`
- 变体只覆盖常规命名（camel / snake / kebab / 常量 / 连写）。拼音、缩写（`user` → `usr`）、历史遗留的错拼不会自动派生，需要手工补第二个符号
- `-Diff` 靠正则识别"定义行"：包级私有方法、lambda、部分动态语言写法可能提取不到；提取为 0 个锚点时会报错而不是静默扫空
- `.md` 不在扫描扩展名内。文档里的引用会漏（案例中有 2 处）
- 只做静态分析：反射、动态 SQL、跨仓库契约需要人工补
- 脚本是 PowerShell，Linux/macOS 上需要 pwsh

## 兼容性

- Windows PowerShell 5.1 和 PowerShell 7 均已实测，并各有 CI 覆盖
- 脚本带 BOM，避免 5.1 把中文注释按 ANSI 解析
- 实测样本：1183 个文件的 Spring Boot + Vue 项目，单符号约 2.5 秒，`-Git` 约 27 秒

## 更新记录

见 [CHANGELOG.md](CHANGELOG.md)。

## License

[MIT](LICENSE)
