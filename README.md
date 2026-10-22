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
git clone https://github.com/amlikshoot/legacy-change-impact.git
cd legacy-change-impact

.\scripts\scan-refs.ps1 -Root .\examples\demo-repo `
  -Symbol get_user_profile,user_profile,profile_cache_ttl,nick_name
```

不用准备真实项目，`examples/demo-repo` 里埋了常见的坑，直接能看到效果。输出样例见 [`examples/sample-output.txt`](examples/sample-output.txt)。

用你自己的仓库：

```powershell
.\scripts\scan-refs.ps1 -Root D:\code\your-legacy-project -Symbol 旧函数名,表名,config.key
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
[user_profile]  命中 10 处   L3=2  L2=8  L1=0
  L3 数据/配置契约（改了不可回滚，重点看）
    migrations\0007_profile.sql:1
      ALTER TABLE user_profile ADD COLUMN nick_name VARCHAR(64);
  L2 字符串内引用（不报错，静默出错）
    app\models.py:2 [str]
      __tablename__ = "user_profile"
  L2 同源命名（可能同源，逐个确认是否要跟着改）
    app\tasks.py:4 [str]
      @shared_task(name="sync_user_profile")
```

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
- 只做静态分析：反射、运行时拼装的表名、跨仓库契约需要人工补
- 脚本是 PowerShell，Linux/macOS 上需要 pwsh

## 兼容性

- Windows PowerShell 5.1 和 PowerShell 7 均已实测（脚本带 BOM，避免 5.1 读中文注释出错）
- 实测样本：1183 个文件的 Spring Boot + Vue 项目，单符号 2.5 秒，`-Git` 约 27 秒

## License

[MIT](LICENSE)
