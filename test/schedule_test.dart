import 'dart:convert';
import 'dart:io';

import 'package:credits_harness/core/calendar.dart';
import 'package:credits_harness/core/models.dart';
import 'package:credits_harness/core/schedule.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// テスト専用の架空の学年暦(実際の日程ではない)。2030-06-03 は月曜日。
const _testCalendar = {
  'academic_year': 2030,
  'modules': {
    'TA': {'start': '2030-06-03', 'end': '2030-06-14'},
    'TB': {'start': '2030-06-17', 'end': '2030-06-28'},
    'TC': {'start': null, 'end': null},
  },
  'no_class_dates': [
    {'date': '2030-06-05', 'note': '休講(水)'},
    {'date': '2030-06-24', 'until': '2030-06-25', 'note': '期間指定'},
    {'date': null, 'note': '未記入は無視'},
  ],
  'weekday_overrides': [
    {'date': '2030-06-11', 'acts_as_weekday': '月', 'note': '火曜だが月曜の授業'},
    {'date': '2030-06-12', 'acts_as_weekday': 5},
    {'date': null, 'acts_as_weekday': null},
  ],
};

Slot _s(String code, int day, int period, {String? name}) =>
    Slot(year: '2030', code: code, name: name ?? '科目$code', teacher: '', day: day, period: period);

void main() {
  tzdata.initializeTimeZones();
  final jst = tz.getLocation('Asia/Tokyo');
  final cal = AcademicCalendar.fromJson(_testCalendar);
  final times = PeriodTimes.fromJson(
    jsonDecode(File('assets/period_times.json').readAsStringSync()) as Map<String, Object?>,
  );
  tz.TZDateTime at(int y, int m, int d, [int h = 0, int min = 0]) => tz.TZDateTime(jst, y, m, d, h, min);

  group('学年暦', () {
    test('モジュール判定は初日・最終日を含む', () {
      expect(cal.moduleOn(DateTime(2030, 6, 2)), isNull);
      expect(cal.moduleOn(DateTime(2030, 6, 3)), 'TA');
      expect(cal.moduleOn(DateTime(2030, 6, 14)), 'TA');
      expect(cal.moduleOn(DateTime(2030, 6, 15)), isNull);
      expect(cal.moduleOn(DateTime(2030, 6, 17)), 'TB');
    });

    test('未記入のモジュールは推測せず incomplete として報告', () {
      expect(cal.modules.keys, ['TA', 'TB']);
      expect(cal.incompleteModules, ['TC']);
    });

    test('休講日(単日・期間)と振替日', () {
      expect(cal.isNoClassDate(DateTime(2030, 6, 5)), isTrue);
      expect(cal.isNoClassDate(DateTime(2030, 6, 24)), isTrue);
      expect(cal.isNoClassDate(DateTime(2030, 6, 25)), isTrue);
      expect(cal.isNoClassDate(DateTime(2030, 6, 26)), isFalse);
      expect(cal.effectiveWeekday(DateTime(2030, 6, 11)), 1);
      expect(cal.effectiveWeekday(DateTime(2030, 6, 12)), 5);
      expect(cal.effectiveWeekday(DateTime(2030, 6, 13)), 4);
    });

    test('不正な曜日は例外', () {
      expect(
        () => AcademicCalendar.fromJson({
          'academic_year': 2030,
          'modules': {},
          'weekday_overrides': [
            {'date': '2030-06-11', 'acts_as_weekday': '月曜'},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('授業ブロック', () {
    final slots = {
      'TA': [
        _s('A', 1, 1), _s('A', 1, 2), // 月1・2 → 1ブロック
        _s('B', 1, 2), // 同じ時限の別科目
        _s('C', 1, 3), _s('C', 1, 5), // 非連続 → 2ブロック
        _s('D', 3, 1),
        _s('E', 5, 4),
      ],
      'TB': [_s('X', 1, 6)],
    };

    test('連続時限の結合・非連続の分離・開始時刻順', () {
      final bs = blocksFor(DateTime(2030, 6, 3), cal, slots, times, jst);
      expect(bs.map((b) => '${b.code}:${b.periodLabel}@${b.start.hour}:${b.start.minute}').toList(), [
        'A:1・2限@8:40',
        'B:2限@10:10',
        'C:3限@12:15',
        'C:5限@15:15',
      ]);
    });

    test('休講日・モジュール外は空', () {
      expect(blocksFor(DateTime(2030, 6, 5), cal, slots, times, jst), isEmpty);
      expect(blocksFor(DateTime(2030, 6, 15), cal, slots, times, jst), isEmpty);
    });

    test('振替日は指定曜日のコマ、モジュールは日付で決まる', () {
      expect(blocksFor(DateTime(2030, 6, 11), cal, slots, times, jst).map((b) => b.code), ['A', 'B', 'C', 'C']);
      expect(blocksFor(DateTime(2030, 6, 12), cal, slots, times, jst).map((b) => b.code), ['E']);
      expect(blocksFor(DateTime(2030, 6, 17), cal, slots, times, jst).map((b) => b.code), ['X']);
    });
  });

  test('FixedModule: 毎日同じモジュール・実際の曜日', () {
    final slots = {
      'M': [_s('A', 1, 1)],
    };
    const days = FixedModule('M');
    expect(blocksFor(DateTime(2030, 6, 3), days, slots, times, jst).map((b) => b.code), ['A']);
    expect(blocksFor(DateTime(2030, 6, 4), days, slots, times, jst), isEmpty);
    expect(blocksFor(DateTime(2030, 6, 3), const FixedModule(null), slots, times, jst), isEmpty);
  });

  group('通知プラン', () {
    final slots = {
      'TA': [_s('A', 1, 1, name: 'サンプル科目α'), _s('A', 1, 2, name: 'サンプル科目α')],
    };

    test('月曜1・2限・N=10 → 08:30 に1件だけ', () {
      final plan = planNotifications(
        now: at(2030, 6, 3, 0, 0),
        leadMinutes: 10,
        windowDays: 0,
        cal: cal,
        slotsByModule: slots,
        times: times,
      );
      expect(plan, hasLength(1));
      expect(plan.single.fireAt, at(2030, 6, 3, 8, 30));
      expect(plan.single.title, 'サンプル科目α');
      expect(plan.single.body, '10分後 08:40 開始（1・2限）');
      expect(plan.single.payload, 'A');
    });

    test('教室が分かれば本文に付ける', () {
      final plan = planNotifications(
        now: at(2030, 6, 3, 0, 0),
        leadMinutes: 10,
        windowDays: 0,
        cal: cal,
        slotsByModule: slots,
        times: times,
        rooms: {'A': '3A204'},
      );
      expect(plan.single.body, '10分後 08:40 開始（1・2限） 3A204');
    });

    test('発火時刻が過ぎたものは除外(境界含む)', () {
      List<PlannedNotification> p(tz.TZDateTime now) =>
          planNotifications(now: now, leadMinutes: 10, windowDays: 0, cal: cal, slotsByModule: slots, times: times);
      expect(p(at(2030, 6, 3, 8, 29)), hasLength(1));
      expect(p(at(2030, 6, 3, 8, 30)), isEmpty);
    });

    test('窓内の振替日を含み、ID は決定的で重複しない', () {
      final plan1 = planNotifications(
        now: at(2030, 6, 1),
        leadMinutes: 15,
        cal: cal,
        slotsByModule: slots,
        times: times,
      );
      // 6/3(月), 6/10(月), 6/11(振替で月)。6/17以降はTBでAなし
      expect(plan1.map((n) => dateKey(n.fireAt)), ['2030-06-03', '2030-06-10', '2030-06-11']);
      expect(plan1.first.fireAt, at(2030, 6, 3, 8, 25));
      final plan2 = planNotifications(
        now: at(2030, 6, 1),
        leadMinutes: 15,
        cal: cal,
        slotsByModule: slots,
        times: times,
      );
      expect(plan2.map((n) => n.id), plan1.map((n) => n.id));
      expect(plan1.map((n) => n.id).toSet(), hasLength(3));
    });

    test('最大件数で近い順に打ち切る', () {
      final many = {
        'TA': [
          for (var d = 1; d <= 5; d++)
            for (var p = 1; p <= 6; p++) _s('K$d$p', d, p),
        ],
      };
      final plan = planNotifications(
        now: at(2030, 6, 3),
        leadMinutes: 10,
        cal: cal,
        slotsByModule: many,
        times: times,
        maxPending: 7,
      );
      expect(plan, hasLength(7));
      for (var i = 1; i < plan.length; i++) {
        expect(plan[i].fireAt.isBefore(plan[i - 1].fireAt), isFalse);
      }
    });

    test('stableId は 31bit 非負で安定', () {
      expect(stableId('2030-06-03|A|1'), stableId('2030-06-03|A|1'));
      expect(stableId('x'), inInclusiveRange(0, 0x7fffffff));
      expect(stableId('2030-06-03|A|1'), isNot(stableId('2030-06-03|A|2')));
    });
  });
}
