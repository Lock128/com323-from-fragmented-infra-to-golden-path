# ${{ values.name }} — scaffolded by the lockhead.cloud platform (Python).
# A minimal HTTP service (stdlib only) so the golden path has something real to
# deploy. The root page renders the CURRENT server date/time on every request,
# so a refresh proves this is a live app handling the request (not a static file).
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = "${{ values.name }}"
TEAM = "${{ values.team }}"
TIER = "${{ values.tier }}"


def render_page(now: str, host: str) -> str:
    return (
        '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
        f"<title>{SERVICE} · lockhead.cloud</title>"
        "<style>body{min-height:100vh;margin:0;display:flex;align-items:center;justify-content:center;"
        "font-family:-apple-system,'Segoe UI',sans-serif;background:#111827;color:#f3f4f6}"
        ".card{text-align:center;padding:48px 56px;border-radius:16px;background:#1e293b;border:1px solid #374151}"
        ".bar{height:6px;width:120px;margin:0 auto 28px;border-radius:6px;background:linear-gradient(90deg,#6083E9,#7B50B4)}"
        "h1{font-size:40px;margin:0 0 6px;background:linear-gradient(135deg,#6083E9,#7B50B4);"
        "-webkit-background-clip:text;background-clip:text;color:transparent}"
        ".sub{color:#94a3b8;font-size:14px;margin-bottom:24px}"
        ".clock{font-size:26px;font-variant-numeric:tabular-nums;margin:8px 0 20px;color:#dbe4ff}"
        ".pill{font-size:13px;padding:6px 14px;border-radius:999px;background:rgba(96,131,233,.15);"
        "border:1px solid #374151;color:#dbe4ff;margin:0 6px}.pill b{color:#9e6fe0}"
        ".foot{margin-top:22px;font-size:12px;color:#64748b}</style></head>"
        f'<body><div class="card"><div class="bar"></div><h1>{SERVICE}</h1>'
        '<div class="sub">deployed by the lockhead.cloud golden path · runtime <b>python</b></div>'
        f'<div class="clock" id="clock">{now}</div>'
        f'<div><span class="pill">team <b>{TEAM}</b></span>'
        f'<span class="pill">tier <b>{TIER}</b></span></div>'
        f'<div class="foot">served live by the {SERVICE} container · host {host}</div></div>'
        "<script>setInterval(function(){document.getElementById('clock').textContent="
        "new Date().toISOString().replace('T',' ').replace(/\\..+/,' UTC')},1000)</script>"
        "</body></html>"
    )


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        now_iso = datetime.now(timezone.utc)
        if self.path == "/api":
            body = json.dumps({
                "service": SERVICE,
                "team": TEAM,
                "tier": TIER,
                "runtime": "python",
                "time": now_iso.replace(microsecond=0).isoformat(),
                "message": "onboarded via the lockhead.cloud golden path",
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        now = now_iso.strftime("%Y-%m-%d %H:%M:%S UTC")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(render_page(now, socket.gethostname()).encode())

    def log_message(self, *args):  # quiet
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"{SERVICE} listening on :{port}")
    ThreadingHTTPServer(("", port), Handler).serve_forever()
