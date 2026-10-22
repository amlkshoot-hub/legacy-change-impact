# 三层引用扫描清单

脚本能覆盖约六成命中。下面三层是补扫清单，按语言挑相关的条目，不要全跑一遍。

## L1 静态可见（编译器/解释器直接报错）

| 语言 | 要找的东西 |
|---|---|
| Python | `from x import y`、`y(...)`、`isinstance`、类型注解、`__all__` |
| TypeScript/JS | import/export、类型引用、interface 扩展、装饰器 |
| Java/Kotlin | import、方法调用、实现类、注解处理器 |
| Go | 包内引用、interface 实现（隐式）、struct 字段 |
| C# | using、接口实现、特性（Attribute） |

L1 风险最低但量最大。报告里合并成"直接调用点 N 处（file:line 列表）"，不要逐条展开。

## L2 隐式引用（真正的事故来源）

逐项核对，命中的写进报告：

### 反射与动态派发
- `getattr(obj, "name")` / `obj["name"]` / `$obj->{...}`
- DI 容器注册表：字符串 key → 类名
- 装饰器/注解按字符串注册路由或任务
- 事件总线：`emit("event.name")`、`on("...")`
- 序列化：`pickle`、`json.loads` 后按 key 取值、`__getattr__`

### 配置与路由表
- `*.yml` / `*.yaml` / `*.json` / `*.toml` / `*.properties` / `*.ini` / `.env*`
- 路由集中注册文件：`urls.py`、`routes.*`、`router.*`、`app.use(...)`
- 权限/菜单配置里写死的接口路径
- Nginx/网关/反代配置里的 upstream 与 path rewrite

### ORM 与数据库约定
- 模型字段名默认映射到列名（Django/TypeORM/SQLAlchemy 都默认这样做）
- `db_column`、`@Column({name: ...})`、`$table->`、`gorm:"column:..."`
- 迁移文件里已经存在的列名与索引名
- 外键、级联删除、唯一约束名
- 视图、存储过程、触发器里引用的表名

### 前端与跨端硬编码
- fetch/axios 的 URL 字面量、API 前缀常量
- i18n key、路由 path、埋点事件名与参数名
- 移动端/小程序的页面路径注册表
- 类型定义与后端 DTO 的手工同步（没有 codegen 时）

### 异步与调度
- cron 表达式、`@scheduled`、`celery beat` 配置
- 队列名、Kafka topic、RocketMQ tag
- 重试策略、死信队列名

### 缓存与状态
- 缓存 key 模板（`user:{id}` 这类）
- 版本号、幂等键、分布式锁 key
- 会话/Token 里的字段名

### 测试资产
- fixture / factory / seed 数据里的字段
- snapshot / golden 文件（改了字段名不改快照 = 下次必红）
- 契约测试与 mock 数据

## L3 数据与外部契约（改了不可回滚的部分）

- 数据表已有数据的兼容性：加非空列、改类型、收敛枚举值
- 已落库的历史 payload（消息积压、日志、审计表）
- 对外 API 响应字段（第三方在消费，删除即破坏契约）
- 文件格式、导出模板、报表列
- 监控告警规则里引用的指标名/日志关键字
- 文档与 SDK 里的对外名称

L3 的共同特征：**改完自己的代码全绿，坏在别人那边。** 有对外契约时，报告里必须单列一节说明影响谁。

## 快速判据

拿不准某处算哪层时，问一个问题：**如果这里改了而没同步改，会在什么时候以什么形式暴露？**

- 编译/启动就红 → L1
- 跑到某个分支才崩 → L2
- 永远不报错，但数据或结果悄悄变了 → L2/L3，按 P0 处理
