/// Android: 日程タブ(WebView で TWINS から更新)。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/store.dart';
import 'course_sheet.dart';
import 'kdb_syllabus.dart';
import 'status_banner.dart';
import 'views/schedule_view.dart';

void showNativeCourseSheet(BuildContext context, AppState app, String code) =>
    showCourseSheet(context, app, code, openSyllabus: openSyllabusInApp);

class ScheduleTab extends StatelessWidget {
  final AppState app;
  const ScheduleTab({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ScheduleView(
      model: app,
      onTapCourse: (ctx, code) => showNativeCourseSheet(ctx, app, code),
      onRefresh: () => app.refresh(manaba: false),
      banner: StatusBanner(app: app, source: Source.twins),
      emptyText: '時間割がまだありません。\n下に引いて更新してください。',
      actions: [
        if (app.refreshingSource == Source.twins)
          const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else
          IconButton(
            tooltip: '更新',
            icon: const Icon(Icons.refresh),
            onPressed: app.refreshing ? null : () => app.refresh(manaba: false),
          ),
      ],
    );
  }
}
