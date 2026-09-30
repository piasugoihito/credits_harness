/// 画面が読むデータ(Android アプリ・Web 版で共通)。
library;

import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/calendar.dart';
import '../core/models.dart';
import '../core/parsers.dart' show findManabaCourse;
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

  /// kdb_ja.xlsx から取得した教室(科目番号 → 教室)と取得日時。未取得なら null。
  Map<String, String> get autoRooms;
  DateTime? get roomsFetchedAt;

  /// 利用者が手で設定した教室(自動取得より優先)。
  Map<String, String> get manualRooms;

  /// 手動の教室を設定する。null または空文字なら手動設定を消して自動取得の値に戻す。
  Future<void> setManualRoom(String code, String? room);

  /// manaba のコース一覧(コース名 → URL)。manaba の取得/取り込み時に更新。
  Map<String, String> get manabaCourses;
}

/// manaba のコース一覧の保持(Android・Web 共通)。
mixin ManabaCoursesState on ChangeNotifier implements CoursesModel {
  Store get store;

  @override
  late Map<String, String> manabaCourses = store.loadManabaCourses();

  /// 1件以上あるときだけ置き換える(取得に失敗した・一覧が空のときは前回の一覧を残す)。
  Future<void> saveManabaCourses(Map<String, String> courses) async {
    if (courses.isEmpty) return;
    manabaCourses = courses;
    await store.saveManabaCourses(courses);
    notifyListeners();
  }
}

/// 教室の保持と手動設定(Android・Web 共通)。
mixin RoomsState on ChangeNotifier implements CoursesModel {
  Store get store;

  @override
  late Map<String, String> autoRooms = store.loadRooms(manual: false);
  @override
  late Map<String, String> manualRooms = store.loadRooms(manual: true);
  @override
  late DateTime? roomsFetchedAt = store.loadRoomsFetchedAt();

  @override
  Future<void> setManualRoom(String code, String? room) async {
    final r = room?.trim() ?? '';
    manualRooms = {...manualRooms};
    if (r.isEmpty) {
      manualRooms.remove(code);
    } else {
      manualRooms[code] = r;
    }
    await store.saveRooms(manualRooms, manual: true);
    notifyListeners();
  }

  /// 自動取得した教室を保存する(手動設定は変えない)。
  Future<void> saveAutoRooms(Map<String, String> rooms) async {
    autoRooms = rooms;
    roomsFetchedAt = DateTime.now();
    await store.saveRooms(rooms, manual: false);
    await store.saveRoomsFetchedAt(roomsFetchedAt!);
    notifyListeners();
  }

  void resetRooms() {
    autoRooms = {};
    manualRooms = {};
    roomsFetchedAt = null;
  }
}

extension CoursesModelX on CoursesModel {
  List<String> get modules => timetable.keys.toList();

  /// 表示する教室(手動 > 自動)。分からなければ null。
  String? roomOf(String code) => manualRooms[code] ?? autoRooms[code];

  /// 表示で使う全科目の教室(手動 > 自動)。
  Map<String, String> get rooms => {...autoRooms, ...manualRooms};

  /// 科目名に対応する manaba のコースページ。見つからなければ null。
  String? manabaUrlFor(String courseName) => findManabaCourse(manabaCourses, courseName);

  /// 時間割にある科目番号の一覧。
  Set<String> get courseCodes => {
    for (final xs in timetable.values)
      for (final s in xs) s.code,
  };

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
