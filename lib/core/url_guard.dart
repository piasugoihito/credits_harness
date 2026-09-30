/// WebView のナビゲーション・JS 注入を許可するドメイン判定。
library;

/// https かつホストが tsukuba.ac.jp またはそのサブドメインのときだけ true。
/// `twins.tsukuba.ac.jp.evil.com` や `eviltsukuba.ac.jp` のようなサフィックス偽装は弾く。
bool isAllowedUrl(Uri? uri) {
  if (uri == null || uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  return host == 'tsukuba.ac.jp' || host.endsWith('.tsukuba.ac.jp');
}

/// 自動操作で押してはいけない要素のシグネチャ(履修登録/取消・提出など)。JS 側の assertSafe と同じ規則。
final forbiddenAction = RegExp(
  r'DeleteCall|InputCall|OtherInputCall|Cancel|Withdraw|Submit(Report|Assignment)',
  caseSensitive: false,
);
