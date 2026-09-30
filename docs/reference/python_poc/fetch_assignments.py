"""
manaba の「未提出の課題一覧」を取得して assignments.json に保存する。

ログイン処理・認証情報(キーチェーン)・セッション保存は fetch_timetable.py と共通。
同じフォルダに fetch_timetable.py を置いておくこと。

準備 (未実施なら):
  python fetch_timetable.py --set-password     # 1回だけ

使い方:
  python fetch_timetable.py は不要。これだけで動く:
  python fetch_assignments.py
  python fetch_assignments.py --headless       # セッション保存後の定期実行用
  python fetch_assignments.py --debug          # 失敗時の診断ファイルを保存

流れ:
  1. https://manaba.tsukuba.ac.jp/ct/home_library_query を開く (未ログインなら自動ログイン)
  2. 『未提出の課題一覧』ボタン(img alt="未提出の課題一覧")をクリック
  3. 表示されたテーブル(table.stdlist)をパースして保存

安全面: クリックするのは『未提出の課題一覧』ボタンだけ。課題の提出などは一切しない。
"""
import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin

from bs4 import BeautifulSoup

import fetch_timetable as ft  # ログイン共通処理

TARGET_URL = "https://manaba.tsukuba.ac.jp/ct/home_library_query"
BUTTON = 'img[alt="未提出の課題一覧"]'
DEFAULT_OUT = "assignments.json"
DT_FORMAT = "%Y-%m-%d %H:%M"


# ---------------------------------------------------------------- パーサー
def parse_dt(text):
    try:
        return datetime.strptime((text or "").strip(), DT_FORMAT)
    except ValueError:
        return None


def parse_assignments(html, base_url=TARGET_URL):
    """未提出課題テーブル -> 項目のリスト (締切が近い順、締切なしは最後)。表が無ければ None。"""
    soup = BeautifulSoup(html, "lxml")
    table = soup.select_one("table.stdlist")
    if table is None:
        return None

    items = []
    for tr in table.select("tr"):
        title_a = tr.select_one(".myassignments-title a")
        if title_a is None:  # ヘッダー行など
            continue
        tds = tr.find_all("td", recursive=False)
        course_a = tr.select_one(".mycourse-title a")
        # td.td-period は 受付開始/受付終了 の2セル (td-period-responsive は別クラス)
        periods = [td.get_text(strip=True) for td in tr.select("td.td-period")]
        periods += [""] * (2 - len(periods))

        href = title_a.get("href", "")
        items.append(
            {
                "id": href.split("?")[0],  # 例: course_1871676_survey_4315684 (重複通知防止のキー)
                "type": tds[0].get_text(strip=True) if tds else "",
                "title": title_a.get_text(strip=True),
                "url": urljoin(base_url, href),
                "course": course_a.get_text(strip=True) if course_a else "",
                "course_url": urljoin(base_url, course_a["href"]) if course_a else "",
                "start": periods[0] or None,
                "due": periods[1] or None,  # 受付終了日時。空なら期限なし
            }
        )

    items.sort(key=lambda it: (it["due"] is None, it["due"] or ""))
    return items


# ---------------------------------------------------------------- ブラウザ操作
def open_unsubmitted(page):
    """『未提出の課題一覧』ボタンを押して、テーブルが出るまで待つ。"""
    if page.locator(BUTTON).count() == 0:
        ft.dump_debug(page, "manaba")
        raise SystemExit(
            f"ボタン {BUTTON} が見つかりません (現在: {ft.short_url(page)})。\n"
            "debug_manaba.html を確認してください。"
        )
    try:
        with page.expect_navigation(wait_until="domcontentloaded", timeout=15000):
            page.locator(BUTTON).first.click()
    except Exception:
        pass  # ページ遷移を伴わない(JS切替)場合もあるので、続けてテーブルを待つ
    try:
        page.wait_for_selector("table.stdlist", timeout=15000)
    except Exception:
        ft.dump_debug(page, "manaba")
        raise SystemExit(
            "課題テーブル(table.stdlist)が表示されませんでした。"
            "未提出課題が0件か、画面構成が違う可能性があります。\n"
            "assignments.json は上書きしません。"
        )


# ---------------------------------------------------------------- 保存・表示
def save(items, out_path):
    payload = {
        "fetched_at": datetime.now().isoformat(timespec="seconds"),
        "count": len(items),
        "items": items,
    }
    Path(out_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"保存: {out_path}")


def remaining_label(due, now):
    dt = parse_dt(due)
    if dt is None:
        return "期限なし"
    hours = (dt - now).total_seconds() / 3600
    if hours < 0:
        return f"期限切れ({int(-hours // 24)}日前)"
    if hours < 48:
        return f"あと{int(hours)}時間"
    return f"あと{int(hours // 24)}日"


def print_summary(items, now=None):
    now = now or datetime.now()
    print(f"\n未提出課題: {len(items)} 件")
    for it in items:
        print(
            f"  [{remaining_label(it['due'], now)}] {it['type']}｜{it['title']}"
            f"  / {it['course']}  締切: {it['due'] or '-'}"
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--debug", action="store_true", help="失敗時の診断ファイルを保存")
    ap.add_argument("--retry-login", action="store_true", help="自動ログイン失敗後に再試行")
    args = ap.parse_args()

    ft.DEBUG = args.debug
    ft.RETRY_LOGIN = args.retry_login
    ft.ensure_gitignore()

    from playwright.sync_api import sync_playwright  # テスト時に不要なので遅延import

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=args.headless)
        ctx = browser.new_context(
            storage_state=str(ft.STATE) if ft.STATE.exists() else None, user_agent=ft.UA
        )
        page = ctx.new_page()
        page.goto(TARGET_URL)

        ft.ensure_logged_in(page, args.headless)
        if "home_library_query" not in page.url:  # ログイン後に別ページへ飛ばされた場合
            page.goto(TARGET_URL)
        ft.save_state(ctx)

        open_unsubmitted(page)
        html, url = page.content(), page.url
        ft.save_state(ctx)
        browser.close()

    items = parse_assignments(html, url)
    if not items:
        raise SystemExit("課題を1件も読み取れませんでした。assignments.json は上書きしません。")
    save(items, args.out)
    print_summary(items)


if __name__ == "__main__":
    main()
