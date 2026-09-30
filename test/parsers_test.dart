import 'dart:convert';
import 'dart:io';

import 'package:credits_harness/core/parsers.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();
Object? _json(String path) => jsonDecode(_read(path));

void main() {
  group('TWINS 時間割 (ゴールデン)', () {
    final html = _read('test/fixtures/twins_registration.html');
    final expected = _json('test/expected/twins_registration.json') as Map<String, Object?>;

    test('タブが Python PoC と一致', () {
      expect(parseTabs(html).map((t) => t.toJson()).toList(), expected['tabs']);
    });

    test('コマが Python PoC と一致', () {
      expect(parseTimetable(html)!.map((s) => s.toJson()).toList(), expected['slots']);
    });

    test('表が無いページは null', () {
      expect(parseTimetable('<html><body><p>ログイン</p></body></html>'), isNull);
    });

    test('授業開始後(取消リンクが無い)でも、表の位置と文字から同じコマを読む', () {
      // 取消リンクを外して文字だけにする(授業が始まったモジュールの表示を想定)
      final locked = html.replaceAllMapped(
        RegExp(r'<a href="" onclick="return DeleteCallA\([^)]*\)">([\s\S]*?)</a>'),
        (m) => m[1]!,
      );
      expect(locked.contains('DeleteCallA'), isFalse);
      final slots = parseTimetable(locked)!;
      final expectedSlots = (expected['slots'] as List).map((e) => {...(e as Map), 'year': ''}).toList();
      expect(slots.map((s) => s.toJson()).toList(), expectedSlots);
    });

    test('取消リンクのあるマスと無いマスが混在しても両方読む(年度はリンクから補う)', () {
      final mixed = html.replaceAllMapped(
        RegExp(r'<a href="" onclick="return DeleteCallA\([^)]*ZZ10005[^)]*\)">([\s\S]*?)</a>'),
        (m) => m[1]!,
      );
      final slots = parseTimetable(mixed)!;
      expect(slots.map((s) => s.toJson()).toList(), expected['slots']);
    });

    test('内側の表(rishu-koma-inner)だけでは表とみなさない', () {
      expect(parseTimetable('<table class="rishu-koma-inner"><tr><td></td></tr></table>'), isNull);
    });

    test('未登録コマ(InputCallA)と未知の onclick は無視', () {
      const h = '''<table class="rishu-koma"><tr>
        <td><a onclick="InputCallA('1','1')">登録</a></td>
        <td><a onclick="DeleteCallA('2026','25','AB12345','3','4')">x</a>AB12345<br>科目<br>先生</td>
      </tr></table>''';
      final slots = parseTimetable(h)!;
      expect(slots, hasLength(1));
      expect(slots.single.day, 3);
      expect(slots.single.period, 4);
    });
  });

  group('manaba 未提出課題 (ゴールデン)', () {
    final html = _read('test/fixtures/manaba_unsubmitted.html');
    final expected = _json('test/expected/manaba_unsubmitted.json');

    test('Python PoC と一致', () {
      expect(parseAssignments(html)!.map((a) => a.toJson()).toList(), expected);
    });

    test('表が無いページは null', () {
      expect(parseAssignments('<html><body></body></html>'), isNull);
    });
  });

  group('シラバス本文の分割', () {
    test('項目名で分割し、長い項目名を優先する', () {
      const text = '授業概要：これは概要\n続き\n\n\n\n教科書・参考書\n本A\n備考';
      final s = splitSyllabusSections(text);
      expect(s['授業概要'], 'これは概要\n続き');
      expect(s['教科書・参考書'], '本A');
      expect(s.containsKey('教科書'), isFalse);
      expect(s.containsKey('備考'), isFalse, reason: '本文が空の項目は除く');
    });

    test('cleanSyllabusText は空行を2つまでに詰める', () {
      expect(cleanSyllabusText(' a \r\n\n\n\nb  \n'), 'a\n\nb');
    });
  });

  group('manaba のコース一覧', () {
    // 架空データ(実際の /ct/home のリンクの形を模したもの)
    const html = '''<div>
      <a href="course_4117498" title="サンプル科目α">サンプル科目α</a>
      <a href="course_4117498">サンプル科目α</a>
      <a href="course_4000001"><span>サンプル演習（基礎）</span></a>
      <a href="course_4117498_report_123" title="レポート">x</a>
      <a href="home_library_query">未提出</a>
      <a href="https://manaba.tsukuba.ac.jp/ct/course_4000002?x=1" title=" 英語 A ">英語</a>
      <a href="course_4000003"><img src="x.png" alt="サンプル実験"></a>
    </div>''';

    test('course_数字 のリンクだけを 名前→URL にする', () {
      expect(parseManabaCourses(html), {
        'サンプル科目α': 'https://manaba.tsukuba.ac.jp/ct/course_4117498',
        'サンプル演習（基礎）': 'https://manaba.tsukuba.ac.jp/ct/course_4000001',
        '英語 A': 'https://manaba.tsukuba.ac.jp/ct/course_4000002',
        'サンプル実験': 'https://manaba.tsukuba.ac.jp/ct/course_4000003',
      });
    });

    test('全角/半角・空白の違いを無視して照合し、部分一致はしない', () {
      final c = parseManabaCourses(html);
      expect(findManabaCourse(c, 'サンプル演習(基礎)'), 'https://manaba.tsukuba.ac.jp/ct/course_4000001');
      expect(findManabaCourse(c, 'ｻﾝﾌﾟﾙ科目α'), isNull, reason: '半角カナまでは変換しない');
      expect(findManabaCourse(c, '英語Ａ'), 'https://manaba.tsukuba.ac.jp/ct/course_4000002');
      expect(findManabaCourse(c, 'サンプル科目'), isNull);
      expect(findManabaCourse(c, ''), isNull);
    });
  });
}
