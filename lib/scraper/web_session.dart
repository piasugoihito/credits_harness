/// 画面なし WebView(HeadlessInAppWebView)をブラウザ代わりに使うための薄いラッパー。
///
/// - ナビゲーションは *.tsukuba.ac.jp の https に限定(それ以外は取り消して記録)。
/// - JS は許可ドメイン上でのみ実行。注入 JS は assets/js/webview_snippets.js。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/failure.dart';
import '../core/url_guard.dart';

export '../core/failure.dart';

typedef Log = void Function(String message);

class ScrapeException implements Exception {
  final FailureKind kind;
  final String message; // 個人情報・資格情報を含めないこと
  const ScrapeException(this.kind, this.message);
  @override
  String toString() => 'ScrapeException(${kind.name}): $message';
}

String? _snippetsCache;
Future<String> loadSnippets() async => _snippetsCache ??= await rootBundle.loadString('assets/js/webview_snippets.js');

/// 可視・不可視の WebView で共通の設定。
InAppWebViewSettings webViewSettings() => InAppWebViewSettings(
  javaScriptEnabled: true,
  useShouldOverrideUrlLoading: true,
  supportMultipleWindows: false,
  javaScriptCanOpenWindowsAutomatically: false,
  thirdPartyCookiesEnabled: false,
  allowFileAccess: false,
  allowContentAccess: false,
);

/// 許可ドメイン外のナビゲーションを取り消す(可視 WebView からも使う)。
Future<NavigationActionPolicy> guardNavigation(
  NavigationAction action, {
  void Function(Uri? blocked)? onBlocked,
}) async {
  final uri = action.request.url;
  if (uri == null || uri.scheme == 'about' || uri.scheme == 'data') {
    return NavigationActionPolicy.ALLOW;
  }
  if (isAllowedUrl(uri)) return NavigationActionPolicy.ALLOW;
  onBlocked?.call(uri);
  return NavigationActionPolicy.CANCEL;
}

class WebSession {
  final Log log;
  final HeadlessInAppWebView _view;
  InAppWebViewController? _c;
  final _ready = Completer<void>();
  final Set<String> hostsSeen = {};
  final List<String> blockedHosts = [];
  int _loadErrors = 0;

  WebSession._(this.log, this._view);

  /// url を開いて最初の読み込み完了まで待つ。
  static Future<WebSession> open(Uri url, {required Log log}) async {
    if (!isAllowedUrl(url)) throw ScrapeException(FailureKind.blockedHost, '許可されていないURL: ${url.host}');
    late WebSession s;
    final view = HeadlessInAppWebView(
      // サイズ0だと JS 側の visible() 判定(getBoundingClientRect)が常に false になるため実寸を与える
      initialSize: const Size(1080, 1920),
      initialSettings: webViewSettings(),
      initialUrlRequest: URLRequest(url: WebUri.uri(url)),
      onWebViewCreated: (c) => s._c = c,
      shouldOverrideUrlLoading: (c, action) => guardNavigation(action, onBlocked: s._onBlocked),
      onLoadStart: (c, u) {
        if (u == null) return;
        s.hostsSeen.add(u.host);
        if (u.scheme == 'https' || u.scheme == 'http') {
          if (!isAllowedUrl(u)) {
            s._onBlocked(u);
            c.stopLoading();
          }
        }
      },
      onLoadStop: (c, u) {
        if (!s._ready.isCompleted) s._ready.complete();
      },
      onReceivedError: (c, req, err) {
        if (req.isForMainFrame ?? true) {
          s._loadErrors++;
          s.log('読み込みエラー(${req.url.host}): ${err.type}');
          if (!s._ready.isCompleted) s._ready.complete();
        }
      },
    );
    s = WebSession._(log, view);
    await view.run();
    await s._ready.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        throw const ScrapeException(FailureKind.offline, 'ページの読み込みがタイムアウトしました');
      },
    );
    if (s._loadErrors > 0 && await s.currentUrl() == null) {
      throw const ScrapeException(FailureKind.offline, 'ページを開けませんでした(オフラインの可能性)');
    }
    return s;
  }

  void _onBlocked(Uri? u) {
    final h = u?.host ?? '?';
    blockedHosts.add(h);
    log('許可ドメイン外への遷移を止めました: $h');
  }

  InAppWebViewController get _ctl {
    final c = _c;
    if (c == null) throw StateError('WebView が初期化されていません');
    return c;
  }

  Future<Uri?> currentUrl() async => (await _ctl.getUrl())?.uriValue;

  /// 現在のページが許可ドメインのときだけ JS を実行する。スニペット未注入なら先に注入。
  Future<dynamic> js(String expression) async {
    final url = await currentUrl();
    if (!isAllowedUrl(url)) {
      throw ScrapeException(FailureKind.blockedHost, '許可ドメイン外のページでJSを実行しようとしました: ${url?.host}');
    }
    final snippets = await loadSnippets();
    return _ctl.evaluateJavascript(source: 'if (!window.TS) { $snippets }\n$expression');
  }

  Future<void> loadUrl(Uri url) async {
    if (!isAllowedUrl(url)) throw ScrapeException(FailureKind.blockedHost, '許可されていないURL: ${url.host}');
    await _markDocument();
    await _ctl.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
  }

  /// 遷移前の文書に目印を付ける(新しい文書に切り替わったかを判定するため)。
  Future<void> _markDocument() async {
    try {
      await _ctl.evaluateJavascript(source: 'window.__chMark = 1; true');
    } catch (_) {}
  }

  /// condJs が true になるまで待つ。newDocument=true なら、目印の無い新しい文書であることも条件にする。
  Future<bool> waitFor(
    String condJs, {
    Duration timeout = const Duration(seconds: 30),
    bool newDocument = false,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final guard = newDocument ? "window.__chMark !== 1 && " : '';
    final probe =
        "(function(){ try { return !!($guard document.readyState === 'complete' && ($condJs)); } catch (e) { return false; } })()";
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (await js(probe) == true) return true;
      } on ScrapeException catch (e) {
        if (e.kind != FailureKind.blockedHost) rethrow; // IdP 途中のリダイレクト等は待ち続ける
      } catch (_) {
        // 遷移中の evaluate 失敗は無視して再試行
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  /// clickJs(戻り値 true=押せた)を実行し、新しい文書で condJs が true になるまで待つ。
  Future<bool> clickAndWait(String clickJs, String condJs, {Duration timeout = const Duration(seconds: 30)}) async {
    await _markDocument();
    final clicked = await js(clickJs);
    if (clicked != true) return false;
    return waitFor(condJs, timeout: timeout, newDocument: true);
  }

  Future<String> html() async => (await js('TS.getHtml()')) as String;

  Future<Object?> jsJson(String expression) async {
    final r = await js(expression);
    return r is String ? jsonDecode(r) : r;
  }

  Future<void> dispose() => _view.dispose();
}

/// 可視 WebView 用: 許可ドメイン上でのみ、スニペットを注入してから expression を実行する。
Future<dynamic> evalWithSnippets(InAppWebViewController c, String expression) async {
  final url = (await c.getUrl())?.uriValue;
  if (!isAllowedUrl(url)) {
    throw ScrapeException(FailureKind.blockedHost, '許可ドメイン外のページでJSを実行しようとしました: ${url?.host}');
  }
  final snippets = await loadSnippets();
  return c.evaluateJavascript(source: 'if (!window.TS) { $snippets }\n$expression');
}
