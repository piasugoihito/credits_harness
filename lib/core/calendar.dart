/// 学年暦(モジュール日程・休講日・振替日)と時限の開始時刻。
///
/// 日付は公式学年暦から転記したものだけを使う。未記入(null)のモジュールは「不明」として扱い、推測で補わない。
library;

import 'package:timezone/timezone.dart' as tz;

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "yyyy-MM-dd" → 日付(時刻なし)。
DateTime _parseDate(String s) {
  final p = s.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

const _weekdayByLabel = {'月': 1, '火': 2, '水': 3, '木': 4, '金': 5, '土': 6, '日': 7};

class DateRange {
  final DateTime start;
  final DateTime end; // 両端を含む
  const DateRange(this.start, this.end);
  bool contains(DateTime d) {
    final x = _dateOnly(d);
    return !x.isBefore(start) && !x.isAfter(end);
  }
}

/// 日付ごとに「どのモジュールの・何曜日の授業があるか」を答えるもの。
abstract interface class ClassDays {
  /// date の有効モジュール名。不明・授業なしなら null。
  String? moduleOn(DateTime date);
  bool isNoClassDate(DateTime date);

  /// その日に行う授業の曜日(1=月..7=日)。
  int effectiveWeekday(DateTime date);
}

/// 学年暦を使わず、常に同じモジュールとみなす(TWINS で選択中のタブ、または設定で固定したモジュール)。
/// 祝日・振替は考慮しない。
class FixedModule implements ClassDays {
  final String? module;
  const FixedModule(this.module);
  @override
  String? moduleOn(DateTime date) => module;
  @override
  bool isNoClassDate(DateTime date) => false;
  @override
  int effectiveWeekday(DateTime date) => date.weekday;
}

/// 公式学年暦(JSON)に基づく判定。現在は未使用(将来、学年暦を取り込む場合用)。
class AcademicCalendar implements ClassDays {
  final int academicYear;

  /// 開始・終了の両方が記入済みのモジュールのみ。TWINS タブの並び順を保つ。
  final Map<String, DateRange> modules;

  /// 日付が未記入のモジュール名(UI で「学年暦が未記入」と知らせるため)。
  final List<String> incompleteModules;
  final Set<String> noClassDates;
  final Map<String, int> weekdayOverrides;

  const AcademicCalendar({
    required this.academicYear,
    required this.modules,
    this.incompleteModules = const [],
    this.noClassDates = const {},
    this.weekdayOverrides = const {},
  });

  factory AcademicCalendar.fromJson(Map<String, Object?> j) {
    final modules = <String, DateRange>{};
    final incomplete = <String>[];
    final rawModules = (j['modules'] as Map?)?.cast<String, Object?>() ?? const {};
    for (final e in rawModules.entries) {
      final m = e.value as Map;
      final s = m['start'] as String?;
      final t = m['end'] as String?;
      if (s == null || t == null) {
        incomplete.add(e.key);
      } else {
        modules[e.key] = DateRange(_parseDate(s), _parseDate(t));
      }
    }

    final noClass = <String>{};
    for (final x in (j['no_class_dates'] as List?) ?? const []) {
      final m = x as Map;
      final d = m['date'] as String?;
      final until = m['until'] as String?; // 任意: 期間指定(両端含む)
      if (d == null) continue;
      if (until == null) {
        noClass.add(d);
      } else {
        for (
          var day = _parseDate(d);
          !day.isAfter(_parseDate(until));
          day = DateTime(day.year, day.month, day.day + 1)
        ) {
          noClass.add(dateKey(day));
        }
      }
    }

    final overrides = <String, int>{};
    for (final x in (j['weekday_overrides'] as List?) ?? const []) {
      final m = x as Map;
      final d = m['date'] as String?;
      final w = m['acts_as_weekday'];
      if (d == null || w == null) continue;
      final wd = w is int ? w : _weekdayByLabel[w.toString()];
      if (wd == null || wd < 1 || wd > 7) {
        throw FormatException('acts_as_weekday が不正: $w ($d)');
      }
      overrides[d] = wd;
    }

    return AcademicCalendar(
      academicYear: j['academic_year'] as int,
      modules: modules,
      incompleteModules: incomplete,
      noClassDates: noClass,
      weekdayOverrides: overrides,
    );
  }

  /// date を含むモジュール名。学年暦に無い(未記入・期間外)なら null。
  @override
  String? moduleOn(DateTime date) {
    for (final e in modules.entries) {
      if (e.value.contains(date)) return e.key;
    }
    return null;
  }

  @override
  bool isNoClassDate(DateTime date) => noClassDates.contains(dateKey(date));

  /// 振替日なら指定の曜日、そうでなければ実際の曜日(1=月..7=日)。
  @override
  int effectiveWeekday(DateTime date) => weekdayOverrides[dateKey(date)] ?? date.weekday;
}

class PeriodTime {
  final int startMinutes; // 0:00 からの分
  final int endMinutes;
  const PeriodTime(this.startMinutes, this.endMinutes);

  String get startLabel => _hm(startMinutes);
  String get endLabel => _hm(endMinutes);
  static String _hm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

class PeriodTimes {
  final Map<int, PeriodTime> periods;
  const PeriodTimes(this.periods);

  factory PeriodTimes.fromJson(Map<String, Object?> j) {
    int mins(String hm) {
      final p = hm.split(':').map(int.parse).toList();
      return p[0] * 60 + p[1];
    }

    final raw = j['periods'] as Map<String, Object?>;
    return PeriodTimes({
      for (final e in raw.entries)
        int.parse(e.key): PeriodTime(
          mins((e.value as Map)['start'] as String),
          mins((e.value as Map)['end'] as String),
        ),
    });
  }

  /// date(年月日のみ使用)の period 限の開始時刻を location のタイムゾーンで返す。
  tz.TZDateTime startOn(DateTime date, int period, tz.Location location) {
    final p = periods[period];
    if (p == null) throw ArgumentError('未知の時限: $period');
    return tz.TZDateTime(location, date.year, date.month, date.day, p.startMinutes ~/ 60, p.startMinutes % 60);
  }
}
