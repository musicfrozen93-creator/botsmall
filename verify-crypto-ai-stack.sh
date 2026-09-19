#!/usr/bin/env bash
# =============================================================================
# CRYPTO AI — post-deployment verification (run on the VPS)
# =============================================================================
# Read-only. Starts/stops/deletes nothing. Never prints ANALYSIS_API_KEY,
# POSTGRES_PASSWORD or DATABASE_URL — the API key is used only by reference
# ($ANALYSIS_API_KEY) inside the container.
# =============================================================================
set -u
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== 1. NEW containers ==="
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}" \
  | grep -E "NAMES|crypto-ai-" || echo "  (none found)"

echo
echo "=== 2. OLD production containers still running (must be untouched) ==="
for c in zentry-analysis-api zengrid-postgres royal1-nginx royal1-web royal1-engine royal1-redis portainer mega99-signal-bot; do
  s=$(docker inspect -f '{{.State.Status}} (started {{.State.StartedAt}})' "$c" 2>/dev/null)
  if [ -n "$s" ]; then echo "  $c : $s"; else echo "  $c : not present on this host"; fi
done

echo
echo "=== 3. Host port mapping ==="
m=$(docker port crypto-ai-api 2>/dev/null)
echo "  crypto-ai-api -> ${m:-<none>}"
echo "$m" | grep -q "0.0.0.0:8010" && ok "API published on host 8010" || no "API not on host 8010"
if docker port crypto-ai-postgres 2>/dev/null | grep -q .; then
  no "PostgreSQL has a host port published (it must be internal-only)"
else
  ok "PostgreSQL has NO host port (internal-only)"
fi

echo
echo "=== 4. Network + volume ==="
docker network inspect crypto-ai-network -f '  network: {{.Name}} | containers: {{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
  && ok "crypto-ai-network exists" || no "crypto-ai-network missing"
docker volume inspect crypto_ai_postgres_data -f '  volume: {{.Name}} | mount: {{.Mountpoint}}' 2>/dev/null \
  && ok "crypto_ai_postgres_data exists" || no "crypto_ai_postgres_data missing"

echo
echo "=== 5. /health (open, no key required) ==="
code=$(curl -s -o /tmp/h.json -w "%{http_code}" http://127.0.0.1:8010/health)
echo "  HTTP $code"; [ -f /tmp/h.json ] && cat /tmp/h.json && echo
[ "$code" = "200" ] && ok "/health returns 200" || no "/health returned $code"

echo
echo "=== 6. FastAPI service-key authentication (values never printed) ==="
B='{"market":"crypto","symbol":"BTCUSDT","timeframe":"1h"}'
c1=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8010/api/analyze -H 'Content-Type: application/json' -d "$B")
echo "  no key      -> $c1 (expect 401)"; [ "$c1" = "401" ] && ok "missing key rejected" || no "missing key gave $c1"
c2=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8010/api/analyze -H 'Content-Type: application/json' -H 'X-Service-Key: definitely-the-wrong-key-value' -d "$B")
echo "  wrong key   -> $c2 (expect 403)"; [ "$c2" = "403" ] && ok "wrong key rejected" || no "wrong key gave $c2"
c3=$(docker exec crypto-ai-api sh -c 'curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8000/api/analyze -H "Content-Type: application/json" -H "X-Service-Key: $ANALYSIS_API_KEY" -d '"'"'{"market":"crypto","symbol":"BTCUSDT","timeframe":"1h"}'"'"'' 2>/dev/null)
echo "  correct key -> $c3 (expect 200)"; [ "$c3" = "200" ] && ok "correct key accepted" || no "correct key gave $c3"

echo
echo "=== 7. Database reachability from the API container ==="
docker exec crypto-ai-api sh -c 'python -c "
import os,urllib.parse,socket
u=urllib.parse.urlparse(os.environ[\"DATABASE_URL\"])
print(\"  DATABASE_URL host:\", u.hostname, \"port:\", u.port or 5432, \"db:\", (u.path or \"/\").lstrip(\"/\"))
assert u.hostname==\"crypto-ai-postgres\", \"DATABASE_URL does not point at crypto-ai-postgres\"
assert (u.path or \"\").lstrip(\"/\")==\"crypto_ai\", \"DATABASE_URL database is not crypto_ai\"
s=socket.create_connection((u.hostname,u.port or 5432),5); s.close(); print(\"  TCP connect: OK\")
"' 2>&1 | sed 's/^/  /'
[ ${PIPESTATUS[0]} -eq 0 ] && ok "API can reach crypto-ai-postgres:5432 and URL targets crypto_ai" || no "DB reachability/target check failed"

echo
echo "=== 8. Credentials work against the NEW database only ==="
docker exec crypto-ai-postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select current_database()||\" as \"||current_user"' 2>/dev/null \
  | sed 's/^/  connected as: /' && ok "crypto_ai credentials valid" || no "could not connect with crypto_ai credentials"

echo
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || echo "Review the [FAIL] lines above before using the stack."
