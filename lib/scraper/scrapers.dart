/// TWINS(時間割)・manaba(未提出課題)の取得。大学サイトに対しては読み取り専用。
///
/// 押す要素は許可リスト方式(メニュー・学期タブ・『未提出の課題一覧』ボタンのみ)。JS 側の assertSafe でも二重に確認する。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;

import '../core/kdb_rooms.dart';
import '../core/models.dart';
import '../core/parsers.dart';
import '../data/credentials.dart';
import 'web_session.dart';

final twinsUrl = Uri.parse('https://twins.tsukuba.ac.jp/campusweb/');
final manabaUrl = Uri.parse('https://manaba.tsukuba.ac.jp/ct/home_library_query');

const _menuText = '履修登録・登録状況照会';
const _unsubmittedAlt = '未提出の課題一覧';
const _isLoginJs = 'TS.isLoginPage()';

enum LoginResult { alreadyLoggedIn, autofilled }

/// 未ログインなら保存済みの資格情報で「1回だけ」自動入力する(FR-2)。
/// 失敗したら失敗フラグを立てて needsLogin を投げる。以後、フラグが解除されるまで自動入力しない。
Future<LoginResult> ensureLoggedIn(WebSession s, String readyJs, CredentialStore store) async {
  final landed = await s.waitFor('($_isLoginJs) || ($readyJs)', timeout: const Duration(seconds: 40));
  if (!landed) {
    final host = (await s.currentUrl())?.host;
    if (s.blockedHosts.isNotEmpty) {
      throw ScrapeException(FailureKind.blockedHost, 'ログイン経路が許可ドメイン外です: ${s.blockedHosts.join(', ')}');
    }
    throw ScrapeException(FailureKind.structureChanged, 'ログイン画面もメニューも見つかりません(現在のホスト: $host)');
  }
  if (await s.js(readyJs) == true) return LoginResult.alreadyLoggedIn;

  if (await store.autofillFailed()) {
    throw const ScrapeException(FailureKind.needsLogin, '前回の自動ログインに失敗したため、自動入力を止めています');
  }
  final cred = await store.read();
  if (cred == null) {
    throw const ScrapeException(FailureKind.needsLogin, '学籍番号・パスワードが保存されていません');
  }

  // 目印を付けてから送信し、送信後は新しい文書かどうかで遷移を判定する
  final diagRaw = await s.js(
    'window.__chMark = 1; TS.fillLogin(${jsonEncode(cred.user)}, ${jsonEncode(cred.password)})',
  );
  final diag = jsonDecode(diagRaw as String) as Map<String, Object?>;
  s.log(
    '自動入力: ok=${diag['ok']} 入力欄=${diag['userField']}/${diag['passField']} ボタン=${diag['button']}'
    '${diag['reason'] != null ? ' 理由=${diag['reason']}' : ''}',
  );
  if (diag['ok'] != true) {
    await store.setAutofillFailed();
    throw ScrapeException(FailureKind.needsLogin, '自動入力できませんでした(${diag['reason']})');
  }

  // 送信後: 新しい文書で「目的の画面」か「再びログイン画面」になるまで待つ(SAML の中継ページは通過待ち)
  final settled = await s.waitFor(
    '($_isLoginJs) || ($readyJs)',
    timeout: const Duration(seconds: 45),
    newDocument: true,
  );
  if (settled && await s.js(readyJs) == true) return LoginResult.autofilled;

  await store.setAutofillFailed();
  String hint = '';
  try {
    hint = ((jsonDecode(await s.js('TS.loginErrorHint()') as String) as List).join(' / '));
  } catch (_) {}
  throw ScrapeException(
    FailureKind.needsLogin,
    settled ? 'ログインできませんでした${hint.isEmpty ? '' : ': $hint'}' : 'ログイン後の画面に進みませんでした(多要素認証などの可能性)',
  );
}

class TimetableResult {
  /// タブ名 → コマ一覧(タブの並び順)
  final Map<String, List<Slot>> slotsByModule;

  /// TWINS を開いた時点で選択されていたタブ(= TWINS が考える現在のモジュール)
  final String? currentModule;
  const TimetableResult(this.slotsByModule, this.currentModule);
}

/// TWINS の全学期タブを巡回してコマを取得する。
Future<TimetableResult> fetchTimetable(CredentialStore store, {required Log log}) async {
  final s = await WebSession.open(twinsUrl, log: log);
  try {
    final login = await ensureLoggedIn(s, "!!document.querySelector('span.menunm')", store);
    log('TWINS: ${login == LoginResult.alreadyLoggedIn ? 'ログイン済み(Cookie再利用)' : '自動ログイン成功'}');

    const hasTable = "!!document.querySelector('table.rishu-koma')";
    if (!await s.clickAndWait('TS.clickMenu(${jsonEncode(_menuText)})', hasTable)) {
      throw const ScrapeException(FailureKind.structureChanged, '「$_menuText」メニューまたは時間割表が見つかりません');
    }

    final tabs = ((await s.jsJson('TS.listTabs()')) as List).cast<Map>();
    if (tabs.isEmpty) throw const ScrapeException(FailureKind.structureChanged, '学期タブが見つかりません');
    final current = tabs.where((t) => t['selected'] == true).map((t) => t['label'] as String).firstOrNull;
    log('TWINS: タブ ${tabs.map((t) => t['label']).join(' ')} (選択中: ${current ?? 'なし'})');

    // 最初に選択されているタブは、他のタブを開く前にいまの画面から読む
    // (後で読むと、その時点で表示中の別のタブの表を読んでしまう)
    final byLabel = <String, List<Slot>>{};
    if (current != null) {
      final slots = parseTimetable(await s.html());
      if (slots == null) throw ScrapeException(FailureKind.structureChanged, '「$current」の時間割表を解析できません');
      byLabel[current] = slots;
      log('TWINS: $current ${slots.length}コマ');
    }
    for (final t in tabs) {
      final label = t['label'] as String;
      if (byLabel.containsKey(label)) continue;
      await Future<void>.delayed(const Duration(milliseconds: 600)); // サイト負荷への配慮
      final sel =
          "(function(){ const e = document.querySelector('td.rishu-tab-sel'); "
          "return !!e && e.textContent.trim() === ${jsonEncode(label)} && $hasTable; })()";
      if (!await s.clickAndWait('TS.clickTab(${jsonEncode(label)})', sel)) {
        throw ScrapeException(FailureKind.structureChanged, '学期タブ「$label」を開けませんでした');
      }
      final slots = parseTimetable(await s.html());
      if (slots == null) throw ScrapeException(FailureKind.structureChanged, '「$label」の時間割表を解析できません');
      byLabel[label] = slots;
      log('TWINS: $label ${slots.length}コマ');
    }
    // タブの並び順で返す
    final result = {for (final t in tabs) t['label'] as String: byLabel[t['label'] as String] ?? const <Slot>[]};
    if (result.values.every((x) => x.isEmpty)) {
      throw const ScrapeException(FailureKind.structureChanged, '全学期で0コマでした(既存データは上書きしません)');
    }
    return TimetableResult(result, current);
  } finally {
    await s.dispose();
  }
}

/// manaba の未提出課題一覧を取得する。
/// 戻り値: 未提出課題と、manaba のコース一覧(コース名 → URL。取れなければ空)。
Future<(List<Assignment>, Map<String, String>)> fetchAssignments(CredentialStore store, {required Log log}) async {
  final s = await WebSession.open(manabaUrl, log: log);
  try {
    final btn = "!!document.querySelector('img[alt=\"$_unsubmittedAlt\"]')";
    final login = await ensureLoggedIn(s, btn, store);
    log('manaba: ${login == LoginResult.alreadyLoggedIn ? 'ログイン済み(Cookie/SSO再利用)' : '自動ログイン成功'}');

    if (!await s.clickAndWait('TS.clickImageButton(${jsonEncode(_unsubmittedAlt)})', 'TS.hasAssignmentsTable()')) {
      throw const ScrapeException(FailureKind.structureChanged, '『$_unsubmittedAlt』ボタンまたは課題表が見つかりません');
    }
    final items = parseAssignments(await s.html(), base: await s.currentUrl());
    if (items == null) throw const ScrapeException(FailureKind.structureChanged, '課題表を解析できません');
    log('manaba: 未提出 ${items.length}件');

    // 科目の詳細から manaba のコースページを開けるよう、マイページのコース一覧も読む(失敗しても課題は返す)
    var courses = <String, String>{};
    try {
      final home = await s.jsAsync(r'''
        const res = await fetch('/ct/home', { credentials: 'include' });
        return res.ok ? await res.text() : null;
      ''');
      if (home is String) courses = parseManabaCourses(home);
      log('manaba: コース一覧 ${courses.length}件');
    } catch (e) {
      log('manaba: コース一覧を取得できませんでした(${e.runtimeType})');
    }
    return (items, courses);
  } finally {
    await s.dispose();
  }
}

/// 教室: TWINS「ダウンロード」の kdb_ja.xlsx を取得し、codes の科目の教室を返す(利用者のボタン操作でのみ実行)。
const _downloadMenuText = 'ダウンロード';
const kdbXlsxName = 'kdb_ja.xlsx';

/// 「ダウンロード」画面でリンクが見つからないときに使う既知のリンク(fileId は年度で変わる可能性がある)。
const kdbXlsxFallbackHref = '/campusweb/campussquare.do?_flowId=SDW-filerefer-flow&fileId=1183';

Future<Map<String, String>> fetchRooms(CredentialStore store, Set<String> codes, {required Log log}) async {
  final s = await WebSession.open(twinsUrl, log: log);
  try {
    await ensureLoggedIn(s, "!!document.querySelector('span.menunm')", store);
    final linkJs =
        "!!Array.from(document.querySelectorAll('a')).find((a) => a.textContent.trim() === ${jsonEncode(kdbXlsxName)})";
    final opened = await s.clickAndWait('TS.clickMenu(${jsonEncode(_downloadMenuText)})', linkJs);
    log('教室: 「ダウンロード」画面 ${opened ? '開けた' : '開けない(既知のリンクで試す)'}');

    // ページ内で(ログイン中のセッションのまま) xlsx を GET し、base64 で受け取る
    final r = await s.jsAsync(
      r"""
      const a = Array.from(document.querySelectorAll('a')).find((x) => x.textContent.trim() === name);
      const href = a ? a.getAttribute('href') : fallback;
      const u = new URL(href, location.href);
      if (u.origin !== location.origin) return { error: 'other-origin' };
      const res = await fetch(u.href, { credentials: 'include' });
      const buf = new Uint8Array(await res.arrayBuffer());
      if (buf.length < 4 || buf[0] !== 0x50 || buf[1] !== 0x4b) {
        return { error: 'not-xlsx', status: res.status, type: res.headers.get('content-type') };
      }
      let bin = '';
      for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
      return { b64: btoa(bin), size: buf.length, fromLink: !!a };
    """,
      arguments: {'name': kdbXlsxName, 'fallback': kdbXlsxFallbackHref},
    );

    final m = (r as Map?) ?? const {};
    if (m['b64'] == null) {
      throw ScrapeException(FailureKind.structureChanged, '$kdbXlsxName を取得できませんでした(${m['error'] ?? '不明'})');
    }
    final bytes = base64.decode(m['b64'] as String);
    log('教室: $kdbXlsxName ${(bytes.length / 1024).round()}KB(${m['fromLink'] == true ? '画面のリンク' : '既知のリンク'})');
    final rooms = await compute(_parseRooms, (bytes, codes));
    log('教室: ${codes.length}科目中 ${rooms.length}科目の教室が分かりました');
    return rooms;
  } on FormatException catch (e) {
    throw ScrapeException(FailureKind.structureChanged, '$kdbXlsxName を読めませんでした(${e.message})');
  } finally {
    await s.dispose();
  }
}

Map<String, String> _parseRooms((List<int>, Set<String>) a) => parseKdbRooms(a.$1, codes: a.$2);
