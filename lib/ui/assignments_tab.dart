/// Android: 課題タブ(WebView で manaba から更新)。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/store.dart';
import 'status_banner.dart';
import 'views/assignments_view.dart';
import 'web_page.dart';

class AssignmentsTab extends StatelessWidget {
  final AppState app;
  const AssignmentsTab({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AssignmentsView(
      model: app,
      onTapAssignment: (ctx, a) => Navigator.of(ctx).push(
        MaterialPageRoute<void>(
          builder: (_) => WebPage(url: Uri.parse(a.url), title: a.title, autoLogin: app.credentials),
        ),
      ),
      onRefresh: () => app.refresh(twins: false),
      banner: StatusBanner(app: app, source: Source.manaba),
      notFetchedText: 'まだ取得していません。\n下に引いて更新してください。',
      actions: [
        if (app.refreshingSource == Source.manaba)
          const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else
          IconButton(
            tooltip: '更新',
            icon: const Icon(Icons.refresh),
            onPressed: app.refreshing ? null : () => app.refresh(twins: false),
          ),
      ],
    );
  }
}
