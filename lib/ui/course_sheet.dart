/// 科目の詳細(ボトムシート)。シラバスの開き方は呼び出し側(Android: アプリ内 KdB / Web: 新しいタブ)が決める。
library;

import 'package:flutter/material.dart';

import '../app/courses_model.dart';
import '../core/models.dart';

typedef OpenSyllabus = void Function(BuildContext context, String code, String name);

Future<void> showCourseSheet(
  BuildContext context,
  CoursesModel model,
  String code, {
  required OpenSyllabus openSyllabus,
  String syllabusLabel = 'シラバスを見る(KdB)',
}) {
  final info = model.courseInfo(code);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final t = Theme.of(ctx).textTheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(info.name, style: t.titleLarge),
              const SizedBox(height: 4),
              Text(code, style: t.bodyMedium?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              if (info.teacher.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.person_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(info.teacher)),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              for (final (module, slots) in info.byModule)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.schedule, size: 18),
                      const SizedBox(width: 8),
                      Text('$module  ${_slotsLabel(slots)}'),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text(syllabusLabel),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    openSyllabus(context, code, info.name);
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String _slotsLabel(List<Slot> slots) {
  final byDay = <int, List<int>>{};
  for (final s in slots) {
    byDay.putIfAbsent(s.day, () => []).add(s.period);
  }
  return [for (final e in byDay.entries) '${weekdayLabels[e.key]}${(e.value..sort()).join('・')}'].join(' ');
}
