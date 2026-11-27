// ${{ values.name }} — scaffolded by the lockhead.cloud platform.
// A minimal HTTP service so the golden path has something real to deploy.
// The root page renders the CURRENT server date/time on every request, so a
// refresh proves this is a live app handling the request (not a static file).
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

const page = `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">` +
	`<title>%[1]s · lockhead.cloud</title>` +
	`<style>body{min-height:100vh;margin:0;display:flex;align-items:center;justify-content:center;` +
	`font-family:-apple-system,"Segoe UI",sans-serif;background:#111827;color:#f3f4f6}` +
	`.card{text-align:center;padding:48px 56px;border-radius:16px;background:#1e293b;border:1px solid #374151}` +
	`.bar{height:6px;width:120px;margin:0 auto 28px;border-radius:6px;background:linear-gradient(90deg,#6083E9,#7B50B4)}` +
	`h1{font-size:40px;margin:0 0 6px;background:linear-gradient(135deg,#6083E9,#7B50B4);` +
	`-webkit-background-clip:text;background-clip:text;color:transparent}` +
	`.sub{color:#94a3b8;font-size:14px;margin-bottom:24px}` +
	`.clock{font-size:26px;font-variant-numeric:tabular-nums;margin:8px 0 20px;color:#dbe4ff}` +
	`.clock b{color:#9e6fe0}` +
	`.pill{font-size:13px;padding:6px 14px;border-radius:999px;background:rgba(96,131,233,.15);` +
	`border:1px solid #374151;color:#dbe4ff;margin:0 6px}.pill b{color:#9e6fe0}` +
	`.foot{margin-top:22px;font-size:12px;color:#64748b}</style></head>` +
	`<body><div class="card"><div class="bar"></div><h1>%[1]s</h1>` +
	`<div class="sub">deployed by the lockhead.cloud golden path · runtime <b>go</b></div>` +
	`<div class="clock" id="clock">%[4]s</div>` +
	`<div><span class="pill">team <b>%[2]s</b></span>` +
	`<span class="pill">tier <b>%[3]s</b></span></div>` +
	`<div class="foot">served live by the %[1]s container · host %[5]s</div></div>` +
	// A ticking clock so it's visibly alive; falls back to the server value if JS is off.
	`<script>setInterval(function(){document.getElementById('clock').textContent=` +
	`new Date().toISOString().replace('T',' ').replace(/\..+/,' UTC')},1000)</script>` +
	`</body></html>`

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// JSON API — includes the live server time so curl shows it changing.
	mux.HandleFunc("/api", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"service": "${{ values.name }}",
			"team":    "${{ values.team }}",
			"tier":    "${{ values.tier }}",
			"runtime": "go",
			"time":    time.Now().UTC().Format(time.RFC3339),
			"message": "onboarded via the lockhead.cloud golden path",
		})
	})

	// Root: branded HTML page rendering the CURRENT server time on each request.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		host, _ := os.Hostname()
		now := time.Now().UTC().Format("2006-01-02 15:04:05 UTC")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = fmt.Fprintf(w, page, "${{ values.name }}", "${{ values.team }}", "${{ values.tier }}", now, host)
	})

	addr := ":8080"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}
	log.Printf("${{ values.name }} listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
