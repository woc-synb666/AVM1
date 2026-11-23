# AVM1 重构记录

> 分支 `dev`，当前 `b18f432`。起点是上游 `7a4de7c`。
> 所有数字都是脚本实测或 pytest 输出，不是估计。

## 一分钟版本

**没改任何功能，只改结构。** 57 个提交做本地重构，之后同步了上游 7 个提交，
再修 3 个真 bug。每一次提交都过同样的三道验证：全量 pytest、装载指纹逐字节比对、
真启动一次控制台。

核心判断只有一句：**AVM 的问题不是函数太长，是模块之间摸对方私有字段摸得太狠。**
所以改造的主线是「收口耦合」，不是「把长函数切短」——虽然后来也切了。

---

## 一、为什么改：实测出来的三个真问题

不是靠读代码读出来的印象，是写了脚本扫的（`analyze_avm.py`、`coupling.py`）：

| 问题 | 起点实测值 |
|---|---|
| 跨模块访问别人私有字段 | **271 处**（`_conv_by_cid` 被 11 个模块读，调度三件套各被 9 个模块碰） |
| 模块级循环依赖 | **3 对**（`boot↔image`、`image↔journal`、`core↔journal`） |
| 超长函数 | >100 行 5 个，61–100 行 21 个，最长的 `load_image` 159 行 / 圈复杂度 64 |

循环依赖的代价是「没法单独理解任何一个模块」；私有字段被摸的代价是
「改 core 的一个字段名要去 11 个文件里找」。这两个才是真问题，长函数只是症状。

---

## 二、判定标准：什么该拆，什么别碰

这条比任何具体改法都重要。**拆之前先看这个方法碰的是公开接口还是私有字段。**

### 拆
- 只碰传进来的参数和公开接口 → 可以搬出去成独立协作者
- 一个类里混了多个不相干职责 → 按职责切
- 同一个契约被抄了两遍 → 收成一处

### 不拆（宁可留着）
- `_build_core_dump` 读 `_active_cid` / `_conv_by_cid` / `_instruction_budget`：
  搬出去只是把「类内直读」变成「跨对象摸私有」，**耦合变重**，不搬
- Core 的调度字段（`_ready_cids` 等）：被上百处测试和 `web/e2e/mock_console.py`
  直接读写，换独立对象要改整条测试链，不搬
- `run()` 里的空闲分支：夹着 `return` / `continue`，抽出去得发明哨兵值表达控制流，更难读
- `_validate_grants` vs `_validate_root_specs`：差异是**刻意的**（替换注册表时故意
  不比旧注册表，否则改名会被自己拦住），合并会把这份不对称藏起来
- `_check_device_table` 的手写遍历：故意**不跟链接**，换成 `resolve_path` 就查不出问题
- `events.dispatch` 的 before/after 两个循环：一个是 fail closed、一个是 fail open，
  策略相反，不能合并

### 手法上的取舍
**不新造 Scheduler / Memory 门面类，只在原类上补语义方法，类内部逻辑一字不动。**
理由：门面类会把「一处私有访问」变成「两次调用 + 一层转发」，diff 也变难读；
而补方法的方式每个提交都能逐行读，回滚成本也低。

---

## 三、四步推进

### 第一步：断环 + 对话表收口
- 3 对循环依赖全部消除 → **0 对**
- 关键发现：`core↔journal` 的环根因只是一个常量 —— `journal.py` 在函数内
  `from .core import PANEL_CID`。把 `PANEL_CID` 挪到契约层 `avm/types.py` 就断了
- `_conv_by_cid` 加 `conversations` property（`MappingProxyType` 只读视图）+
  `remove_conversation` / `clear_conversations`，**271 → 230**

### 第二步：调度三件套收口
`_ready_cids` / `_dormant_cids` / `_active_cid` 各被 9 个模块碰，而且带队列语义
（append / remove / 顺序），不能简单换成只读代理，只能补语义方法：
`sleep()` / `prioritize()` / `is_ready()` / `get_conversation()` / `is_finished()`。
**230 → 24**（剩余都是设备插件协议，要动得连 `packages/` 一起改）

### 第三步：大函数拆解
切了 20 多个函数，典型几个：

| 函数 | 前 | 后 | 拆法 |
|---|---|---|---|
| `load_image` | 159 行 / CC64 | 33 行 | 9 个阶段函数（**装载顺序即语义**，不能重排） |
| `console.main` | 123 行 | 38 行 | 参数/启动/面板/公告/服务/收尾 |
| `core.SendInstruction.execute` | 106 行 | 22 行 | 校验/解析/投递/回报 |
| `events._resolve_condition` | 105 行 / CC36 | 30 行 | 五个条件字段各一个函数 |
| `python_server._parse_transition` | 99 行 / CC32 | 22 行 | 目标/来源/工具声明 三段 |

### 第四步：大类拆分
单类太大，按「协作者」切，新模块都单独成文件：

| 原类 | 前 | 后 | 拆出来的协作者 |
|---|---|---|---|
| `Core` | 2033 行 | 1854 行 | `TargetProbe`(319) / `EventConditions`(203) / `ModelCatalog`(151) / `memory_nodes`(223) / `memory_codec` |
| `EventSystem` | 1332 行 | 823 行 | `TargetProbe` / `EventConditions` / `event_contracts` |
| `Memory` | 1222 行 | 1031 行 | `memory_nodes` / `memory_codec` |
| `Console` | 610 行 | 284 行 | `ClientLease` / `MaskLedger` / `MemorySnapshots` / `ConsoleView` / `DeviceActions` / `OperatorActions` / `Lifecycle` |

Console 拆得最彻底：610 行、33 个方法，现在只剩 `__init__` 装配、`state()` 聚合、
`_install_io_devices`、`io_input` 和生命周期五件；**20 个对外方法是一行转调**，
HTTP 层和测试一行没改。

---

## 四、三条最有价值的经验（都是「看着等价，其实不等价」）

### 1. 实参求值顺序 = 校验顺序
```python
return Capability(mode=..., groups=..., roots=..., tools=..., imports=...)
```
Python 按**书写顺序**求值。原代码是 mode→tools→imports→groups→roots，
改写成上面那样，多处同时非法时「报哪一条」就变了 —— 这是可观测行为。
**解法**：先按原顺序算到局部变量，再构造。

### 2. 字典字面量按插入顺序求值
所以 `return {"events": f(), "phases": g(), ...}` 能保住校验顺序，
但前提是 key 顺序照抄原 `return` 的书写顺序。

### 3. AST 取方法的坑
`ast.FunctionDef.lineno` 指向 `def` 行，**不含 `@staticmethod` 装饰器**。
照抄会得到 `def _events(raw)` 却仍按 `self._events(raw)` 调用 → 运行期缺参数。
按行号切片删除后，**被删块后面的装饰器也可能被一起吃掉**，拼完必须肉眼过接缝。

---

## 五、验证方法：三道关，每次都跑

1. **全量 pytest** —— 起点 8 failed / 1356 passed 是仓库原有的（`test_pkg_repo` 等），
   已用 `git stash` 在原始代码上验证过，不是重构引入的。重构完成后 **0 failed / 1455 passed**。
   失败数在本机有过 8↔9 抖动，定性为 `test_console_http` 的并发用例，基准 worktree 同样出现。
2. **装载指纹** —— `fingerprint_image.py` 把 `images/base/base.json` 装载成 Core 后
   压成 115 行 JSON（对话全字段、待发批次、内存树 sha256、设备表、全部落点配置），
   与基线**逐字节一致**（除三处随目录名变的绝对路径）。这是比「测试通过」更硬的证据。
3. **真启动冒烟** —— `smoke_console.py` 起一次真 console 进程（临时端口），验：
   四行公告 / 凭证文件 / 带凭证 200 / 无凭证 401 / 前端未构建提示 / 4 个对话 /
   面板 cid=-1。摸到 `Core.__init__` 时必须跑这一关。

---

## 六、同步上游时的取舍

上游 `7a4de7c..cac5c05` 七个提交：拆 LLM/PLM 服务层、消息格式升 IR v1、
新增 Responses/Anthropic/Gemini/chat 四个协议适配器（30 文件 +4888/−1593）。

四个容易做错的地方：

1. **`core.py` 的 9 块冲突里，块 2–7 我方侧是上游已原样搬进 `instructions.py` 的代码**
   （上游 instructions.py 的独有符号集为空 = 纯位置迁移）。按我方侧保留会让同一份
   指令集存在两处 → 必须取上游侧。
2. **我方重构的核心是「私有转公开 + 细粒度调度器 API」**，上游新文件全按旧私有名写
   → `instructions.py` 里 7 处 `core._journaling()`、1 处 `core._is_waiting_for_return()`
   会 AttributeError，已改公开名。
3. 上游把 `check_new_key` 留在 `memory.py`，我方拆到了 `memory_nodes.py`
   → 导入要跟着改，否则 **import 期**就崩，不是运行期才报。
4. **唯一放弃我方重构的地方：`model_catalog`。**
   上游把它整体重写成多接口架构（走 `services.llm.interfaces()`），我方 `ModelCatalog`
   还是旧的单接口 `core.lmu.client` 实现。按我方版本会废掉上游的多协议功能
   → 取上游内联版，`avm/model_catalog.py` 保留但 `ModelCatalog` 类已成孤立代码
   （只有 `_catalog_entry` 还被 8 条测试用）。

---

## 七、数字对比

| 指标 | 起点 | 现在 |
|---|---|---|
| 跨模块私有字段访问 | 271 | 24 |
| 模块级循环依赖 | 3 对 | 0 |
| 被 ≥2 模块共享的字段 | 3 个 | 1 个（`MetaDict._data`，类型友元） |
| >100 行函数 | 5 | 0 |
| 61–100 行函数 | 21 | 10 |
| CC≥30 函数 | 8 | 0 |
| 测试 | 1356 passed / 8 failed | 1455 passed / 0 failed |
| 文件数 | 24 | 31（+docstring，功能零增） |

---

## 八、现在的状态与遗留

### 状态
- `dev` @ `b18f432`，已推送 `origin/dev`（= 你自己的 fork `woc-synb666/AVM1`）
- 上游提交 0 条未并入
- 本工作区可以直接跑：双击 `启动AVM控制台.cmd` → `http://127.0.0.1:8700`

### 已知遗留（都是有意留下的，不是漏了）
1. **`avm/model_catalog.py` 的 `ModelCatalog` 类已无人引用**，只有 `_catalog_entry`
   被 8 条测试用。清理它要连同测试一起改，收益低。
2. **剩余 24 处跨模块私有访问**多是设备插件协议
   （`info_devices` 调 `device._read_field/_write_field/_read_meta_key/_write_meta_key`
   与 `Memory._index_of`），要动得同时改 `packages/`。
3. **`Core` 仍有 1854 行 / 少说上百个方法。** 继续拆要按协作者切，属结构调整，
   风险高于函数级整理 —— 而剩下的候选都碰私有字段，按第二节的判定标准不该拆。
4. `core.py` 与 `python_server.py` 是唯二没有模块 docstring 的模块，
   恰好是行数第 1、第 3。补 docstring 需要先真正理解它们，别硬编。

### 怎么接着干
```bash
# 跑测试（这台机器上唯一装了 openai 的解释器）
"C:/Users/Lenovo/AppData/Local/Programs/Python/Python312/python.exe" -m pytest -q

# 跑起来
双击 启动AVM控制台.cmd
```

改动前先跑一次全量 + 指纹，留基线；改完再跑一次对比。
