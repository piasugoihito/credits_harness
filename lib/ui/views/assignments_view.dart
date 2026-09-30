/// 課題画面の本体: 未提出課題のグループ表示(Android/Web 共通)。通知はしない。
library;

import 'package:flutter/material.dart';

import '../../app/courses_model.dart';
import '../../core/assignment_groups.dart';
import '../../core/models.dart';
import '../format.dart';

class AssignmentsView extends StatefulWidget {
  final CoursesModel model;
  final void Function(BuildContext context, Assignment a) onTapAssignment;
  final Future<void> Function()? onRefresh;
  final List<Widget> actions;
  final Widget? banner;
  final String notFetchedText;

  const AssignmentsView({
    super.key,
    required this.model,
    required this.onTapAssignment,
    this.onRefresh,
    this.actions = const [],
    this.banner,
    this.notFetchedText = 'まだ取得していません。',
  });

  @override
  State<AssignmentsView> createState() => _AssignmentsViewState();
}

class _AssignmentsViewState extends State<AssignmentsView> {
  bool _showOverdue = false;

  CoursesModel get model => widget.model;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final groups = groupAssignments(model.assignments, now);
    final t = Theme.of(context).textTheme;

    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ?widget.banner,
        if (model.assignments.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                model.manabaSync.lastSuccessAt == null ? widget.notFetchedText : '未提出の課題はありません 🎉',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        for (final e in groups.entries) ...[
          _GroupHeader(
            label: '${dueGroupLabels[e.key]}(${e.value.length})',
            color: e.key == DueGroup.within24h ? Theme.of(context).colorScheme.error : null,
            trailing: e.key == DueGroup.overdue
                ? TextButton(
                    onPressed: () => setState(() => _showOverdue = !_showOverdue),
                    child: Text(_showOverdue ? '閉じる' : '表示'),
                  )
                : null,
          ),
          if (e.key != DueGroup.overdue || _showOverdue)
            for (final a in e.value) _AssignmentTile(a: a, now: now, onTap: () => widget.onTapAssignment(context, a)),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Center(child: Text('最終更新: ${formatUpdatedAt(model.manabaSync.lastSuccessAt)}', style: t.bodySmall)),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('課題'), actions: widget.actions),
      body: widget.onRefresh == null ? list : RefreshIndicator(onRefresh: widget.onRefresh!, child: list),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  final Color? color;
  final Widget? trailing;
  const _GroupHeader({required this.label, this.color, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: color)),
        ),
        ?trailing,
      ],
    ),
  );
}

class _AssignmentTile extends StatelessWidget {
  final Assignment a;
  final DateTime now;
  final VoidCallback onTap;
  const _AssignmentTile({required this.a, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final group = dueGroupOf(a, now);
    return ListTile(
      leading: Chip(
        label: Text(a.type.isEmpty ? '課題' : a.type, style: t.labelSmall),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
      ),
      title: Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(a.course, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            a.due == null ? '期限なし' : '${a.due} まで(${relativeDueLabel(a, now)})',
            style: TextStyle(color: group == DueGroup.within24h || group == DueGroup.overdue ? cs.error : null),
          ),
        ],
      ),
      isThreeLine: true,
      onTap: onTap,
    );
  }
}
