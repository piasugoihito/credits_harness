import 'dart:io';

import 'package:credits_harness/core/kdb_rooms.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bytes = File('test/fixtures/kdb_sample.xlsx').readAsBytesSync();

  test('6行目以降の A=科目番号, H=教室 を読む(共有文字列・インライン・リッチテキスト・数値)', () {
    expect(parseKdbRooms(bytes), {
      'ZZ10001': '3A204',
      'ZZ10002': '1H101・1H102',
      'ZZ10003': '2B305',
      'ZZ99999': 'Y001',
      '12345': '9Z999',
    });
  });

  test('見出し行(5行目まで)と教室が空の科目は含めない', () {
    final r = parseKdbRooms(bytes);
    expect(r.containsKey('科目番号'), isFalse);
    expect(r.containsKey('ZZ10004'), isFalse);
  });

  test('指定した科目だけに絞る', () {
    expect(parseKdbRooms(bytes, codes: {'ZZ10001', 'ZZ10004', 'NOPE'}), {'ZZ10001': '3A204'});
  });

  test('xlsx でなければ FormatException', () {
    expect(() => parseKdbRooms('<html>ログイン</html>'.codeUnits), throwsFormatException);
  });

  test('normalizeRoom', () {
    expect(normalizeRoom(' 3A204 \r\n\n 3A  205 '), '3A204・3A 205');
    expect(normalizeRoom('  '), '');
  });
}
