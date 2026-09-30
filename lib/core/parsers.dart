/// 大学サイトの HTML パーサー(純Dart)。セレクタ・正規表現はここに集約する。
///
/// 表が見つからない場合は null を返す。呼び出し側は null/0件のとき既存データを上書きしないこと。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as hp;

import 'models.dart';

final _deleteRe = RegExp(r"DeleteCallA\('([^']*)','([^']*)','([^']*)','(\d+)','(\d+)'\)");

/// 子孫の Text ノードを順に集める(コメントは含まない)。
void _texts(Node n, List<String> out) {
  if (n is Text) {
    out.add(n.data);
    return;
  }
  for (final c in n.nodes) {
    _texts(c, out);
  }
}

/// BeautifulSoup の get_text(strip=True) 相当: 各テキストを trim して空を除き、区切りなしで連結。
String _strippedText(Element e) {
  final raw = <String>[];
  _texts(e, raw);
  return raw.map((s) => s.trim()).where((s) => s.isNotEmpty).join();
}

Element? _closest(Element e, String tag) {
  var p = e.parent;
  while (p != null && p.localName != tag) {
    p = p.parent;
  }
  return p;
}

/// TWINS「履修登録・登録状況照会」の時間割表 → コマ一覧(曜日・時限・科目番号順)。
///
/// 登録済みのマスは2通りある:
/// - 取消できる期間: 科目番号が `DeleteCallA('年度','?','科目番号','曜日','時限')` のリンク → 引数から読む
/// - 授業が始まり取消できなくなった後: リンクが無く文字だけ → 表の位置(行=時限, 列=曜日)とマスの文字から読む
List<Slot>? parseTimetable(String htmlText) {
  // 内側の表は rishu-koma-inner なので、クラス完全一致の外側の表だけを拾う。
  final table = hp.parse(htmlText).querySelector('table.rishu-koma');
  if (table == null) return null;

  final byKey = <String, Slot>{};
  String? pageYear;
  for (final a in table.querySelectorAll('a')) {
    final m = _deleteRe.firstMatch(a.attributes['onclick'] ?? '');
    if (m == null) continue; // 未登録コマ(InputCallA)は無視
    final td = _closest(a, 'td');
    if (td == null) continue;
    final lines = _cellLines(td);
    final slot = Slot(
      year: m[1]!,
      code: m[3]!,
      name: lines.length > 1 ? lines[1] : '',
      teacher: lines.length > 2 ? lines.sublist(2).join('、') : '',
      day: int.parse(m[4]!),
      period: int.parse(m[5]!),
    );
    pageYear ??= slot.year;
    byKey['${slot.day}|${slot.period}|${slot.code}'] = slot;
  }

  // 取消リンクの無い登録済みマス(授業開始後のモジュール)を表の位置から読む
  final body = table.children.where((c) => c.localName == 'tbody').firstOrNull ?? table;
  for (final tr in body.children.where((c) => c.localName == 'tr')) {
    final tds = tr.children.where((c) => c.localName == 'td').toList();
    if (tds.length < 2) continue;
    final pm = _periodHeadRe.firstMatch(_strippedText(tds.first));
    if (pm == null) continue; // 曜日の見出し行など
    final period = int.parse(pm[1]!);
    for (var i = 1; i < tds.length && i <= 7; i++) {
      final cell = tds[i];
      if (cell.querySelectorAll('a').any((a) => _deleteRe.hasMatch(a.attributes['onclick'] ?? ''))) continue;
      final lines = _cellLines(cell).where((l) => l != '未登録').toList();
      if (lines.length < 2 || !_courseCodeRe.hasMatch(lines[0])) continue;
      final slot = Slot(
        year: pageYear ?? '',
        code: lines[0],
        name: lines[1],
        teacher: lines.length > 2 ? lines.sublist(2).join('、') : '',
        day: i,
        period: period,
      );
      byKey.putIfAbsent('${slot.day}|${slot.period}|${slot.code}', () => slot);
    }
  }

  return byKey.values.toList()..sort((a, b) {
    if (a.day != b.day) return a.day - b.day;
    if (a.period != b.period) return a.period - b.period;
    return a.code.compareTo(b.code);
  });
}

final _periodHeadRe = RegExp(r'^(\d)限$');
final _courseCodeRe = RegExp(r'^[0-9A-Za-z]{5,10}$');

/// マスの文字を行に分ける: [科目番号, 科目名, 教員...](「シラバス」の行は除く)。
List<String> _cellLines(Element td) {
  final raw = <String>[];
  _texts(td, raw);
  return raw
      .expand((s) => s.split('\n'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && !s.contains('シラバス'))
      .toList();
}

/// TWINS の学期タブ(選択中のタブはリンクを持たない)。
List<TabInfo> parseTabs(String htmlText) => hp
    .parse(htmlText)
    .querySelectorAll('td.rishu-tab, td.rishu-tab-sel')
    .map((td) => TabInfo(_strippedText(td), td.classes.contains('rishu-tab-sel')))
    .toList();

final manabaBase = Uri.parse('https://manaba.tsukuba.ac.jp/ct/home_library_query');

/// manaba『未提出の課題一覧』の table.stdlist → 課題一覧(締切昇順、期限なしは最後)。
List<Assignment>? parseAssignments(String htmlText, {Uri? base}) {
  final b = base ?? manabaBase;
  final table = hp.parse(htmlText).querySelector('table.stdlist');
  if (table == null) return null;

  String? nz(String s) => s.isEmpty ? null : s;
  final items = <Assignment>[];
  for (final tr in table.querySelectorAll('tr')) {
    final titleA = tr.querySelector('.myassignments-title a');
    if (titleA == null) continue; // ヘッダー行など
    final tds = tr.children.where((c) => c.localName == 'td').toList();
    final courseA = tr.querySelector('.mycourse-title a');
    // td.td-period は 受付開始/受付終了 の2セル(td-period-responsive は別クラス)
    final periods = tr.querySelectorAll('td.td-period').map(_strippedText).toList();
    while (periods.length < 2) {
      periods.add('');
    }
    final href = titleA.attributes['href'] ?? '';
    items.add(
      Assignment(
        id: href.split('?').first,
        type: tds.isEmpty ? '' : _strippedText(tds.first),
        title: _strippedText(titleA),
        url: b.resolve(href).toString(),
        course: courseA == null ? '' : _strippedText(courseA),
        courseUrl: courseA == null ? '' : b.resolve(courseA.attributes['href'] ?? '').toString(),
        start: nz(periods[0]),
        due: nz(periods[1]),
      ),
    );
  }
  items.sort((x, y) {
    if ((x.due == null) != (y.due == null)) return x.due == null ? 1 : -1;
    return (x.due ?? '').compareTo(y.due ?? '');
  });
  return items;
}

// ---------------------------------------------------------------- シラバス(KdB)
// KdB の画面構造は未確認。本文テキストを項目名で分割するだけにとどめる。

const syllabusHeadings = [
  '科目番号',
  '科目名',
  '授業方法',
  '単位数',
  '標準履修年次',
  '時間割',
  '開講年度',
  '担当教員',
  '授業概要',
  '到達目標',
  'キーワード',
  '授業計画',
  '履修条件',
  '成績評価方法',
  '教科書',
  '参考書',
  '教科書・参考書',
  'オフィスアワー',
  '備考',
  '要旨',
  '実務経験',
];

String cleanSyllabusText(String text) {
  final t = text.replaceAll('\r', '').replaceAll(' ', ' ').split('\n').map((l) => l.trimRight()).join('\n');
  return t.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// 行頭が項目名の行で区切って {項目名: 本文} にする。同名は連結。本文が空の項目は除く。
Map<String, String> splitSyllabusSections(String text) {
  final heads = [...syllabusHeadings]..sort((a, b) => b.length - a.length);
  final pat = RegExp('^(${heads.map(RegExp.escape).join('|')})[\\t :：]*(.*)\$');
  final sections = <String, List<String>>{};
  String? current;
  for (final line in text.split('\n')) {
    final m = pat.firstMatch(line.trim());
    if (m != null) {
      current = m[1]!;
      sections.putIfAbsent(current, () => []);
      if (m[2]!.isNotEmpty) sections[current]!.add(m[2]!);
    } else if (current != null) {
      sections[current]!.add(line);
    }
  }
  return {
    for (final e in sections.entries)
      if (e.value.any((x) => x.trim().isNotEmpty)) e.key: cleanSyllabusText(e.value.join('\n')),
  };
}

// ---------------------------------------------------------------- manaba のコース一覧(/ct/home)

final _courseHrefRe = RegExp(r'(^|/)(course_\d+)$');

/// manaba「マイページ」(/ct/home)のコースへのリンク → {コース名: コースURL}。
/// `<a href="course_4117498" title="科目名">` の形(title が無ければリンクの文字)。
Map<String, String> parseManabaCourses(String htmlText, {Uri? base}) {
  final b = base ?? Uri.parse('https://manaba.tsukuba.ac.jp/ct/home');
  final out = <String, String>{};
  for (final a in hp.parse(htmlText).querySelectorAll('a[href]')) {
    final href = (a.attributes['href'] ?? '').split('?').first.split('#').first;
    if (!_courseHrefRe.hasMatch(href)) continue;
    // 名前: title → リンクの文字 → 画像の alt/title(サムネイル表示)の順
    final img = a.querySelector('img');
    final name = [
      a.attributes['title'],
      _strippedText(a),
      img?.attributes['alt'],
      img?.attributes['title'],
    ].map((x) => (x ?? '').trim()).firstWhere((x) => x.isNotEmpty, orElse: () => '');
    if (name.isEmpty) continue;
    out.putIfAbsent(name, () => b.resolve(href).toString());
  }
  return out;
}

/// 科目名の照合用: 全角英数記号を半角に、空白を除き、小文字にする(TWINS と manaba の表記ゆれ対策)。
String normalizeCourseName(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) {
      buf.writeCharCode(r - 0xFEE0);
    } else if (r == 0x3000 || r == 0x20 || r == 0x09 || r == 0x0A || r == 0x0D) {
      continue;
    } else {
      buf.writeCharCode(r);
    }
  }
  return buf.toString().toLowerCase();
}

/// TWINS の科目名 name に対応する manaba のコース URL。完全一致(表記ゆれを除く)が無ければ null。
String? findManabaCourse(Map<String, String> courses, String name) {
  final key = normalizeCourseName(name);
  if (key.isEmpty) return null;
  for (final e in courses.entries) {
    if (normalizeCourseName(e.key) == key) return e.value;
  }
  return null;
}
