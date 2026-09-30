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
}
