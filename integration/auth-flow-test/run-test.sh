#!/usr/bin/env bash
# Authorization-flow integration test
#
# Validates the two supported login modes from scripts/setup-client.sh and
# the subnet-route admin-approval path:
#   Phase 1 — Mode 1: pre-auth-key (purr up --authkey=...)
#   Phase 2 — Mode 2: browser/manual approval
#       client: purr up --login-server=URL  (no authkey)
#       client prints registration URL on stderr
#       admin: phub nodes register --user U --key REG_ID
#   Phase 3 — Subnet route: --advertise-routes → admin approve-routes → peer
#       reaches a node only reachable through the router via tailnet.
#
# This test is independent of apisix-test (which exercises proxy/disguise).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yaml -p auth-flow-test"
PURR="purr --socket=/var/run/purr/purrd.sock"
PHUB="purrhub -c /etc/purrhub/config.yaml"
SERVER_URL="http://172.30.1.10:8080"
INTERNAL_CIDR="172.30.4.0/24"
INTERNAL_IP="172.30.4.10"

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${YELLOW}[TEST]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

cleanup() {
    log "Saving logs..."
    mkdir -p "$SCRIPT_DIR/logs"
    for svc in purrhub purr-authkey purr-browser node-internal; do
        $COMPOSE logs "$svc" > "$SCRIPT_DIR/logs/$svc.log" 2>&1 || true
    done
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# ─── Phase 0: build & start ───────────────────────────────────────────
log "Phase 0: build & start containers"
$COMPOSE build --parallel
$COMPOSE up -d

log "Waiting for purrhub health..."
for i in $(seq 1 30); do
    $COMPOSE exec -T purrhub curl -sf http://localhost:8080/health >/dev/null 2>&1 && break
    [ "$i" -eq 30 ] && { fail "purrhub never healthy"; exit 1; }
    sleep 2
done
pass "purrhub healthy"

# Wait for purrd ready on both clients
for node in purr-authkey purr-browser; do
    for i in $(seq 1 20); do
        if $COMPOSE exec -T "$node" $PURR status 2>&1 | grep -qE "Logged out|Log in|NeedsLogin|Stopped"; then
            break
        fi
        [ "$i" -eq 20 ] && log "WARN: $node purrd may not be ready"
        sleep 1
    done
done
pass "purrd ready on both clients"

# Create user "alice". Note: `preauthkeys create --user` accepts the numeric
# ID, but `nodes register --user` looks up by *name* — so keep both around.
USER_NAME="alice"
$COMPOSE exec -T purrhub $PHUB users create "$USER_NAME" 2>/dev/null || true
USER_ID=$($COMPOSE exec -T purrhub $PHUB users list -o json 2>/dev/null \
    | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
USER_ID="${USER_ID:-1}"
log "user $USER_NAME → id=$USER_ID"

# ─── Phase 1: pre-auth-key (Mode 1) ───────────────────────────────────
log "Phase 1: pre-auth-key login (purr-authkey, also acts as subnet router)"

KEY=$($COMPOSE exec -T purrhub $PHUB preauthkeys create \
        --user "$USER_ID" --reusable --expiration 1h 2>/dev/null \
    | grep -oE 'hskey-[^[:space:]]+' | head -1)
if [ -n "$KEY" ]; then
    pass "preauthkey created (${KEY:0:24}...)"
else
    fail "failed to create preauthkey"; exit 1
fi

$COMPOSE exec -T purr-authkey $PURR up \
    --login-server="$SERVER_URL" \
    --authkey="$KEY" \
    --hostname=router \
    --advertise-routes="$INTERNAL_CIDR" \
    --accept-routes \
    --accept-dns=false \
    --timeout=60s 2>&1 || true

sleep 3
if $COMPOSE exec -T purr-authkey $PURR status --json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('Self',{}).get('Online') else 1)" 2>/dev/null; then
    pass "purr-authkey online via authkey"
else
    fail "purr-authkey not online after authkey login"
    $COMPOSE exec -T purr-authkey $PURR status 2>&1 | sed 's/^/  /' || true
fi

# ─── Phase 2: browser/manual approval (Mode 2) ────────────────────────
log "Phase 2: browser/manual approval (purr-browser)"

# Run `purr up` detached inside the container, redirect both fds to a file
# so we can extract the registration URL the daemon prints.
$COMPOSE exec -dT purr-browser sh -c "
    rm -f /tmp/purr-up.out
    $PURR up \
        --login-server=$SERVER_URL \
        --hostname=worker \
        --accept-routes \
        --accept-dns=false \
        --timeout=300s > /tmp/purr-up.out 2>&1
"

# Wait for the registration URL/ID to appear
REG_ID=""
for i in $(seq 1 30); do
    OUT=$($COMPOSE exec -T purr-browser cat /tmp/purr-up.out 2>/dev/null || echo "")
    REG_ID=$(echo "$OUT" | grep -oE '/register/[A-Za-z0-9_-]+' | head -1 | sed 's|/register/||')
    [ -n "$REG_ID" ] && break
    sleep 1
done

if [ -z "$REG_ID" ]; then
    fail "client never produced registration URL"
    log "client output so far:"
    $COMPOSE exec -T purr-browser cat /tmp/purr-up.out 2>&1 | tail -20 | sed 's/^/  /' || true
    exit 1
fi
pass "client produced registration ID (${REG_ID:0:12}...)"

# Sanity baseline: prove purr-browser CANNOT reach node-internal yet — if it
# can already, Docker's cross-bridge routing is on and the later "via tailnet"
# test would be a false positive.
PRE_TAILNET=$($COMPOSE exec -T purr-browser \
    curl -sf --max-time 3 "http://${INTERNAL_IP}:8080/" 2>&1 || echo "BLOCKED")
if echo "$PRE_TAILNET" | grep -q internal-target; then
    fail "purr-browser already reaches node-internal without tailnet — Docker bridges not isolated, the connectivity test below would be a false positive"
else
    pass "baseline: purr-browser cannot reach node-internal yet (good — proves later success is via tailnet)"
fi

# Admin approves: simulates the operator copying the command from the
# registration page and running it on the purrhub server.
log "running: $PHUB nodes register --user $USER_NAME --key $REG_ID"
REGISTER_OUT=$($COMPOSE exec -T purrhub $PHUB nodes register \
    --user "$USER_NAME" --key "$REG_ID" 2>&1 || true)
log "register full output:"
echo "$REGISTER_OUT" | sed 's/^/  /'

# Wait for the client's `purr up` call to settle and report Online.
# Generous timeout — registration → first map response → DERP setup can take
# tens of seconds in cold containers.
ONLINE_OK=0
for i in $(seq 1 90); do
    if $COMPOSE exec -T purr-browser $PURR status --json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('Self',{}).get('Online') else 1)" 2>/dev/null; then
        ONLINE_OK=1; break
    fi
    sleep 1
done
if [ "$ONLINE_OK" -eq 1 ]; then
    pass "purr-browser online via manual approval"
else
    fail "purr-browser not online after admin register"
    log "purr-browser /tmp/purr-up.out:"
    $COMPOSE exec -T purr-browser cat /tmp/purr-up.out 2>&1 | tail -25 | sed 's/^/  /' || true
    log "purr-browser status:"
    $COMPOSE exec -T purr-browser $PURR status 2>&1 | sed 's/^/  /' || true
    log "purrhub recent log:"
    $COMPOSE logs --tail 40 purrhub 2>&1 | sed 's/^/  /' || true
fi

# ─── Phase 3: subnet route admin approval ─────────────────────────────
log "Phase 3: subnet route admin approval"

ROUTER_ID=$($COMPOSE exec -T purrhub $PHUB nodes list -o json 2>/dev/null \
    | python3 -c "
import sys, json
for n in json.load(sys.stdin):
    if n.get('given_name') == 'router' or n.get('name') == 'router':
        print(n.get('id')); break
" 2>/dev/null || echo "")

if [ -z "$ROUTER_ID" ]; then
    fail "could not locate router node id"
else
    pass "router node id = $ROUTER_ID"

    # Pre-approval: route should be advertised but not yet approved.
    PRE=$($COMPOSE exec -T purrhub $PHUB nodes list-routes 2>&1 || true)
    log "pre-approval routes:"
    echo "$PRE" | sed 's/^/  /'

    APPROVE_OUT=$($COMPOSE exec -T purrhub $PHUB nodes approve-routes \
        -i "$ROUTER_ID" --routes "$INTERNAL_CIDR" 2>&1 || true)
    log "approve-routes output: $(echo "$APPROVE_OUT" | tail -3 | head -1)"

    POST=$($COMPOSE exec -T purrhub $PHUB nodes list-routes 2>&1 || true)
    log "post-approval routes:"
    echo "$POST" | sed 's/^/  /'

    if echo "$POST" | grep -q "$INTERNAL_CIDR"; then
        pass "purrhub shows $INTERNAL_CIDR as approved"
    else
        fail "purrhub does not show $INTERNAL_CIDR as approved"
    fi

    # Give netmap a few seconds to propagate to purr-browser
    sleep 5

    # Headline: connectivity. node-internal app-level filter requires the
    # request's source IP to be in 172.30.4.0/24 — only achievable when the
    # packet arrives via tailnet → router (which SNATs to 172.30.4.20).
    # If Docker cross-bridge routing leaks the packet, source would be
    # 172.30.1.30 and the server would 403.
    HTTP_OUT=$($COMPOSE exec -T purr-browser curl -sf --max-time 15 \
        "http://${INTERNAL_IP}:8080/" 2>&1 || echo "FAIL")
    if echo "$HTTP_OUT" | grep -q 'internal-target'; then
        pass "purr-browser reached node-internal via tailnet subnet route"
    else
        fail "purr-browser cannot reach http://${INTERNAL_IP}:8080/ via tailnet"
        log "  curl output: $HTTP_OUT"
    fi
fi

# ─── Summary ──────────────────────────────────────────────────────────
echo
echo "============================================"
echo -e "  Auth-flow results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} / ${TOTAL}"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}AUTH-FLOW TEST FAILED${NC}"
    echo "Logs saved to: ${SCRIPT_DIR}/logs/"
    exit 1
fi
echo -e "${GREEN}AUTH-FLOW TEST PASSED${NC}"
exit 0
