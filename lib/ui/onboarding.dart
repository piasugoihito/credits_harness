/// 初回セットアップ: 免責への同意 → 資格情報 → 通知の許可 → 初回取得。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/credentials.dart';
import 'settings_tab.dart' show disclaimerText;

class OnboardingPage extends StatefulWidget {
  final AppState app;
  const OnboardingPage({super.key, required this.app});
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  int _step = 0;
  bool _agreed = false;
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _fetching = false;

  AppState get app => widget.app;

  Future<void> _saveCredentials() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) return;
    await app.saveCredentials(Credentials(_user.text.trim(), _pass.text));
    _pass.clear();
    setState(() => _step = 2);
  }

  Future<void> _fetch() async {
    setState(() => _fetching = true);
    await app.refresh();
    if (mounted) setState(() => _fetching = false);
  }

  Future<void> _finish() => app.updateSettings(app.settings.copyWith(setupDone: true));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_step) {
            0 => _page(
              title: '単位ハーネスへようこそ',
              children: [
                Text('TWINSの時間割・manabaの未提出課題・KdBのシラバスをまとめて見られ、授業の前に通知します。', style: t.bodyLarge),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(disclaimerText, style: t.bodyMedium),
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _agreed,
                  onChanged: (v) => setState(() => _agreed = v ?? false),
                  title: const Text('上記に同意します'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
              next: FilledButton(onPressed: _agreed ? () => setState(() => _step = 1) : null, child: const Text('次へ')),
            ),
            1 => _page(
              title: 'ログイン情報',
              children: [
                Text('TWINS・manabaへの自動ログインに使います。この端末のキーストアにのみ保存されます。', style: t.bodyMedium),
                const SizedBox(height: 16),
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(labelText: '学籍番号', border: OutlineInputBorder()),
                  keyboardType: TextInputType.number,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  decoration: const InputDecoration(labelText: 'パスワード(統一認証)', border: OutlineInputBorder()),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => _saveCredentials(),
                ),
                const SizedBox(height: 12),
                Text('ログインに失敗した場合、アカウントロックを防ぐため自動では再試行しません。', style: t.bodySmall),
              ],
              next: FilledButton(onPressed: _saveCredentials, child: const Text('保存して次へ')),
            ),
            2 => _page(
              title: '授業の通知',
              children: [
                Text('授業開始の${app.settings.leadMinutes}分前に「何の授業か」を通知します(設定で変更・オフにできます)。', style: t.bodyLarge),
                const SizedBox(height: 12),
                Text('祝日や休講は考慮しないので、休みの期間は設定から通知をオフにしてください。', style: t.bodyMedium),
              ],
              next: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: () async {
                      await app.notifier.requestPermissions();
                      setState(() => _step = 3);
                      await _fetch();
                    },
                    child: const Text('通知を許可する'),
                  ),
                  TextButton(
                    onPressed: () async {
                      await app.updateSettings(app.settings.copyWith(notifyEnabled: false));
                      setState(() => _step = 3);
                      await _fetch();
                    },
                    child: const Text('あとで'),
                  ),
                ],
              ),
            ),
            _ => _page(
              title: _fetching ? 'データを取得しています…' : '準備ができました',
              children: [
                if (_fetching) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 16),
                  Text('TWINSとmanabaにログインして、時間割と課題を読み込んでいます(30秒ほど)。', style: t.bodyMedium),
                ] else ...[
                  _resultRow(
                    '時間割',
                    app.twinsSync.failing
                        ? app.twinsSync.lastError
                        : '${app.timetable.values.fold<int>(0, (n, x) => n + x.length)}コマ',
                  ),
                  _resultRow(
                    '課題',
                    app.manabaSync.failing ? app.manabaSync.lastError : '未提出 ${app.assignments.length}件',
                  ),
                  if (app.twinsSync.failing || app.manabaSync.failing)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text('取得できなかった分は、あとで各画面から更新・ログインできます。', style: t.bodySmall),
                    ),
                ],
              ],
              next: FilledButton(onPressed: _fetching ? null : _finish, child: const Text('はじめる')),
            ),
          },
        ),
      ),
    );
  }

  Widget _resultRow(String label, String? value) {
    final failing = label == '時間割' ? app.twinsSync.failing : app.manabaSync.failing;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        failing ? Icons.error_outline : Icons.check_circle_outline,
        color: failing ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary,
      ),
      title: Text(label),
      subtitle: Text(value ?? ''),
    );
  }

  Widget _page({required String title, required List<Widget> children, required Widget next}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 20),
        Expanded(child: ListView(children: children)),
        const SizedBox(height: 12),
        next,
      ],
    );
  }
}
