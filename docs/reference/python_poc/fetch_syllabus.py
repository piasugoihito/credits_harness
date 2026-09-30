"""
KdB(筑波大学 科目データベース) から、科目番号でシラバス本文を取得して保存する。ログイン不要。

使い方:
  pip install playwright beautifulsoup4     # 済みなら不要
  python fetch_syllabus.py ZZ10001 ZZ10002  # 科目番号を指定
  python fetch_syllabus.py --from-timetable # timetable.json の全科目 (fetch_timetable.py の出力)

オプション:
  --refresh   キャッシュがあっても再取得する
  --show      ブラウザを表示して動きを見る
  --debug     各科目の画面HTML/スクリーンショットを debug_kdb_<科目番号>.* に保存
  --delay N   科目ごとの待ち時間(秒, デフォルト3)

出力:
  syllabus.json          全科目のまとめ (キャッシュを兼ねる)
  syllabus/<科目番号>.txt  読みやすいテキスト

流れ:
  https://kdb.tsukuba.ac.jp/ を開く -> #txtSyllabus に科目番号 -> #btnSearch をクリック
  -> 結果の科目名(p.ut-title)をクリックしてシラバスを開く -> 本文テキストを取得

サイトへの配慮:
  KdBは自動アクセスを歓迎しない設定(robots.txt)なので、必要な科目だけ・1件ずつ・
  間隔を空けて取得し、取得済みはキャッシュを使う。頻繁に --refresh しないこと。
"""
import argparse
import json
import re
import time
from datetime import datetime
from pathlib import Path

KDB_URL = "https://kdb.tsukuba.ac.jp/"
SEARCH_INPUT = "#txtSyllabus"
SEARCH_BUTTON = "#btnSearch"
RESULT_TITLE = "p.ut-break-word.ut-title"

CACHE = Path("syllabus.json")
TXT_DIR = Path("syllabus")
TIMETABLE = Path("timetable.json")

# シラバスの項目名 (該当行があれば sections に分割。無ければ text 全体だけ使う)
HEADINGS = [
    "科目番号", "科目名", "授業方法", "単位数", "標準履修年次", "時間割", "開講年度",
    "担当教員", "授業概要", "到達目標", "キーワード", "授業計画", "履修条件",
    "成績評価方法", "教科書", "参考書", "教科書・参考書", "オフィスアワー",
    "備考", "要旨", "実務経験",
]


# ---------------------------------------------------------------- テキスト処理
def clean_text(text):
    text = text.replace("\r", "").replace("\u00a0", " ")
    lines = [ln.rstrip() for ln in text.split("\n")]
    text = "\n".join(lines)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def split_sections(text):
    """行頭が項目名の行で区切って {項目名: 本文} にする。同名は連結。"""
    pat = re.compile(r"^(" + "|".join(map(re.escape, sorted(HEADINGS, key=len, reverse=True))) + r")[\t :：]*(.*)$")
    sections, current = {}, None
    for line in text.split("\n"):
        m = pat.match(line.strip())
        if m:
            current = m.group(1)
            sections.setdefault(current, [])
            if m.group(2):
                sections[current].append(m.group(2))
        elif current is not None:
            sections[current].append(line)
    return {k: clean_text("\n".join(v)) for k, v in sections.items() if any(x.strip() for x in v)}


def load_from_timetable(path=TIMETABLE):
    """timetable.json -> {科目番号: 科目名} (重複除去)"""
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    out = {}
    for slots in data.get("modules", {}).values():
        for s in slots:
            out.setdefault(s["code"], s["name"])
    return out


def load_cache():
    if CACHE.exists():
        return json.loads(CACHE.read_text(encoding="utf-8")).get("courses", {})
    return {}


def save_cache(courses):
    payload = {"updated_at": datetime.now().isoformat(timespec="seconds"), "courses": courses}
    CACHE.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def write_txt(entry):
    TXT_DIR.mkdir(exist_ok=True)
    head = f"科目番号: {entry['code']}\n科目名: {entry['name']}\nURL: {entry['url']}\n取得: {entry['fetched_at']}\n\n"
    (TXT_DIR / f"{entry['code']}.txt").write_text(head + entry["text"] + "\n", encoding="utf-8")


# ---------------------------------------------------------------- ブラウザ操作
def wait_stable(page, tries=6):
    """本文の長さが2回連続で変わらなくなるまで待つ (動的描画対策)。"""
    last = -1
    for _ in range(tries):
        try:
            n = len(page.locator("body").inner_text(timeout=5000))
        except Exception:
            n = -1
        if n == last and n > 0:
            return
        last = n
        page.wait_for_timeout(1000)


def page_text(page):
    """全フレームの本文を集める (シラバスがiframe内でも拾えるように)。"""
    parts = []
    for fr in page.frames:
        try:
            t = clean_text(fr.locator("body").inner_text(timeout=5000))
        except Exception:
            continue
        if t and t not in parts:
            parts.append(t)
    return "\n\n".join(parts)


def dump_debug(page, code):
    Path(f"debug_kdb_{code}.html").write_text(page.content(), encoding="utf-8")
    page.screenshot(path=f"debug_kdb_{code}.png", full_page=True)
    print(f"    診断: debug_kdb_{code}.html / .png を保存")


def fetch_one(ctx, page, code, name, debug):
    """1科目を検索してシラバス本文を取得。見つからなければ None。"""
    page.goto(KDB_URL, wait_until="domcontentloaded")
    page.wait_for_selector(SEARCH_INPUT, timeout=20000)
    page.fill(SEARCH_INPUT, code)
    page.click(SEARCH_BUTTON)
    try:
        page.wait_for_load_state("networkidle", timeout=20000)
    except Exception:
        pass

    titles = page.locator(RESULT_TITLE)
    if name and titles.filter(has_text=name).count() == 0:
        try:  # 描画待ち
            titles.filter(has_text=name).first.wait_for(timeout=8000)
        except Exception:
            pass
    if titles.count() == 0:
        try:
            titles.first.wait_for(timeout=8000)
        except Exception:
            dump_debug(page, code)
            return None

    # 科目名が分かっていれば一致する結果を優先、なければ先頭
    by_name = titles.filter(has_text=name) if name else None
    target = by_name.first if (by_name is not None and by_name.count()) else titles.first
    clicked = target.inner_text().strip()
    print(f"    検索結果 {titles.count()} 件 -> 「{clicked}」を開きます")

    before = list(ctx.pages)
    target.click()
    page.wait_for_timeout(1500)
    opened = [p for p in ctx.pages if p not in before]  # 新しいタブで開く場合
    sp = opened[-1] if opened else page
    try:
        sp.wait_for_load_state("networkidle", timeout=20000)
    except Exception:
        pass
    wait_stable(sp)

    text = page_text(sp)
    url = sp.url
    if debug:
        dump_debug(sp, code)
    if opened:
        sp.close()
    if not text:
        return None

    if code not in text:
        print("    警告: 本文に科目番号が含まれません。別の科目/画面の可能性があります。")
    return {
        "code": code,
        "name": clicked,
        "url": url,
        "fetched_at": datetime.now().isoformat(timespec="seconds"),
        "text": text,
        "sections": split_sections(text),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("codes", nargs="*", help="科目番号 (例: ZZ10001)")
    ap.add_argument("--from-timetable", action="store_true", help="timetable.json の全科目")
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--show", action="store_true", help="ブラウザを表示")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--delay", type=float, default=3.0)
    args = ap.parse_args()

    targets = {}
    if args.from_timetable:
        if not TIMETABLE.exists():
            raise SystemExit("timetable.json がありません。先に fetch_timetable.py を実行してください。")
        targets.update(load_from_timetable())
    for c in args.codes:
        targets.setdefault(c.strip(), None)
    if not targets:
        raise SystemExit("科目番号を指定するか --from-timetable を付けてください。")

    courses = load_cache()
    todo = [c for c in targets if args.refresh or c not in courses]
    for c in targets:
        if c not in todo:
            print(f"{c}: キャッシュ済み (再取得は --refresh)")
    if not todo:
        return

    from playwright.sync_api import sync_playwright  # テスト時に不要なので遅延import

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.show)
        ctx = browser.new_context(locale="ja-JP")  # ログイン情報は使わない(cookieなしの別コンテキスト)
        page = ctx.new_page()
        for i, code in enumerate(todo):
            print(f"{code} {targets[code] or ''}: 取得中...")
            try:
                entry = fetch_one(ctx, page, code, targets[code], args.debug)
            except Exception as e:
                print(f"    失敗: {type(e).__name__}: {e}")
                entry = None
            if entry:
                courses[code] = entry
                write_txt(entry)
                save_cache(courses)  # 1件ごとに保存
                print(f"    保存: syllabus/{code}.txt ({len(entry['text'])}文字, 項目 {len(entry['sections'])})")
            else:
                print("    取得できませんでした (--show --debug で確認)")
            if i < len(todo) - 1:
                time.sleep(args.delay)
        browser.close()


if __name__ == "__main__":
    main()
