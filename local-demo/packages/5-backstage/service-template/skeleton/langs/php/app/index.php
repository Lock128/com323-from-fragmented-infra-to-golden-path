<?php
// ${{ values.name }} — scaffolded by the lockhead.cloud platform (PHP).
// A minimal HTTP service so the golden path has something real to deploy.
// The root page renders the CURRENT server date/time on every request, so a
// refresh proves this is a live app handling the request (not a static file).
// Served by PHP's built-in web server (see Dockerfile).

$service = "${{ values.name }}";
$team    = "${{ values.team }}";
$tier    = "${{ values.tier }}";

$path = parse_url($_SERVER["REQUEST_URI"] ?? "/", PHP_URL_PATH);
$now_iso = gmdate("Y-m-d\TH:i:s\Z");

if ($path === "/healthz") {
    http_response_code(200);
    header("Content-Type: text/plain");
    echo "ok";
    exit;
}

if ($path === "/api") {
    header("Content-Type: application/json");
    echo json_encode([
        "service" => $service,
        "team"    => $team,
        "tier"    => $tier,
        "runtime" => "php",
        "time"    => $now_iso,
        "message" => "onboarded via the lockhead.cloud golden path",
    ]);
    exit;
}

$now = gmdate("Y-m-d H:i:s") . " UTC";
$host = gethostname();
header("Content-Type: text/html; charset=utf-8");
?>
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<title><?= htmlspecialchars($service) ?> · lockhead.cloud</title>
<style>
body{min-height:100vh;margin:0;display:flex;align-items:center;justify-content:center;font-family:-apple-system,"Segoe UI",sans-serif;background:#111827;color:#f3f4f6}
.card{text-align:center;padding:48px 56px;border-radius:16px;background:#1e293b;border:1px solid #374151}
.bar{height:6px;width:120px;margin:0 auto 28px;border-radius:6px;background:linear-gradient(90deg,#6083E9,#7B50B4)}
h1{font-size:40px;margin:0 0 6px;background:linear-gradient(135deg,#6083E9,#7B50B4);-webkit-background-clip:text;background-clip:text;color:transparent}
.sub{color:#94a3b8;font-size:14px;margin-bottom:24px}
.clock{font-size:26px;font-variant-numeric:tabular-nums;margin:8px 0 20px;color:#dbe4ff}
.pill{font-size:13px;padding:6px 14px;border-radius:999px;background:rgba(96,131,233,.15);border:1px solid #374151;color:#dbe4ff;margin:0 6px}.pill b{color:#9e6fe0}
.foot{margin-top:22px;font-size:12px;color:#64748b}
</style></head>
<body><div class="card"><div class="bar"></div>
<h1><?= htmlspecialchars($service) ?></h1>
<div class="sub">deployed by the lockhead.cloud golden path · runtime <b>php</b></div>
<div class="clock" id="clock"><?= htmlspecialchars($now) ?></div>
<div>
<span class="pill">team <b><?= htmlspecialchars($team) ?></b></span>
<span class="pill">tier <b><?= htmlspecialchars($tier) ?></b></span>
</div>
<div class="foot">served live by the <?= htmlspecialchars($service) ?> container · host <?= htmlspecialchars($host) ?></div>
</div>
<script>setInterval(function(){document.getElementById('clock').textContent=new Date().toISOString().replace('T',' ').replace(/\..+/,' UTC')},1000)</script>
</body></html>
