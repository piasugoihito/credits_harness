#!/usr/bin/env python3
"""Web 版をビルドし、ブックマークレット入りの setup.html を生成する。

使い方:
  python3 tool/build_web.py --app-url https://<user>.github.io/credits_harness/ --base-href /credits_harness/
  python3 tool/build_web.py --app-url http://localhost:8080/          # ローカル確認用

--app-url はブックマークレットが戻る先(= 公開する URL、末尾 /)。
"""
import argparse
import pathlib
import shutil
import subprocess
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app-url", required=True)
    ap.add_argument("--base-href", default="/")
    ap.add_argument("--skip-flutter", action="store_true", help="setup.html だけ作り直す")
    a = ap.parse_args()
    if not a.app_url.endswith("/"):
        raise SystemExit("--app-url は / で終わる URL にしてください")

    out = ROOT / "build" / "web"
    if not a.skip_flutter:
        subprocess.run(
            ["flutter", "build", "web", "--release", "-t", "lib/main_web.dart", "--base-href", a.base_href],
            cwd=ROOT,
            check=True,
        )

    src = (ROOT / "tool" / "bookmarklet.js").read_text(encoding="utf-8").replace("__APP_URL__", a.app_url)
    # 改行を含めて URL エンコードする(// コメントや ASI を壊さないため、改行を消さない)
    bookmarklet = "javascript:" + urllib.parse.quote(src, safe="")
    html = (ROOT / "tool" / "setup.template.html").read_text(encoding="utf-8")
    html = html.replace("__BOOKMARKLET__", bookmarklet.replace("&", "&amp;").replace('"', "&quot;"))
    (out / "setup.html").write_text(html, encoding="utf-8")
    (out / "bookmarklet.js").write_text(src, encoding="utf-8")
    # GitHub Pages が _ で始まるファイルを無視しないように
    (out / ".nojekyll").write_text("", encoding="utf-8")
    print(f"OK: {out}  (bookmarklet {len(bookmarklet)} 文字)")


if __name__ == "__main__":
    main()
