/// Web 版: ブックマークレットから URL フラグメント(#import=...)で受け取ったデータの復号と解析(純Dart)。
///
/// 形式: `#import=<方式>.<base64url>`
///   方式 z = JSON を zlib 圧縮(CompressionStream('deflate'))、j = 無圧縮 JSON。
/// JSON:
///   TWINS:  {"v":1,"kind":"twins","current":"秋A","tabs":[{"label":"春A","html":"<table class=\"rishu-koma\">…"}]}
///   manaba: {"v":1,"kind":"manaba","base":"https://manaba…","html":"<table class=\"stdlist\">…"}
///   教室:   {"v":1,"kind":"rooms","rooms":{"3A204":["FA01111","GB12345"],…}}(kdb_ja.xlsx から。教室ごとにまとめて小さくする)
/// HTML の解析はアプリ側のパーサー(ゴールデンテスト済み)で行う。
library;

import 'dart:convert';

import 'package:archive/archive.dart';

import '../core/kdb_rooms.dart';
import '../core/models.dart';
import '../core/parsers.dart';

const importFormatVersion = 1;

sealed class ImportResult {
  const ImportResult();
}

class TwinsImport extends ImportResult {
  final Map<String, List<Slot>> slotsByModule;
  final String? currentModule;
  const TwinsImport(this.slotsByModule, this.currentModule);
}

class ManabaImport extends ImportResult {
  final List<Assignment> items;
  const ManabaImport(this.items);
}

class RoomsImport extends ImportResult {
  /// 科目番号 → 教室
  final Map<String, String> rooms;
  const RoomsImport(this.rooms);
}

class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}

/// フラグメント全体(先頭の # の有無は問わない)から import= の値を取り出す。無ければ null。
String? importValueFromFragment(String fragment) {
  final f = fragment.startsWith('#') ? fragment.substring(1) : fragment;
  if (!f.startsWith('import=')) return null;
  return f.substring('import='.length);
}

Object? _decodeJson(String value) {
  final dot = value.indexOf('.');
  if (dot != 1) throw const ImportException('取り込みデータの形式が正しくありません');
  final method = value[0];
  var b64 = Uri.decodeComponent(value.substring(2)).replaceAll('-', '+').replaceAll('_', '/');
  b64 = b64.padRight((b64.length + 3) ~/ 4 * 4, '=');
  final List<int> bytes;
  try {
    final raw = base64.decode(b64);
    bytes = switch (method) {
      'z' => const ZLibDecoder().decodeBytes(raw),
      'j' => raw,
      _ => throw const ImportException('未対応の取り込み形式です'),
    };
  } on ImportException {
    rethrow;
  } catch (_) {
    throw const ImportException('取り込みデータが壊れています(URLが途中で切れた可能性)');
  }
  try {
    return jsonDecode(utf8.decode(bytes));
  } catch (_) {
    throw const ImportException('取り込みデータを読めませんでした');
  }
}

ImportResult decodeImport(String value) {
  final j = _decodeJson(value);
  if (j is! Map) throw const ImportException('取り込みデータの形式が正しくありません');
  final v = j['v'];
  if (v is! int || v > importFormatVersion) {
    throw const ImportException('新しい形式のデータです。ページを再読み込みしてから取り込み直してください');
  }
  switch (j['kind']) {
    case 'twins':
      final tabs = j['tabs'];
      if (tabs is! List || tabs.isEmpty) throw const ImportException('学期タブが見つかりませんでした');
      final out = <String, List<Slot>>{};
      for (final t in tabs) {
        final label = (t as Map)['label'] as String;
        final slots = parseTimetable(t['html'] as String? ?? '');
        if (slots == null) throw ImportException('「$label」の時間割表を解析できませんでした');
        out[label] = slots;
      }
      if (out.values.every((x) => x.isEmpty)) {
        throw const ImportException('全学期で0コマでした(既存データは上書きしません)');
      }
      return TwinsImport(out, j['current'] as String?);
    case 'manaba':
      final base = Uri.tryParse(j['base'] as String? ?? '');
      final items = parseAssignments(j['html'] as String? ?? '', base: base);
      if (items == null) throw const ImportException('課題の表を解析できませんでした');
      return ManabaImport(items);
    case 'rooms':
      final grouped = j['rooms'];
      if (grouped is! Map) throw const ImportException('教室のデータが見つかりませんでした');
      final rooms = <String, String>{};
      for (final e in grouped.entries) {
        final room = normalizeRoom(e.key as String);
        if (room.isEmpty || e.value is! List) continue;
        for (final code in e.value as List) {
          rooms[(code as String).trim()] = room;
        }
      }
      if (rooms.isEmpty) throw const ImportException('教室が1件も見つかりませんでした');
      return RoomsImport(rooms);
    default:
      throw const ImportException('未対応のデータです');
  }
}
