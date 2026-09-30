# Dart 移植スケッチ (未検証)

> **この中のコードはDartで実行していません。** Python PoC(`python_poc/`)のロジックを移植した下書きです。
> 正しさの基準は `fixtures/` + `expected/` のゴールデンテスト。**テストを先に書き、通るまで直すこと。**

依存(推奨): `html`(パース), `timezone` + `flutter_timezone`, `flutter_local_notifications`, `drift` or `sqflite`,
`flutter_secure_storage`, `flutter_inappwebview`, `riverpod`。

---

## 1. モデル

```dart
class Slot {
  final String year, code, name, teacher;
  final int day;     // 1=月 … 7=日 (DeleteCallA の第4引数)
  final int period;  // 1..6      (DeleteCallA の第5引数)
  const Slot(this.year, this.code, this.name, this.teacher, this.day, this.period);
}

class TabInfo { final String label; final bool selected; const TabInfo(this.label, this.selected); }

class Assignment {
  final String id;          // 例: course_1000001_survey_9000001 (重複判定キー)
  final String type, title, url, course, courseUrl;
  final String? start, due; // "yyyy-MM-dd HH:mm" / due==null は期限なし
  const Assignment(this.id, this.type, this.title, this.url, this.course, this.courseUrl, this.start, this.due);
}
```

## 2. パーサー (package:html)

```dart
import 'package:html/parser.dart' as hp;
import 'package:html/dom.dart';

final _deleteRe = RegExp(r"DeleteCallA\('([^']*)','([^']*)','([^']*)','(\d+)','(\d+)'\)");

Element? _closest(Element e, String tag) {
  Element? p = e.parent;
  while (p != null && p.localName != tag) { p = p.parent; }
  return p;
}

/// <br>区切りを保つため、Text ノード単位で集める (BeautifulSoup の get_text("\n") 相当)。コメントは含まれない。
void _texts(Node n, List<String> out) {
  if (n is Text) { out.add(n.data); return; }
  for (final c in n.nodes) { _texts(c, out); }
}

/// 時間割表 → スロット。表が無いページなら null。
List<Slot>? parseTimetable(String htmlText) {
  final table = hp.parse(htmlText).querySelector('table.rishu-koma'); // 内側は rishu-koma-inner なので外側だけ一致
  if (table == null) return null;
  final byKey = <String, Slot>{};
  for (final a in table.querySelectorAll('a')) {
    final m = _deleteRe.firstMatch(a.attributes['onclick'] ?? '');
    if (m == null) continue;                       // 未登録(InputCallA)は無視
    final td = _closest(a, 'td');
    if (td == null) continue;
    final raw = <String>[]; _texts(td, raw);
    final lines = raw.expand((s) => s.split('\n')).map((s) => s.trim())
        .where((s) => s.isNotEmpty && !s.contains('シラバス')).toList();
    final slot = Slot(m[1]!, m[3]!,
        lines.length > 1 ? lines[1] : '',          // lines[0]=科目番号, [1]=科目名, [2..]=教員
        lines.length > 2 ? lines.sublist(2).join('、') : '',
        int.parse(m[4]!), int.parse(m[5]!));
    byKey['${slot.day}|${slot.period}|${slot.code}'] = slot;
  }
  final list = byKey.values.toList()
    ..sort((a, b) => a.day != b.day ? a.day - b.day : a.period != b.period ? a.period - b.period : a.code.compareTo(b.code));
  return list;
}

List<TabInfo> parseTabs(String htmlText) => hp.parse(htmlText)
    .querySelectorAll('td.rishu-tab, td.rishu-tab-sel')
    .map((td) => TabInfo(td.text.trim(), td.classes.contains('rishu-tab-sel')))
    .toList();

/// manaba 未提出課題。表が無ければ null。締切昇順(期限なしは最後)。
List<Assignment>? parseAssignments(String htmlText, Uri base) {
  final table = hp.parse(htmlText).querySelector('table.stdlist');
  if (table == null) return null;
  final items = <Assignment>[];
  for (final tr in table.querySelectorAll('tr')) {
    final titleA = tr.querySelector('.myassignments-title a');
    if (titleA == null) continue;                  // ヘッダー行
    final tds = tr.children.where((c) => c.localName == 'td').toList();
    final courseA = tr.querySelector('.mycourse-title a');
    final periods = tr.querySelectorAll('td.td-period').map((e) => e.text.trim()).toList(); // td-period-responsive は別クラス
    while (periods.length < 2) { periods.add(''); }
    final href = titleA.attributes['href'] ?? '';
    String? nz(String s) => s.isEmpty ? null : s;
    items.add(Assignment(
      href.split('?').first,
      tds.isEmpty ? '' : tds.first.text.trim(),
      titleA.text.trim(),
      base.resolve(href).toString(),
      courseA?.text.trim() ?? '',
      courseA == null ? '' : base.resolve(courseA.attributes['href'] ?? '').toString(),
      nz(periods[0]), nz(periods[1]),
    ));
  }
  items.sort((a, b) {
    if ((a.due == null) != (b.due == null)) return a.due == null ? 1 : -1;
    return (a.due ?? '').compareTo(b.due ?? '');
  });
  return items;
}
```

**ゴールデンテスト**: `fixtures/twins_registration.html` → `expected/twins_registration.json` (`tabs` と `slots`)、
`fixtures/manaba_unsubmitted.html` → `expected/manaba_unsubmitted.json`。JSONのキーは Python PoC の出力と同名(`day` は「月」等の文字列、`day_index` が数値)。
Dart側のモデルは自由だが、テストでは正規化して比較する。

## 3. 今日の学期(モジュール)判定と授業ブロック生成

```dart
/// date に対する有効モジュール名を返す。範囲外は null(夏休/春休や授業期間外)。
String? moduleOn(DateTime date, AcademicCalendar cal) { /* cal.modules の start<=date<=end */ }

/// 振替日対応: その日が「何曜日の授業を行う日か」。override があればそちら、無ければ実際の曜日。
int effectiveWeekday(DateTime date, AcademicCalendar cal) =>
    cal.weekdayOverrides[dateKey(date)] ?? date.weekday;   // Dart: 月=1..日=7 で DeleteCallA の day と一致

/// 連続する時限を1ブロックに結合 (例: 1限+2限 → 開始は1限の 08:40)。非連続(2限と5限)は別ブロック。
class ClassBlock {
  final String code, name;
  final int firstPeriod, lastPeriod;
  final DateTime start;   // tz.TZDateTime(Asia/Tokyo)
  ClassBlock(this.code, this.name, this.firstPeriod, this.lastPeriod, this.start);
}

List<ClassBlock> blocksFor(DateTime date, AcademicCalendar cal, Map<String, List<Slot>> slotsByModule, PeriodTimes times) {
  if (cal.isNoClassDate(date)) return [];
  final module = moduleOn(date, cal);
  if (module == null) return [];
  final day = effectiveWeekday(date, cal);
  final todays = (slotsByModule[module] ?? []).where((s) => s.day == day).toList()
    ..sort((a, b) => a.code != b.code ? a.code.compareTo(b.code) : a.period - b.period);
  final blocks = <ClassBlock>[];
  for (final s in todays) {
    if (blocks.isNotEmpty && blocks.last.code == s.code && blocks.last.lastPeriod == s.period - 1) {
      final b = blocks.removeLast();
      blocks.add(ClassBlock(b.code, b.name, b.firstPeriod, s.period, b.start));
    } else {
      blocks.add(ClassBlock(s.code, s.name, s.period, s.period, times.startOn(date, s.period)));
    }
  }
  blocks.sort((a, b) => a.start.compareTo(b.start));
  return blocks;
}
```

## 4. 通知プラン (純粋関数にしてテストしやすくする)

```dart
class PlannedNotification {
  final int id;             // 予定日+科目+時限から決定的に作る 31bit ハッシュ(再スケジュールで重複しない)
  final DateTime fireAt;    // block.start - leadMinutes
  final String title, body, payload;   // payload = 科目番号 (タップでシラバス画面へ)
  ...
}

/// now から windowDays 日先まで。fireAt が過去のものは除外。近い順に最大 maxPending 件(iOS上限64のため60推奨)。
List<PlannedNotification> planNotifications({
  required DateTime now, required int leadMinutes, required int windowDays, int maxPending = 60,
  required AcademicCalendar cal, required Map<String, List<Slot>> slotsByModule, required PeriodTimes times,
}) { /* 日ごとに blocksFor → fireAt=start-lead → 過去除外 → ソート → take(maxPending) */ }
```

再スケジュールは常に **「全キャンセル → planNotifications の結果を全登録」** (差分更新しない・冪等)。
トリガー: アプリ起動 / 時間割更新成功 / 設定変更 / 学年暦更新 / (SHOULD) バックグラウンド定期実行。

本文例: タイトル `サンプル科目α` / 本文 `10分後 08:40 開始（1・2限）`。

## 5. 更新の状態機械 (WebView)

```
idle
 └ refresh() ─► ensureSession
      ├ ログイン画面でない ─────────────────► scrape
      ├ ログイン画面 & 認証情報あり & 失敗フラグ無し ─► autofill(1回だけ)
      │       ├ 成功 ──► scrape
      │       └ 失敗 ──► setFailFlag ─► needsUserLogin
      └ ログイン画面 & (認証情報なし or 失敗フラグ有り) ─► needsUserLogin (可視WebViewで手動ログイン)
scrape(TWINS): clickMenu → 表待ち → listTabs → 各タブ: (選択中でなければ clickTab → 表待ち) → getHtml → parseTimetable
scrape(manaba): goto home_library_query → clickImageButton → 表待ち → getHtml → parseAssignments
共通: パース結果が null/0件 → 既存データを上書きせず「取得失敗」バナー。成功時のみ DB を置換し、通知を再スケジュール。
```

失敗フラグ: 自動ログイン失敗後は、ユーザーが設定画面で認証情報を更新するか「再試行」を押すまで自動入力しない
(パスワード誤りの連続試行によるアカウントロック防止。PoCの `.autofill_failed` と同じ考え方)。
