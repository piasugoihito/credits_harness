/// 下部タブ(日程 / 課題 / 設定)。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/assignment_groups.dart';
import 'assignments_tab.dart';
import 'schedule_tab.dart';
import 'settings_tab.dart';

class HomePage extends StatefulWidget {
  final AppState app;
  const HomePage({super.key, required this.app});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;
  final _scheduleKey = GlobalKey();

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.notifier.onTap = _openFromNotification;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final code = await app.notifier.launchPayload();
      if (code != null) _openFromNotification(code);
      await app.reschedule();
      await app.refreshIfStale();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 通知の予約窓(14日)を先に進め、古ければ更新する
      app.reschedule().then((_) => app.refreshIfStale());
    }
  }

  void _openFromNotification(String? code) {
    if (code == null || code == 'TEST' || !mounted) return;
    setState(() => _tab = 0);
    Navigator.of(context).popUntil((r) => r.isFirst);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _scheduleKey.currentContext;
      if (ctx != null) showNativeCourseSheet(ctx, app, code);
    });
  }

  @override
  Widget build(BuildContext context) {
    final urgent = app.assignments.where((a) => dueGroupOf(a, DateTime.now()) == DueGroup.within24h).length;
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          KeyedSubtree(
            key: _scheduleKey,
            child: ScheduleTab(app: app),
          ),
          AssignmentsTab(app: app),
          SettingsTab(app: app),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.calendar_view_week_outlined),
            selectedIcon: Icon(Icons.calendar_view_week),
            label: '日程',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: urgent > 0,
              label: Text('$urgent'),
              child: const Icon(Icons.assignment_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: urgent > 0,
              label: Text('$urgent'),
              child: const Icon(Icons.assignment),
            ),
            label: '課題',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '設定',
          ),
        ],
      ),
    );
  }
}
