# 参考資料 (reference/)

要件定義書 `../REQUIREMENTS.md` に書ききれない分。**信頼度**の列に注意(検証済み = 実際に動かして確認)。

| ファイル | 内容 | 信頼度 |
|---|---|---|
| `python_poc/fetch_timetable.py` | TWINSにログイン→学期タブを巡回→時間割(科目番号・曜日・時限)取得。パーサー `parse_timetable` / `parse_tabs` | 検証済み(実サイトで15/13/2コマ取得。パーサーは単体テスト済み) |
| `python_poc/fetch_assignments.py` | manabaの『未提出の課題一覧』取得。パーサー `parse_assignments` | 検証済み(実サイトで2件取得) |
| `python_poc/fetch_syllabus.py` | KdBで科目番号検索→シラバス本文取得 | **画面構造は未確認**(robots.txtで私のツールが閲覧不可。ユーザー提供のセレクタのみ根拠)。処理ロジックの単体テストのみ |
| `fixtures/twins_registration.html` | 学期タブ+時間割表の**架空データ**HTML(実DOM構造と同形) | 実HTML(ユーザー提供)から構造を写した合成データ |
| `fixtures/manaba_unsubmitted.html` | 未提出課題テーブルの**架空データ**HTML | 同上 |
| `expected/*.json` | 上記フィクスチャに対する正解出力(ゴールデンテスト用)。Python PoCのパーサー出力 | 検証済み |
| `webview_snippets.js` | WebViewに注入するJS(自動入力・メニュー/タブ/ボタンのクリック・安全ガード) | jsdomで単体テスト済み。**実機WebViewは未検証** |
| `dart_sketch.md` | Dart移植スケッチ(パーサー、授業ブロック生成、通知プラン、更新の状態機械) | **未実行**。ゴールデンテストで検証すること |
| `period_times.json` | 筑波キャンパスの時限(1限 8:40 〜 6限 16:45-18:00) | 大学公式資料の複数箇所で一致 |
| `academic_calendar.example.json` | 学年暦JSONのスキーマ。確認済みなのは学期の開始/終了のみ | **DRAFT**: モジュール日程・休講・振替は未記入 |

## 個人情報について
`fixtures/` は架空データ。**実データ(実際の科目・学籍番号・氏名を含むHTML/JSON)はリポジトリに入れない**。
PoCの出力(`timetable.json`, `assignments.json`, `auth_state.json`, `debug_*`)は `.gitignore` 対象。

## PoCで判明している実サイトの事実
- TWINS: ログインページは `/campusweb/` 上。ユーザー欄 `#userNameInput`(name=userName)、パスワード欄 `#passwordInput`(name=password)。ログインボタンの正体は未確認。
- TWINS: ログイン後メニュー `<span class="menunm">履修登録・登録状況照会</span>`(親は`<a>`)をクリックすると `campussquare.do?_flowExecutionKey=…` に遷移。**このキーはリクエストごとに変わる使い捨て**(URL決め打ち不可)。
- TWINS 時間割: 登録済みコマは `a[onclick^="DeleteCallA('年度','?','科目番号','曜日(1=月)','時限')"]`。未登録は `InputCallA('曜日','時限')`。第2引数(`'25'` `'26'` `'1F'` など)の意味は不明。
- TWINS 学期タブ: `td.rishu-tab`(リンクあり) / `td.rishu-tab-sel`(選択中・リンクなし)。ラベルは 春A 春B 春C 夏休 秋A 秋B 秋C 春休。タブは学期ごとに正確なコマを返す(例: 秋Aにあって秋Bに無い科目がある)。
- manaba: `https://manaba.tsukuba.ac.jp/ct/home_library_query` の `img[alt="未提出の課題一覧"]` をクリック → `table.stdlist`。受付終了が空 = 期限なし。期限切れでも未提出なら一覧に残る。
- セッション: ヘッドあり実行ではCookie再利用でログイン画面が出なかった。**ヘッドレス(画面なし)で再利用できるか、TWINSとmanabaのSSO共有の有無は未確認**。
