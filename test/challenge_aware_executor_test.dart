// [my新增] 挑战感知执行器单元测试 — 直连/挑战/WebView/FlareSolverr 兜底链
// 与 isChallengeBody 判定。全部用注入假通道, 不触网。
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/services/flaresolverr/flaresolverr_service.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';

RuleExecutionConfig _config({bool webviewFetch = false}) {
  return RuleExecutionConfig(
    pluginName: 't',
    baseUrl: 'https://t.example/',
    usePost: false,
    searchMode: 'xpath',
    chapterMode: 'xpath',
    searchUrl: 'https://t.example/s?q=@keyword',
    searchList: '//div',
    searchName: './/a',
    searchResult: './/a',
    chapterRoads: '//ul',
    chapterResult: '//li/a',
    searchApiConfig: ApiSearchConfig(),
    chapterApiConfig: ApiChapterConfig(),
    antiCrawlerConfig: AntiCrawlerConfig.empty(),
    webviewFetch: webviewFetch,
  );
}

const _okHtml = '<html><body>正常页面内容</body></html>';
const _cfHtml = '<html><title>Just a moment...</title></html>';
const _slHtml =
    '<html><head><title>Loading...</title></head><body><script>'
    "window.location.replace('https://x.example/search.html?ch=1&js=eyJhbGciOiJ9');"
    '</script></body></html>';

void main() {
  group('FlareSolverrService.isChallengeBody', () {
    test('CF 显性文案判定', () {
      expect(FlareSolverrService.isChallengeBody(_cfHtml), isTrue);
    });
    test('雷池 JS 壳签名判定', () {
      expect(FlareSolverrService.isChallengeBody(_slHtml), isTrue);
    });
    test('正常页面不误判', () {
      expect(FlareSolverrService.isChallengeBody(_okHtml), isFalse);
      // 大页面含 challenge-platform 字样不误判 (体积启发防误伤)
      final big = '<html>${'x' * 30000}challenge-platform</html>';
      expect(FlareSolverrService.isChallengeBody(big), isFalse);
    });
  });

  group('ChallengeAwareRuleRequestExecutor', () {
    late List<String> calls;
    setUp(() {
      calls = [];
    });

    RuleRequestExecutor _innerReturning(String html) {
      return _FakeInner(html, calls);
    }

    RuleRequestExecutor _innerThrowing() {
      return _FakeThrowingInner(calls);
    }

    test('无标志规则: 直连结果直通, 即使命中挑战体也不回退', () async {
      final exec = ChallengeAwareRuleRequestExecutor(
        _innerReturning(_cfHtml),
        webviewFetcher: (url) async {
          calls.add('webview');
          return 'webview-html';
        },
        flareSolverrSolver: (url) async {
          calls.add('fs');
          return 'fs-html';
        },
      );
      final raw = await exec.execute(
        const PreparedRuleRequest(method: 'GET', url: 'https://t.example/s'),
        _config(),
      );
      expect(raw, _cfHtml);
      expect(calls, isNot(contains('webview')));
      expect(calls, isNot(contains('fs')));
    });

    test('有标志 + 直连正常: 直通不回退', () async {
      final exec = ChallengeAwareRuleRequestExecutor(
        _innerReturning(_okHtml),
        webviewFetcher: (url) async {
          calls.add('webview');
          return 'webview-html';
        },
        flareSolverrSolver: (url) async => 'fs-html',
      );
      final raw = await exec.execute(
        const PreparedRuleRequest(method: 'GET', url: 'https://ok1.example/s'),
        _config(webviewFetch: true),
      );
      expect(raw, _okHtml);
      expect(calls, isNot(contains('webview')));
      expect(calls, isNot(contains('fs')));
    });

    test('有标志 + 直连挑战体: WebView 接管', () async {
      final exec = ChallengeAwareRuleRequestExecutor(
        _innerReturning(_cfHtml),
        webviewFetcher: (url) async {
          calls.add('webview');
          return 'webview-html';
        },
        flareSolverrSolver: (url) async {
          calls.add('fs');
          return 'fs-html';
        },
      );
      final raw = await exec.execute(
        const PreparedRuleRequest(method: 'GET', url: 'https://cf1.example/s'),
        _config(webviewFetch: true),
      );
      expect(raw, 'webview-html');
      expect(calls, ['inner', 'webview']);
    });

    test('有标志 + 直连异常: WebView 接管; WebView 失败再 FS 兜底', () async {
      final exec = ChallengeAwareRuleRequestExecutor(
        _innerThrowing(),
        webviewFetcher: (url) async {
          calls.add('webview');
          throw Exception('webview 不可用');
        },
        flareSolverrSolver: (url) async {
          calls.add('fs');
          return 'fs-html';
        },
      );
      final raw = await exec.execute(
        const PreparedRuleRequest(method: 'GET', url: 'https://down1.example/s'),
        _config(webviewFetch: true),
      );
      expect(raw, 'fs-html');
      expect(calls, ['inner', 'webview', 'fs']);
    });

    test('双通道全失败: 抛 ChallengeFetchException', () async {
      final exec = ChallengeAwareRuleRequestExecutor(
        _innerThrowing(),
        webviewFetcher: (url) async {
          throw Exception('webview 不可用');
        },
        flareSolverrSolver: (url) async {
          throw Exception('fs 不可达');
        },
      );
      await expectLater(
        exec.execute(
          const PreparedRuleRequest(method: 'GET', url: 'https://dead1.example/s'),
          _config(webviewFetch: true),
        ),
        throwsA(isA<ChallengeFetchException>()),
      );
    });

    test('per-host 记忆: 第二次请求跳过直连', () async {
      var innerCalls = 0;
      final exec = ChallengeAwareRuleRequestExecutor(
        _FakeInner(_cfHtml, calls, onCall: () => innerCalls++),
        webviewFetcher: (url) async => 'webview-html',
        flareSolverrSolver: (url) async => 'fs-html',
      );
      final cfg = _config(webviewFetch: true);
      const req = PreparedRuleRequest(method: 'GET', url: 'https://mem1.example/s');
      await exec.execute(req, cfg);
      expect(innerCalls, 1);
      final raw = await exec.execute(req, cfg);
      expect(innerCalls, 1, reason: 'per-host 记忆后不应再撞直连');
      expect(raw, 'webview-html');
    });
  });
}

class _FakeInner implements RuleRequestExecutor {
  _FakeInner(this.html, this.calls, {this.onCall});
  final String html;
  final List<String> calls;
  final void Function()? onCall;

  @override
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    dynamic cancelToken,
  }) async {
    calls.add('inner');
    onCall?.call();
    return html;
  }
}

class _FakeThrowingInner implements RuleRequestExecutor {
  _FakeThrowingInner(this.calls);
  final List<String> calls;

  @override
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    dynamic cancelToken,
  }) async {
    calls.add('inner');
    throw Exception('直连被挑战墙挡下 (403)');
  }
}
