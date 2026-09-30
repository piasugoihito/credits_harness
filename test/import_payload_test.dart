import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:credits_harness/web/import_payload.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as hp;

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _encode(Object json, {bool zlib = true}) {
  final raw = utf8.encode(jsonEncode(json));
  return zlib ? 'z.${_b64url(const ZLibEncoder().encode(raw))}' : 'j.${_b64url(raw)}';
}

void main() {
  final twinsHtml = File('test/fixtures/twins_registration.html').readAsStringSync();
  final table = hp.parse(twinsHtml).querySelector('table.rishu-koma')!.outerHtml;
  final expectedTwins = jsonDecode(File('test/expected/twins_registration.json').readAsStringSync()) as Map;
  final manabaTable = hp
      .parse(File('test/fixtures/manaba_unsubmitted.html').readAsStringSync())
      .querySelector('table.stdlist')!
      .outerHtml;

  test('フラグメントから値を取り出す', () {
    expect(importValueFromFragment('#import=z.abc'), 'z.abc');
    expect(importValueFromFragment('import=j.x'), 'j.x');
    expect(importValueFromFragment('#/'), isNull);
    expect(importValueFromFragment(''), isNull);
  });

  for (final zlib in [true, false]) {
    test('TWINS: 表のHTMLだけからゴールデンと同じコマになる (zlib=$zlib)', () {
      final value = _encode({
        'v': 1,
        'kind': 'twins',
        'current': '秋A',
        'tabs': [
          {'label': '春A', 'html': '<table class="rishu-koma"><tr><td></td></tr></table>'},
          {'label': '秋A', 'html': table},
        ],
      }, zlib: zlib);
      final r = decodeImport(value) as TwinsImport;
      expect(r.currentModule, '秋A');
      expect(r.slotsByModule.keys, ['春A', '秋A']);
      expect(r.slotsByModule['春A'], isEmpty);
      expect(r.slotsByModule['秋A']!.map((s) => s.toJson()).toList(), expectedTwins['slots']);
    });
  }

  test('manaba: ゴールデンと一致', () {
    final r = decodeImport(
      _encode({
        'v': 1,
        'kind': 'manaba',
        'base': 'https://manaba.tsukuba.ac.jp/ct/home_library_query',
        'html': manabaTable,
      }),
    ) as ManabaImport;
    expect(
      r.items.map((a) => a.toJson()).toList(),
      jsonDecode(File('test/expected/manaba_unsubmitted.json').readAsStringSync()),
    );
  });

  test('URLエンコードされた値も読める', () {
    final v = _encode({'v': 1, 'kind': 'manaba', 'base': '', 'html': manabaTable});
    expect(decodeImport(Uri.encodeComponent(v)), isA<ManabaImport>());
  });

  test('異常系: 0コマ・表なし・壊れたデータ・新しい版', () {
    expect(
      () => decodeImport(
        _encode({
          'v': 1,
          'kind': 'twins',
          'tabs': [
            {'label': '春A', 'html': '<table class="rishu-koma"></table>'},
          ],
        }),
      ),
      throwsA(isA<ImportException>()),
    );
    expect(
      () => decodeImport(
        _encode({
          'v': 1,
          'kind': 'twins',
          'tabs': [
            {'label': '春A', 'html': '<p>ログイン</p>'},
          ],
        }),
      ),
      throwsA(isA<ImportException>()),
    );
    expect(() => decodeImport(_encode({'v': 1, 'kind': 'manaba', 'html': '<p></p>'})), throwsA(isA<ImportException>()));
    expect(() => decodeImport('z.AAAA'), throwsA(isA<ImportException>()));
    expect(() => decodeImport('x'), throwsA(isA<ImportException>()));
    expect(() => decodeImport(_encode({'v': 99, 'kind': 'twins'})), throwsA(isA<ImportException>()));
  });
}
