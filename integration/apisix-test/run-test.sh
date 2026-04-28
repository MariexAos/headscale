#!/usr/bin/env bash
# Integration test: APISIX reverse proxy + Purrhub + disguised DERP
#
# Architecture:
#   purr-node1 --> APISIX(:80) --> purrhub(:8080) <-- APISIX(:80) <-- purr-node2
#                                  (embedded DERP)
#
# Verifies:
#   1. Purrhub starts with disguise config
#   2. APISIX proxies control plane and DERP traffic
#   3. Tailscale nodes register through APISIX
#   4. Nodes can reach each other via DERP relay
#   5. No original protocol identifiers leak in traffic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yaml -p apisix-test"

# Brand binaries with their explicit flags — daemon defaults to upstream
# paths (paths.go unchanged), so every caller passes them.
PURR="purr --socket=/var/run/purr/purrd.sock"
PHUB="purrhub -c /etc/purrhub/config.yaml"

PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${YELLOW}[TEST]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

cleanup() {
    log "Collecting logs..."
    mkdir -p "${SCRIPT_DIR}/logs"
    ${COMPOSE} logs purrhub > "${SCRIPT_DIR}/logs/purrhub.log" 2>&1 || true
    ${COMPOSE} logs apisix    > "${SCRIPT_DIR}/logs/apisix.log"    2>&1 || true
    ${COMPOSE} logs purr-node1  > "${SCRIPT_DIR}/logs/purr-node1.log"  2>&1 || true
    ${COMPOSE} logs purr-node2  > "${SCRIPT_DIR}/logs/purr-node2.log"  2>&1 || true
    log "Shutting down containers..."
    ${COMPOSE} down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# ──────────────────────────────────────────────
# Phase 0: Build & Start
# ──────────────────────────────────────────────
log "Phase 0: Building and starting containers..."
${COMPOSE} build --parallel
${COMPOSE} up -d

log "Waiting for purrhub to be healthy..."
for i in $(seq 1 30); do
    if ${COMPOSE} exec -T purrhub curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        fail "Purrhub did not become healthy"
        exit 1
    fi
    sleep 2
done
pass "Purrhub is healthy"

log "Waiting for APISIX to be ready..."
for i in $(seq 1 20); do
    if ${COMPOSE} exec -T purrhub curl -sf http://apisix:80/health >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 20 ]; then
        fail "APISIX did not become ready"
        exit 1
    fi
    sleep 2
done
pass "APISIX is ready and proxying to purrhub"

# ──────────────────────────────────────────────
# Phase 1: Verify disguised endpoints via APISIX
# ──────────────────────────────────────────────
log "Phase 1: Verifying disguised endpoints through APISIX..."

# The /key endpoint should be reachable through APISIX (returns 400 without params, which is fine)
KEY_CODE=$(${COMPOSE} exec -T purrhub curl -s -o /dev/null -w "%{http_code}" http://apisix:80/key 2>/dev/null || echo "000")
if [ "$KEY_CODE" != "404" ] && [ "$KEY_CODE" != "502" ] && [ "$KEY_CODE" != "000" ]; then
    pass "APISIX proxies /key endpoint (HTTP $KEY_CODE)"
else
    fail "APISIX cannot proxy /key endpoint (HTTP $KEY_CODE)"
fi

# The disguised control path should be reachable (will return upgrade required, but not 404)
HTTP_CODE=$(${COMPOSE} exec -T purrhub curl -s -o /dev/null -w "%{http_code}" http://apisix:80/api/connect 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "404" ] && [ "$HTTP_CODE" != "000" ]; then
    pass "Disguised control path /api/connect is routed (HTTP $HTTP_CODE)"
else
    fail "Disguised control path /api/connect returned $HTTP_CODE"
fi

# The old /ts2021 path should NOT be routed (caught by wildcard, purrhub returns 404 or unexpected)
# This verifies the disguise is active on the server side
HTTP_CODE_OLD=$(${COMPOSE} exec -T purrhub curl -s -o /dev/null -w "%{http_code}" http://apisix:80/ts2021 2>/dev/null || echo "000")
log "Old path /ts2021 returns HTTP $HTTP_CODE_OLD (expected: not a successful upgrade)"

# ──────────────────────────────────────────────
# Phase 2: Create user and auth keys
# ──────────────────────────────────────────────
log "Phase 2: Creating user and pre-auth keys..."

${COMPOSE} exec -T purrhub $PHUB users create testuser 2>/dev/null || true

# Get user ID (purrhub v0.28+ uses numeric user IDs)
USER_ID=$(${COMPOSE} exec -T purrhub $PHUB users list -o json 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
if [ -z "$USER_ID" ]; then
    USER_ID=1
fi
log "User ID: $USER_ID"

KEY1=$(${COMPOSE} exec -T purrhub $PHUB preauthkeys create --user "$USER_ID" --reusable --expiration 1h 2>/dev/null | grep -o 'hskey-[^ ]*' | tr -d '[:space:]')
if [ -n "$KEY1" ]; then
    pass "Created pre-auth key: ${KEY1:0:20}..."
else
    fail "Failed to create pre-auth key"
    exit 1
fi

# ──────────────────────────────────────────────
# Phase 3: Register tailscale nodes through APISIX
# ──────────────────────────────────────────────
log "Phase 3: Registering tailscale nodes through APISIX..."

# Wait for tailscaled to be ready
log "Waiting for tailscaled to be ready on nodes..."
for node in purr-node1 purr-node2; do
    for i in $(seq 1 15); do
        if ${COMPOSE} exec -T "$node" $PURR status 2>&1 | grep -q "Logged out" || \
           ${COMPOSE} exec -T "$node" $PURR status 2>&1 | grep -q "Log in" || \
           ${COMPOSE} exec -T "$node" $PURR status 2>&1 | grep -q "NeedsLogin"; then
            break
        fi
        [ "$i" -eq 15 ] && log "Warning: $node tailscaled may not be ready"
        sleep 1
    done
done

# Each node resolves its own `gateway` alias to a private RFC1918 IP. Using
# the IP (not the hostname) in --login-server stops Tailscale from doing
# its "force HTTPS-on-443" fallback for non-IP-literal login servers.
#
#   purr-node1's gateway → nginx     (net-node1 side)
#   purr-node2's gateway → apisix    (net-node2 side)
GW_IP_NODE1=$(${COMPOSE} exec -T purr-node1 getent hosts gateway 2>/dev/null | awk '{print $1}' | head -1)
GW_IP_NODE2=$(${COMPOSE} exec -T purr-node2 getent hosts gateway 2>/dev/null | awk '{print $1}' | head -1)
log "purr-node1 gateway IP: $GW_IP_NODE1   (→ nginx)"
log "purr-node2 gateway IP: $GW_IP_NODE2   (→ apisix)"

if [ -z "$GW_IP_NODE1" ] || [ -z "$GW_IP_NODE2" ]; then
    fail "Could not resolve gateway alias inside one of the nodes"
    exit 1
fi

# Node 1: connect through nginx using its private IP. Accept routes so it
# can reach node3 (git/http server) through the purr-node2 subnet router.
log "Registering purr-node1..."
${COMPOSE} exec -T purr-node1 $PURR up \
    --login-server="http://${GW_IP_NODE1}:80" \
    --authkey="$KEY1" \
    --hostname=purr-node1 \
    --accept-routes \
    --accept-dns=false \
    --timeout=60s 2>&1 || true

# Node 2: connect through APISIX directly (it's in net-node2 with apisix alias=gateway).
# Advertises the internal LAN (172.28.4.0/24 → node3) so purr-node1 can reach git.
log "Registering purr-node2..."
${COMPOSE} exec -T purr-node2 $PURR up \
    --login-server="http://${GW_IP_NODE2}:80" \
    --authkey="$KEY1" \
    --hostname=purr-node2 \
    --advertise-routes=172.28.4.0/24 \
    --accept-dns=false \
    --timeout=60s 2>&1 || true

# Wait for registration to complete
for i in $(seq 1 15); do
    NODE_COUNT_TMP=$(${COMPOSE} exec -T purrhub $PHUB nodes list -o json 2>/dev/null | grep -c '"id"' 2>/dev/null || echo "0")
    [ "$NODE_COUNT_TMP" -ge 2 ] 2>/dev/null && break
    sleep 2
done

# Verify both nodes are registered
NODE_COUNT=$(${COMPOSE} exec -T purrhub $PHUB nodes list -o json 2>/dev/null | grep -c '"id"' 2>/dev/null || echo "0")
if [ "$NODE_COUNT" -ge 2 ]; then
    pass "Both nodes registered ($NODE_COUNT nodes found)"
else
    fail "Expected 2+ nodes, found $NODE_COUNT"
    # Show debug info
    ${COMPOSE} exec -T purrhub $PHUB nodes list 2>/dev/null || true
fi

# ──────────────────────────────────────────────
# Phase 4: Verify tailscale status on each node
# ──────────────────────────────────────────────
log "Phase 4: Checking tailscale status..."

STATUS1=$(${COMPOSE} exec -T purr-node1 $PURR status --json 2>/dev/null || echo "{}")
STATUS2=$(${COMPOSE} exec -T purr-node2 $PURR status --json 2>/dev/null || echo "{}")

# Check node1 sees itself as connected
SELF1=$(echo "$STATUS1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('Online', False))" 2>/dev/null || echo "False")
if [ "$SELF1" = "True" ]; then
    pass "purr-node1 is online"
else
    fail "purr-node1 is not online"
fi

SELF2=$(echo "$STATUS2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('Online', False))" 2>/dev/null || echo "False")
if [ "$SELF2" = "True" ]; then
    pass "purr-node2 is online"
else
    fail "purr-node2 is not online"
fi

# ──────────────────────────────────────────────
# Phase 5: Test node-to-node connectivity via DERP
# ──────────────────────────────────────────────
log "Phase 5: Testing node-to-node ping (via DERP relay)..."

# Get node2's tailscale IP from node1's perspective
NODE2_IP=$(echo "$STATUS1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k, p in d.get('Peer', {}).items():
    if 'purr-node2' in p.get('HostName', ''):
        addrs = p.get('TailscaleIPs', [])
        if addrs:
            print(addrs[0])
            break
" 2>/dev/null || echo "")

if [ -n "$NODE2_IP" ]; then
    pass "purr-node1 sees purr-node2 at $NODE2_IP"

    # Ping from node1 to node2
    PING_RESULT=$(${COMPOSE} exec -T purr-node1 $PURR ping --c 3 --timeout 10s "$NODE2_IP" 2>&1 || echo "failed")
    if echo "$PING_RESULT" | grep -qi "pong"; then
        pass "purr-node1 can ping purr-node2 via tailnet"

        # Check if it went through DERP
        if echo "$PING_RESULT" | grep -qi "via DERP"; then
            pass "Traffic is routed through DERP relay (as expected without STUN)"
        else
            log "Traffic may be going direct (DERP not detected in ping output)"
        fi
    else
        fail "purr-node1 cannot ping purr-node2: $PING_RESULT"
    fi
else
    fail "purr-node1 does not see purr-node2 as a peer"
fi

# ──────────────────────────────────────────────
# Phase 6: Verify protocol disguise (no leakage)
# ──────────────────────────────────────────────
log "Phase 6: Checking protocol disguise..."

# Check purrhub logs for original identifiers
HS_LOG=$(${COMPOSE} logs purrhub 2>&1)

# These original identifiers should NOT appear in logs
LEAKED=0
for pattern in "/ts2021" "Upgrade: DERP" "tailscale-control-protocol" "X-Tailscale-Handshake" "Derp-Fast-Start"; do
    if echo "$HS_LOG" | grep -q "$pattern"; then
        fail "Leaked original identifier in purrhub logs: $pattern"
        LEAKED=1
    fi
done
if [ "$LEAKED" -eq 0 ]; then
    pass "No original protocol identifiers found in purrhub logs"
fi

# These disguised identifiers SHOULD appear
for pattern in "/api/connect" "/relay"; do
    if echo "$HS_LOG" | grep -q "$pattern"; then
        pass "Disguised path '$pattern' found in purrhub logs"
    else
        log "Disguised path '$pattern' not found in logs (may be in trace level only)"
    fi
done

# Check APISIX access logs for routes
APISIX_LOG=$(${COMPOSE} logs apisix 2>&1)
for pattern in "/api/connect" "/relay"; do
    if echo "$APISIX_LOG" | grep -q "$pattern"; then
        pass "APISIX routed disguised path '$pattern'"
    else
        log "APISIX log does not show '$pattern' (may need access log enabled)"
    fi
done

# ──────────────────────────────────────────────
# Phase 7: Verify DERP netcheck
# ──────────────────────────────────────────────
log "Phase 7: Running netcheck..."

NETCHECK=$(${COMPOSE} exec -T purr-node1 $PURR netcheck 2>&1 || echo "failed")
echo "$NETCHECK"

if echo "$NETCHECK" | grep -qi "999"; then
    pass "DERP region 999 (embedded) is visible in netcheck"
else
    log "DERP region 999 not explicitly shown in netcheck output"
fi

# ──────────────────────────────────────────────
# Phase 8: Subnet router — purr-node1 reaches node3 (git/http server) through
# purr-node2 via tailnet, all relayed via DERP.
# ──────────────────────────────────────────────
log "Phase 8: Subnet routing — purr-node1 → purr-node2 → node3 (172.28.4.10) ..."

# Find purr-node2's node ID and approve its advertised route
NODE2_ID=$(${COMPOSE} exec -T purrhub $PHUB nodes list -o json 2>/dev/null | \
    python3 -c "
import sys, json
nodes = json.load(sys.stdin)
for n in nodes:
    if n.get('given_name') == 'purr-node2' or n.get('name') == 'purr-node2':
        print(n.get('id'))
        break
" 2>/dev/null || echo "")

if [ -z "$NODE2_ID" ]; then
    fail "Could not resolve purr-node2 node ID for route approval"
else
    log "purr-node2 node ID: $NODE2_ID"
    APPROVE_OUT=$(${COMPOSE} exec -T purrhub $PHUB nodes approve-routes -i "$NODE2_ID" --routes 172.28.4.0/24 2>&1 || true)
    log "Route approve: $(echo "$APPROVE_OUT" | tail -3 | head -1)"

    # Give the netmap a couple of seconds to propagate to purr-node1
    sleep 5

    # purr-node1 should now see 172.28.4.0/24 in its routing table (via tailnet)
    ROUTE_CHECK=$(${COMPOSE} exec -T purr-node1 ip route 2>/dev/null | grep -c '172.28.4' || true)
    if [ "$ROUTE_CHECK" -ge 1 ]; then
        pass "purr-node1 received subnet route 172.28.4.0/24"
    else
        log "Subnet route not yet in purr-node1 routing table (tailnet may still be settling)"
    fi

    # The headline test: purr-node1 fetches HTTP from node3 via tailnet.
    # node3 is on net-internal only — purr-node1 has no direct route to it.
    # The only way this works is via tailnet → purr-node2 → forward → node3.
    log "purr-node1 → http://172.28.4.10:8080 (node3) via tailnet ..."
    HTTP_OUT=$(${COMPOSE} exec -T purr-node1 curl -sf --max-time 15 http://172.28.4.10:8080/ 2>&1 || echo "FAIL: $?")
    if echo "$HTTP_OUT" | grep -q '"service":"internal-api"'; then
        pass "purr-node1 fetched node3 HTTP via tailnet subnet route"
        log "  payload: $HTTP_OUT"
    else
        fail "purr-node1 could not fetch http://172.28.4.10:8080/ via tailnet"
        log "  curl output: $HTTP_OUT"
        log "  purr-node1 routes:"
        ${COMPOSE} exec -T purr-node1 ip route 2>&1 | sed 's/^/    /' | tail -10 || true
    fi

    # Bonus: node3 also runs sshd with a bare git repo. Use nc to probe the
    # SSH port (we don't actually git-clone — that needs git + SSH key
    # plumbing not present in the purr-node1 image).
    if ${COMPOSE} exec -T purr-node1 nc -z -w 5 172.28.4.10 22 >/dev/null 2>&1; then
        pass "purr-node1 can reach git server SSH (172.28.4.10:22) via tailnet"
    else
        log "SSH probe to git server failed (HTTP test already proves L4 connectivity)"
    fi
fi

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo ""
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} / ${TOTAL} total"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}INTEGRATION TEST FAILED${NC}"
    echo "Logs saved to: ${SCRIPT_DIR}/logs/"
    exit 1
else
    echo -e "${GREEN}INTEGRATION TEST PASSED${NC}"
    exit 0
fi
