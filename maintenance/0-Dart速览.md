# 0 Dart 速览 — C/Python 背景读懂本代码库的最小集

> 目标不是学 Dart，是**读懂并安全修改这个项目的维护面代码**。
> 读完本文 + 对照任意一个 services/ 文件，应该能看懂 80% 的维护面逻辑。

---

## 一、空安全三件套（出现频率最高）

Dart 的每个类型默认**不可为 null**。可能为空的类型加 `?`：

```dart
String name;          // 不可为 null，必须初始化
String? nickname;     // 可为 null（相当于 C 的指针可能为 NULL）
```

三个高频操作符：

```dart
// 1. ?. 空安全调用 — 相当于 C 里 if (p != NULL) p->field
final len = nickname?.length;        // nickname 为 null 时结果是 null，不崩溃

// 2. ?? 空合并 — 相当于 Python 的 `or` 默认值
final show = nickname ?? '无名';

// 3. ??= 仅在为 null 时赋值
_cache ??= {};                       // 缓存未初始化才建（本库高频单例模式）

// 4. ! 断言非空 — 危险操作符，null 时直接崩（本项目少用，见到即知"作者确信非空"）
final n = nickname!.length;
```

`late` = 「晚点初始化，我保证用它之前赋值」：

```dart
late final Timer? _skipChipTimer;    // 声明在类里，init 时才赋值
```

`required` = 命名参数必须传（见第三节）。

## 二、Future / async / await（异步模型）

Dart 单线程事件循环（类似 Python asyncio）。**所有 IO 都是异步**，返回 `Future<T>`：

```dart
// await = 等它完成再往下走（期间不阻塞其他任务，类似 Python await）
final resp = await dio.get(url);
final data = await req.close().timeout(Duration(seconds: 20));

// Future<T> = 一个"将来会有 T"的票
Future<List<SkipInterval>> intervalsFor(...) { ... }

// .timeout 包装 = 超时抛 TimeoutException（本库大量使用）
final trace = await plugin.traceSearch(kw).timeout(const Duration(seconds: 10));

// unawaited = 明确"不等它"（发后不管）
unawaited(service.dispose());
```

**坑**：`Future.timeout` 到点抛 `TimeoutException`——扫描工具里见到的
`TimeoutException after 0:00:10` 就是查询包了一层 10 秒超时。

## 三、函数与命名参数

```dart
// 命名参数（本库 API 的主要风格）：
SkipTimeService.intervalsFor(
  malId: 54492,                    // required 命名参数
  episodeNumber: 11,
  episodeLengthSec: durationSec,   // 变量直接传
);

// 可选命名参数带默认值：
const SkipInterval({required this.type, this.skipId = '', this.isTemplate = false});
```

## 四、dynamic 与 jsonDecode 陷阱

`jsonDecode` 返回 `dynamic`——**所有字段访问都不会在编译期检查**，错字段 = 运行时崩溃：

```dart
final d = jsonDecode(raw);              // d 是 dynamic
final start = (interval['startTime'] as num?)?.toDouble();  // 标准防御链：
//   as num?           → 断言类型（可能为 null）
//   ?.toDouble()      → null 安全转换
// 本库 everywhere，照抄这个模式即可
```

**另一个高频坑**：`jsonEncode` 默认把中文转成 `\uXXXX`（合法 JSON，无碍）；
但手动拼 JSON 字符串经 bash 传中文会编码损坏（本项目踩过两次，见 05 防坑）。

## 五、字符串插值与集合

```dart
print('已跳过 ${it.type} (${end}s)');   // $变量 / ${表达式}，双引号或单引号等价
var list = <String>[];                  // 泛型列表
final map = <String, int>{};            // 字典
list.where((e) => e.name.contains(kw)).toList();   // 链式过滤（类似 Python 推导式）
for (final r in results) { ... }        // for-in
```

## 六、改代码的安全五步（每次修改都走这个循环）

```bash
# 1. 改完后静态检查（编译错误/警告全在此暴露）
../tools/flutter3477/bin/flutter.bat analyze lib/改动的文件.dart

# 2. 跑相关单测
../tools/flutter3477/bin/flutter.bat test --no-pub test/相关测试.dart

# 3. 热验证：直接跑真机 QA（无头全链路，不用开 GUI）
timeout 150 "build/windows/x64/runner/Release/kazumi.exe" --qa-play <源> <番名> --qa-timeout 40 --qa-output /tmp/t.json
# 注意：QA 需独占存储，跑之前 GUI 必须关闭

# 4. 全量回归（排除 manual_z_ 工具）
../tools/flutter3477/bin/flutter.bat test --no-pub $(ls test/*.dart | grep -v manual_z_)

# 5. commit（本地；推远端等你验收）
git add <文件> && git commit -m "feat(scope): 说明"
```

## 七、本库高频模式速查

| 模式 | 长相 | 在哪看例子 |
|---|---|---|
| 单例服务 | `static final X instance = X._();` | skip_time_service / flaresolverr_service |
| 会话缓存+并发闸 | `_cache.containsKey(key)` + `_inflight.putIfAbsent(...)` | skip_time_service 区间/malId |
| JSON 持久化 | `GStorage.putSetting(key, jsonEncode(map))` | skip 黑名单 / malId 缓存 |
| 双层 per-host 记忆 | `static final Map<String, bool> _hostNeedsFetch` | rule_engine ChallengeAware 执行器 |
| 重试阶梯 | `for (final len in lengths) { try ... on 404 continue; }` | skip_time_service 片长阶梯 |
| 平台分支 | `Platform.isWindows ? windows实现 : 移动实现` | webview_page_fetch_service |

## 八、学习路径建议

1. 通读 `lib/services/skip/skip_time_service.dart`（322 行，功能独立，模式齐全）
2. 对照 `test/skip_guards_test.dart` 看纯函数怎么测
3. 有 Unknown 语法随手查 dart.dev（语言 tour 中文版可用）
4. 改动永远从小开始：改日志文案 → 改常量 → 改逻辑分支 → 加新分支
