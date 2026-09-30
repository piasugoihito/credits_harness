"""
TWINS の履修登録画面から「学期(モジュール)ごとの 曜日・時限・科目番号・科目名」を
取得して timetable.json に保存する。

準備:
  pip install playwright beautifulsoup4 lxml keyring
  playwright install chromium

使い方:
  # 1回だけ: 学籍番号とパスワードをOSのキーチェーンに保存 (入力は画面に表示されない)
  python fetch_timetable.py --set-password

  # 以降は毎回これだけ (ログイン自動入力 + セッションcookie再利用)
  python fetch_timetable.py
  python fetch_timetable.py --headless      # セッション保存後の定期実行用

  # 保存した認証情報とセッションを全部消す
  python fetch_timetable.py --forget

認証情報の扱い:
  - パスワードは平文ファイルに保存しない。OSのキーチェーン(keyring)に保存する。
  - キーチェーンが使えない環境では環境変数 TSUKUBA_USER / TSUKUBA_PASS を使う。
  - auth_state.json (ログインセッション) と timetable.json は .gitignore に自動追記する。

安全面:
  クリックするのは学期タブ(春A/秋A...)のリンクだけ。
  科目セル内の DeleteCallA(履修取消) / InputCallA(履修登録) は絶対に押さない。
  科目セルはHTML文字列として読むだけ。
"""
import argparse
import getpass
import json
import os
import re
import subprocess
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

from bs4 import BeautifulSoup

TWINS_URL = "https://twins.tsukuba.ac.jp/campusweb/"
STATE = Path("auth_state.json")
DEFAULT_OUT = "timetable.json"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
DEBUG = False
RETRY_LOGIN = False
FAIL_FLAG = Path(".autofill_failed")  # 自動ログイン失敗の記録(ロック防止)

DAYS = {1: "月", 2: "火", 3: "水", 4: "木", 5: "金", 6: "土", 7: "日"}

# DeleteCallA('年度','?','科目番号','曜日(1=月)','時限')
DELETE_RE = re.compile(
    r"DeleteCallA\('([^']*)','([^']*)','([^']*)','(\d+)','(\d+)'\)"
)

# 履修登録画面へ移る際に押すメニュー名の候補 (見つからなければ手動移動にフォールバック)
NAV_TEXT = "履修登録・登録状況照会"  # <span class="menunm"> のメニュー名


# ---------------------------------------------------------------- パーサー
def parse_timetable(html):
    """時間割表HTML -> スロットのリスト。表が無いページなら None。"""
    soup = BeautifulSoup(html, "lxml")
    table = soup.select_one("table.rishu-koma")  # 外側の表 (内側は rishu-koma-inner)
    if table is None:
        return None

    slots = {}
    for a in table.find_all("a", onclick=DELETE_RE):
        year, _, code, day, period = DELETE_RE.search(a["onclick"]).groups()
        td = a.find_parent("td")
        # HTMLコメントは get_text に含まれない。行: [科目番号, 科目名, 教員...]
        lines = [
            s.strip()
            for s in td.get_text("\n").split("\n")
            if s.strip() and "シラバス" not in s
        ]
        slot = {
            "day": DAYS.get(int(day), day),
            "day_index": int(day),
            "period": int(period),
            "code": code,
            "name": lines[1] if len(lines) > 1 else "",
            "teacher": "、".join(lines[2:]),
            "year": year,
        }
        slots[(slot["day_index"], slot["period"], code)] = slot

    return [slots[k] for k in sorted(slots)]


def parse_tabs(html):
    """学期タブ -> [{'label': '秋A', 'selected': True}, ...]"""
    soup = BeautifulSoup(html, "lxml")
    return [
        {
            "label": td.get_text(strip=True),
            "selected": "rishu-tab-sel" in (td.get("class") or []),
        }
        for td in soup.select("td.rishu-tab, td.rishu-tab-sel")
    ]


# ---------------------------------------------------------------- 認証情報 (keyring)
SERVICE = "tsukuba-twins-notifier"
IGNORE_ENTRIES = ["auth_state.json", "timetable.json", "assignments.json", "html_dump/", "debug_*", ".autofill_failed", ".env", "__pycache__/"]


def _keyring():
    try:
        import keyring

        return keyring
    except ImportError:
        return None


def get_credentials():
    """keyring -> 環境変数 の順で (user, pass) を返す。無ければ (None, None)。"""
    kr = _keyring()
    if kr is not None:
        try:
            user = kr.get_password(SERVICE, "user")
            pw = kr.get_password(SERVICE, "pass")
            if user and pw:
                return user, pw
        except Exception:
            pass  # バックエンド無し(ヘッドレスLinuxなど) -> 環境変数へ
    return os.environ.get("TSUKUBA_USER"), os.environ.get("TSUKUBA_PASS")


def set_credentials():
    kr = _keyring()
    if kr is None:
        raise SystemExit("keyring が未インストールです: pip install keyring")
    user = input("学籍番号: ").strip()
    pw = getpass.getpass("パスワード(表示されません): ")
    if not (user and pw):
        raise SystemExit("未入力のため中止しました。")
    try:
        kr.set_password(SERVICE, "user", user)
        kr.set_password(SERVICE, "pass", pw)
    except Exception as e:
        raise SystemExit(
            f"キーチェーンに保存できませんでした ({e})。\n"
            "環境変数 TSUKUBA_USER / TSUKUBA_PASS を使ってください。"
        )
    print("キーチェーンに保存しました。")


def forget_all():
    kr = _keyring()
    if kr is not None:
        for key in ("user", "pass"):
            try:
                kr.delete_password(SERVICE, key)
            except Exception:
                pass
    STATE.unlink(missing_ok=True)
    FAIL_FLAG.unlink(missing_ok=True)
    print("保存済みの認証情報とセッション(auth_state.json)を削除しました。")


def ensure_gitignore():
    """秘密を含むファイルを .gitignore に追記し、すでにgit管理下なら警告する。"""
    gi = Path(".gitignore")
    current = gi.read_text(encoding="utf-8") if gi.exists() else ""
    lines = {ln.strip() for ln in current.splitlines()}
    missing = [e for e in IGNORE_ENTRIES if e not in lines]
    if missing:
        sep = "" if (not current or current.endswith("\n")) else "\n"
        gi.write_text(current + sep + "\n".join(missing) + "\n", encoding="utf-8")
        print(f".gitignore に追記: {', '.join(missing)}")
    if Path(".git").exists():
        for f in ("auth_state.json", "timetable.json"):
            try:
                tracked = subprocess.run(
                    ["git", "ls-files", "--error-unmatch", f],
                    capture_output=True,
                ).returncode == 0
            except OSError:
                break
            if tracked:
                print(
                    f"警告: {f} は既にgitで追跡されています。\n"
                    f"      git rm --cached {f}  で追跡を外してください。"
                    "(過去にpush済みならセッション無効化のため再ログイン/パスワード変更も)"
                )


# ---------------------------------------------------------------- ブラウザ操作
def is_login_page(page):
    return page.locator('input[type="password"]:visible').count() > 0


def describe(loc):
    """要素の種類だけを表示 (値は出さない)。診断用。"""
    try:
        return loc.evaluate(
            "e => `${e.tagName.toLowerCase()}[type=${e.type||''} name=${e.name||''} id=${e.id||''}]`"
        )
    except Exception:
        return "?"


LOGIN_LABEL = re.compile(r"ログイン|login|sign\s*in", re.I)
INTERACTIVE = (
    'input[type="submit"], input[type="button"], input[type="image"], button, '
    'a, [role="button"], [onclick]'
)
ERROR_WORDS = re.compile(r"エラー|正しく|誤|ロック|失敗|無効|invalid|incorrect|error", re.I)


def label_of(loc):
    try:
        return (
            loc.evaluate(
                "e => (e.value||e.alt||e.title||e.getAttribute('aria-label')||e.innerText||'')"
            )
            or ""
        ).strip()[:40]
    except Exception:
        return ""


def find_login_button(page, scope):
    """まずform内、なければページ全体から『ログイン』ボタンを探す。"""
    seen = []
    for root in ([scope, page] if scope is not page else [page]):
        els = root.locator(f"{INTERACTIVE} >> visible=true")
        for i in range(min(els.count(), 60)):
            el = els.nth(i)
            label = label_of(el)
            seen.append((el, label))
            # 短いラベルのみ対象 (body等の大きな要素の誤クリック防止)
            if len(label) <= 15 and LOGIN_LABEL.search(label):
                return el, label, seen
    return None, "", seen


def login_error_hint(page):
    """ログイン失敗時に画面上のエラーらしき行だけ表示 (個人情報を含みにくい行のみ)。"""
    try:
        lines = [ln.strip() for ln in page.inner_text("body").splitlines() if ln.strip()]
    except Exception:
        return
    hits = [ln[:80] for ln in lines if ERROR_WORDS.search(ln)][:3]
    for ln in hits:
        print(f"  画面のメッセージ: {ln}")


def try_autofill(page):
    """パスワード欄を基準に、同じform内のユーザー欄と送信ボタンを探して入力する。1回だけ。"""
    user, pw = get_credentials()
    if not (user and pw):
        return
    if FAIL_FLAG.exists() and not RETRY_LOGIN:
        print("  前回の自動ログインが失敗したためスキップします(ロック防止)。")
        print("  原因を直したら --retry-login を付けて1回だけ再試行してください。")
        return
    try:
        pw_box = page.locator('input[type="password"]:visible').first
        form = pw_box.locator("xpath=ancestor::form[1]")
        scope = form if form.count() else page
        user_box = scope.locator(
            'input[type="text"]:visible, input[type="email"]:visible, input:not([type]):visible'
        ).first
        print(f"  ユーザー欄: {describe(user_box)} / パスワード欄: {describe(pw_box)}")
        user_box.fill(user)
        pw_box.fill(pw)

        target, label, seen = find_login_button(page, scope)
        if target is not None:
            print(f"  送信ボタン: {describe(target)} 「{label}」")
            target.click()
        else:
            print("  ログインボタンが見つかりません。ページ上の候補:")
            for el, lb in seen[:12]:
                print(f"    {describe(el)} 「{lb}」")
            print("  -> フォームを直接送信します")
            try:
                form.evaluate("f => f.requestSubmit ? f.requestSubmit() : f.submit()")
            except Exception:
                pw_box.press("Enter")
        page.wait_for_load_state("networkidle", timeout=30000)
    except Exception as e:
        print(f"  自動入力に失敗: {type(e).__name__}")  # -> 手動ログインにフォールバック


def dump_debug(page, tag):
    """ログイン画面の状態を保存 (中身を確認してから共有すること)。"""
    Path(f"debug_{tag}.html").write_text(page.content(), encoding="utf-8")
    page.screenshot(path=f"debug_{tag}.png")
    print(f"  診断用に debug_{tag}.html / debug_{tag}.png を保存しました")


def short_url(page):
    return page.url.split("?")[0]


def ensure_logged_in(page, headless):
    try:
        page.wait_for_load_state("networkidle", timeout=15000)
    except Exception:
        pass
    if not is_login_page(page):
        return
    print(f"ログイン画面を検出: {short_url(page)}")
    creds = get_credentials()
    print(f"  保存済み認証情報: {'あり' if all(creds) else 'なし'} -> 自動入力を1回だけ試します")
    try_autofill(page)
    if not is_login_page(page):
        FAIL_FLAG.unlink(missing_ok=True)
        return
    if get_credentials()[0] and not FAIL_FLAG.exists():
        FAIL_FLAG.write_text(datetime.now().isoformat(timespec="seconds"))
    login_error_hint(page)
    if DEBUG or headless:
        dump_debug(page, "login")
    if headless:
        raise SystemExit(
            "ログイン画面に戻されました(セッション切れ、または自動入力が失敗)。\n"
            f"  現在のURL: {short_url(page)}\n"
            "  --headless なしで一度実行してログインし直してください。"
        )
    for _ in range(3):
        input("ブラウザでログインを完了したら Enter を押してください > ")
        if not is_login_page(page):
            return
        print("  まだログイン画面のようです。")
    raise SystemExit("ログインを確認できませんでした。")


def has_timetable(page):
    return page.locator("table.rishu-koma").count() > 0


def find_menu_item(page):
    """全フレームから <span class="menunm">履修登録・登録状況照会</span> を探す。"""
    for frame in page.frames:
        loc = frame.locator("span.menunm", has_text=NAV_TEXT)
        if loc.count():
            return loc
    return None


def open_registration(ctx, page, headless):
    """メニュー『履修登録・登録状況照会』を開き、時間割表の画面まで移動する。

    メニューはドロップダウン内で非表示のことがあるため、通常のclickではなく
    DOM上で親の <a> を直接clickする (見えているかどうかに依存しない)。
    """
    if has_timetable(page):
        return page
    try:
        page.wait_for_selector("span.menunm", state="attached", timeout=15000)
    except Exception:
        pass
    loc = find_menu_item(page)
    if loc is None:
        print(f"  メニュー『{NAV_TEXT}』が見つかりません: {short_url(page)}")
    else:
        try:
            with page.expect_navigation(wait_until="domcontentloaded", timeout=20000):
                loc.first.evaluate("el => (el.closest('a') || el).click()")
            page.wait_for_selector("table.rishu-koma", timeout=20000)
            return page
        except Exception as e:
            print(f"  自動移動に失敗: {type(e).__name__} (現在: {short_url(page)})")
    dump_debug(page, "nav")
    if headless:
        raise SystemExit("履修登録画面への自動移動に失敗。--debug 付き・--headless なしで実行してください。")
    input(
        "同じブラウザで「履修登録・登録状況照会」を開き、\n"
        "時間割表(学期タブ付き)が見えたら Enter を押してください > "
    )
    return ctx.pages[-1]


def collect(page):
    """全学期タブを順に開いてパースする。押すのは学期タブのリンクのみ。"""
    labels = [t["label"] for t in parse_tabs(page.content())]
    if not labels or not has_timetable(page):
        raise SystemExit(
            "学期タブ/時間割表が見つかりません(履修登録画面が開かれていません)。\n"
            "timetable.json は上書きしません。"
        )
    result = {}
    for label in labels:
        selected = next(
            (t["label"] for t in parse_tabs(page.content()) if t["selected"]), None
        )
        if selected != label:
            link = page.locator("td.rishu-tab a", has_text=label).first
            with page.expect_navigation(wait_until="domcontentloaded"):
                link.click()
            page.wait_for_selector("table.rishu-koma", timeout=30000)
            time.sleep(1)  # サーバー負荷を避ける
        slots = parse_timetable(page.content())
        result[label] = slots or []
        print(f"  {label}: {len(result[label])} コマ")
    return result


# ---------------------------------------------------------------- 保存・表示
def save(data, out_path):
    years = Counter(s["year"] for v in data.values() for s in v)
    payload = {
        "fetched_at": datetime.now().isoformat(timespec="seconds"),
        "year": years.most_common(1)[0][0] if years else None,
        "modules": data,
    }
    Path(out_path).write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n保存: {out_path}")


def print_summary(data):
    for label, slots in data.items():
        if not slots:
            continue
        print(f"\n【{label}】")
        for s in slots:
            print(f"  {s['day']}{s['period']}限  {s['code']}  {s['name']}  ({s['teacher']})")


def save_state(ctx):
    ctx.storage_state(path=str(STATE))
    try:
        os.chmod(STATE, 0o600)  # ログインセッションなので自分だけ読めるように
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--set-password", action="store_true", help="認証情報をキーチェーンに保存")
    ap.add_argument("--debug", action="store_true", help="ログイン画面の診断ファイルを保存")
    ap.add_argument("--retry-login", action="store_true", help="自動ログイン失敗後に再試行")
    ap.add_argument("--forget", action="store_true", help="保存した認証情報とセッションを削除")
    args = ap.parse_args()

    if args.set_password:
        set_credentials()
        return
    if args.forget:
        forget_all()
        return
    global DEBUG, RETRY_LOGIN
    DEBUG = args.debug
    RETRY_LOGIN = args.retry_login
    ensure_gitignore()

    from playwright.sync_api import sync_playwright  # テスト時に不要なので遅延import

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=args.headless)
        ctx = browser.new_context(
            storage_state=str(STATE) if STATE.exists() else None, user_agent=UA
        )
        page = ctx.new_page()
        page.goto(TWINS_URL)

        ensure_logged_in(page, args.headless)
        save_state(ctx)  # ログイン済みセッションを先に保存 (後段で失敗しても再利用できる)
        page = open_registration(ctx, page, args.headless)
        print("取得中...")
        data = collect(page)

        save_state(ctx)
        browser.close()

    if not any(data.values()):
        raise SystemExit("1コマも取得できませんでした。timetable.json は上書きしません。")
    save(data, args.out)
    print_summary(data)


if __name__ == "__main__":
    main()
