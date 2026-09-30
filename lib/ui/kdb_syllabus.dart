/// Android: KdB をアプリ内で開き、科目番号で検索して該当する結果を開く(ユーザー操作起点で1科目1回)。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../scraper/web_session.dart';
import 'web_page.dart';

final kdbUrl = Uri.parse('https://kdb.tsukuba.ac.jp/');

void openSyllabusInApp(BuildContext context, String code, String name) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => WebPage(url: kdbUrl, title: name, onFirstLoad: (c) => _kdbAutopilot(c, code, name, context)),
    ),
  );
}

Future<void> _kdbAutopilot(InAppWebViewController c, String code, String name, BuildContext context) async {
  if (await evalWithSnippets(c, 'KDB.search(${jsonEncode(code)})') != true) return;
  // 検索結果(同じページ内で描画される)を最大10秒待つ
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final r = await evalWithSnippets(c, 'KDB.listResults()');
    final n = r is String ? (jsonDecode(r) as List).length : 0;
    if (n > 0) {
      await evalWithSnippets(c, 'KDB.clickResult(${jsonEncode(name)})');
      return;
    }
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('KdBで「$code」が見つかりませんでした。画面で検索してください')));
  }
}
