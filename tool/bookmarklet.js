/*
 * 単位ハーネス Web 版の取り込みブックマークレット(ソース)。tool/build_web.py が __APP_URL__ を置き換えて
 * javascript: URL にし、setup.html に埋め込む。
 *
 * - 利用者自身のブラウザで、ログイン済みの TWINS / manaba のページ上でだけ動く。パスワードには触れない。
 * - 大学サイトへは GET のみ(学期タブのリンク・『未提出の課題一覧』・「ダウンロード」画面の kdb_ja.xlsx)。
 *   履修登録・取消などの要素は使わない。
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

  async function getBytes(url) {
    const u = new URL(url, location.href);
    if (u.origin !== location.origin) throw new Error('別サイトへのアクセスは行いません');
    const res = await fetch(u.href, { credentials: 'include' });
    if (!res.ok) throw new Error('読み込みに失敗しました(HTTP ' + res.status + ')');
    return new Uint8Array(await res.arrayBuffer());
  }

  /* ---- kdb_ja.xlsx(zip + XML)の最小限の読み取り。lib/core/kdb_rooms.dart と同じ規則: 6行目から A=科目番号, H=教室 */
  async function unzip(buf, wanted) {
    const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    let eocd = -1;
    for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
      if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) throw new Error('kdb_ja.xlsx を読めませんでした(ログインが切れた可能性)');
    const count = dv.getUint16(eocd + 10, true);
    let p = dv.getUint32(eocd + 16, true);
    const utf8 = new TextDecoder();
    const out = {};
    for (let k = 0; k < count; k++) {
      if (dv.getUint32(p, true) !== 0x02014b50) throw new Error('kdb_ja.xlsx の形式が想定と違います');
      const method = dv.getUint16(p + 10, true);
      const csize = dv.getUint32(p + 20, true);
      const nlen = dv.getUint16(p + 28, true), elen = dv.getUint16(p + 30, true), clen = dv.getUint16(p + 32, true);
      const off = dv.getUint32(p + 42, true);
      const name = utf8.decode(buf.subarray(p + 46, p + 46 + nlen));
      p += 46 + nlen + elen + clen;
      if (!wanted(name)) continue;
      const start = off + 30 + dv.getUint16(off + 26, true) + dv.getUint16(off + 28, true);
      const data = buf.subarray(start, start + csize);
      const raw = method === 0 ? data : new Uint8Array(await new Response(
        new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());
      out[name] = utf8.decode(raw);
    }
    return out;
  }

  const unescapeXml = (s) => s.replace(/&(lt|gt|amp|quot|apos|#\d+|#x[0-9a-f]+);/gi, (m, e) => {
    const map = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" };
    if (map[e]) return map[e];
    return String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
  });
  const texts = (xml) => {
    let r = '';
    for (const m of xml.replace(/<rPh[\s\S]*?<\/rPh>/g, '').matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)) r += m[1];
    return unescapeXml(r);
  };
  const normalizeRoom = (s) => s.split(/[\r\n]+/).map((x) => x.trim().replace(/\s+/g, ' ')).filter(Boolean).join('・');

  async function kdbRooms(buf) {
    const files = await unzip(buf, (n) => /^xl\/(workbook\.xml|_rels\/workbook\.xml\.rels|sharedStrings\.xml|worksheets\/[^/]+\.xml)$/.test(n));
    let sheetPath = 'xl/worksheets/sheet1.xml';
    const rid = /<sheet\b[^>]*\br:id="([^"]+)"/.exec(files['xl/workbook.xml'] || '');
    if (rid) {
      const rel = new RegExp('<Relationship\\b[^>]*\\bId="' + rid[1] + '"[^>]*>').exec(files['xl/_rels/workbook.xml.rels'] || '');
      const target = rel && /\bTarget="([^"]+)"/.exec(rel[0]);
      if (target) sheetPath = target[1].startsWith('/') ? target[1].slice(1) : 'xl/' + target[1];
    }
    const sheet = files[sheetPath] || files['xl/worksheets/sheet1.xml'];
    if (!sheet) throw new Error('kdb_ja.xlsx にシートが見つかりません');
    const shared = [];
    for (const m of (files['xl/sharedStrings.xml'] || '').matchAll(/<si>([\s\S]*?)<\/si>|<si\/>/g)) shared.push(m[1] ? texts(m[1]) : '');

    const codes = {}, rooms = {};
    for (const m of sheet.matchAll(/<c\s([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const ref = /\br="([A-Z]+)(\d+)"/.exec(m[1]);
      if (!ref || (ref[1] !== 'A' && ref[1] !== 'H') || Number(ref[2]) < 6 || !m[2]) continue;
      const type = (/\bt="([^"]+)"/.exec(m[1]) || [])[1];
      let v;
      if (type === 'inlineStr') v = texts(m[2]);
      else {
        const vm = /<v>([\s\S]*?)<\/v>/.exec(m[2]);
        v = vm ? unescapeXml(vm[1]) : '';
        if (type === 's') v = shared[Number(v)] || '';
      }
      (ref[1] === 'A' ? codes : rooms)[ref[2]] = v;
    }
    /* URL を短くするため 教室 → [科目番号] にまとめる */
    const grouped = {};
    let n = 0;
    for (const row in codes) {
      const code = codes[row].trim();
      const room = normalizeRoom(rooms[row] || '');
      if (!code || !room) continue;
      (grouped[room] = grouped[room] || []).push(code);
      n++;
    }
    if (!n) throw new Error('kdb_ja.xlsx から教室を読み取れませんでした');
    return grouped;
  }

  async function roomsFromDownloadPage(link) {
    toast('科目一覧(kdb_ja.xlsx)を読み込み中…');
    if (FORBIDDEN.test(link.getAttribute('href') || '')) throw new Error('想定外のリンクのため中止しました');
    const buf = await getBytes(link.getAttribute('href'));
    toast('教室を読み取り中…');
    return { v: V, kind: 'rooms', rooms: await kdbRooms(buf) };
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
    const kdbLink = Array.from(document.querySelectorAll('a')).find((a) => a.textContent.trim() === 'kdb_ja.xlsx');
    if (kdbLink) payload = await roomsFromDownloadPage(kdbLink);
    else if (document.querySelector('td.rishu-tab, td.rishu-tab-sel, table.rishu-koma')) payload = await twins();
    else if (/(^|\.)manaba\.tsukuba\.ac\.jp$/.test(location.hostname)) payload = await manaba();
    else throw new Error('TWINS(「履修登録・登録状況照会」または「ダウンロード」)か manaba を開いてから実行してください');
    toast('単位ハーネスを開いています…');
    location.href = APP + '#import=' + (await encode(payload));
  } catch (e) {
    toast('エラー: ' + (e && e.message ? e.message : e));
  }
})();
