/// M0 実現性スパイク: 実機で (a)〜(f) を確かめるための画面。
///
/// ログには件数・ホスト名・画面要素の有無だけを出す(科目名・氏名・学籍番号は出さない)。
/// ログをコピーして開発側に共有しても個人情報が含まれないようにしている。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/credentials.dart';
import '../notify/notifier.dart';
import '../scraper/scrapers.dart';
import '../scraper/web_session.dart';
import '../ui/web_page.dart';

final kdbUrl = Uri.parse('https://kdb.tsukuba.ac.jp/');

class SpikePage extends StatefulWidget {
  const SpikePage({super.key});
  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  final _store = CredentialStore();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  final _logs = <String>[];
  bool _busy = false;
  bool _hasCred = false;
  bool _autofillFailed = false;
  String _notifStatus = '';

  @override
  void initState() {
    super.initState();
    _refreshState();
  }

  Future<void> _refreshState() async {
    final c = await _store.read();
    final f = await _store.autofillFailed();
    final st = await Notifier.instance.status();
    final pending = await Notifier.instance.pendingCount();
    if (!mounted) return;
    setState(() {
      _hasCred = c != null;
      _autofillFailed = f;
      _notifStatus =
          '通知許可=${st.notificationsEnabled ? 'あり' : 'なし'} / 正確なアラーム=${st.exactAlarms ? 'あり' : 'なし'} / 予約中=$pending件';
    });
  }

  void _log(String m) {
    final t = DateTime.now();
    final ts =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    if (mounted) setState(() => _logs.add('[$ts] $m'));
  }

  Future<void> _run(String name, Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    _log('▶ $name');
    final sw = Stopwatch()..start();
    try {
      await f();
      _log('✔ $name (${sw.elapsed.inSeconds}秒)');
    } on ScrapeException catch (e) {
      _log('✖ $name [${e.kind.name}] ${e.message}');
    } catch (e) {
      _log('✖ $name 予期しないエラー: ${e.runtimeType}');
    } finally {
      await _refreshState();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWeb(Uri url, String title, {List<WebPageAction> actions = const []}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebPage(url: url, title: title, actions: actions, log: _log),
      ),
    );
    await _refreshState();
  }

  // KdB の画面構造を、本文テキストを含めずに要約する(タグ・id・class の出現数のみ)
  static const _structureJs = r'''
(function(){
  const ids = Array.from(document.querySelectorAll('[id]')).map(e => e.tagName.toLowerCase() + '#' + e.id).slice(0, 60);
  const cls = {};
  document.querySelectorAll('[class]').forEach(e => e.classList.forEach(c => cls[c] = (cls[c] || 0) + 1));
  const topCls = Object.entries(cls).sort((a, b) => b[1] - a[1]).slice(0, 40).map(x => x[0] + ':' + x[1]);
  return JSON.stringify({
    host: location.host, path: location.pathname,
    iframes: document.querySelectorAll('iframe').length,
    forms: document.querySelectorAll('form').length,
    tables: document.querySelectorAll('table').length,
    resultTitles: document.querySelectorAll('p.ut-break-word.ut-title').length,
    hasSearchBox: !!document.querySelector('#txtSyllabus'), hasSearchBtn: !!document.querySelector('#btnSearch'),
    textLength: (document.body.innerText || '').length,
    ids: ids, classes: topCls
  });
})()''';

  List<WebPageAction> _kdbActions() => [
    WebPageAction('① 科目番号で検索', (c) async {
      final code = _code.text.trim();
      if (code.isEmpty) return '科目番号を入力してください(M0画面)';
      final snippets = await loadSnippets();
      final r = await c.evaluateJavascript(source: 'if (!window.KDB) { $snippets }\nKDB.search(${jsonEncode(code)})');
      return 'KdB検索: 検索欄とボタン=${r == true ? '見つかった' : '見つからない'}';
    }),
    WebPageAction('② 検索結果の件数', (c) async {
      final snippets = await loadSnippets();
      final r = await c.evaluateJavascript(source: 'if (!window.KDB) { $snippets }\nKDB.listResults()');
      final n = (jsonDecode(r as String) as List).length;
      return 'KdB検索結果: $n件 (p.ut-break-word.ut-title)';
    }),
    WebPageAction('③ 先頭の結果を開く', (c) async {
      final snippets = await loadSnippets();
      final r = await c.evaluateJavascript(source: 'if (!window.KDB) { $snippets }\nKDB.clickResult(null)');
      return 'KdB結果クリック: ${r == true ? '押した(開き方をログのURLで確認)' : '結果が無い'}';
    }),
    WebPageAction('④ 画面構造の要約(本文なし)', (c) async {
      final r = await c.evaluateJavascript(source: _structureJs);
      return 'KdB構造: $r';
    }),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget section(String title, List<Widget> children) => Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: t.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
    Widget btn(String label, VoidCallback f) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: FilledButton.tonal(onPressed: _busy ? null : f, child: Text(label)),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('M0 実現性スパイク')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          section('資格情報(端末のKeystoreにのみ保存)', [
            Text('保存: ${_hasCred ? 'あり' : 'なし'} / 自動ログイン: ${_autofillFailed ? '停止中(前回失敗)' : '有効'}'),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: '学籍番号'),
              autocorrect: false,
            ),
            TextField(
              controller: _pass,
              decoration: const InputDecoration(labelText: 'パスワード'),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
            ),
            btn('保存(自動ログインを1回だけ再開)', () async {
              if (_user.text.isEmpty || _pass.text.isEmpty) return;
              await _store.save(Credentials(_user.text.trim(), _pass.text));
              _pass.clear();
              _log('資格情報を保存しました');
              await _refreshState();
            }),
            btn('資格情報を削除', () async {
              await _store.delete();
              _log('資格情報を削除しました');
              await _refreshState();
            }),
            if (_autofillFailed)
              btn('再試行(自動ログインを1回だけ許可)', () async {
                await _store.clearAutofillFailed();
                await _refreshState();
              }),
          ]),
          section('(a)(b) TWINS: ログイン維持と時間割取得', [
            const Text('1回目は自動ログイン。成功したらアプリを完全に終了→再起動して、もう一度押す。「ログイン済み(Cookie再利用)」と出ればOK。'),
            btn(
              'TWINS 時間割を取得(画面なし)',
              () => _run('TWINS取得', () async {
                final r = await fetchTimetable(_store, log: _log);
                _log('TWINS結果: ${r.slotsByModule.entries.map((e) => '${e.key}=${e.value.length}').join(', ')}');
              }),
            ),
            btn('TWINS を画面ありで開く(手動ログイン)', () => _openWeb(twinsUrl, 'TWINS')),
          ]),
          section('(c)(d) manaba: 未提出課題とSSO共有', [
            const Text('TWINSのログイン直後に押し、「ログイン済み(Cookie/SSO再利用)」ならSSO共有あり。'),
            btn(
              'manaba 未提出課題を取得(画面なし)',
              () => _run('manaba取得', () async {
                await fetchAssignments(_store, log: _log);
              }),
            ),
            btn('manaba を画面ありで開く', () => _openWeb(manabaUrl, 'manaba')),
          ]),
          section('Cookie', [
            btn('Cookieをすべて削除(未ログイン状態から試す)', () async {
              await CookieManager.instance().deleteAllCookies();
              _log('Cookieを削除しました');
            }),
          ]),
          section('(e) 通知(アプリ終了状態・再起動後)', [
            Text(_notifStatus),
            btn('通知の権限を許可する', () async {
              final s = await Notifier.instance.requestPermissions();
              _log('権限: 通知=${s.notificationsEnabled} 正確なアラーム=${s.exactAlarms}');
              await _refreshState();
            }),
            btn('2分後にテスト通知 → すぐアプリを完全終了', () async {
              final at = await Notifier.instance.scheduleTest(const Duration(minutes: 2));
              _log('テスト通知を ${at.hour}:${at.minute.toString().padLeft(2, '0')} に予約');
              await _refreshState();
            }),
            btn('6分後にテスト通知 → 端末を再起動', () async {
              final at = await Notifier.instance.scheduleTest(const Duration(minutes: 6), title: '再起動テスト');
              _log('再起動テスト通知を ${at.hour}:${at.minute.toString().padLeft(2, '0')} に予約');
              await _refreshState();
            }),
          ]),
          section('(f) KdB: 検索→シラバス表示の実DOM', [
            const Text('KdBを開き、右上メニュー①〜④を順に実行。④は本文を含まない構造の要約です。'),
            TextField(
              controller: _code,
              decoration: const InputDecoration(labelText: '科目番号(例: 自分の履修科目)'),
            ),
            btn('KdB を開く', () => _openWeb(kdbUrl, 'KdB', actions: _kdbActions())),
          ]),
          section('ログ(個人情報は出力しません)', [
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('コピー'),
                  onPressed: () => Clipboard.setData(ClipboardData(text: _logs.join('\n'))),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('クリア'),
                  onPressed: () => setState(_logs.clear),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ],
            ),
            SelectableText(
              _logs.isEmpty ? '(まだありません)' : _logs.join('\n'),
              style: t.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ]),
        ],
      ),
    );
  }
}
