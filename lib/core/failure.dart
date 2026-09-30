/// 取得失敗の種類(画面のバナーの出し分けに使う)。
library;

enum FailureKind {
  /// ログインが必要(自動ログイン失敗・資格情報なし・MFA 等)
  needsLogin,

  /// 期待した画面要素・表が見つからない(サイト構造の変更の可能性)
  structureChanged,

  /// ネットワークに接続できない
  offline,

  /// 許可ドメイン外へ遷移しようとした
  blockedHost,
}
