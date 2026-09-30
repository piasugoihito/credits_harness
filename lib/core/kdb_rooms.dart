/// TWINS「ダウンロード」の kdb_ja.xlsx(全科目一覧)から、科目番号 → 教室 を取り出す(純Dart)。
///
/// 配置(利用者の確認による): 6行目から、A列=科目番号、H列=教室。
/// ファイルは1万行を超えるので、XML は DOM にせずイベントで読み流す。
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml_events.dart';

const kdbFirstDataRow = 6;
const kdbCodeColumn = 'A';
const kdbRoomColumn = 'H';

/// xlsx(zip)の中身から教室を取り出す。codes を渡すとその科目だけ返す。
/// 教室が空の科目は含めない。xlsx として読めなければ FormatException。
Map<String, String> parseKdbRooms(List<int> xlsxBytes, {Set<String>? codes}) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(xlsxBytes);
  } catch (_) {
    throw const FormatException('xlsx(zip)として読めません');
  }
  String? text(String name) {
    final f = zip.findFile(name);
    final bytes = f?.readBytes();
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  final sheetXml = text(_firstSheetPath(text)) ?? text('xl/worksheets/sheet1.xml');
  if (sheetXml == null) throw const FormatException('シートが見つかりません');
  final shared = _sharedStrings(text('xl/sharedStrings.xml'));

  final codeByRow = <int, String>{};
  final roomByRow = <int, String>{};
  String? ref;
  String? type;
  final value = StringBuffer();
  var inValue = false;

  for (final e in parseEvents(sheetXml)) {
    if (e is XmlStartElementEvent) {
      switch (e.localName) {
        case 'c':
          ref = _attr(e, 'r');
          type = _attr(e, 't');
          value.clear();
          if (e.isSelfClosing) ref = null;
        case 'v' || 't':
          inValue = ref != null;
      }
    } else if (e is XmlTextEvent || e is XmlCDATAEvent) {
      if (inValue) value.write(e is XmlTextEvent ? e.value : (e as XmlCDATAEvent).value);
    } else if (e is XmlEndElementEvent) {
      switch (e.localName) {
        case 'v' || 't':
          inValue = false;
        case 'c':
          final r = ref;
          ref = null;
          if (r == null) break;
          final m = _cellRef.firstMatch(r);
          if (m == null) break;
          final col = m[1]!;
          final row = int.parse(m[2]!);
          if (row < kdbFirstDataRow || (col != kdbCodeColumn && col != kdbRoomColumn)) break;
          var v = value.toString();
          if (type == 's') {
            final i = int.tryParse(v.trim());
            v = (i != null && i >= 0 && i < shared.length) ? shared[i] : '';
          }
          (col == kdbCodeColumn ? codeByRow : roomByRow)[row] = v;
      }
    }
  }

  final out = <String, String>{};
  for (final e in codeByRow.entries) {
    final code = e.value.trim();
    if (code.isEmpty || (codes != null && !codes.contains(code))) continue;
    final room = normalizeRoom(roomByRow[e.key] ?? '');
    if (room.isNotEmpty) out[code] = room;
  }
  if (codeByRow.isEmpty) throw const FormatException('科目番号の列が見つかりません');
  return out;
}

/// 複数行・余分な空白を「・」区切りの1行にする。
String normalizeRoom(String s) => s
    .split(RegExp(r'[\r\n]+'))
    .map((x) => x.trim().replaceAll(RegExp(r'\s+'), ' '))
    .where((x) => x.isNotEmpty)
    .join('・');

final _cellRef = RegExp(r'^([A-Z]+)(\d+)$');

String? _attr(XmlStartElementEvent e, String name) {
  for (final a in e.attributes) {
    if (a.localName == name) return a.value;
  }
  return null;
}

List<String> _sharedStrings(String? xml) {
  if (xml == null) return const [];
  final out = <String>[];
  final cur = StringBuffer();
  var inSi = false;
  var inT = false;
  var inRph = false; // ふりがな(rPh)は除く
  for (final e in parseEvents(xml)) {
    if (e is XmlStartElementEvent) {
      switch (e.localName) {
        case 'si':
          inSi = true;
          cur.clear();
          if (e.isSelfClosing) {
            out.add('');
            inSi = false;
          }
        case 'rPh':
          inRph = true;
        case 't':
          inT = inSi && !inRph && !e.isSelfClosing;
      }
    } else if (e is XmlTextEvent) {
      if (inT) cur.write(e.value);
    } else if (e is XmlEndElementEvent) {
      switch (e.localName) {
        case 't':
          inT = false;
        case 'rPh':
          inRph = false;
        case 'si':
          out.add(cur.toString());
          inSi = false;
      }
    }
  }
  return out;
}

/// workbook.xml の最初のシートの実ファイルのパス。分からなければ sheet1。
String _firstSheetPath(String? Function(String) text) {
  const fallback = 'xl/worksheets/sheet1.xml';
  final wb = text('xl/workbook.xml');
  final rels = text('xl/_rels/workbook.xml.rels');
  if (wb == null || rels == null) return fallback;
  String? rid;
  for (final e in parseEvents(wb)) {
    if (e is XmlStartElementEvent && e.localName == 'sheet') {
      rid = _attr(e, 'id');
      break;
    }
  }
  if (rid == null) return fallback;
  for (final e in parseEvents(rels)) {
    if (e is XmlStartElementEvent && e.localName == 'Relationship' && _attr(e, 'Id') == rid) {
      final target = _attr(e, 'Target');
      if (target == null) return fallback;
      return target.startsWith('/') ? target.substring(1) : 'xl/$target';
    }
  }
  return fallback;
}
