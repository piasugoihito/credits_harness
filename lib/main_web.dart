/// Web 版のエントリーポイント(flutter build web -t lib/main_web.dart)。
///
/// ブックマークレットから #import=... 付きで開かれたら取り込み、フラグメントはすぐに URL と履歴から消す。
library;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'web/import_payload.dart';
import 'web/web_home.dart';
import 'web/web_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Flutter のルーティングが読む前に取り出して消す(取り込みデータを履歴・共有URLに残さない)
  final value = importValueFromFragment(web.window.location.hash);
  if (value != null) {
    web.window.history.replaceState(null, '', '${web.window.location.pathname}${web.window.location.search}');
  }

  final state = await WebState.load();
  String? message;
  var failed = false;
  if (value != null) {
    try {
      message = await state.applyImport(value);
    } on ImportException catch (e) {
      message = '取り込めませんでした: ${e.message}';
      failed = true;
    }
  }

  runApp(
    MaterialApp(
      title: '単位ハーネス',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
      home: WebHome(state: state, importMessage: message, importFailed: failed),
    ),
  );
}
