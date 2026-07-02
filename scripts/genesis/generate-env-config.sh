#!/bin/bash
# generate-env-config.sh
# Generate a complete Ethereum testnet genesis config for a NAMED environment
# (staging, a new namespace, a release snapshot, ...). This is the standalone,
# locally-testable sibling of generate-preview-config.sh — that one is
# preview/PR-specific (namespace-exists detection, stale-genesis PR comments,
# reuse-vs-fresh re-deploy logic); this one is a clean "generate a fresh config
# for env <name>" with none of that. Both reuse the same generate-genesis.sh.
#
# Deliberately NOT DRY-merged with the preview pipeline: the orchestration is
# genuinely different per context; only generate-genesis.sh is (already) shared.
#
# Usage: ./generate-env-config.sh --env <name> [OPTIONS]
#
# Required:
#   --env NAME            → network-configs/<name>/metadata/
#                          e.g. "staging", "ethereum-test", "release/v0.2.5-1751200000"
# Optional:
#   --validators NUM      default 128
#   --chain-id ID         default 3151909
#   --genesis-delay SEC   default 120   (genesis_time = now + this)
#   --mnemonic-file FILE  default <script-dir>/mnemonic.txt (the SHARED validator set)
#   --output-base DIR     default ./network-configs
#   --fresh-accounts      mint a NEW accounts set (default: reuse the committed
#                         scripts/genesis/accounts/ — fixed withdrawal, so this env's genesis
#                         identity/fork_digest matches previews & staging)
#   --push                git add/commit/push to origin/main (DEFAULT: OFF — generate only)
#   --dry-run             print the plan and exit, generate nothing
#
# Output: <output-base>/<name>/metadata/{genesis.json,genesis.ssz,config.yaml,
#         deposit_contract_block.txt,config-web3signer.yaml,generation-info.json}
#         and prints CONFIG_PATH=<name> on success.

set -euo pipefail

ENV_NAME=""
VALIDATORS=128
CHAIN_ID=3151909
GENESIS_DELAY=120
MNEMONIC_FILE=""
OUTPUT_BASE="./network-configs"
FRESH_ACCOUNTS=false
DO_PUSH=false
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)           ENV_NAME="$2"; shift 2 ;;
    --validators)    VALIDATORS="$2"; shift 2 ;;
    --chain-id)      CHAIN_ID="$2"; shift 2 ;;
    --genesis-delay) GENESIS_DELAY="$2"; shift 2 ;;
    --mnemonic-file) MNEMONIC_FILE="$2"; shift 2 ;;
    --output-base)   OUTPUT_BASE="$2"; shift 2 ;;
    --fresh-accounts) FRESH_ACCOUNTS=true; shift ;;
    --push)          DO_PUSH=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --help|-h)       head -30 "$0" | tail -n +2 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

[ -z "$ENV_NAME" ] && { log_error "--env <name> is required"; exit 1; }

# Default mnemonic = the shared validator set alongside this script
[ -z "$MNEMONIC_FILE" ] && MNEMONIC_FILE="${SCRIPT_DIR}/mnemonic.txt"
[ -f "$MNEMONIC_FILE" ] || { log_error "mnemonic file not found: $MNEMONIC_FILE"; exit 1; }
MNEMONIC="$(head -1 "$MNEMONIC_FILE" | xargs)"

CONFIG_PATH="${OUTPUT_BASE}/${ENV_NAME}"
METADATA_PATH="${CONFIG_PATH}/metadata"
GENESIS_TIMESTAMP=$(( $(date +%s) + GENESIS_DELAY ))

log_info "==========================================="
log_info "Generate ENV Config: ${ENV_NAME}"
log_info "==========================================="
log_info "  Validators:    ${VALIDATORS}"
log_info "  Chain ID:      ${CHAIN_ID}"
log_info "  Genesis delay: ${GENESIS_DELAY}s  → genesis_time=${GENESIS_TIMESTAMP} ($(date -r "$GENESIS_TIMESTAMP" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$GENESIS_TIMESTAMP"))"
log_info "  Mnemonic:      ${MNEMONIC_FILE} ($(echo "$MNEMONIC" | awk '{print $1, $2, "...", $NF}'))"
log_info "  Output:        ${METADATA_PATH}"
log_info "  Push:          ${DO_PUSH}"

if [ "$DRY_RUN" = true ]; then
  log_warn "DRY RUN — nothing generated"
  echo "CONFIG_PATH=${ENV_NAME}"
  exit 0
fi

mkdir -p "${METADATA_PATH}"
METADATA_ABS="$(cd "${METADATA_PATH}" && pwd)"
WORK_DIR="${CONFIG_PATH}/work"
mkdir -p "${WORK_DIR}"
pushd "${WORK_DIR}" >/dev/null

echo "$MNEMONIC" > mnemonic.txt

# Step 1: accounts. DEFAULT = reuse the COMMITTED scripts/genesis/accounts/ (fixed pre-funded +
# withdrawal 0x57C77A6f...). The withdrawal feeds the validator deposit credentials, so a
# DIFFERENT withdrawal ⇒ a DIFFERENT genesis_validators_root / fork_digest. Reusing the committed
# set keeps this env's identity MATCHED to previews/staging (same as the preview, which auto-
# detects the same accounts/). --fresh-accounts deliberately mints a new, different-identity set.
if [ "$FRESH_ACCOUNTS" = true ]; then
  log_warn "Step 1: minting FRESH accounts (--fresh-accounts) — new withdrawal ⇒ NEW genesis identity"
  bash "${SCRIPT_DIR}/generate-accounts.sh" 30 1000
else
  log_info "Step 1: reusing committed accounts (${SCRIPT_DIR}/accounts, withdrawal 0x57C77A6f...)"
  cp -r "${SCRIPT_DIR}/accounts" ./accounts
fi

# Step 2: genesis (reuses the shared generator)
log_info "Step 2: generating genesis (generate-genesis.sh)..."
bash "${SCRIPT_DIR}/generate-genesis.sh" \
  --validators "$VALIDATORS" \
  --chain-id "$CHAIN_ID" \
  --genesis-delay "$GENESIS_DELAY" \
  --mnemonic-file ./mnemonic.txt \
  --output-dir ./genesis \
  --clean

# Step 3: copy the chart-required files up to metadata/. generate-genesis.sh may leave
# them in ./genesis/ or ./genesis/metadata/ depending on the generator's output nesting.
log_info "Step 3: copying files to ${METADATA_ABS}..."
SRC="genesis"; [ -d "genesis/metadata" ] && SRC="genesis/metadata"
# Copy the FULL generated metadata set (genesis.json/ssz, config.yaml, genesis_validators_root.txt,
# mnemonics.yaml, chainspec.json, deposit_contract*, ... — everything staging carries), not a
# hardcoded shortlist.
find "${SRC}" -maxdepth 1 -type f -exec cp {} "${METADATA_ABS}/" \;
[ -d "genesis/parsed" ] && cp -r "genesis/parsed" "${METADATA_ABS}/" 2>/dev/null
log_info "  copied $(find "${METADATA_ABS}" -maxdepth 1 -type f | wc -l | tr -d ' ') files"
for f in genesis.json genesis.ssz config.yaml; do
  [ -f "${METADATA_ABS}/$f" ] || log_warn "  MISSING critical file: $f"
done
[ -f "${METADATA_ABS}/deposit_contract_block.txt" ] || echo "0" > "${METADATA_ABS}/deposit_contract_block.txt"

# env-info.json (sibling of preview-info.json)
cat > "${METADATA_ABS}/env-info.json" <<EOF
{
  "env": "${ENV_NAME}",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "genesis_timestamp": ${GENESIS_TIMESTAMP},
  "validators": ${VALIDATORS},
  "chain_id": ${CHAIN_ID},
  "config_path": "${ENV_NAME}",
  "mnemonic_hint": "$(echo "$MNEMONIC" | awk '{print $1, $2, "...", $NF}')"
}
EOF

popd >/dev/null
rm -rf "${WORK_DIR}"

log_info "Files in ${METADATA_ABS}:"
ls -la "${METADATA_ABS}" >&2

# Step 4: optional push (same rebase+retry as the preview pipeline)
if [ "$DO_PUSH" = true ]; then
  log_info "Step 4: pushing to origin/main..."
  git add "${CONFIG_PATH}/"
  git commit -m "env config: ${ENV_NAME} (genesis_time ${GENESIS_TIMESTAMP})"
  pushed=""
  for attempt in 1 2 3 4 5; do
    if git push origin main; then pushed=yes; break; fi
    log_warn "push rejected — attempt ${attempt}/5, rebasing on origin/main"
    git fetch -q origin main && git rebase origin/main || git rebase --abort
    sleep $((attempt * 3))
  done
  [ -z "$pushed" ] && { log_error "could not push after 5 attempts"; exit 1; }
  log_info "pushed."
else
  log_warn "Not pushed (--push not set). Config is local only."
fi

log_info "Done. CONFIG_URL (once pushed) = https://raw.githubusercontent.com/mikelear/ethereum-config-chains/main/network-configs/${ENV_NAME}/metadata"
echo "CONFIG_PATH=${ENV_NAME}"
