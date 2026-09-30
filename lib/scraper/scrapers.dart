/// TWINS(時間割)・manaba(未提出課題)の取得。大学サイトに対しては読み取り専用。
///
/// 押す要素は許可リスト方式(メニュー・学期タブ・『未提出の課題一覧』ボタンのみ)。JS 側の assertSafe でも二重に確認する。
library;

import 'dart:convert';

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

    final result = <String, List<Slot>>{};
    for (final t in tabs) {
      final label = t['label'] as String;
      if (t['selected'] != true) {
        await Future<void>.delayed(const Duration(milliseconds: 600)); // サイト負荷への配慮
        final sel =
            "(function(){ const e = document.querySelector('td.rishu-tab-sel'); "
            "return !!e && e.textContent.trim() === ${jsonEncode(label)} && $hasTable; })()";
        if (!await s.clickAndWait('TS.clickTab(${jsonEncode(label)})', sel)) {
          throw ScrapeException(FailureKind.structureChanged, '学期タブ「$label」を開けませんでした');
        }
      }
      final slots = parseTimetable(await s.html());
      if (slots == null) throw ScrapeException(FailureKind.structureChanged, '「$label」の時間割表を解析できません');
      result[label] = slots;
      log('TWINS: $label ${slots.length}コマ');
    }
    if (result.values.every((x) => x.isEmpty)) {
      throw const ScrapeException(FailureKind.structureChanged, '全学期で0コマでした(既存データは上書きしません)');
    }
    return TimetableResult(result, current);
  } finally {
    await s.dispose();
  }
}

/// manaba の未提出課題一覧を取得する。
Future<List<Assignment>> fetchAssignments(CredentialStore store, {required Log log}) async {
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
    return items;
  } finally {
    await s.dispose();
  }
}
