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
              ListenableBuilder(
                listenable: model,
                builder: (ctx, _) {
                  final room = model.roomOf(code);
                  final manual = model.manualRooms.containsKey(code);
                  return Row(
                    children: [
                      const Icon(Icons.meeting_room_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          room == null ? '教室: 未設定' : '$room${manual ? '(手動)' : ''}',
                          style: room == null
                              ? t.bodyMedium?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)
                              : null,
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('教室を編集'),
                        onPressed: () => _editRoom(ctx, model, code),
                      ),
                    ],
                  );
                },
              ),
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

/// 教室を手で設定する。空にして保存、または「自動に戻す」で手動設定を消す。
Future<void> _editRoom(BuildContext context, CoursesModel model, String code) async {
  final manual = model.manualRooms[code];
  final auto = model.autoRooms[code];
  final c = TextEditingController(text: manual ?? auto ?? '');
  final result = await showDialog<(bool, String?)>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('教室を編集'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(labelText: '教室(例: 3A204)'),
            onSubmitted: (v) => Navigator.pop(ctx, (true, v)),
          ),
          const SizedBox(height: 8),
          Text(auto == null ? '自動取得の教室: なし' : '自動取得の教室: $auto', style: Theme.of(ctx).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
        if (manual != null) TextButton(onPressed: () => Navigator.pop(ctx, (true, null)), child: const Text('自動に戻す')),
        FilledButton(onPressed: () => Navigator.pop(ctx, (true, c.text)), child: const Text('保存')),
      ],
    ),
  );
  if (result == null) return;
  final value = result.$2?.trim();
  // 自動取得と同じ値なら手動設定にしない
  await model.setManualRoom(code, value == auto ? null : value);
}
