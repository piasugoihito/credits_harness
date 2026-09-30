/// Web 版の状態。データはこのブラウザ(localStorage)にだけ保存する。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../app/courses_model.dart';
import '../core/calendar.dart';
import '../core/models.dart';
import '../data/store.dart';
import 'import_payload.dart';

class WebState extends ChangeNotifier with RoomsState, ManabaCoursesState implements CoursesModel {
  @override
  final Store store;
  @override
  final PeriodTimes times;
  @override
  final tz.Location jst;

  WebState._(this.store, this.times, this.jst)
    : settings = store.loadSettings(),
      timetable = store.loadTimetable(),
      twinsCurrentModule = store.loadTwinsCurrentModule(),
      assignments = store.loadAssignments(),
      twinsSync = store.loadSync(Source.twins),
      manabaSync = store.loadSync(Source.manaba);

  static Future<WebState> load() async {
    tzdata.initializeTimeZones();
    final times = PeriodTimes.fromJson(
      jsonDecode(await rootBundle.loadString('assets/period_times.json')) as Map<String, Object?>,
    );
    return WebState._(await Store.open(), times, tz.getLocation('Asia/Tokyo'));
  }

  Settings settings;
  @override
  Map<String, List<Slot>> timetable;
  String? twinsCurrentModule;
  @override
  List<Assignment> assignments;
  @override
  SyncState twinsSync;
  @override
  SyncState manabaSync;

  @override
  String? get currentModule => settings.moduleOverride ?? twinsCurrentModule;

  /// 取り込みを反映する。戻り値: 画面に出す結果の文。失敗時は既存データを変えずに ImportException。
  Future<String> applyImport(String value) async {
    final r = decodeImport(value);
    final now = SyncState(lastSuccessAt: DateTime.now());
    switch (r) {
      case TwinsImport():
        timetable = r.slotsByModule;
        twinsCurrentModule = r.currentModule;
        twinsSync = now;
        await store.saveTimetable(timetable, twinsCurrentModule);
        await store.saveSync(Source.twins, now);
        if (autoRooms.length > courseCodes.length) {
          autoRooms = {
            for (final c in courseCodes)
              if (autoRooms[c] != null) c: autoRooms[c]!,
          };
          await store.saveRooms(autoRooms, manual: false);
        }
        notifyListeners();
        final summary = r.slotsByModule.entries
            .where((e) => e.value.isNotEmpty)
            .map((e) => '${e.key} ${e.value.length}コマ');
        return '時間割を取り込みました(${summary.join(' / ')})';
      case ManabaImport():
        assignments = r.items;
        manabaSync = now;
        await store.saveAssignments(assignments);
        await saveManabaCourses(r.courses);
        await store.saveSync(Source.manaba, now);
        notifyListeners();
        return '未提出の課題を取り込みました(${r.items.length}件)';
      case RoomsImport():
        // 時間割があれば自分の科目だけ保存する(無ければいったん全部。表示は時間割の科目だけ)
        final codes = courseCodes;
        final mine = codes.isEmpty
            ? r.rooms
            : {
                for (final c in codes)
                  if (r.rooms[c] != null) c: r.rooms[c]!,
              };
        await saveAutoRooms(mine);
        return codes.isEmpty ? '教室を取り込みました(時間割を取り込むと自分の科目に絞られます)' : '教室を取り込みました(${codes.length}科目中 ${mine.length}科目)';
    }
  }

  Future<void> setModuleOverride(String? m) async {
    settings = settings.copyWith(moduleOverride: () => m);
    await store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> wipe() async {
    await store.clearAll();
    settings = const Settings();
    timetable = {};
    twinsCurrentModule = null;
    assignments = [];
    twinsSync = const SyncState();
    manabaSync = const SyncState();
    resetRooms();
    manabaCourses = {};
    notifyListeners();
  }
}
