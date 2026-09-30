/// アプリ全体の状態と、更新・通知再スケジュールの手順。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show CookieManager;
import 'package:timezone/timezone.dart' as tz;

import '../core/calendar.dart';
import '../core/schedule.dart';
import 'courses_model.dart';
import '../core/models.dart';
import '../data/credentials.dart';
import '../data/store.dart';
import '../notify/notifier.dart';
import '../scraper/scrapers.dart' hide fetchRooms;
import '../scraper/scrapers.dart' as scrapers show fetchRooms;
import '../scraper/web_session.dart';

class AppState extends ChangeNotifier with RoomsState, ManabaCoursesState implements CoursesModel {
  @override
  final Store store;
  final CredentialStore credentials;
  @override
  final PeriodTimes times;
  final Notifier notifier;

  AppState._(this.store, this.credentials, this.times, this.notifier)
    : settings = store.loadSettings(),
      timetable = store.loadTimetable(),
      twinsCurrentModule = store.loadTwinsCurrentModule(),
      assignments = store.loadAssignments(),
      twinsSync = store.loadSync(Source.twins),
      manabaSync = store.loadSync(Source.manaba);

  static Future<AppState> load() async {
    final times = PeriodTimes.fromJson(
      jsonDecode(await rootBundle.loadString('assets/period_times.json')) as Map<String, Object?>,
    );
    final s = AppState._(await Store.open(), CredentialStore(), times, Notifier.instance);
    s.hasCredentials = await s.credentials.read() != null;
    s.autofillFailed = await s.credentials.autofillFailed();
    return s;
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
  bool hasCredentials = false;
  bool autofillFailed = false;

  /// 実行中の更新(同時に2つ走らせない)
  Future<void>? _refreshing;
  bool get refreshing => _refreshing != null;
  Source? refreshingSource;

  /// 直近の更新のログ(件数・ホスト名のみ。設定の「取得ログ」で見られる)
  final List<String> log = [];

  void _log(String m) {
    final t = DateTime.now();
    log.add(
      '[${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}] $m',
    );
    if (log.length > 300) log.removeRange(0, log.length - 300);
  }

  /// 設定で固定したモジュール、なければ TWINS で選択中のタブ。
  @override
  String? get currentModule => settings.moduleOverride ?? twinsCurrentModule;

  @override
  tz.Location get jst => notifier.jst;

  // ------------------------------------------------------------------ 更新

  /// 起動時: 自動更新がオンで、最終成功から設定間隔を超えていれば更新する。
  Future<void> refreshIfStale() async {
    if (!settings.autoRefresh || !hasCredentials) return;
    final limit = Duration(hours: settings.refreshHours);
    bool stale(SyncState s) => s.lastSuccessAt == null || DateTime.now().difference(s.lastSuccessAt!) > limit;
    if (stale(twinsSync) || stale(manabaSync)) {
      await refresh(twins: stale(twinsSync), manaba: stale(manabaSync));
    }
  }

  /// 手動更新。失敗しても既存データは消さない。
  Future<void> refresh({bool twins = true, bool manaba = true}) {
    return _refreshing ??= _doRefresh(twins, manaba).whenComplete(() {
      _refreshing = null;
      refreshingSource = null;
      notifyListeners();
    });
  }

  Future<void> _doRefresh(bool twins, bool manaba) async {
    if (twins) {
      refreshingSource = Source.twins;
      notifyListeners();
      await _guarded(Source.twins, () async {
        final r = await fetchTimetable(credentials, log: _log);
        timetable = r.slotsByModule;
        twinsCurrentModule = r.currentModule;
        await store.saveTimetable(timetable, twinsCurrentModule);
      });
      await reschedule();
    }
    if (manaba) {
      refreshingSource = Source.manaba;
      notifyListeners();
      await _guarded(Source.manaba, () async {
        final (items, courses) = await fetchAssignments(credentials, log: _log);
        assignments = items;
        await store.saveAssignments(assignments);
        await saveManabaCourses(courses);
        final names = {
          for (final xs in timetable.values)
            for (final s in xs) s.name,
        };
        _log('manaba: 時間割の科目 ${names.length}件中 ${names.where((n) => manabaUrlFor(n) != null).length}件がコースと一致');
      });
    }
  }

  Future<void> _guarded(Source src, Future<void> Function() f) async {
    final prev = src == Source.twins ? twinsSync : manabaSync;
    SyncState next;
    try {
      await f();
      next = SyncState(lastSuccessAt: DateTime.now());
    } on ScrapeException catch (e) {
      _log('✖ ${src.name} [${e.kind.name}] ${e.message}');
      next = SyncState(
        lastSuccessAt: prev.lastSuccessAt,
        lastErrorAt: DateTime.now(),
        lastErrorKind: e.kind,
        lastError: e.message,
      );
    } catch (e) {
      _log('✖ ${src.name} 予期しないエラー: ${e.runtimeType}');
      next = SyncState(
        lastSuccessAt: prev.lastSuccessAt,
        lastErrorAt: DateTime.now(),
        lastErrorKind: FailureKind.structureChanged,
        lastError: '予期しないエラー(${e.runtimeType})',
      );
    }
    if (src == Source.twins) {
      twinsSync = next;
    } else {
      manabaSync = next;
    }
    await store.saveSync(src, next);
    autofillFailed = await credentials.autofillFailed();
    notifyListeners();
  }

  // ------------------------------------------------------------------ 教室

  bool roomsFetching = false;
  String? roomsError;

  /// kdb_ja.xlsx から教室を取得する(利用者のボタン操作でのみ)。失敗しても既存の教室は消さない。
  Future<void> fetchRooms() async {
    if (roomsFetching || refreshing) return;
    final codes = courseCodes;
    if (codes.isEmpty) {
      roomsError = '先に時間割を取得してください';
      notifyListeners();
      return;
    }
    roomsFetching = true;
    roomsError = null;
    notifyListeners();
    try {
      await saveAutoRooms(await scrapers.fetchRooms(credentials, codes, log: _log));
    } on ScrapeException catch (e) {
      _log('✖ 教室 [${e.kind.name}] ${e.message}');
      roomsError = e.message;
    } catch (e) {
      _log('✖ 教室 予期しないエラー: ${e.runtimeType}');
      roomsError = '予期しないエラー(${e.runtimeType})';
    } finally {
      roomsFetching = false;
      autofillFailed = await credentials.autofillFailed();
      notifyListeners();
    }
  }

  @override
  Future<void> saveAutoRooms(Map<String, String> rooms) async {
    await super.saveAutoRooms(rooms);
    await reschedule(); // 通知の本文に教室が入るため
  }

  @override
  Future<void> setManualRoom(String code, String? room) async {
    await super.setManualRoom(code, room);
    await reschedule();
  }

  // ------------------------------------------------------------------ 通知

  /// 常に全キャンセル → 全登録。通知オフなら全キャンセルのみ。戻り値: 予約件数。
  Future<int> reschedule() async {
    if (!settings.notifyEnabled) {
      await notifier.cancelAll();
      return 0;
    }
    final plan = planNotifications(
      now: notifier.now(),
      leadMinutes: settings.leadMinutes,
      cal: FixedModule(currentModule),
      slotsByModule: timetable,
      times: times,
      rooms: rooms,
    );
    await notifier.applyPlan(plan);
    _log('通知を${plan.length}件予約(${currentModule ?? 'モジュール不明'})');
    return plan.length;
  }

  // ------------------------------------------------------------------ 設定

  Future<void> updateSettings(Settings s) async {
    final needsReschedule =
        s.notifyEnabled != settings.notifyEnabled ||
        s.leadMinutes != settings.leadMinutes ||
        s.moduleOverride != settings.moduleOverride;
    settings = s;
    await store.saveSettings(s);
    notifyListeners();
    if (needsReschedule) await reschedule();
  }

  Future<void> saveCredentials(Credentials c) async {
    await credentials.save(c);
    hasCredentials = true;
    autofillFailed = false;
    notifyListeners();
  }

  /// 自動ログインを1回だけ再開する(FR-2 の「再試行」)。
  Future<void> retryLogin() async {
    await credentials.clearAutofillFailed();
    autofillFailed = false;
    notifyListeners();
    await refresh();
  }

  /// ログアウト: 資格情報と Cookie を消す(取得済みデータは残す)。
  Future<void> logout() async {
    await credentials.delete();
    await CookieManager.instance().deleteAllCookies();
    hasCredentials = false;
    notifyListeners();
  }

  /// 全データ削除: 資格情報・Cookie・取得データ・設定・予約中の通知。初回セットアップに戻る。
  Future<void> wipe() async {
    await notifier.cancelAll();
    await credentials.delete();
    await CookieManager.instance().deleteAllCookies();
    await store.clearAll();
    settings = const Settings();
    timetable = {};
    twinsCurrentModule = null;
    assignments = [];
    twinsSync = const SyncState();
    manabaSync = const SyncState();
    hasCredentials = false;
    autofillFailed = false;
    resetRooms();
    manabaCourses = {};
    roomsError = null;
    log.clear();
    notifyListeners();
  }
}
