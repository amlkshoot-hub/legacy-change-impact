# legacy-change-impact

> 改老代码之前，先摸清会炸到哪。

A skill for AI coding agents: before you modify legacy code, map every reference — including the ones the compiler cannot see — and produce a graded impact report with a regression checklist and rollback points.

---

## 问题

在老项目里把一个字段名改掉，编译照样通过，测试也绿，然后线上静默出错。

因为真正的引用不在 import 里，而在这些地方：

- `@TableName("user_profile")` 这种字符串映射
- MyBatis XML 里手写的 `FROM user_profile`
- 配置文件的 key、`*.properties`、`*.yml`
- 已经执行过的迁移脚本
- 定时任务名、消息 topic、缓存 key
- 前端硬编码的接口路径

模型默认的行为是 grep 一下符号名就停手，正好漏掉全部这些。这个技能就是补这个洞。

## 它做什么

五步流程，产出三样东西：

1. **拆锚点** —— 把"我要改什么"拆成 3~8 个可搜索的符号
2. **三层扫描** —— 见下表，脚本负责找得到
3. **补扫隐式引用** —— 反射、DI、ORM 约定、序列化、调度，脚本扫不到的部分
4. **定级** —— P0 静默出错 / P1 运行才崩 / P2 编译即红 / P3 无影响
5. **产出** —— 影响面表（带 `file:line` 证据）+ 可执行回归清单 + 回滚点

| 层 | 内容 | 出错时机 |
|---|---|---|
| **L1** | 普通代码里的引用 | 编译或启动直接报错，风险最低 |
| **L2** | 字符串内引用、同源命名 | 不报错，**静默出错** |
| **L3** | sql / yml / xml 等数据契约 | 改完不可回滚，坏在别人那边 |

事故几乎全部落在 L2 和 L3。所以分析的时间花在这两层，不是花在找 import 上。

## 快速开始

需要 PowerShell 5.1 或 7（Windows 自带），git 可选。

```powershell
git clone https://github.com/amlkshoot-hub/legacy-change-impact.git
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

所以给一个 Java 类名，就能同时带出数据库表名、迁移脚本和 MyBatis XML 里的引用——这正是手工 grep 最容易漏掉的一层。

### 只知道改了什么文件？

那就别猜符号，直接让脚本从 git diff 里提取：

```powershell
.\scripts\scan-refs.ps1 -Root D:\code\your-project -Diff HEAD~1   # 某个提交范围
.\scripts\scan-refs.ps1 -Root D:\code\your-project -Diff working  # 当前未提交的改动
.\scripts\scan-refs.ps1 -Root D:\code\your-project -Diff staged   # 已暂存
```

它会从 diff 里提取被改动的类名、函数名、方法名、表名、注解字符串和配置键，最多 12 个，然后按同一套三层规则扫描。适合"拉了个分支改了几个方法，想知道影响了谁"。

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
  L3 数据/配置契约（改了不可回滚，重点看）
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

完整样例见 [`examples/sample-output.txt`](examples/sample-output.txt)。

报告模板见 [`references/report-template.md`](references/report-template.md)。

## 设计原则

| 原则 | 具体做法 |
|---|---|
| 要证据 | 每条结论必须带 `file:line`，没有证据的不进报告 |
| 不猜 | 判断不了就标"未验证"并给验证步骤，不写"可能""大概" |
| 只分析 | 不改代码、不重构、不擅自跑测试，用户没问就不提 |
| 不说废话 | 回归清单必须能执行，"测试相关功能正常"这种一律不收 |
| 承认边界 | 命中被截断、目录没覆盖，必须写进报告的未验证项 |

## 已知限制

- 大仓库（>2 万文件）建议按模块子目录分段扫
- `-Git` 的 `git log -S` 在大仓库上很慢
- L2 的"同源命名"默认上限 200 条，超出会截断并在输出里标 `⚠ 有层级截断`
- 变体只覆盖常规命名（camel / snake / kebab / 常量 / 连写）。拼音、缩写（`user` → `usr`）、历史遗留的错拼不会自动派生，需要手工补第二个符号
- `-Diff` 靠正则识别"定义行"，提取不到时会退化为 0 个锚点（此时脚本会报错而不是静默扫空）
- 只做静态分析：反射、运行时拼装的表名、跨仓库契约需要人工补
- 脚本是 PowerShell，Linux/macOS 上需要 pwsh

## 更新记录

- **v0.2** — 命名变体自动派生（一个符号覆盖 6 种写法）；`-Diff` 从 git diff 提取锚点；输出"建议执行的回归"（真实存在的测试文件 + 可执行命令）
- **v0.1** — 初版：三层扫描、P0-P3 定级、报告模板、可运行的 demo-repo

## 兼容性

- Windows PowerShell 5.1 和 PowerShell 7 均已实测（脚本带 BOM，避免 5.1 读中文注释出错）
- 实测样本：1183 个文件的 Spring Boot + Vue 项目，单符号 2.5 秒，`-Git` 约 27 秒

## License

[MIT](LICENSE)
