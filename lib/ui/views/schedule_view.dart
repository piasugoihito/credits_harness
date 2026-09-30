/// 日程画面の本体: モジュール切替・今日の授業・時間割グリッド(Android/Web 共通)。
library;

import 'package:flutter/material.dart';

import '../../app/courses_model.dart';
import '../../core/models.dart';
import '../format.dart';

class ScheduleView extends StatefulWidget {
  final CoursesModel model;
  final void Function(BuildContext context, String code) onTapCourse;
  final Future<void> Function()? onRefresh;
  final List<Widget> actions;
  final Widget? banner;
  final String emptyText;

  const ScheduleView({
    super.key,
    required this.model,
    required this.onTapCourse,
    this.onRefresh,
    this.actions = const [],
    this.banner,
    this.emptyText = '時間割がまだありません。',
  });

  @override
  State<ScheduleView> createState() => _ScheduleViewState();
}

class _ScheduleViewState extends State<ScheduleView> {
  /// 表示中のモジュール(null = 現在のモジュール)
  String? _viewing;

  CoursesModel get model => widget.model;

  @override
  Widget build(BuildContext context) {
    final modules = model.modules;
    final current = model.currentModule;
    var viewing = _viewing ?? current ?? (modules.isEmpty ? null : modules.first);
    if (viewing != null && !modules.contains(viewing)) viewing = modules.isEmpty ? null : modules.first;
    final slots = viewing == null ? const <Slot>[] : model.timetable[viewing] ?? const <Slot>[];

    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ?widget.banner,
        if (viewing == current && modules.isNotEmpty) TodayCard(model: model, onTapCourse: widget.onTapCourse),
        if (modules.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: Text(widget.emptyText, textAlign: TextAlign.center)),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: TimetableGrid(model: model, slots: slots, onTapCourse: widget.onTapCourse),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Center(
            child: Text(
              '最終更新: ${formatUpdatedAt(model.twinsSync.lastSuccessAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('日程'),
        actions: widget.actions,
        bottom: modules.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final m in modules)
                        Padding(
                          padding: const EdgeInsets.only(right: 6, bottom: 8),
                          child: _ModuleChip(
                            label: m == current ? '$m(今)' : m,
                            selected: m == viewing,
                            onTap: () => setState(() => _viewing = m),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
      body: widget.onRefresh == null ? list : RefreshIndicator(onRefresh: widget.onRefresh!, child: list),
    );
  }
}

/// モジュール切替のチップ。ChoiceChip は Web で日本語ラベルの幅が狭く測られて文字が切れるため、自前で描く。
class _ModuleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ModuleChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shape = StadiumBorder(side: selected ? BorderSide.none : BorderSide(color: cs.outlineVariant));
    return Material(
      color: selected ? cs.secondaryContainer : Colors.transparent,
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

class TodayCard extends StatelessWidget {
  final CoursesModel model;
  final void Function(BuildContext context, String code) onTapCourse;
  const TodayCard({super.key, required this.model, required this.onTapCourse});

  @override
  Widget build(BuildContext context) {
    final now = model.now();
    final blocks = model.blocksOn(DateTime(now.year, now.month, now.day));
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('今日の授業(${now.month}/${now.day} ${weekdayLabels[now.weekday]})', style: t.titleSmall),
            const SizedBox(height: 4),
            if (blocks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('ありません', style: t.bodyMedium),
              )
            else
              for (final b in blocks)
                InkWell(
                  onTap: () => onTapCourse(context, b.code),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 56,
                          child: Text(
                            '${b.start.hour.toString().padLeft(2, '0')}:${b.start.minute.toString().padLeft(2, '0')}',
                            style: t.titleMedium?.copyWith(
                              color: b.start.isBefore(now) ? cs.onSurfaceVariant : cs.primary,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(b.name, style: t.bodyLarge, overflow: TextOverflow.ellipsis),
                        ),
                        Text(b.periodLabel, style: t.bodySmall),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class TimetableGrid extends StatelessWidget {
  final CoursesModel model;
  final List<Slot> slots;
  final void Function(BuildContext context, String code) onTapCourse;
  const TimetableGrid({super.key, required this.model, required this.slots, required this.onTapCourse});

  @override
  Widget build(BuildContext context) {
    final days = [
      1,
      2,
      3,
      4,
      5,
      if (slots.any((s) => s.day == 6) || slots.any((s) => s.day == 7)) 6,
      if (slots.any((s) => s.day == 7)) 7,
    ];
    final periods = model.times.periods.keys.toList()..sort();
    final byCell = <String, List<Slot>>{};
    for (final s in slots) {
      byCell.putIfAbsent('${s.day}|${s.period}', () => []).add(s);
    }
    final now = model.now();
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    const headerH = 28.0;
    const rowH = 76.0;
    const timeW = 34.0;

    Widget cell(int day, int period) {
      final xs = byCell['$day|$period'] ?? const <Slot>[];
      if (xs.isEmpty) {
        return Container(
          margin: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(6)),
        );
      }
      final s = xs.first;
      return Padding(
        padding: const EdgeInsets.all(1.5),
        child: Material(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onTapCourse(context, s.code),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      xs.length > 1 ? '${s.name} 他${xs.length - 1}' : s.name,
                      style: t.labelSmall?.copyWith(color: cs.onPrimaryContainer, height: 1.2),
                      overflow: TextOverflow.fade,
                    ),
                  ),
                  Text(
                    s.code,
                    style: t.labelSmall?.copyWith(fontSize: 9, color: cs.onPrimaryContainer.withValues(alpha: 0.7)),
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: timeW),
            for (final d in days)
              Expanded(
                child: SizedBox(
                  height: headerH,
                  child: Center(
                    child: Text(
                      weekdayLabels[d]!,
                      style: t.labelLarge?.copyWith(
                        color: d == now.weekday ? cs.primary : null,
                        fontWeight: d == now.weekday ? FontWeight.bold : null,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        for (final p in periods)
          SizedBox(
            height: rowH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: timeW,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('$p', style: t.titleSmall),
                      Text(model.times.periods[p]!.startLabel, style: t.labelSmall?.copyWith(fontSize: 9)),
                    ],
                  ),
                ),
                for (final d in days) Expanded(child: cell(d, p)),
              ],
            ),
          ),
      ],
    );
  }
}
