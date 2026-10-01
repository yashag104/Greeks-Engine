"""Export every project document into one folder that opens offline.

    .venv/bin/python docs/export_local.py [output folder]

Default output: the Windows Desktop, "Greeks Engine Documents". Each file opens
with a double-click: the dashboard has its figures embedded and its links
pointed at the files beside it; Markdown documents are converted to HTML.
Re-run after any document changes. Needs the `markdown` package in the venv.
"""
import base64
import os
import re
import shutil
import sys

import markdown

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
OUT = sys.argv[1] if len(sys.argv) > 1 else "/mnt/c/Users/hp/OneDrive/Desktop/Greeks Engine Documents"

GH = "https://github.com/yashag104/Greeks-Engine/blob/pipeline-shared-mult/Greek%20Engine/"
FILES = {  # local name -> source (relative to ROOT)
    "02 Project Report.pdf": "docs/report/greeks_engine_report.pdf",
    "04 Course.html": "docs/course.html",
    "05 Viva Guide.html": "docs/viva_study_guide.html",
    "Block Design.pdf": "validation/results/vivado/Block_design.pdf",
    "Data/board_sweep_zedboard_2026-09-29.txt": "validation/results/board_sweep_zedboard_2026-09-29.log",
    "Data/board_sweep_report_2026-09-29.csv": "validation/results/board_sweep_report_2026-09-29.csv",
    "Data/cpu_baseline.csv": "validation/results/cpu_baseline.csv",
}
MARKDOWN = {
    "03 Novelty Assessment.html": ("docs/novelty_assessment.md", "Novelty Assessment"),
    "06 Literature Review.html": ("docs/05_literature_review.md", "Literature Review"),
    "07 Architecture and Results.html": ("docs/architecture.md", "Architecture and Results"),
    "08 Precision Bound.html": ("docs/precision_bound.md", "Precision Bound"),
    "09 Result Tables.html": ("validation/figures/tables.md", "Result Tables"),
}
LINKS = [  # dashboard link target (substring) -> local file
    ("https://claude.ai/artifact/TfsL5nqmM2wBGDQS7udL85", "04 Course.html"),
    ("https://claude.ai/artifact/G15DevL4ShygS5Np42vAqD", "05 Viva Guide.html"),
    (GH + "docs/report/greeks_engine_report.pdf", "02 Project Report.pdf"),
    (GH + "docs/novelty_assessment.md", "03 Novelty Assessment.html"),
    (GH + "docs/05_literature_review.md", "06 Literature Review.html"),
    (GH + "docs/architecture.md", "07 Architecture and Results.html"),
    (GH + "docs/precision_bound.md", "08 Precision Bound.html"),
    (GH + "validation/figures/tables.md", "09 Result Tables.html"),
    (GH + "validation/results/board_sweep_zedboard_2026-09-29.log", "Data/board_sweep_zedboard_2026-09-29.txt"),
    (GH + "validation/results/board_sweep_report_2026-09-29.csv", "Data/board_sweep_report_2026-09-29.csv"),
    (GH + "validation/results/vivado/Block_design.pdf", "Block Design.pdf"),
    ("validation/results/vivado/Block_design.pdf", "Block Design.pdf"),
]

STYLE = """<style>
body{font:15px/1.6 "Segoe UI",system-ui,sans-serif;color:#16202a;background:#f3f5f1;margin:0;padding:24px 16px 64px}
main{max-width:980px;margin:0 auto;background:#fff;border:1px solid #d5dbd3;border-radius:8px;padding:24px 32px}
h1,h2,h3{font-family:"Segoe UI Semibold","Segoe UI",sans-serif;line-height:1.25}
h1{font-size:1.9rem}h2{font-size:1.35rem;margin-top:1.8em;color:#0f6b5c}h3{font-size:1.1rem}
table{border-collapse:collapse;margin:12px 0;font-size:.9rem;display:block;overflow-x:auto}
th,td{border:1px solid #d5dbd3;padding:6px 10px;text-align:left;vertical-align:top}
th{background:#eef1ec}
code{background:#eef1ec;padding:1px 4px;border-radius:3px;font-size:.88em}
pre{background:#eef1ec;padding:12px;border-radius:6px;overflow-x:auto}
blockquote{border-left:3px solid #0f6b5c;margin:12px 0;padding:4px 14px;background:#dcefe9}
a{color:#0f6b5c}.back{font-size:.9rem;margin-bottom:12px;display:block}
</style>"""


def md_page(src, title):
    body = markdown.markdown(open(os.path.join(ROOT, src), encoding="utf-8").read(),
                             extensions=["tables", "fenced_code"])
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" '
            'content="width=device-width, initial-scale=1"><title>%s</title>%s</head><body><main>'
            '<a class="back" href="01 Dashboard.html">&larr; Dashboard</a>%s</main></body></html>'
            % (title, STYLE, body))


def dashboard():
    s = open(os.path.join(ROOT, "dashboard.html"), encoding="utf-8").read()

    def embed(m):
        path = os.path.join(ROOT, m.group(1))
        mime = "image/png" if path.endswith(".png") else "application/octet-stream"
        return 'src="data:%s;base64,%s"' % (mime, base64.b64encode(open(path, "rb").read()).decode())
    s = re.sub(r'src="(validation/[^"]+\.png)"', embed, s)
    for target, local in LINKS:
        s = s.replace('href="%s"' % target, 'href="%s"' % local.replace(" ", "%20"))
    left = [u for u in re.findall(r'href="([^"]+)"', s) if u.startswith("validation/")]
    assert not left, "dashboard links not mapped: %s" % left
    return '<!doctype html><html lang="en"><head><meta charset="utf-8">\n' + s + "\n</html>\n"


def main():
    os.makedirs(os.path.join(OUT, "Data"), exist_ok=True)
    open(os.path.join(OUT, "01 Dashboard.html"), "w", encoding="utf-8").write(dashboard())
    for local, src in FILES.items():
        shutil.copyfile(os.path.join(ROOT, src), os.path.join(OUT, local))
    for local, (src, title) in MARKDOWN.items():
        open(os.path.join(OUT, local), "w", encoding="utf-8").write(md_page(src, title))
    # LaTeX report: the source folder, and a zip ready to upload to Overleaf
    tex_src = os.path.join(ROOT, "docs", "report", "latex")
    tex_out = os.path.join(OUT, "Report (LaTeX)")
    shutil.rmtree(tex_out, ignore_errors=True)
    shutil.copytree(tex_src, tex_out)
    shutil.make_archive(os.path.join(OUT, "Report (LaTeX) for Overleaf"), "zip", tex_src)
    for name in sorted(os.listdir(OUT)):
        p = os.path.join(OUT, name)
        print("%8.0f KB  %s" % (os.path.getsize(p) / 1024, name) if os.path.isfile(p) else "          %s/" % name)


if __name__ == "__main__":
    main()
