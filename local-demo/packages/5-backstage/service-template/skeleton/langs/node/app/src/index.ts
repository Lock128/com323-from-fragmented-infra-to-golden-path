// ${{ values.name }} — scaffolded by the lockhead.cloud platform (TypeScript).
// A minimal HTTP service so the golden path has something real to deploy.
// The root page renders the CURRENT server date/time on every request, so a
// refresh proves this is a live app handling the request (not a static file).
import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { hostname } from "node:os";

const service = "${{ values.name }}";
const team = "${{ values.team }}";
const tier = "${{ values.tier }}";

function renderPage(now: string, host: string): string {
  return `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">` +
    `<title>${service} · lockhead.cloud</title>` +
    `<style>body{min-height:100vh;margin:0;display:flex;align-items:center;justify-content:center;` +
    `font-family:-apple-system,"Segoe UI",sans-serif;background:#111827;color:#f3f4f6}` +
    `.card{text-align:center;padding:48px 56px;border-radius:16px;background:#1e293b;border:1px solid #374151}` +
    `.bar{height:6px;width:120px;margin:0 auto 28px;border-radius:6px;background:linear-gradient(90deg,#6083E9,#7B50B4)}` +
    `h1{font-size:40px;margin:0 0 6px;background:linear-gradient(135deg,#6083E9,#7B50B4);` +
    `-webkit-background-clip:text;background-clip:text;color:transparent}` +
    `.sub{color:#94a3b8;font-size:14px;margin-bottom:24px}` +
    `.clock{font-size:26px;font-variant-numeric:tabular-nums;margin:8px 0 20px;color:#dbe4ff}` +
    `.pill{font-size:13px;padding:6px 14px;border-radius:999px;background:rgba(96,131,233,.15);` +
    `border:1px solid #374151;color:#dbe4ff;margin:0 6px}.pill b{color:#9e6fe0}` +
    `.foot{margin-top:22px;font-size:12px;color:#64748b}</style></head>` +
    `<body><div class="card"><div class="bar"></div><h1>${service}</h1>` +
    `<div class="sub">deployed by the lockhead.cloud golden path · runtime <b>node</b></div>` +
    `<div class="clock" id="clock">${now}</div>` +
    `<div><span class="pill">team <b>${team}</b></span>` +
    `<span class="pill">tier <b>${tier}</b></span></div>` +
    `<div class="foot">served live by the ${service} container · host ${host}</div></div>` +
    `<script>setInterval(function(){document.getElementById('clock').textContent=` +
    `new Date().toISOString().replace('T',' ').replace(/\\..+/,' UTC')},1000)</script>` +
    `</body></html>`;
}

const server = createServer((req: IncomingMessage, res: ServerResponse) => {
  if (req.url === "/healthz") {
    res.writeHead(200);
    res.end("ok");
    return;
  }
  if (req.url === "/api") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({
      service,
      team,
      tier,
      runtime: "node",
      time: new Date().toISOString(),
      message: "onboarded via the lockhead.cloud golden path",
    }));
    return;
  }
  const now = new Date().toISOString().replace("T", " ").replace(/\..+/, " UTC");
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(renderPage(now, hostname()));
});

const port = Number(process.env.PORT ?? 8080);
server.listen(port, () => console.log(`${service} listening on :${port}`));
