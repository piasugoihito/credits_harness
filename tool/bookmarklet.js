/*
 * 単位ハーネス Web 版の取り込みブックマークレット(ソース)。tool/build_web.py が __APP_URL__ を置き換えて
 * javascript: URL にし、setup.html に埋め込む。
 *
 * - 利用者自身のブラウザで、ログイン済みの TWINS / manaba のページ上でだけ動く。パスワードには触れない。
 * - 大学サイトへは GET のみ(学期タブのリンクと『未提出の課題一覧』)。履修登録・取消などの要素は使わない。
 * - 取り出すのは時間割表・課題表の HTML だけ。圧縮して URL のフラグメント(#import=...)で Web 版に渡す。
 *   フラグメントはサーバーに送信されない。
 */
(async () => {
  const APP = '__APP_URL__';
  const V = 1;
  /* lib/core/url_guard.dart の forbiddenAction と同じ規則(unsubmitted 等に誤反応しないよう Submit は限定) */
  const FORBIDDEN = /DeleteCall|InputCall|OtherInputCall|Cancel|Withdraw|Submit(Report|Assignment)/i;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  const toast = (() => {
    const el = document.createElement('div');
    el.style.cssText = 'position:fixed;left:50%;top:16px;transform:translateX(-50%);z-index:2147483647;' +
      'background:#1a237e;color:#fff;padding:12px 18px;border-radius:10px;font:15px/1.4 sans-serif;' +
      'box-shadow:0 4px 16px rgba(0,0,0,.3);max-width:90vw';
    document.body.appendChild(el);
    return (msg) => { el.textContent = '単位ハーネス: ' + msg; };
  })();

  /* 文字コード(Shift_JIS 等)を考慮して GET し、Document にする */
  async function getDoc(url) {
    const u = new URL(url, location.href);
    if (u.origin !== location.origin) throw new Error('別サイトへのアクセスは行いません');
    const res = await fetch(u.href, { credentials: 'include' });
    if (!res.ok) throw new Error('読み込みに失敗しました(HTTP ' + res.status + ')');
    const buf = await res.arrayBuffer();
    const m = /charset=([^;]+)/i.exec(res.headers.get('content-type') || '');
    let cs = m ? m[1].trim() : '';
    if (!cs) {
      const head = new TextDecoder('latin1').decode(buf.slice(0, 4096));
      const mm = /<meta[^>]+charset=["']?([\w-]+)/i.exec(head);
      cs = mm ? mm[1] : document.characterSet || 'utf-8';
    }
    const text = new TextDecoder(cs).decode(buf);
    return { doc: new DOMParser().parseFromString(text, 'text/html'), url: res.url || u.href };
  }

  async function encode(obj) {
    const bytes = new TextEncoder().encode(JSON.stringify(obj));
    let method = 'j';
    let out = bytes;
    if (typeof CompressionStream === 'function') {
      const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate'));
      out = new Uint8Array(await new Response(stream).arrayBuffer());
      method = 'z';
    }
    let bin = '';
    for (let i = 0; i < out.length; i += 0x8000) bin += String.fromCharCode.apply(null, out.subarray(i, i + 0x8000));
    return method + '.' + btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  const tabLabel = (td) => td.textContent.trim();

  async function twins() {
    let doc = document;
    if (!doc.querySelector('table.rishu-koma')) {
      throw new Error('TWINS の「履修登録・登録状況照会」の画面を開いてから実行してください');
    }
    const labels = Array.from(doc.querySelectorAll('td.rishu-tab, td.rishu-tab-sel')).map(tabLabel);
    const selTd = doc.querySelector('td.rishu-tab-sel');
    const current = selTd ? tabLabel(selTd) : null;
    const byLabel = {};
    if (current) byLabel[current] = doc.querySelector('table.rishu-koma').outerHTML;

    let done = 0;
    for (const label of labels) {
      if (byLabel[label]) continue;
      toast('時間割を読み込み中… (' + (++done) + '/' + (labels.length - 1) + ')');
      /* 直前に取得したページのリンクを使う(_flowExecutionKey は毎回変わるため) */
      const a = Array.from(doc.querySelectorAll('td.rishu-tab a')).find((x) => x.textContent.trim() === label);
      if (!a) throw new Error('学期タブ「' + label + '」のリンクが見つかりません');
      if (FORBIDDEN.test((a.getAttribute('onclick') || '') + ' ' + (a.getAttribute('href') || ''))) {
        throw new Error('想定外のリンクのため中止しました');
      }
      const got = await getDoc(a.getAttribute('href'));
      const sel = got.doc.querySelector('td.rishu-tab-sel');
      const table = got.doc.querySelector('table.rishu-koma');
      if (!sel || tabLabel(sel) !== label || !table) {
        throw new Error('「' + label + '」の時間割を取得できませんでした(ログインが切れた可能性)');
      }
      byLabel[label] = table.outerHTML;
      doc = got.doc;
      await sleep(400); /* サイトへの負荷を抑える */
    }
    return { v: V, kind: 'twins', current: current, tabs: labels.map((l) => ({ label: l, html: byLabel[l] })) };
  }

  async function manaba() {
    toast('未提出の課題を読み込み中…');
    const home = await getDoc('/ct/home_library_query');
    const img = home.doc.querySelector('img[alt="未提出の課題一覧"]');
    const link = img && img.closest('a');
    if (!link) throw new Error('『未提出の課題一覧』が見つかりません(ログインが切れた可能性)');
    if (FORBIDDEN.test(link.getAttribute('href') || '')) throw new Error('想定外のリンクのため中止しました');
    const list = await getDoc(new URL(link.getAttribute('href'), home.url).href);
    const table = list.doc.querySelector('table.stdlist');
    if (!table) throw new Error('課題の表が見つかりません');
    return { v: V, kind: 'manaba', base: list.url, html: table.outerHTML };
  }

  try {
    let payload;
    if (document.querySelector('td.rishu-tab, td.rishu-tab-sel, table.rishu-koma')) payload = await twins();
    else if (/(^|\.)manaba\.tsukuba\.ac\.jp$/.test(location.hostname)) payload = await manaba();
    else throw new Error('TWINS(履修登録・登録状況照会)か manaba を開いてから実行してください');
    toast('単位ハーネスを開いています…');
    location.href = APP + '#import=' + (await encode(payload));
  } catch (e) {
    toast('エラー: ' + (e && e.message ? e.message : e));
  }
})();
