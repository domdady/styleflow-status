#!/usr/bin/env bash
# Probes every component from GitHub's runners and rewrites status.json / incidents.json.
# A component is DOWN only when two probes 20 s apart both fail (status or marker); a single blip is "degraded".
# Exit 0 always: the workflow commits only when the files changed or the hourly heartbeat is due.
set -uo pipefail
NOW=$(date -u +%FT%TZ)
probe() { # url okcodes marker -> "up|down <code>"
  local url="$1" ok="$2" marker="$3" code body
  body=$(curl -s -L --max-time 20 -A "styleflow-status-probe/1" -o /tmp/body -w "%{http_code}" "$url" 2>/dev/null) || body="000"
  code="$body"
  if ! printf '%s' "$code" | grep -Eq "^($ok)$"; then echo "down $code"; return; fi
  if [ -n "$marker" ] && ! grep -q -- "$marker" /tmp/body; then echo "down $code-marker"; return; fi
  echo "up $code"
}
# label|name|url|okcodes|marker
COMPONENTS='booking|Booking & client site|https://styleflowapp.com/|200|href="/login"
signin|Sign in|https://styleflowapp.com/login|200|id="login-password"
api|Booking API|https://styleflowapp.com/api/version|200|commit
shop|Dominick'"'"'s Barbershop (current site)|https://domsonlineshop.com/|200|book-now'
prev=$(cat status.json 2>/dev/null || echo '{}')
items=""; overall="operational"
while IFS='|' read -r label name url ok marker; do
  [ -n "$label" ] || continue
  r1=$(probe "$url" "$ok" "$marker"); state="operational"
  if [[ "$r1" == down* ]]; then sleep 20; r2=$(probe "$url" "$ok" "$marker"); if [[ "$r2" == down* ]]; then state="down"; else state="degraded"; fi; fi
  [ "$state" = "down" ] && overall="outage"
  [ "$state" = "degraded" ] && [ "$overall" = "operational" ] && overall="degraded"
  items="$items{\"id\":\"$label\",\"name\":\"$name\",\"state\":\"$state\",\"detail\":\"${r1}\"},"
done <<< "$COMPONENTS"
items="[${items%,}]"
printf '{"updatedAt":"%s","overall":"%s","components":%s}\n' "$NOW" "$overall" "$items" > status.json
# incidents: open one per component on down, close it on operational
python3 - "$NOW" <<'PY'
import json,sys
now=sys.argv[1]; st=json.load(open("status.json")); inc=json.load(open("incidents.json"))
open_by={i["component"]:i for i in inc if not i.get("resolvedAt")}
for c in st["components"]:
    if c["state"]=="down" and c["id"] not in open_by:
        inc.append({"component":c["id"],"name":c["name"],"startedAt":now,"resolvedAt":None,"detail":c["detail"]})
    if c["state"]=="operational" and c["id"] in open_by:
        open_by[c["id"]]["resolvedAt"]=now
json.dump(inc[-50:],open("incidents.json","w"),indent=1)
PY
