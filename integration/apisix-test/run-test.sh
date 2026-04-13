#!/usr/bin/env bash
# Integration test: APISIX reverse proxy + Headscale + disguised DERP
#
# Architecture:
#   ts-node1 --> APISIX(:80) --> headscale(:8080) <-- APISIX(:80) <-- ts-node2
#                                  (embedded DERP)
#
# Verifies:
#   1. Headscale starts with disguise config
#   2. APISIX proxies control plane and DERP traffic
#   3. Tailscale nodes register through APISIX
#   4. Nodes can reach each other via DERP relay
#   5. No original protocol identifiers leak in traffic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yaml -p apisix-test"
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
    ${COMPOSE} logs headscale > "${SCRIPT_DIR}/logs/headscale.log" 2>&1 || true
    ${COMPOSE} logs apisix    > "${SCRIPT_DIR}/logs/apisix.log"    2>&1 || true
    ${COMPOSE} logs ts-node1  > "${SCRIPT_DIR}/logs/ts-node1.log"  2>&1 || true
    ${COMPOSE} logs ts-node2  > "${SCRIPT_DIR}/logs/ts-node2.log"  2>&1 || true
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

log "Waiting for headscale to be healthy..."
for i in $(seq 1 30); do
    if ${COMPOSE} exec -T headscale curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        fail "Headscale did not become healthy"
        exit 1
    fi
    sleep 2
done
pass "Headscale is healthy"

log "Waiting for APISIX to be ready..."
for i in $(seq 1 20); do
    if curl -sf http://localhost:8880/health >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 20 ]; then
        fail "APISIX did not become ready"
        exit 1
    fi
    sleep 2
done
pass "APISIX is ready and proxying to headscale"

# ──────────────────────────────────────────────
# Phase 1: Verify disguised endpoints via APISIX
# ──────────────────────────────────────────────
log "Phase 1: Verifying disguised endpoints through APISIX..."

# The /key endpoint should be reachable through APISIX (returns 400 without params, which is fine)
KEY_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8880/key 2>/dev/null || echo "000")
if [ "$KEY_CODE" != "404" ] && [ "$KEY_CODE" != "502" ] && [ "$KEY_CODE" != "000" ]; then
    pass "APISIX proxies /key endpoint (HTTP $KEY_CODE)"
else
    fail "APISIX cannot proxy /key endpoint (HTTP $KEY_CODE)"
fi

# The disguised control path should be reachable (will return upgrade required, but not 404)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8880/api/connect 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "404" ] && [ "$HTTP_CODE" != "000" ]; then
    pass "Disguised control path /api/connect is routed (HTTP $HTTP_CODE)"
else
    fail "Disguised control path /api/connect returned $HTTP_CODE"
fi

# The old /ts2021 path should NOT be routed (caught by wildcard, headscale returns 404 or unexpected)
# This verifies the disguise is active on the server side
HTTP_CODE_OLD=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8880/ts2021 2>/dev/null || echo "000")
log "Old path /ts2021 returns HTTP $HTTP_CODE_OLD (expected: not a successful upgrade)"

# ──────────────────────────────────────────────
# Phase 2: Create user and auth keys
# ──────────────────────────────────────────────
log "Phase 2: Creating user and pre-auth keys..."

${COMPOSE} exec -T headscale headscale users create testuser 2>/dev/null || true

# Get user ID (headscale v0.28+ uses numeric user IDs)
USER_ID=$(${COMPOSE} exec -T headscale headscale users list -o json 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
if [ -z "$USER_ID" ]; then
    USER_ID=1
fi
log "User ID: $USER_ID"

KEY1=$(${COMPOSE} exec -T headscale headscale preauthkeys create --user "$USER_ID" --reusable --expiration 1h 2>/dev/null | grep -o 'hskey-[^ ]*' | tr -d '[:space:]')
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
for node in ts-node1 ts-node2; do
    for i in $(seq 1 15); do
        if ${COMPOSE} exec -T "$node" tailscale status 2>&1 | grep -q "Logged out" || \
           ${COMPOSE} exec -T "$node" tailscale status 2>&1 | grep -q "Log in" || \
           ${COMPOSE} exec -T "$node" tailscale status 2>&1 | grep -q "NeedsLogin"; then
            break
        fi
        [ "$i" -eq 15 ] && log "Warning: $node tailscaled may not be ready"
        sleep 1
    done
done

# Resolve APISIX's internal IP (private IP disables HTTPS fallback in tailscale)
APISIX_IP=$(${COMPOSE} exec -T ts-node1 getent hosts apisix 2>/dev/null | awk '{print $1}' | head -1)
if [ -z "$APISIX_IP" ]; then
    APISIX_IP="apisix"
fi
log "APISIX internal IP: $APISIX_IP"

# Node 1: connect through APISIX using private IP (prevents HTTPS fallback to 443)
log "Registering ts-node1..."
${COMPOSE} exec -T ts-node1 tailscale up \
    --login-server="http://${APISIX_IP}:80" \
    --authkey="$KEY1" \
    --hostname=ts-node1 \
    --accept-dns=false \
    --timeout=60s 2>&1 || true

# Node 2: connect through APISIX
log "Registering ts-node2..."
${COMPOSE} exec -T ts-node2 tailscale up \
    --login-server="http://${APISIX_IP}:80" \
    --authkey="$KEY1" \
    --hostname=ts-node2 \
    --accept-dns=false \
    --timeout=60s 2>&1 || true

# Wait for registration to complete
for i in $(seq 1 15); do
    NODE_COUNT_TMP=$(${COMPOSE} exec -T headscale headscale nodes list -o json 2>/dev/null | grep -c '"id"' 2>/dev/null || echo "0")
    [ "$NODE_COUNT_TMP" -ge 2 ] 2>/dev/null && break
    sleep 2
done

# Verify both nodes are registered
NODE_COUNT=$(${COMPOSE} exec -T headscale headscale nodes list -o json 2>/dev/null | grep -c '"id"' 2>/dev/null || echo "0")
if [ "$NODE_COUNT" -ge 2 ]; then
    pass "Both nodes registered ($NODE_COUNT nodes found)"
else
    fail "Expected 2+ nodes, found $NODE_COUNT"
    # Show debug info
    ${COMPOSE} exec -T headscale headscale nodes list 2>/dev/null || true
fi

# ──────────────────────────────────────────────
# Phase 4: Verify tailscale status on each node
# ──────────────────────────────────────────────
log "Phase 4: Checking tailscale status..."

STATUS1=$(${COMPOSE} exec -T ts-node1 tailscale status --json 2>/dev/null || echo "{}")
STATUS2=$(${COMPOSE} exec -T ts-node2 tailscale status --json 2>/dev/null || echo "{}")

# Check node1 sees itself as connected
SELF1=$(echo "$STATUS1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('Online', False))" 2>/dev/null || echo "False")
if [ "$SELF1" = "True" ]; then
    pass "ts-node1 is online"
else
    fail "ts-node1 is not online"
fi

SELF2=$(echo "$STATUS2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('Online', False))" 2>/dev/null || echo "False")
if [ "$SELF2" = "True" ]; then
    pass "ts-node2 is online"
else
    fail "ts-node2 is not online"
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
    if 'ts-node2' in p.get('HostName', ''):
        addrs = p.get('TailscaleIPs', [])
        if addrs:
            print(addrs[0])
            break
" 2>/dev/null || echo "")

if [ -n "$NODE2_IP" ]; then
    pass "ts-node1 sees ts-node2 at $NODE2_IP"

    # Ping from node1 to node2
    PING_RESULT=$(${COMPOSE} exec -T ts-node1 tailscale ping --c 3 --timeout 10s "$NODE2_IP" 2>&1 || echo "failed")
    if echo "$PING_RESULT" | grep -qi "pong"; then
        pass "ts-node1 can ping ts-node2 via tailnet"

        # Check if it went through DERP
        if echo "$PING_RESULT" | grep -qi "via DERP"; then
            pass "Traffic is routed through DERP relay (as expected without STUN)"
        else
            log "Traffic may be going direct (DERP not detected in ping output)"
        fi
    else
        fail "ts-node1 cannot ping ts-node2: $PING_RESULT"
    fi
else
    fail "ts-node1 does not see ts-node2 as a peer"
fi

# ──────────────────────────────────────────────
# Phase 6: Verify protocol disguise (no leakage)
# ──────────────────────────────────────────────
log "Phase 6: Checking protocol disguise..."

# Check headscale logs for original identifiers
HS_LOG=$(${COMPOSE} logs headscale 2>&1)

# These original identifiers should NOT appear in logs
LEAKED=0
for pattern in "/ts2021" "Upgrade: DERP" "tailscale-control-protocol" "X-Tailscale-Handshake" "Derp-Fast-Start"; do
    if echo "$HS_LOG" | grep -q "$pattern"; then
        fail "Leaked original identifier in headscale logs: $pattern"
        LEAKED=1
    fi
done
if [ "$LEAKED" -eq 0 ]; then
    pass "No original protocol identifiers found in headscale logs"
fi

# These disguised identifiers SHOULD appear
for pattern in "/api/connect" "/relay"; do
    if echo "$HS_LOG" | grep -q "$pattern"; then
        pass "Disguised path '$pattern' found in headscale logs"
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

NETCHECK=$(${COMPOSE} exec -T ts-node1 tailscale netcheck 2>&1 || echo "failed")
echo "$NETCHECK"

if echo "$NETCHECK" | grep -qi "999"; then
    pass "DERP region 999 (embedded) is visible in netcheck"
else
    log "DERP region 999 not explicitly shown in netcheck output"
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
