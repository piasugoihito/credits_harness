# 単位ハーネス (credits_harness)

筑波大学の学生向け **非公式** ツール(Flutter)。TWINS の時間割・manaba の未提出課題・KdB のシラバスをまとめて見られます。

- **Android アプリ**: アプリ内でTWINS/manabaにログインして自動取得し、授業開始 N 分前にローカル通知します。
- **Web 版(iPhone など)**: ブックマークレットでTWINS/manabaの表を読み取って表示します(通知なし・パスワードは扱わない)。

> **免責**: 本アプリは筑波大学とは無関係の非公式アプリです。利用は自己責任で、大学の利用規程は各自で確認してください。
> 学籍番号・パスワード・取得データは端末内(Android Keystore / アプリ内DB)にのみ保存し、外部には送信しません。
> 大学サイトに対しては読み取り専用です(履修登録・取消・課題提出などは一切行いません)。

## 状態

| マイルストーン | 状態 |
|---|---|
| M0 実現性スパイク | 実機(Android)で確認済み → [docs/M0.md](docs/M0.md) |
| M1 コア(パーサー・通知プラン) | 実装済み・`flutter test` 通過 |
| M2〜M3 取得基盤・画面(Android) | 実機で確認済み |
| Web 版(ブックマークレット) | PC Chrome で実サイト確認済み |
| リリース(APK 配布・Web 公開) | 未着手 |

要件は [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)、参考資料は [docs/reference/](docs/reference/)。

## 開発

```bash
flutter test          # ゴールデンテスト含む
flutter run           # USB接続したAndroid実機で起動
python3 tool/build_web.py --app-url http://localhost:8080/   # Web 版(build/web)とブックマークレット入り setup.html を生成
```

- 対象: Android 8.0 (API 26) 以上。iOS は後日対応(Flutter なので構造は保つ)。
- 学年暦は使わない。「今のモジュール」は TWINS で最初に選択されているタブ(設定で手動固定も可)。祝日・休講は考慮しない。
- `test/fixtures` は架空データ。実データ(実際の科目・学籍番号・氏名を含む HTML/JSON)はコミットしない。

## 構成

```
lib/core/      純Dart: モデル, パーサー(package:html), 授業ブロック/通知プラン, 課題グループ, URLガード
lib/app/       画面が読むデータ(CoursesModel)と Android の状態・更新手順(AppState)
lib/scraper/   Android: HeadlessInAppWebView による取得。ナビゲーションは *.tsukuba.ac.jp に限定
lib/notify/    Android: flutter_local_notifications(全キャンセル→全登録で冪等)
lib/data/      資格情報(flutter_secure_storage)・設定/データ保存
lib/ui/        画面(views/ は Android と Web で共通)
lib/web/       Web 版: ブックマークレットからの取り込み・画面(エントリーポイント lib/main_web.dart)
lib/m0/        M0 検証画面(設定の「開発者向け」から開ける)
tool/          ブックマークレットのソース・setup.html テンプレート・Web ビルドスクリプト
```

## ライセンス

MIT
