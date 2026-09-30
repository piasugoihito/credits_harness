/// Web 版の画面: 日程 / 課題 / 取り込み。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/courses_model.dart';
import '../ui/course_sheet.dart';
import '../ui/format.dart';
import '../ui/views/assignments_view.dart';
import '../ui/views/schedule_view.dart';
import 'web_state.dart';

const _disclaimer =
    '本サービスは筑波大学とは無関係の非公式ツールです。利用は自己責任でお願いします。'
    '大学の利用規程は各自で確認してください。\n\n'
    'パスワードは扱いません。取り込んだ時間割・課題はこのブラウザの中にだけ保存され、'
    '運営者を含む外部には送信されません。';

final _kdbUrl = Uri.parse('https://kdb.tsukuba.ac.jp/');
final _twinsUrl = Uri.parse('https://twins.tsukuba.ac.jp/campusweb/');
final _manabaUrl = Uri.parse('https://manaba.tsukuba.ac.jp/ct/home_library_query');

Future<void> _openTab(Uri url) => launchUrl(url, webOnlyWindowName: '_blank');

void _openSyllabus(BuildContext context, String code, String name) {
  Clipboard.setData(ClipboardData(text: code));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('科目番号「$code」をコピーしました。KdBの検索欄に貼り付けてください'), duration: const Duration(seconds: 6)),
  );
  _openTab(_kdbUrl);
}

class WebHome extends StatefulWidget {
  final WebState state;

  /// 起動時の取り込み結果(成功/失敗の文)。
  final String? importMessage;
  final bool importFailed;
  const WebHome({super.key, required this.state, this.importMessage, this.importFailed = false});

  @override
  State<WebHome> createState() => _WebHomeState();
}

class _WebHomeState extends State<WebHome> {
  late int _tab = widget.state.timetable.isEmpty && widget.state.assignments.isEmpty ? 2 : 0;

  WebState get s => widget.state;

  @override
  void initState() {
    super.initState();
    final msg = widget.importMessage;
    if (msg != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: widget.importFailed ? Theme.of(context).colorScheme.error : null,
            duration: const Duration(seconds: 6),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            ScheduleView(
              model: s,
              onTapCourse: (ctx, code) => showCourseSheet(
                ctx,
                s,
                code,
                openSyllabus: _openSyllabus,
                openManaba: (_, url, _) => _openTab(url),
                syllabusLabel: 'KdBでシラバスを探す(科目番号をコピー)',
              ),
              emptyText: '時間割がまだありません。\n「取り込み」タブの手順で TWINS から取り込んでください。',
              onFetchRooms: () {
                setState(() => _tab = 2);
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('「教室を取り込む」の手順で、TWINS の「ダウンロード」画面からブックマークを実行してください')));
              },
            ),
            AssignmentsView(
              model: s,
              onTapAssignment: (ctx, a) => _openTab(Uri.parse(a.url)),
              notFetchedText: 'まだ取り込んでいません。\n「取り込み」タブの手順で manaba から取り込んでください。',
            ),
            _ImportTab(state: s),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.calendar_view_week_outlined),
              selectedIcon: Icon(Icons.calendar_view_week),
              label: '日程',
            ),
            NavigationDestination(
              icon: Icon(Icons.assignment_outlined),
              selectedIcon: Icon(Icons.assignment),
              label: '課題',
            ),
            NavigationDestination(
              icon: Icon(Icons.download_outlined),
              selectedIcon: Icon(Icons.download),
              label: '取り込み',
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportTab extends StatelessWidget {
  final WebState state;
  const _ImportTab({required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    Widget step(String n, String title, String body, {Widget? action}) => ListTile(
      leading: CircleAvatar(radius: 14, child: Text(n, style: t.labelLarge)),
      title: Text(title),
      subtitle: Text(body),
      trailing: action,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('取り込み')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('はじめに(1回だけ)', style: t.titleMedium),
                  const SizedBox(height: 8),
                  const Text('取り込み用のブックマーク(ブックマークレット)を登録します。手順ページを開いてください。'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('ブックマークの登録手順'),
                    onPressed: () => _openTab(Uri.base.resolve('setup.html')),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('時間割を取り込む', style: t.titleSmall?.copyWith(color: cs.primary)),
          ),
          step(
            '1',
            'TWINS にログイン',
            '「履修登録・登録状況照会」を開く',
            action: TextButton(onPressed: () => _openTab(_twinsUrl), child: const Text('開く')),
          ),
          step('2', 'ブックマーク「単位ハーネスに取り込む」を実行', '全学期の時間割を読み込み、自動でこのページに戻ります'),
          ListTile(
            dense: true,
            title: Text('最終取り込み: ${formatUpdatedAt(state.twinsSync.lastSuccessAt)}'),
            subtitle: Text('今のモジュール: ${state.currentModule ?? '不明'}'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('未提出の課題を取り込む', style: t.titleSmall?.copyWith(color: cs.primary)),
          ),
          step(
            '1',
            'manaba にログイン',
            'どのページでも OK',
            action: TextButton(onPressed: () => _openTab(_manabaUrl), child: const Text('開く')),
          ),
          step('2', 'ブックマーク「単位ハーネスに取り込む」を実行', '未提出の課題を読み込み、自動でこのページに戻ります'),
          ListTile(dense: true, title: Text('最終取り込み: ${formatUpdatedAt(state.manabaSync.lastSuccessAt)}')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              state.roomsFetchedAt == null ? '教室を取り込む(未取得)' : '教室を取り込み直す',
              style: t.titleSmall?.copyWith(color: cs.primary),
            ),
          ),
          step(
            '1',
            'TWINS のメニュー「ダウンロード」を開く',
            '「kdb_ja.xlsx」が表示される画面',
            action: TextButton(onPressed: () => _openTab(_twinsUrl), child: const Text('開く')),
          ),
          step('2', 'ブックマーク「単位ハーネスに取り込む」を実行', '科目一覧から教室を読み込み、自動でこのページに戻ります(数秒かかります)'),
          ListTile(
            dense: true,
            title: Text(
              state.roomsFetchedAt == null
                  ? '最終取り込み: 未取得'
                  : '最終取り込み: ${formatUpdatedAt(state.roomsFetchedAt)}(${state.autoRooms.length}科目)',
            ),
            subtitle: const Text('個別の教室は、日程で科目をタップして「教室を編集」から設定できます'),
          ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.date_range_outlined),
            title: const Text('今のモジュール'),
            subtitle: Text(
              state.settings.moduleOverride == null
                  ? '自動: TWINSで選択中のタブ(${state.twinsCurrentModule ?? '未取得'})'
                  : '手動で固定中',
            ),
            trailing: DropdownButton<String?>(
              value: state.settings.moduleOverride,
              onChanged: state.setModuleOverride,
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('自動')),
                for (final m in {...state.modules, ?state.settings.moduleOverride})
                  DropdownMenuItem<String?>(value: m, child: Text(m)),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('免責・プライバシー'),
            onTap: () => showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('免責・プライバシー'),
                content: const SingleChildScrollView(child: Text(_disclaimer)),
                actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('閉じる'))],
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: cs.error),
            title: Text('このブラウザのデータを削除', style: TextStyle(color: cs.error)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('削除しますか?'),
                  content: const Text('取り込んだ時間割・課題をこのブラウザから削除します。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('削除')),
                  ],
                ),
              );
              if (ok == true) await state.wipe();
            },
          ),
          const ListTile(dense: true, title: Text('単位ハーネス Web版(非公式)')),
        ],
      ),
    );
  }
}
