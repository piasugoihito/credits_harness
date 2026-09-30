/// 授業ブロックの生成と通知プラン(純粋関数)。
library;

import 'package:timezone/timezone.dart' as tz;

import 'calendar.dart';
import 'models.dart';

/// 同じ科目の連続時限をまとめたもの(1・2限 → 1ブロック、開始は1限)。
class ClassBlock {
  final String code;
  final String name;
  final int firstPeriod;
  final int lastPeriod;
  final tz.TZDateTime start;

  const ClassBlock(this.code, this.name, this.firstPeriod, this.lastPeriod, this.start);

  String get periodLabel => '${[for (var p = firstPeriod; p <= lastPeriod; p++) '$p'].join('・')}限';
}

/// date(location での暦日)に行われる授業ブロック(開始時刻順)。休講日・モジュール不明の日は空。
List<ClassBlock> blocksFor(
  DateTime date,
  ClassDays cal,
  Map<String, List<Slot>> slotsByModule,
  PeriodTimes times,
  tz.Location location,
) {
  if (cal.isNoClassDate(date)) return [];
  final module = cal.moduleOn(date);
  if (module == null) return [];
  final day = cal.effectiveWeekday(date);
  final todays =
      (slotsByModule[module] ?? const <Slot>[])
          .where((s) => s.day == day && times.periods.containsKey(s.period))
          .toList()
        ..sort((a, b) => a.code != b.code ? a.code.compareTo(b.code) : a.period - b.period);

  final blocks = <ClassBlock>[];
  for (final s in todays) {
    final last = blocks.isEmpty ? null : blocks.last;
    if (last != null && last.code == s.code && last.lastPeriod == s.period - 1) {
      blocks[blocks.length - 1] = ClassBlock(last.code, last.name, last.firstPeriod, s.period, last.start);
    } else if (last != null && last.code == s.code && last.lastPeriod == s.period) {
      continue; // 同一コマの重複
    } else {
      blocks.add(ClassBlock(s.code, s.name, s.period, s.period, times.startOn(date, s.period, location)));
    }
  }
  blocks.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : a.code.compareTo(b.code);
  });
  return blocks;
}

class PlannedNotification {
  final int id;
  final tz.TZDateTime fireAt;
  final String title;
  final String body;
  final String payload; // 科目番号

  const PlannedNotification({
    required this.id,
    required this.fireAt,
    required this.title,
    required this.body,
    required this.payload,
  });

  @override
  String toString() => 'PlannedNotification($fireAt $title / $body)';
}

/// 文字列から決定的な 31bit ID を作る(FNV-1a)。String.hashCode は実行間で安定が保証されないため使わない。
int stableId(String key) {
  var h = 0x811c9dc5;
  for (final b in key.codeUnits) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

/// now の日から windowDays 日先まで(両端含む)。発火時刻が now 以前のものは除外。近い順に最大 maxPending 件。
List<PlannedNotification> planNotifications({
  required tz.TZDateTime now,
  required int leadMinutes,
  required ClassDays cal,
  required Map<String, List<Slot>> slotsByModule,
  required PeriodTimes times,
  int windowDays = 14,
  int maxPending = 60,
}) {
  final loc = now.location;
  final result = <PlannedNotification>[];
  for (var i = 0; i <= windowDays; i++) {
    final date = DateTime(now.year, now.month, now.day + i);
    for (final b in blocksFor(date, cal, slotsByModule, times, loc)) {
      final fireAt = b.start.subtract(Duration(minutes: leadMinutes));
      if (!fireAt.isAfter(now)) continue;
      final hm = '${b.start.hour.toString().padLeft(2, '0')}:${b.start.minute.toString().padLeft(2, '0')}';
      result.add(
        PlannedNotification(
          id: stableId('${dateKey(date)}|${b.code}|${b.firstPeriod}'),
          fireAt: fireAt,
          title: b.name.isEmpty ? b.code : b.name,
          body: '$leadMinutes分後 $hm 開始（${b.periodLabel}）',
          payload: b.code,
        ),
      );
    }
  }
  result.sort((a, b) => a.fireAt.compareTo(b.fireAt));
  return result.take(maxPending).toList();
}
