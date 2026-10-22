# 影响面分析报告模板

输出用中文，直接给结论，不铺垫。三个小节缺一不可。

---

## 变更锚点

| # | 符号 | 类型 | 说明 |
|---|---|---|---|
| 1 | `get_user_profile` | 函数 | 待改名为 `fetch_user_profile` |
| 2 | `user_profile` | 表 | 增列 `last_login_at` |
| 3 | `profile_cache_ttl` | 配置 | 单位由天改为秒 |

## 影响面

| 级别 | 位置 | 引用形式 | 影响 | 证据 |
|---|---|---|---|---|
| P0 | `migrations/0007_user.sql:12` | 列名 `nick_name` | 模型字段改名后列名不匹配，写入静默失败 | `ALTER TABLE user_profile ADD COLUMN nick_name` |
| P0 | `config/settings.yml:31` | 配置 key | 代码读 `profile_cache_ttl`，配置已改名为 `cache.profile.ttl` | — |
| P1 | `app/api/routes.py:44` | 字符串路由 | 反射注册，启动不报错，请求 404 | `add_route("/api/v1/users/profile", "get_user_profile")` |
| P2 | `app/services/order.py:88` | 直接调用 | 编译期报错 | `get_user_profile(uid)` |

> 约定：`file:line` 是硬要求，任何一行没有证据就不要写进表里。判断不了的在"影响"列写"未验证"并单列待人工确认项。

## P0 专项说明

P0 每条都要单独解释"为什么它不会报错"，一句话即可。这段是给评审人看的，也是这个报告的价值所在。

## 回归清单

| # | 操作 | 预期结果 | 覆盖 | 类型 |
|---|---|---|---|---|
| 1 | 调用 `GET /api/v1/users/profile?uid=1` | 返回 200，字段 `nick_name` 有值 | P1 | 自动 |
| 2 | 老用户（`nick_name` 为空）登录 | 不抛异常，`nick_name` 返回 `null` | P0 | 自动 |
| 3 | 改配置后重启，观察缓存命中 | 首次回源，二次命中，TTL 为设定秒数 | P0 | 手工 |
| 4 | 跑一遍定时任务 `sync_profile` | 日志中无 `KeyError` | P1 | 手工 |

> 规则：先把脚本输出里"建议执行的回归"中的真实测试文件和命令抄进来（那是确定存在的），再补手工用例。操作要能直接执行，预期要能判断真假。覆盖列必须标注对应 P 级；"测试相关功能"这种条目一律不写。脚本说"未找到相关测试文件"时，这本身就是一条未验证项。

## 回滚点

- 代码：单 commit 可回退，无 schema 变更时直接 revert
- 数据：本次含 `ALTER TABLE`，回滚需执行 `0007_user.down.sql`；回滚前确认新列无写入
- 配置：`config/settings.yml` 保留旧 key 一个发布周期，双写兼容
- 观察窗口：发布后 30 分钟内看 5xx 率与 `profile` 相关错误日志

## 未验证项

| 项 | 原因 | 验证方式 |
|---|---|---|
| 第三方是否消费 `profile` 字段 | 无契约文件 | 查网关访问日志中该字段的调用方 |
