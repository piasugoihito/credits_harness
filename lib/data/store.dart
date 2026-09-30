/// 設定・取得データ・同期状態の保存(アプリ専用領域。バックアップ対象外)。
///
/// データ量が小さい(コマ数十件・課題数件)ため、JSON で shared_preferences に保存する。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import '../core/failure.dart';

const leadMinuteChoices = [5, 10, 15, 20, 30, 60];

class Settings {
  final bool notifyEnabled;
  final int leadMinutes;
  final bool autoRefresh;
  final int refreshHours;

  /// null = TWINS で選択中のタブに自動で合わせる
  final String? moduleOverride;
  final bool setupDone;

  const Settings({
    this.notifyEnabled = true,
    this.leadMinutes = 10,
    this.autoRefresh = true,
    this.refreshHours = 6,
    this.moduleOverride,
    this.setupDone = false,
  });

  Settings copyWith({
    bool? notifyEnabled,
    int? leadMinutes,
    bool? autoRefresh,
    int? refreshHours,
    String? Function()? moduleOverride,
    bool? setupDone,
  }) => Settings(
    notifyEnabled: notifyEnabled ?? this.notifyEnabled,
    leadMinutes: leadMinutes ?? this.leadMinutes,
    autoRefresh: autoRefresh ?? this.autoRefresh,
    refreshHours: refreshHours ?? this.refreshHours,
    moduleOverride: moduleOverride != null ? moduleOverride() : this.moduleOverride,
    setupDone: setupDone ?? this.setupDone,
  );
}

enum Source { twins, manaba }

class SyncState {
  final DateTime? lastSuccessAt;
  final DateTime? lastErrorAt;
  final FailureKind? lastErrorKind;
  final String? lastError;

  const SyncState({this.lastSuccessAt, this.lastErrorAt, this.lastErrorKind, this.lastError});

  /// 最後の試行が失敗だったか(成功後に失敗していれば true)。
  bool get failing => lastErrorAt != null && (lastSuccessAt == null || lastErrorAt!.isAfter(lastSuccessAt!));

  Map<String, Object?> toJson() => {
    'last_success_at': lastSuccessAt?.toIso8601String(),
    'last_error_at': lastErrorAt?.toIso8601String(),
    'last_error_kind': lastErrorKind?.name,
    'last_error': lastError,
  };

  factory SyncState.fromJson(Map<String, Object?> j) => SyncState(
    lastSuccessAt: DateTime.tryParse(j['last_success_at'] as String? ?? ''),
    lastErrorAt: DateTime.tryParse(j['last_error_at'] as String? ?? ''),
    lastErrorKind: FailureKind.values.where((k) => k.name == j['last_error_kind']).firstOrNull,
    lastError: j['last_error'] as String?,
  );
}

class Store {
  final SharedPreferences _p;
  Store._(this._p);
  static Future<Store> open() async => Store._(await SharedPreferences.getInstance());

  // ---- 設定
  Settings loadSettings() => Settings(
    notifyEnabled: _p.getBool('notify_enabled') ?? true,
    leadMinutes: _p.getInt('notify_lead_minutes') ?? 10,
    autoRefresh: _p.getBool('auto_refresh') ?? true,
    refreshHours: _p.getInt('refresh_hours') ?? 6,
    moduleOverride: _p.getString('module_override'),
    setupDone: _p.getBool('setup_done') ?? false,
  );

  Future<void> saveSettings(Settings s) async {
    await _p.setBool('notify_enabled', s.notifyEnabled);
    await _p.setInt('notify_lead_minutes', s.leadMinutes);
    await _p.setBool('auto_refresh', s.autoRefresh);
    await _p.setInt('refresh_hours', s.refreshHours);
    if (s.moduleOverride == null) {
      await _p.remove('module_override');
    } else {
      await _p.setString('module_override', s.moduleOverride!);
    }
    await _p.setBool('setup_done', s.setupDone);
  }

  // ---- 時間割
  /// タブの並び順を保つため、[[タブ名, [コマ...]], ...] の形で保存する。
  Map<String, List<Slot>> loadTimetable() {
    final raw = _p.getString('timetable');
    if (raw == null) return {};
    return {
      for (final e in (jsonDecode(raw) as List).cast<List>())
        e[0] as String: [for (final s in (e[1] as List)) Slot.fromJson((s as Map).cast())],
    };
  }

  String? loadTwinsCurrentModule() => _p.getString('twins_current_module');

  Future<void> saveTimetable(Map<String, List<Slot>> byModule, String? currentModule) async {
    await _p.setString(
      'timetable',
      jsonEncode([
        for (final e in byModule.entries) [e.key, e.value.map((s) => s.toJson()).toList()],
      ]),
    );
    if (currentModule == null) {
      await _p.remove('twins_current_module');
    } else {
      await _p.setString('twins_current_module', currentModule);
    }
  }

  // ---- 課題
  List<Assignment> loadAssignments() {
    final raw = _p.getString('assignments');
    if (raw == null) return [];
    return [for (final a in jsonDecode(raw) as List) Assignment.fromJson((a as Map).cast())];
  }

  Future<void> saveAssignments(List<Assignment> items) =>
      _p.setString('assignments', jsonEncode(items.map((a) => a.toJson()).toList()));

  // ---- 同期状態
  SyncState loadSync(Source s) {
    final raw = _p.getString('sync_${s.name}');
    return raw == null ? const SyncState() : SyncState.fromJson((jsonDecode(raw) as Map).cast());
  }

  Future<void> saveSync(Source s, SyncState st) => _p.setString('sync_${s.name}', jsonEncode(st.toJson()));

  /// 取得データ・同期状態を消す(設定は残す)。
  Future<void> clearData() async {
    for (final k in ['timetable', 'twins_current_module', 'assignments', 'sync_twins', 'sync_manaba']) {
      await _p.remove(k);
    }
  }

  /// 設定を含めてすべて消す。
  Future<void> clearAll() => _p.clear();
}
