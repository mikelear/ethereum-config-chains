#!/bin/bash
# generate-genesis.sh - Generate Ethereum genesis files for private testnet
#
# This script generates genesis.json (EL) and genesis.ssz (CL) files
# using the ethpandaops/ethereum-genesis-generator Docker image.
#
# Can run in two modes:
#   1. Outside container: Uses docker run to invoke the generator
#   2. Inside container: Calls /work/entrypoint.sh directly (auto-detected)
#
# Designed to run from a working directory with:
#   ./accounts/withdrawal_account.txt
#   ./accounts/genesis_alloc.json
#   ./validator_keys/ (optional, for mnemonic reference)
#
# Usage: ./generate-genesis.sh [OPTIONS]
#
# Options:
#   --validators NUM       Number of validators (default: $NUM_VALIDATORS or 128)
#   --chain-id ID          Chain ID (default: $CHAIN_ID or 3151909)
#   --genesis-delay SEC    Seconds from now for genesis time (default: 300)
#   --mnemonic "WORDS"     BIP39 mnemonic for validator keys
#   --mnemonic-file FILE   Read mnemonic from file (one line, just the words)
#   --withdrawal-address   Address for validator withdrawals (auto-detects from accounts/)
#   --premine-file FILE    Pre-funded accounts JSON (auto-detects from accounts/)
#   --output-dir DIR       Output directory (default: ./genesis)
#   --clean                Remove existing output before generating
#   --test                 Run local validation tests after generation
#   --inside-container     Force inside-container mode (skip auto-detection)
#   --outside-container    Force docker mode (skip auto-detection)
#
# Mnemonic resolution order:
#   1. --mnemonic "words"          (explicit command line)
#   2. --mnemonic-file FILE        (explicit file path)
#   3. Auto-detect ./mnemonic.txt  (if file exists)
#   4. $MNEMONIC env variable      (from config.env or shell)
#   5. Default test mnemonic       (test test ... test junk)
#
# Environment variables (from config.env):
#   NUM_VALIDATORS, CHAIN_ID, MNEMONIC, WITHDRAWAL_ADDRESS

set -euo pipefail

# Defaults - use environment variables if set, otherwise use defaults
VALIDATORS=${NUM_VALIDATORS:-128}
CHAIN_ID=${CHAIN_ID:-3151909}
GENESIS_DELAY=${GENESIS_DELAY:-300}
MNEMONIC=${MNEMONIC:-""}
MNEMONIC_FILE=""
MNEMONIC_FROM_CLI=false
WITHDRAWAL_ADDRESS=${WITHDRAWAL_ADDRESS:-""}
DEPOSIT_CONTRACT=${DEPOSIT_CONTRACT_ADDRESS:-"0x00000000219ab540356cBB839Cbe05303d7705Fa"}

# Paths relative to current working directory
OUTPUT_DIR="./genesis"
PREMINE_FILE=""

# Fork versions
GENESIS_FORK_VERSION=${GENESIS_FORK_VERSION:-"0x10000038"}
ALTAIR_FORK_EPOCH=${ALTAIR_FORK_EPOCH:-0}
BELLATRIX_FORK_EPOCH=${BELLATRIX_FORK_EPOCH:-0}
CAPELLA_FORK_EPOCH=${CAPELLA_FORK_EPOCH:-0}
DENEB_FORK_EPOCH=${DENEB_FORK_EPOCH:-0}
ELECTRA_FORK_EPOCH=${ELECTRA_FORK_EPOCH:-1}
FULU_FORK_EPOCH=${FULU_FORK_EPOCH:-18446744073709551615}

# Flags
CLEAN=false
TEST=false
FORCE_INSIDE_CONTAINER=false
FORCE_OUTSIDE_CONTAINER=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --validators)
            VALIDATORS="$2"
            shift 2
            ;;
        --chain-id)
            CHAIN_ID="$2"
            shift 2
            ;;
        --genesis-delay)
            GENESIS_DELAY="$2"
            shift 2
            ;;
        --mnemonic)
            MNEMONIC="$2"
            MNEMONIC_FROM_CLI=true
            shift 2
            ;;
        --mnemonic-file)
            MNEMONIC_FILE="$2"
            shift 2
            ;;
        --withdrawal-address)
            WITHDRAWAL_ADDRESS="$2"
            shift 2
            ;;
        --premine-file)
            PREMINE_FILE="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --test)
            TEST=true
            shift
            ;;
        --inside-container)
            FORCE_INSIDE_CONTAINER=true
            shift
            ;;
        --outside-container)
            FORCE_OUTSIDE_CONTAINER=true
            shift
            ;;
        --help|-h)
            head -35 "$0" | tail -n +2 | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Detect if running inside the ethereum-genesis-generator container
# Check for /work/entrypoint.sh which exists in the ethpandaops container
INSIDE_CONTAINER=false
if [ "$FORCE_INSIDE_CONTAINER" = true ]; then
    INSIDE_CONTAINER=true
    log_info "Forced inside-container mode"
elif [ "$FORCE_OUTSIDE_CONTAINER" = true ]; then
    INSIDE_CONTAINER=false
    log_info "Forced docker mode"
elif [ -f "/work/entrypoint.sh" ]; then
    INSIDE_CONTAINER=true
    log_info "Detected running inside ethereum-genesis-generator container"
elif ! command -v docker &> /dev/null; then
    log_error "Docker not found and not running inside genesis container"
    log_error "Either install Docker or run inside the ethpandaops/ethereum-genesis-generator container"
    exit 1
fi

# Auto-detect withdrawal address from accounts directory
if [ -z "$WITHDRAWAL_ADDRESS" ] && [ -f "./accounts/withdrawal_account.txt" ]; then
    WITHDRAWAL_ADDRESS=$(grep "Address:" ./accounts/withdrawal_account.txt | awk '{print $2}')
    log_info "Auto-detected withdrawal address from ./accounts/withdrawal_account.txt"
fi

# Auto-detect premine file from accounts directory
if [ -z "$PREMINE_FILE" ] && [ -f "./accounts/genesis_alloc.json" ]; then
    PREMINE_FILE="./accounts/genesis_alloc.json"
    log_info "Auto-detected premine file from ./accounts/genesis_alloc.json"
fi

# Validate required inputs
if [ -z "$WITHDRAWAL_ADDRESS" ]; then
    log_error "Withdrawal address required. Either:"
    echo "  1. Run Step 1 first to create ./accounts/withdrawal_account.txt"
    echo "  2. Pass --withdrawal-address 0x..."
    exit 1
fi

# Resolve mnemonic: --mnemonic > --mnemonic-file > ./mnemonic.txt > $MNEMONIC env > default
if [ "$MNEMONIC_FROM_CLI" = true ]; then
    log_info "Using mnemonic from --mnemonic argument"
elif [ -n "$MNEMONIC_FILE" ]; then
    if [ ! -f "$MNEMONIC_FILE" ]; then
        log_error "Mnemonic file not found: $MNEMONIC_FILE"
        exit 1
    fi
    MNEMONIC=$(head -1 "$MNEMONIC_FILE" | xargs)
    log_info "Loaded mnemonic from file: $MNEMONIC_FILE"
elif [ -f "./mnemonic.txt" ]; then
    MNEMONIC=$(head -1 "./mnemonic.txt" | xargs)
    log_info "Auto-detected mnemonic from ./mnemonic.txt"
elif [ -n "$MNEMONIC" ]; then
    log_info "Using mnemonic from \$MNEMONIC environment variable"
else
    log_warn "No mnemonic provided. Using default test mnemonic."
    log_warn "For production, create ./mnemonic.txt or pass --mnemonic-file FILE"
    MNEMONIC="test test test test test test test test test test test junk"
fi

if [ -z "$MNEMONIC" ]; then
    log_error "Mnemonic is empty. Check your mnemonic file or argument."
    exit 1
fi

echo ""
log_info "Genesis Generator for Ethereum Private Testnet"
log_info "=============================================="
echo ""
log_info "Configuration:"
echo "  Validators:          $VALIDATORS"
echo "  Chain ID:            $CHAIN_ID"
echo "  Genesis Delay:       ${GENESIS_DELAY}s from now"
echo -e "  Withdrawal Address:  ${BLUE}$WITHDRAWAL_ADDRESS${NC}"
echo "  Deposit Contract:    $DEPOSIT_CONTRACT"
echo -e "  Output Directory:    ${BLUE}$OUTPUT_DIR${NC}"
echo ""

# Load premine addresses from file
PREMINE_ADDRS="{}"
if [ -n "$PREMINE_FILE" ] && [ -f "$PREMINE_FILE" ]; then
    log_info "Loading pre-funded accounts from: $PREMINE_FILE"
    PREMINE_ADDRS=$(cat "$PREMINE_FILE")
    PREMINE_COUNT=$(echo "$PREMINE_ADDRS" | jq 'keys | length')
    echo "  Pre-funded accounts: $PREMINE_COUNT"
    echo ""
fi

# Clean if requested
if [ "$CLEAN" = true ]; then
    log_warn "Cleaning existing output directory..."
    rm -rf "$OUTPUT_DIR"
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Calculate genesis timestamp
GENESIS_TIMESTAMP=$(($(date +%s) + GENESIS_DELAY))
GENESIS_DATE=$(date -r "$GENESIS_TIMESTAMP" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || date -d "@$GENESIS_TIMESTAMP" "+%Y-%m-%d %H:%M:%S UTC")

log_info "Genesis timestamp: $GENESIS_TIMESTAMP ($GENESIS_DATE)"
echo ""

# Get absolute path for Docker mount (only needed for docker mode)
OUTPUT_DIR_ABS=$(cd "$OUTPUT_DIR" && pwd)

# Generate genesis files
log_info "Running ethereum-genesis-generator..."

if [ "$INSIDE_CONTAINER" = true ]; then
    # Running inside the container - export env vars and call entrypoint directly
    log_info "Using inside-container mode - calling /work/entrypoint.sh directly"

    export EL_AND_CL_MNEMONIC="$MNEMONIC"
    export NUMBER_OF_VALIDATORS="$VALIDATORS"
    export GENESIS_TIMESTAMP="$GENESIS_TIMESTAMP"
    export GENESIS_DELAY=0
    export WITHDRAWAL_ADDRESS="$WITHDRAWAL_ADDRESS"
    export CHAIN_ID="$CHAIN_ID"
    export DEPOSIT_CONTRACT_ADDRESS="$DEPOSIT_CONTRACT"
    export GENESIS_FORK_VERSION="$GENESIS_FORK_VERSION"
    export ALTAIR_FORK_EPOCH="$ALTAIR_FORK_EPOCH"
    export BELLATRIX_FORK_EPOCH="$BELLATRIX_FORK_EPOCH"
    export CAPELLA_FORK_EPOCH="$CAPELLA_FORK_EPOCH"
    export DENEB_FORK_EPOCH="$DENEB_FORK_EPOCH"
    export ELECTRA_FORK_EPOCH="$ELECTRA_FORK_EPOCH"
    export FULU_FORK_EPOCH="$FULU_FORK_EPOCH"
    export EL_PREMINE_ADDRS="$PREMINE_ADDRS"

    # The entrypoint outputs to /data by default
    # We need to ensure output goes to our desired location
    ORIGINAL_PWD=$(pwd)
    cd /work
    /work/entrypoint.sh all
    cd "$ORIGINAL_PWD"

    # Copy generated files from /data to our output directory
    log_info "Copying generated files from /data to $OUTPUT_DIR_ABS"
    if [ -d "/data/metadata" ]; then
        cp -r /data/metadata/* "$OUTPUT_DIR_ABS/" 2>/dev/null || true
    fi
    if [ -d "/data/custom_config_data" ]; then
        cp -r /data/custom_config_data/* "$OUTPUT_DIR_ABS/" 2>/dev/null || true
    fi
    if [ -d "/data/parsed" ]; then
        cp -r /data/parsed "$OUTPUT_DIR_ABS/" 2>/dev/null || true
    fi
    # Copy any top-level files
    for f in genesis.json genesis.ssz config.yaml deposit_contract_block.txt; do
        [ -f "/data/$f" ] && cp "/data/$f" "$OUTPUT_DIR_ABS/" 2>/dev/null || true
    done
else
    # Running outside container - use docker
    log_info "Using docker mode"
    docker run --rm \
        -v "$OUTPUT_DIR_ABS:/data" \
        -e EL_AND_CL_MNEMONIC="$MNEMONIC" \
        -e NUMBER_OF_VALIDATORS="$VALIDATORS" \
        -e GENESIS_TIMESTAMP="$GENESIS_TIMESTAMP" \
        -e GENESIS_DELAY=0 \
        -e WITHDRAWAL_ADDRESS="$WITHDRAWAL_ADDRESS" \
        -e CHAIN_ID="$CHAIN_ID" \
        -e DEPOSIT_CONTRACT_ADDRESS="$DEPOSIT_CONTRACT" \
        -e GENESIS_FORK_VERSION="$GENESIS_FORK_VERSION" \
        -e ALTAIR_FORK_EPOCH="$ALTAIR_FORK_EPOCH" \
        -e BELLATRIX_FORK_EPOCH="$BELLATRIX_FORK_EPOCH" \
        -e CAPELLA_FORK_EPOCH="$CAPELLA_FORK_EPOCH" \
        -e DENEB_FORK_EPOCH="$DENEB_FORK_EPOCH" \
        -e ELECTRA_FORK_EPOCH="$ELECTRA_FORK_EPOCH" \
        -e FULU_FORK_EPOCH="$FULU_FORK_EPOCH" \
        -e EL_PREMINE_ADDRS="$PREMINE_ADDRS" \
        ethpandaops/ethereum-genesis-generator:master all
fi

echo ""
log_info "Generation complete!"
echo ""

# Move files from nested structure to output dir
if [ -d "$OUTPUT_DIR/metadata" ]; then
    log_info "Moving files from metadata/ to $OUTPUT_DIR/"
    mv "$OUTPUT_DIR/metadata"/* "$OUTPUT_DIR/" 2>/dev/null || true
    rmdir "$OUTPUT_DIR/metadata" 2>/dev/null || true
fi

# Extract and display validator public keys
PARSED_GENESIS="$OUTPUT_DIR/parsed/parsedConsensusGenesis.json"
log_info "Validator public keys (first 5 and last 5):"
if [ -f "$PARSED_GENESIS" ]; then
    TOTAL_KEYS=$(jq -r '.validators | length' "$PARSED_GENESIS")
    # Use jq slicing to avoid SIGPIPE from head/tail with pipefail
    jq -r '.validators[0:5][].pubkey' "$PARSED_GENESIS" | nl -v 0
    echo "  ..."
    jq -r '.validators[-5:][].pubkey' "$PARSED_GENESIS" | nl -v $((TOTAL_KEYS - 5))
    echo ""
    echo "  Total validators: $TOTAL_KEYS"
else
    log_warn "Could not find parsed genesis JSON at $PARSED_GENESIS"
fi

echo ""
log_info "Generated files in $OUTPUT_DIR/:"
ls -la "$OUTPUT_DIR/"

# Generate Web3Signer compatible config (whitelist only known working fields)
if [ -f "$OUTPUT_DIR/config.yaml" ]; then
    log_info "Creating config-web3signer.yaml (stripped for Web3Signer compatibility)..."
    cat > "$OUTPUT_DIR/config-web3signer.yaml" << 'HEADER'
# Web3Signer compatible config
# Derived from config.yaml - only includes fields web3signer can parse
#
# Stripped fields:
# - BLOB_SCHEDULE (array format not supported)
# - Future forks: FULU, GLOAS, EIP7441, EIP7805, EIP7928
# - Electra-specific networking params
# - Various timing BPS params

HEADER
    # Whitelist of fields known to work with Web3Signer 24.12.0
    # Based on working config from ethereum-config-chains repo
    grep -E '^(PRESET_BASE|CONFIG_NAME|TERMINAL_TOTAL_DIFFICULTY|TERMINAL_BLOCK_HASH|TERMINAL_BLOCK_HASH_ACTIVATION_EPOCH|MIN_GENESIS_ACTIVE_VALIDATOR_COUNT|MIN_GENESIS_TIME|GENESIS_FORK_VERSION|GENESIS_DELAY|ALTAIR_FORK_VERSION|ALTAIR_FORK_EPOCH|BELLATRIX_FORK_VERSION|BELLATRIX_FORK_EPOCH|CAPELLA_FORK_VERSION|CAPELLA_FORK_EPOCH|DENEB_FORK_VERSION|DENEB_FORK_EPOCH|ELECTRA_FORK_VERSION|ELECTRA_FORK_EPOCH|SECONDS_PER_SLOT|SECONDS_PER_ETH1_BLOCK|MIN_VALIDATOR_WITHDRAWABILITY_DELAY|SHARD_COMMITTEE_PERIOD|ETH1_FOLLOW_DISTANCE|INACTIVITY_SCORE_BIAS|INACTIVITY_SCORE_RECOVERY_RATE|EJECTION_BALANCE|MIN_PER_EPOCH_CHURN_LIMIT|CHURN_LIMIT_QUOTIENT|MAX_PER_EPOCH_ACTIVATION_CHURN_LIMIT|MIN_PER_EPOCH_CHURN_LIMIT_ELECTRA|MAX_PER_EPOCH_ACTIVATION_EXIT_CHURN_LIMIT|PROPOSER_SCORE_BOOST|REORG_HEAD_WEIGHT_THRESHOLD|REORG_PARENT_WEIGHT_THRESHOLD|REORG_MAX_EPOCHS_SINCE_FINALIZATION|DEPOSIT_CHAIN_ID|DEPOSIT_NETWORK_ID|DEPOSIT_CONTRACT_ADDRESS|GOSSIP_MAX_SIZE|MAX_REQUEST_BLOCKS|EPOCHS_PER_SUBNET_SUBSCRIPTION|MIN_EPOCHS_FOR_BLOCK_REQUESTS|MAX_CHUNK_SIZE|TTFB_TIMEOUT|RESP_TIMEOUT|ATTESTATION_PROPAGATION_SLOT_RANGE|MAXIMUM_GOSSIP_CLOCK_DISPARITY|MESSAGE_DOMAIN_INVALID_SNAPPY|MESSAGE_DOMAIN_VALID_SNAPPY|SUBNETS_PER_NODE|ATTESTATION_SUBNET_COUNT|ATTESTATION_SUBNET_EXTRA_BITS|ATTESTATION_SUBNET_PREFIX_BITS|MAX_REQUEST_BLOCKS_DENEB|MIN_EPOCHS_FOR_BLOB_SIDECARS_REQUESTS|BLOB_SIDECAR_SUBNET_COUNT|MAX_BLOBS_PER_BLOCK|MAX_REQUEST_BLOB_SIDECARS):' "$OUTPUT_DIR/config.yaml" >> "$OUTPUT_DIR/config-web3signer.yaml"

    # Add standard networking fields if not present (newer generators may omit these)
    if ! grep -q '^GOSSIP_MAX_SIZE:' "$OUTPUT_DIR/config-web3signer.yaml"; then
        echo "" >> "$OUTPUT_DIR/config-web3signer.yaml"
        echo "# Networking (added - not in newer generator output)" >> "$OUTPUT_DIR/config-web3signer.yaml"
        echo "GOSSIP_MAX_SIZE: 10485760" >> "$OUTPUT_DIR/config-web3signer.yaml"
        echo "MAX_CHUNK_SIZE: 10485760" >> "$OUTPUT_DIR/config-web3signer.yaml"
        echo "TTFB_TIMEOUT: 5" >> "$OUTPUT_DIR/config-web3signer.yaml"
        echo "RESP_TIMEOUT: 10" >> "$OUTPUT_DIR/config-web3signer.yaml"
    fi

    # Add attestation subnet fields required by web3signer 24.12.0 (newer generators omit these)
    if ! grep -q '^ATTESTATION_SUBNET_PREFIX_BITS:' "$OUTPUT_DIR/config-web3signer.yaml"; then
        echo "" >> "$OUTPUT_DIR/config-web3signer.yaml"
        echo "# Attestation subnet fields (added - required by web3signer 24.12.0)" >> "$OUTPUT_DIR/config-web3signer.yaml"
        echo "ATTESTATION_SUBNET_PREFIX_BITS: 6" >> "$OUTPUT_DIR/config-web3signer.yaml"
    fi
    if ! grep -q '^MIN_EPOCHS_FOR_BLOCK_REQUESTS:' "$OUTPUT_DIR/config-web3signer.yaml"; then
        echo "MIN_EPOCHS_FOR_BLOCK_REQUESTS: 33024" >> "$OUTPUT_DIR/config-web3signer.yaml"
    fi
fi

# Save generation metadata
cat > "$OUTPUT_DIR/generation-info.json" << EOF
{
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "genesis_timestamp": $GENESIS_TIMESTAMP,
    "genesis_date": "$GENESIS_DATE",
    "validators": $VALIDATORS,
    "chain_id": $CHAIN_ID,
    "withdrawal_address": "$WITHDRAWAL_ADDRESS",
    "deposit_contract": "$DEPOSIT_CONTRACT",
    "mnemonic_hint": "$(echo "$MNEMONIC" | awk '{print $1, $2, "...", $(NF-1), $NF}')",
    "premine_file": "$PREMINE_FILE",
    "fork_epochs": {
        "altair": $ALTAIR_FORK_EPOCH,
        "bellatrix": $BELLATRIX_FORK_EPOCH,
        "capella": $CAPELLA_FORK_EPOCH,
        "deneb": $DENEB_FORK_EPOCH,
        "electra": $ELECTRA_FORK_EPOCH,
        "fulu": $FULU_FORK_EPOCH
    }
}
EOF
log_info "Saved generation metadata to $OUTPUT_DIR/generation-info.json"

# Run tests if requested
if [ "$TEST" = true ]; then
    echo ""
    if [ "$INSIDE_CONTAINER" = true ]; then
        log_warn "Skipping validation tests - not available in inside-container mode"
        log_info "Tests require Docker which is not available inside the generator container"
    else
        log_info "Running validation tests..."

        TEST_DIR="./test-data"
        mkdir -p "$TEST_DIR/geth" "$TEST_DIR/lighthouse" "$TEST_DIR/prysm"

        # Test with Geth
        log_info "Testing with Geth..."
        rm -rf "$TEST_DIR/geth"/*
        if docker run --rm \
            -v "$OUTPUT_DIR_ABS:/genesis:ro" \
            -v "$(pwd)/$TEST_DIR/geth:/data" \
            ethereum/client-go:v1.14.12 \
            init --datadir /data /genesis/genesis.json 2>&1 | grep -q "Successfully wrote genesis state"; then
            log_info "  Geth: PASSED"
        else
            log_error "  Geth: FAILED"
        fi

        # Test with Lighthouse
        log_info "Testing with Lighthouse..."
        rm -rf "$TEST_DIR/lighthouse"/*
        if timeout 15 docker run --rm \
            -v "$OUTPUT_DIR_ABS:/testnet:ro" \
            -v "$(pwd)/$TEST_DIR/lighthouse:/data" \
            sigp/lighthouse:latest \
            lighthouse beacon_node \
            --testnet-dir /testnet \
            --datadir /data \
            --disable-enr-auto-update \
            --execution-endpoint http://localhost:8551 \
            --execution-jwt-secret-key 0000000000000000000000000000000000000000000000000000000000000001 \
            --http 2>&1 | grep -q "Beacon chain initialized"; then
            log_info "  Lighthouse: PASSED"
        else
            log_error "  Lighthouse: FAILED (or timed out)"
        fi

        echo ""
    fi
fi

echo ""
log_info "Done! Genesis files are in: $OUTPUT_DIR/"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}Next steps:${NC}"
echo ""
echo -e "${YELLOW}Copy to config repo:${NC}"
echo "  mkdir -p \$ETHEREUM_CONFIG_CHAINS/\$NETWORK_DIR/metadata"
echo "  cp $OUTPUT_DIR/* \$ETHEREUM_CONFIG_CHAINS/\$NETWORK_DIR/metadata/"
echo ""
echo -e "${YELLOW}Commit and push:${NC}"
echo "  cd \$ETHEREUM_CONFIG_CHAINS"
echo "  git add . && git commit -m \"Add genesis files\" && git push"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
