/// 画面が読むデータ(Android アプリ・Web 版で共通)。
library;

import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/calendar.dart';
import '../core/models.dart';
import '../core/schedule.dart';
import '../data/store.dart';

abstract interface class CoursesModel implements Listenable {
  /// モジュール名 → コマ(TWINS のタブ順)
  Map<String, List<Slot>> get timetable;

  /// 今のモジュール(設定で固定 > TWINS で選択中のタブ)
  String? get currentModule;
  List<Assignment> get assignments;
  SyncState get twinsSync;
  SyncState get manabaSync;
  PeriodTimes get times;
  tz.Location get jst;
}

extension CoursesModelX on CoursesModel {
  List<String> get modules => timetable.keys.toList();

  tz.TZDateTime now() => tz.TZDateTime.now(jst);

  /// date に行われる授業(祝日・休講は考慮しない)。
  List<ClassBlock> blocksOn(DateTime date) => blocksFor(date, FixedModule(currentModule), timetable, times, jst);

  /// 科目の名前・教員・モジュールごとのコマ。
  ({String name, String teacher, List<(String module, List<Slot> slots)> byModule}) courseInfo(String code) {
    final byModule = <(String, List<Slot>)>[];
    for (final e in timetable.entries) {
      final xs = e.value.where((s) => s.code == code).toList();
      if (xs.isNotEmpty) byModule.add((e.key, xs));
    }
    final any = byModule.isEmpty ? null : byModule.first.$2.first;
    return (name: any?.name ?? code, teacher: any?.teacher ?? '', byModule: byModule);
  }
}
