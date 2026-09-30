/// アプリ内の可視 WebView。手動ログイン・manaba の課題表示・KdB 表示に使う(Cookie はアプリ全体で共有)。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/url_guard.dart';
import '../data/credentials.dart';
import '../scraper/web_session.dart';

class WebPage extends StatefulWidget {
  final Uri url;
  final String title;

  /// AppBar のメニューに並べる追加操作(M0 の KdB 調査など)。
  final List<WebPageAction> actions;
  final void Function(String message)? log;

  /// ログイン画面が出たら、保存済みの資格情報で1回だけ自動入力する(失敗フラグが立っていればしない)。
  final CredentialStore? autoLogin;

  /// 最初のページ読み込み完了時に1回だけ呼ばれる(許可ドメイン上のみ)。
  final Future<void> Function(InAppWebViewController c)? onFirstLoad;

  const WebPage({
    super.key,
    required this.url,
    required this.title,
    this.actions = const [],
    this.log,
    this.autoLogin,
    this.onFirstLoad,
  });

  @override
  State<WebPage> createState() => _WebPageState();
}

class WebPageAction {
  final String label;
  final Future<String?> Function(InAppWebViewController c) run;
  const WebPageAction(this.label, this.run);
}

class _WebPageState extends State<WebPage> {
  InAppWebViewController? _c;
  double _progress = 0;
  String _host = '';
  bool _firstLoadDone = false;
  bool _autofillTried = false;
  bool _autofillGaveUp = false;

  void _log(String m) => widget.log?.call(m);

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m, maxLines: 4)));
  }

  Future<void> _onLoadStop(InAppWebViewController c, WebUri? url) async {
    if (!isAllowedUrl(url?.uriValue)) return;
    try {
      await _maybeAutoLogin(c);
      if (!_firstLoadDone && widget.onFirstLoad != null) {
        _firstLoadDone = true;
        await widget.onFirstLoad!(c);
      }
    } catch (e) {
      _log('WebView操作エラー: ${e.runtimeType}');
    }
  }

  Future<void> _maybeAutoLogin(InAppWebViewController c) async {
    final store = widget.autoLogin;
    if (store == null || _autofillGaveUp) return;
    if (await evalWithSnippets(c, 'TS.isLoginPage()') != true) return;
    if (_autofillTried) {
      // 自動入力の後に再びログイン画面 → 失敗とみなし、以後は自動入力しない(アカウントロック防止)
      _autofillGaveUp = true;
      await store.setAutofillFailed();
      _snack('自動ログインできませんでした。画面で直接ログインしてください');
      return;
    }
    if (await store.autofillFailed()) return;
    final cred = await store.read();
    if (cred == null) return;
    _autofillTried = true;
    await evalWithSnippets(c, 'TS.fillLogin(${jsonEncode(cred.user)}, ${jsonEncode(cred.password)})');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, overflow: TextOverflow.ellipsis),
            Text(_host, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(tooltip: '再読み込み', icon: const Icon(Icons.refresh), onPressed: () => _c?.reload()),
          PopupMenuButton<WebPageAction>(
            onSelected: (a) async {
              final c = _c;
              if (c == null) return;
              final url = (await c.getUrl())?.uriValue;
              if (!isAllowedUrl(url)) {
                _log('許可ドメイン外のため操作しません: ${url?.host}');
                return;
              }
              final r = await a.run(c);
              if (r != null) {
                _log(r);
                _snack(r);
              }
            },
            itemBuilder: (_) => [
              for (final a in widget.actions) PopupMenuItem(value: a, child: Text(a.label)),
              PopupMenuItem(
                value: WebPageAction('ブラウザで開く', (c) async {
                  final u = (await c.getUrl())?.uriValue ?? widget.url;
                  await launchUrl(u, mode: LaunchMode.externalApplication);
                  return null;
                }),
                child: const Text('ブラウザで開く'),
              ),
            ],
          ),
        ],
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress),
              )
            : null,
      ),
      body: InAppWebView(
        initialSettings: webViewSettings(),
        initialUrlRequest: URLRequest(url: WebUri.uri(widget.url)),
        onWebViewCreated: (c) => _c = c,
        shouldOverrideUrlLoading: (c, action) => guardNavigation(
          action,
          onBlocked: (u) {
            _log('許可ドメイン外への遷移を止めました: ${u?.host}');
            _snack('大学外のページはアプリ内では開けません: ${u?.host}');
          },
        ),
        onLoadStart: (c, u) {
          if (u == null) return;
          _log('可視WebView: ${u.host}${u.path}');
          setState(() => _host = u.host);
        },
        onLoadStop: _onLoadStop,
        onProgressChanged: (c, p) => setState(() => _progress = p / 100),
      ),
    );
  }
}
