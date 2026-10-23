# 更新记录

版本号从 v1.0.0 起开始打 git tag。更早的两次提交没有打 tag，按时间补记在此。

## v1.0.1 — 2026-10-23

跨平台修复。此前 README 声称"Linux/macOS 需要 pwsh"，但代码里有多处硬编码反斜杠，实际只在 Windows 验证过。

**修复**

- 扫描器：测试文件推断内部统一用 `/` 计算，输出时转平台分隔符。去掉 `src\test\java`、`__tests__\`、`-replace '/', '\'` 等 6 处字面量
- 测试脚本：路径一律按段拼接，断言改为分隔符无关比较
- 测试脚本：`pwsh.exe` / `powershell.exe` 按平台与版本选择，不再写死于 Windows

**新增**

- CI 增加 `ubuntu-latest` job，与两个 Windows job 并列

**验证**

- 三个 job 首次运行全部通过，Ubuntu 上 9 项断言无差异
## v1.0.0 — 2026-10-22

首个正式版本：功能范围与验证范围明确，行为可预期，适合试用。

**新增**

- 可复现案例 [`examples/case-study/`](examples/case-study/CASE-STUDY.md)：14 个文件的 Spring Boot + MyBatis + Vue 样例，记录了普通 grep 与本工具的差异、人工判定结果、1 处误报和 5 类漏报
- 自动化验证 [`tests/run-tests.ps1`](tests/run-tests.ps1)：9 项断言，不依赖 Pester
- CI [`verify.yml`](.github/workflows/verify.yml)：在 Windows 上分别用 pwsh 7 与 Windows PowerShell 5.1 跑测试
- README 增加"边界：它不声称什么"一节

**修复**

- 测试文件推断：当 `src\main\java\...` 位于仓库根时，前导分隔符必需导致推断失败
- `-Diff` 提取：补充无访问修饰符的方法声明（`void foo(...) {` 这类）
- PowerShell 5.1：`Sort-Object -Stable` 在 5.1 不存在，导致 `-Diff` 直接崩溃
- 测试脚本在 5.1 下的两处兼容问题（`$PSScriptRoot` 在 param 默认值为空、原生命令 stderr 触发终止错误）

**表述调整**

- 输出标签从"改了不可回滚"改为"回滚成本高"
- README 与 SKILL.md 中若干绝对化表述（"模型默认就是 grep 一下就停手""事故几乎全部落在 L2/L3"）改为带限定的描述，并标注样本来源

## v0.2.0 — 2026-10-22（未打 tag）

- 命名变体自动派生：一个符号覆盖 camel / snake / kebab / 常量 / 连写 6 种写法
- 新增 `-Diff`：从 git diff 提取类名、函数名、表名、配置键作为锚点
- 新增"建议执行的回归"：真实存在的测试文件与可执行命令
- 修复 4 个缺陷：`return , $List` 导致属性枚举（测试文件全被误判为存在）、大小写不敏感哈希表吞掉变体、单仓库时 `$gitRoots` 标量拆包、diff 路径尾部 CR 导致扩展名匹配失败

## v0.1.0 — 2026-10-22（未打 tag）

- 初版：三层扫描（L1/L2/L3）、P0–P3 定级、报告模板、可运行的 `examples/demo-repo`
