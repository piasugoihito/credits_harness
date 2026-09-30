/// 課題画面のグループ分け(期限切れ / 24時間以内 / それ以降 / 期限なし)。
library;

import 'models.dart';

enum DueGroup { overdue, within24h, later, noDue }

const dueGroupLabels = {
  DueGroup.overdue: '期限切れ',
  DueGroup.within24h: '24時間以内',
  DueGroup.later: 'それ以降',
  DueGroup.noDue: '期限なし',
};

/// "yyyy-MM-dd HH:mm"(JST)→ UTC の DateTime。形式が違えば null。
DateTime? parseJstDateTime(String? s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$').firstMatch(s?.trim() ?? '');
  if (m == null) return null;
  final v = [for (var i = 1; i <= 5; i++) int.parse(m[i]!)];
  return DateTime.utc(v[0], v[1], v[2], v[3], v[4]).subtract(const Duration(hours: 9));
}

DueGroup dueGroupOf(Assignment a, DateTime now) {
  final due = parseJstDateTime(a.due);
  if (due == null) return DueGroup.noDue;
  if (!due.isAfter(now)) return DueGroup.overdue;
  if (due.difference(now) <= const Duration(hours: 24)) return DueGroup.within24h;
  return DueGroup.later;
}

/// 締切が近い順を保ったままグループ分け(空のグループは含めない)。
Map<DueGroup, List<Assignment>> groupAssignments(List<Assignment> items, DateTime now) {
  final sorted = [...items]
    ..sort((x, y) {
      final a = parseJstDateTime(x.due), b = parseJstDateTime(y.due);
      if ((a == null) != (b == null)) return a == null ? 1 : -1;
      return a == null ? 0 : a.compareTo(b!);
    });
  final out = <DueGroup, List<Assignment>>{};
  for (final g in DueGroup.values) {
    final xs = sorted.where((a) => dueGroupOf(a, now) == g).toList();
    if (xs.isNotEmpty) out[g] = xs;
  }
  return out;
}

/// 「あと3時間」「2日前に終了」などの相対表示。
String relativeDueLabel(Assignment a, DateTime now) {
  final due = parseJstDateTime(a.due);
  if (due == null) return '期限なし';
  final d = due.difference(now);
  String span(Duration x) {
    if (x.inDays >= 1) return '${x.inDays}日';
    if (x.inHours >= 1) return '${x.inHours}時間';
    return '${x.inMinutes < 1 ? 1 : x.inMinutes}分';
  }

  return d.isNegative ? '${span(-d)}前に終了' : 'あと${span(d)}';
}
