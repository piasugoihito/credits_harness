/*
 * WebView(flutter_inappwebview)に注入するJS。Playwright PoCの操作をDOM操作に移植したもの。
 * 【未検証】実機WebViewでは動かしていない。M0(実現性スパイク)で検証すること。
 *
 * 使い方(Dart側):
 *   await controller.evaluateJavascript(source: kSnippets);          // 1回注入
 *   final r = await controller.evaluateJavascript(
 *       source: 'TS.fillLogin(${jsonEncode(user)}, ${jsonEncode(pass)})');  // 値は必ず jsonEncode で渡す
 *
 * 絶対ルール:
 *   - 認証情報をログ・例外メッセージ・戻り値に含めない。
 *   - 許可ドメイン(*.tsukuba.ac.jp)以外では何もしない (フィッシング/リダイレクト対策)。
 *   - クリックしてよいのは下の関数が指定するセレクタだけ。履修取消(DeleteCallA)・履修登録(InputCall*)
 *     など副作用のある要素は assertSafe() で弾く。
 */
(function () {
  'use strict';

  const ALLOWED_HOST = /(^|\.)tsukuba\.ac\.jp$/;
  const FORBIDDEN = /DeleteCall|InputCall|OtherInputCall|Cancel|Withdraw|Submit(Report|Assignment)/i;
  const LOGIN_LABEL = /ログイン|login|sign\s*in/i;
  const INTERACTIVE = 'input[type="submit"],input[type="button"],input[type="image"],button,a,[role="button"],[onclick]';

  function assertHost() {
    if (!ALLOWED_HOST.test(location.hostname)) throw new Error('blocked host');
  }
  function assertSafe(el) {
    const sig = (el.getAttribute('onclick') || '') + ' ' + (el.getAttribute('href') || '');
    if (FORBIDDEN.test(sig)) throw new Error('forbidden action');
  }
  function visible(el) {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  }
  // ReactやVueでも値が反映されるよう、ネイティブsetter経由で入力する
  function setValue(el, v) {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function labelOf(el) {
    return ((el.value || el.alt || el.title || el.getAttribute('aria-label') || el.innerText || '') + '').trim().slice(0, 40);
  }

  // ---------------------------------------------------------------- 共通・TWINS/manaba
  const TS = {
    /** パスワード入力欄が見えていればログイン画面 */
    isLoginPage() {
      assertHost();
      return Array.from(document.querySelectorAll('input[type="password"]')).some(visible);
    },

    /**
     * PoCの try_autofill 相当。パスワード欄と同じform内のユーザー欄・ログインボタンを探して入力→送信。
     * 戻り値(診断用・値は含まない): {ok, userField, passField, button}
     * 失敗が返ったら【自動再試行しない】(アカウントロック防止)。呼び出し側で失敗フラグを保存し、
     * ユーザーに手動ログイン(可視WebView)を促す。
     * 観測済み(TWINS): ユーザー欄 id=userNameInput name=userName / パスワード欄 id=passwordInput name=password
     * ログインボタンの正体は未確認(→M0で確認)。
     */
    fillLogin(user, pass) {
      assertHost();
      const pw = Array.from(document.querySelectorAll('input[type="password"]')).find(visible);
      if (!pw) return JSON.stringify({ ok: false, reason: 'no-password-field' });
      const form = pw.closest('form');
      const scope = form || document;
      const userEl = Array.from(scope.querySelectorAll('input[type="text"],input[type="email"],input:not([type])')).find(visible);
      if (!userEl) return JSON.stringify({ ok: false, reason: 'no-user-field' });
      setValue(userEl, user);
      setValue(pw, pass);

      // ログインボタン: form内 → ページ全体の順で、ラベルが短く「ログイン」を含む要素
      let btn = null;
      for (const root of form ? [form, document] : [document]) {
        btn = Array.from(root.querySelectorAll(INTERACTIVE))
          .filter(visible)
          .find((e) => { const l = labelOf(e); return l.length <= 15 && LOGIN_LABEL.test(l); });
        if (btn) break;
      }
      const diag = {
        userField: userEl.id || userEl.name || '?',
        passField: pw.id || pw.name || '?',
        button: btn ? (btn.tagName.toLowerCase() + ':' + labelOf(btn)) : null,
      };
      if (btn) btn.click();
      else if (form && form.requestSubmit) form.requestSubmit();
      else if (form) form.submit();
      else return JSON.stringify(Object.assign({ ok: false, reason: 'no-submit' }, diag));
      return JSON.stringify(Object.assign({ ok: true }, diag));
    },

    /** ログイン画面上のエラーらしき行(最大3行)。個人情報を含みにくい行だけ。 */
    loginErrorHint() {
      const re = /エラー|正しく|誤|ロック|失敗|無効|invalid|incorrect|error/i;
      return JSON.stringify(
        document.body.innerText.split('\n').map((s) => s.trim()).filter((s) => s && re.test(s)).slice(0, 3).map((s) => s.slice(0, 80))
      );
    },

    /**
     * TWINSのメニュー <span class="menunm">履修登録・登録状況照会</span> を、親の<a>ごと直接クリック。
     * ドロップダウンが閉じていても押せる(見えている必要なし)。戻り値: 押せたか。
     * 遷移先URLの _flowExecutionKey は毎回変わる使い捨て → URLを保存・再利用しないこと。
     */
    clickMenu(text) {
      assertHost();
      const span = Array.from(document.querySelectorAll('span.menunm')).find((s) => s.textContent.includes(text));
      if (!span) return false;
      const target = span.closest('a') || span;
      assertSafe(target);
      target.click();
      return true;
    },

    /** 学期タブの一覧: [{label, selected}] (選択中のタブはリンクを持たない) */
    listTabs() {
      return JSON.stringify(
        Array.from(document.querySelectorAll('td.rishu-tab, td.rishu-tab-sel')).map((td) => ({
          label: td.textContent.trim(),
          selected: td.classList.contains('rishu-tab-sel'),
        }))
      );
    },

    /** 学期タブ(未選択)のリンクをクリック。押すのはこのタブリンクだけ。 */
    clickTab(label) {
      assertHost();
      const a = Array.from(document.querySelectorAll('td.rishu-tab a')).find((x) => x.textContent.trim() === label);
      if (!a) return false;
      assertSafe(a);
      a.click();
      return true;
    },

    hasTimetable() {
      return !!document.querySelector('table.rishu-koma');
    },

    /** manaba: 『未提出の課題一覧』ボタン(img alt)をクリック。親<a>があればそちら。 */
    clickImageButton(alt) {
      assertHost();
      const img = document.querySelector('img[alt="' + alt.replace(/"/g, '') + '"]');
      if (!img) return false;
      const target = img.closest('a') || img;
      assertSafe(target);
      target.click();
      return true;
    },

    hasAssignmentsTable() {
      return !!document.querySelector('table.stdlist');
    },

    /** パース用に全HTMLを返す(Dart側 package:html でパースする) */
    getHtml() {
      return document.documentElement.outerHTML;
    },
  };

  // ---------------------------------------------------------------- KdB (ログイン不要)
  // 注意: KdBは robots.txt で自動アクセス不可。ユーザーが科目ボタンを押した時に1件だけ実行し、結果はキャッシュ。
  const KDB = {
    /** #txtSyllabus に科目番号を入れて #btnSearch を押す */
    search(code) {
      assertHost();
      const input = document.querySelector('#txtSyllabus');
      const btn = document.querySelector('#btnSearch');
      if (!input || !btn) return false;
      setValue(input, code);
      btn.click();
      return true;
    },
    /** 検索結果の科目名 p.ut-break-word.ut-title の一覧 */
    listResults() {
      return JSON.stringify(Array.from(document.querySelectorAll('p.ut-break-word.ut-title')).map((p) => p.textContent.trim()));
    },
    /** 科目名が一致する結果(なければ先頭)をクリック。シラバスの開き方(同一画面/新タブ/ダイアログ)は未確認。 */
    clickResult(name) {
      const ps = Array.from(document.querySelectorAll('p.ut-break-word.ut-title'));
      const p = (name && ps.find((x) => x.textContent.trim() === name)) || ps[0];
      if (!p) return false;
      p.click();
      return true;
    },
  };

  window.TS = TS;
  window.KDB = KDB;
})();
