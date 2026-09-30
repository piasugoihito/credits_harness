/// 設定タブ。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import '../app/courses_model.dart';
import '../data/credentials.dart';
import '../data/store.dart';
import '../m0/spike_page.dart';
import '../notify/notifier.dart';

const appVersion = '0.1.0';

const disclaimerText =
    '本アプリは筑波大学とは無関係の非公式アプリです。利用は自己責任でお願いします。'
    '大学の利用規程は各自で確認してください。\n\n'
    '学籍番号・パスワード・取得したデータはこの端末の中にだけ保存され、外部には送信されません。'
    '大学のサイトに対しては読み取りのみを行い、履修登録・取消や課題の提出などは一切行いません。';

class SettingsTab extends StatefulWidget {
  final AppState app;
  const SettingsTab({super.key, required this.app});
  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> with WidgetsBindingObserver {
  PermissionStatus? _perm;
  int? _pending;

  AppState get app => widget.app;
  Settings get s => app.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 端末の設定アプリから戻ってきたときに権限状態を読み直す
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadStatus();
  }

  Future<void> _loadStatus() async {
    final p = await app.notifier.status();
    final n = await app.notifier.pendingCount();
    if (!mounted) return;
    setState(() {
      _perm = p;
      _pending = n;
    });
  }

  Future<void> _update(Settings next) async {
    await app.updateSettings(next);
    await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          const _Header('アカウント'),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('学籍番号・パスワード'),
            subtitle: Text(app.hasCredentials ? '登録済み(端末内のみに保存)' : '未登録'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => showCredentialDialog(context, app),
          ),
          if (app.autofillFailed)
            ListTile(
              leading: Icon(Icons.error_outline, color: cs.error),
              title: const Text('自動ログインを停止中'),
              subtitle: const Text('前回ログインに失敗したため、アカウントロック防止のため止めています'),
              trailing: TextButton(onPressed: app.refreshing ? null : app.retryLogin, child: const Text('再試行')),
            ),
          if (app.hasCredentials)
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('ログアウト'),
              subtitle: const Text('学籍番号・パスワードとログイン状態(Cookie)を削除'),
              onTap: () async {
                if (await _confirm(context, 'ログアウトしますか?', '取得済みの時間割・課題は残ります。')) await app.logout();
              },
            ),

          const _Header('通知'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('授業開始の通知'),
            subtitle: const Text('祝日・休講は考慮しません。休みの期間はオフにしてください'),
            value: s.notifyEnabled,
            onChanged: (v) async {
              if (v && _perm?.notificationsEnabled != true) await app.notifier.requestPermissions();
              await _update(s.copyWith(notifyEnabled: v));
            },
          ),
          ListTile(
            enabled: s.notifyEnabled,
            leading: const Icon(Icons.timer_outlined),
            title: const Text('何分前に通知するか'),
            trailing: DropdownButton<int>(
              value: s.leadMinutes,
              onChanged: s.notifyEnabled ? (v) => _update(s.copyWith(leadMinutes: v)) : null,
              items: [for (final m in leadMinuteChoices) DropdownMenuItem(value: m, child: Text('$m分前'))],
            ),
          ),
          if (_perm != null && (!_perm!.notificationsEnabled || !_perm!.exactAlarms))
            ListTile(
              leading: Icon(Icons.warning_amber_outlined, color: cs.error),
              title: Text(!_perm!.notificationsEnabled ? '通知が許可されていません' : '正確なアラームが許可されていません'),
              subtitle: Text(!_perm!.notificationsEnabled ? '通知が届きません' : '通知が数分遅れることがあります'),
              trailing: TextButton(
                onPressed: () async {
                  await app.notifier.requestPermissions();
                  await _loadStatus();
                },
                child: const Text('許可する'),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.send_outlined),
            title: const Text('テスト通知'),
            subtitle: Text('5秒後に届きます${_pending == null ? '' : '(予約中の授業通知 $_pending件)'}'),
            onTap: () async {
              await app.notifier.scheduleTest(const Duration(seconds: 5));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('5秒後にテスト通知を送ります')));
              }
              await Future<void>.delayed(const Duration(seconds: 6));
              // テスト通知(ID=1)を送った後、授業通知の予約を作り直しておく
              await app.reschedule();
              await _loadStatus();
            },
          ),

          const _Header('学期(モジュール)'),
          ListTile(
            leading: const Icon(Icons.date_range_outlined),
            title: const Text('今のモジュール'),
            subtitle: Text(
              s.moduleOverride == null ? '自動: TWINSで選択中のタブ(${app.twinsCurrentModule ?? '未取得'})' : '手動で固定中',
            ),
            trailing: DropdownButton<String?>(
              value: s.moduleOverride,
              onChanged: (v) => _update(s.copyWith(moduleOverride: () => v)),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('自動')),
                for (final m in {...app.modules, ?s.moduleOverride})
                  DropdownMenuItem<String?>(value: m, child: Text(m)),
              ],
            ),
          ),

          const _Header('データ更新'),
          SwitchListTile(
            secondary: const Icon(Icons.sync),
            title: const Text('起動時に自動で更新'),
            subtitle: Text('前回の更新から${s.refreshHours}時間以上たっていれば更新'),
            value: s.autoRefresh,
            onChanged: (v) => _update(s.copyWith(autoRefresh: v)),
          ),
          ListTile(
            enabled: s.autoRefresh,
            leading: const Icon(Icons.hourglass_empty),
            title: const Text('更新の間隔'),
            trailing: DropdownButton<int>(
              value: s.refreshHours,
              onChanged: s.autoRefresh ? (v) => _update(s.copyWith(refreshHours: v)) : null,
              items: [
                for (final h in const [1, 3, 6, 12, 24]) DropdownMenuItem(value: h, child: Text('$h時間')),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('今すぐ更新'),
            subtitle: Text(app.refreshing ? '更新中…' : 'TWINS(時間割)と manaba(課題)'),
            enabled: !app.refreshing && app.hasCredentials,
            onTap: () => app.refresh(),
          ),

          const _Header('データ'),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: cs.error),
            title: Text('すべてのデータを削除', style: TextStyle(color: cs.error)),
            subtitle: const Text('資格情報・ログイン状態・時間割・課題・設定・予約中の通知'),
            onTap: () async {
              if (await _confirm(context, 'すべて削除しますか?', '初回セットアップからやり直しになります。')) await app.wipe();
            },
          ),

          const _Header('情報'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('免責・プライバシー'),
            onTap: () => showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('免責・プライバシー'),
                content: const SingleChildScrollView(child: Text(disclaimerText)),
                actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('閉じる'))],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('取得ログ'),
            subtitle: const Text('不具合の報告用(個人情報は含みません)'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _LogPage(app: app))),
          ),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('ライセンス'),
            onTap: () => showLicensePage(context: context, applicationName: '単位ハーネス', applicationVersion: appVersion),
          ),
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('開発者向け: M0 検証画面'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SpikePage())),
          ),
          const ListTile(title: Text('単位ハーネス v$appVersion(非公式)'), dense: true),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
        ],
      ),
    ) ??
    false;

/// 学籍番号・パスワードの入力ダイアログ。戻り値: 保存したか。
Future<bool> showCredentialDialog(BuildContext context, AppState app) async {
  final user = TextEditingController();
  final pass = TextEditingController();
  final saved = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('学籍番号・パスワード'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: user,
            decoration: const InputDecoration(labelText: '学籍番号'),
            keyboardType: TextInputType.number,
            autocorrect: false,
            autofillHints: const [AutofillHints.username],
          ),
          TextField(
            controller: pass,
            decoration: const InputDecoration(labelText: 'パスワード(統一認証)'),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
          ),
          const SizedBox(height: 12),
          const Text('この端末のキーストアにのみ保存されます。', style: TextStyle(fontSize: 12)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
        FilledButton(
          onPressed: () {
            if (user.text.trim().isEmpty || pass.text.isEmpty) return;
            Navigator.pop(c, true);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (saved == true) {
    await app.saveCredentials(Credentials(user.text.trim(), pass.text));
  }
  return saved == true;
}

class _LogPage extends StatelessWidget {
  final AppState app;
  const _LogPage({required this.app});
  @override
  Widget build(BuildContext context) {
    final text = app.log.isEmpty ? '(まだありません)' : app.log.join('\n');
    return Scaffold(
      appBar: AppBar(
        title: const Text('取得ログ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'コピー',
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
      ),
    );
  }
}
