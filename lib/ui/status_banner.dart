/// 取得状態のバナー(再ログインが必要 / 取得失敗 / オフライン)と最終更新時刻。
library;

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../data/store.dart';
import '../scraper/scrapers.dart';
import '../scraper/web_session.dart';
import 'format.dart';
import 'web_page.dart';

class StatusBanner extends StatelessWidget {
  final AppState app;
  final Source source;
  const StatusBanner({super.key, required this.app, required this.source});

  @override
  Widget build(BuildContext context) {
    final sync = source == Source.twins ? app.twinsSync : app.manabaSync;
    final cs = Theme.of(context).colorScheme;
    final siteName = source == Source.twins ? 'TWINS' : 'manaba';

    if (!app.hasCredentials) {
      return _banner(
        context,
        Icons.key_off_outlined,
        cs.errorContainer,
        cs.onErrorContainer,
        '学籍番号・パスワードが未設定です。設定タブから登録してください。',
      );
    }
    if (!sync.failing) return const SizedBox.shrink();

    final last = '(最終成功: ${formatUpdatedAt(sync.lastSuccessAt)})';
    switch (sync.lastErrorKind) {
      case FailureKind.needsLogin:
        return _banner(
          context,
          Icons.lock_outline,
          cs.errorContainer,
          cs.onErrorContainer,
          '$siteNameへの再ログインが必要です $last\n${sync.lastError ?? ''}',
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WebPage(url: source == Source.twins ? twinsUrl : manabaUrl, title: '$siteNameにログイン'),
                ),
              ),
              child: const Text('手動でログイン'),
            ),
            if (app.autofillFailed)
              TextButton(onPressed: app.refreshing ? null : app.retryLogin, child: const Text('自動ログインを再試行')),
          ],
        );
      case FailureKind.offline:
        return _banner(
          context,
          Icons.cloud_off_outlined,
          cs.surfaceContainerHighest,
          cs.onSurface,
          'オフラインのため更新できませんでした。前回のデータを表示しています $last',
        );
      case FailureKind.structureChanged:
      case FailureKind.blockedHost:
      case null:
        return _banner(
          context,
          Icons.warning_amber_outlined,
          cs.tertiaryContainer,
          cs.onTertiaryContainer,
          '$siteNameの取得に失敗しました(サイトの構造が変わった可能性)。前回のデータを表示しています $last\n${sync.lastError ?? ''}',
        );
    }
  }

  Widget _banner(
    BuildContext context,
    IconData icon,
    Color bg,
    Color fg,
    String text, {
    List<Widget> actions = const [],
  }) {
    return Card(
      color: bg,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: fg, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text.trim(), style: TextStyle(color: fg)),
                ),
              ],
            ),
            if (actions.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(children: actions),
              ),
          ],
        ),
      ),
    );
  }
}
