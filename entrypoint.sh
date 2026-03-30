#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------
# Entrypoint for solana-test-validator
#
# On first start:
#   1. Launches test-validator with instant finality
#   2. Creates a USDC-like SPL token mint
#   3. Creates an M2M SPL token mint (user-facing payment token)
#   4. Funds the facilitator, server, client, and gateway wallets
#   5. Creates associated token accounts (ATAs) for all parties
#   6. Mints USDC to the client wallet's ATA
#   7. Mints M2M tokens to the client wallet's ATA
#
# Environment variables:
#   *_PUBKEY            — public key (base58) for FACILITATOR, SERVER, CLIENT, GATEWAY.
#                         If omitted, a keypair is auto-generated and saved to
#                         /ledger/<role>.json for later retrieval.
#   MINT_DECIMALS       — USDC token decimals (default: 6)
#   MINT_AMOUNT         — USDC amount to mint to client (default: 1000000000)
#   M2M_MINT_DECIMALS   — M2M token decimals (default: 6)
#   M2M_MINT_AMOUNT     — M2M amount to mint to client (default: 1000000000)
#   LACONICD_GQL        — laconicd GraphQL endpoint for wizard seed data
#   LEDGER_DIR          — ledger directory (default: /ledger)
# -----------------------------------------------------------------------

LEDGER_DIR="${LEDGER_DIR:-/ledger}"
MINT_DECIMALS="${MINT_DECIMALS:-6}"
MINT_AMOUNT="${MINT_AMOUNT:-1000000000}"
M2M_MINT_DECIMALS="${M2M_MINT_DECIMALS:-6}"
M2M_MINT_AMOUNT="${M2M_MINT_AMOUNT:-1000000000}"
SETUP_MARKER="${LEDGER_DIR}/.setup-done"

# --- Resolve wallet keypairs for all roles ---
# For each role: if *_PUBKEY is set, use it (no keypair stored). If not set,
# generate a fresh keypair, save it to $LEDGER_DIR/<role>.json, and export
# the pubkey. Keypair files can be extracted via `docker cp` for test use.
resolve_wallet() {
  local role="$1"
  local pubkey_var="${role}_PUBKEY"
  local keypair_file="${LEDGER_DIR}/${role,,}.json"

  if [ -f "${keypair_file}" ]; then
    # Already resolved on a previous run
    eval "${pubkey_var}=\$(solana-keygen pubkey '${keypair_file}')"
    export "${pubkey_var?}"
    echo "${role}: reusing ${keypair_file} ($(eval echo \$${pubkey_var}))"
    return
  fi

  if [ -z "${!pubkey_var:-}" ]; then
    # No pubkey provided — generate fresh keypair
    solana-keygen new --no-bip39-passphrase --outfile "${keypair_file}" --force --silent
    eval "${pubkey_var}=\$(solana-keygen pubkey '${keypair_file}')"
    export "${pubkey_var?}"
    echo "${role}: generated fresh keypair ($(eval echo \$${pubkey_var}))"
  else
    echo "${role}: using provided pubkey (${!pubkey_var}) — no keypair file"
  fi
}

for ROLE in FACILITATOR SERVER CLIENT GATEWAY; do
  resolve_wallet "${ROLE}"
done

# Start test-validator in the background
# Gossip panics on 0.0.0.0 in agave 3.1.9, so bind to 127.0.0.1
# and use socat to expose RPC/WS on all interfaces for Docker networking.
solana-test-validator \
  --ledger "${LEDGER_DIR}" \
  --rpc-port 8899 \
  --quiet &

VALIDATOR_PID=$!

# Wait for RPC to become available
echo "Waiting for test-validator RPC..."
for i in $(seq 1 60); do
  if solana cluster-version --url http://127.0.0.1:8899 >/dev/null 2>&1; then
    echo "Test-validator is ready (attempt ${i})"
    break
  fi
  sleep 1
done

solana config set --url http://127.0.0.1:8899

# Only run setup once (idempotent via marker file)
if [ ! -f "${SETUP_MARKER}" ]; then
  echo "Running first-time setup..."

  # Airdrop SOL to all wallets for gas
  for PUBKEY in "${FACILITATOR_PUBKEY:-}" "${SERVER_PUBKEY:-}" "${CLIENT_PUBKEY:-}" "${GATEWAY_PUBKEY:-}"; do
    if [ -n "${PUBKEY}" ]; then
      echo "Airdropping 100 SOL to ${PUBKEY}..."
      solana airdrop 100 "${PUBKEY}" --url http://127.0.0.1:8899 || true
    fi
  done

  # Create a USDC-equivalent SPL token mint
  # We use a generated keypair as the mint authority
  MINT_AUTHORITY_FILE="${LEDGER_DIR}/mint-authority.json"
  if [ ! -f "${MINT_AUTHORITY_FILE}" ]; then
    solana-keygen new --no-bip39-passphrase --outfile "${MINT_AUTHORITY_FILE}" --force
    # Fund the mint authority
    MINT_AUTH_PUBKEY=$(solana-keygen pubkey "${MINT_AUTHORITY_FILE}")
    solana airdrop 10 "${MINT_AUTH_PUBKEY}" --url http://127.0.0.1:8899
  fi

  # Create the token mint
  MINT_ADDRESS_FILE="${LEDGER_DIR}/usdc-mint-address.txt"
  if [ ! -f "${MINT_ADDRESS_FILE}" ]; then
    spl-token create-token \
      --decimals "${MINT_DECIMALS}" \
      --mint-authority "${MINT_AUTHORITY_FILE}" \
      --fee-payer "${MINT_AUTHORITY_FILE}" \
      --url http://127.0.0.1:8899 \
      2>&1 | grep "Creating token" | awk '{print $3}' > "${MINT_ADDRESS_FILE}"
    echo "Created USDC mint: $(cat ${MINT_ADDRESS_FILE})"
  fi

  USDC_MINT=$(cat "${MINT_ADDRESS_FILE}")

  # Create ATAs and mint tokens for the client
  if [ -n "${CLIENT_PUBKEY:-}" ]; then
    echo "Creating ATA for client ${CLIENT_PUBKEY}..."
    spl-token create-account "${USDC_MINT}" \
      --owner "${CLIENT_PUBKEY}" \
      --fee-payer "${MINT_AUTHORITY_FILE}" \
      --url http://127.0.0.1:8899 || true

    echo "Minting ${MINT_AMOUNT} tokens to client..."
    spl-token mint "${USDC_MINT}" "${MINT_AMOUNT}" \
      --recipient-owner "${CLIENT_PUBKEY}" \
      --mint-authority "${MINT_AUTHORITY_FILE}" \
      --fee-payer "${MINT_AUTHORITY_FILE}" \
      --url http://127.0.0.1:8899 || true
  fi

  # Create USDC ATAs for server, facilitator, and gateway (they receive payments)
  for PUBKEY in "${SERVER_PUBKEY:-}" "${FACILITATOR_PUBKEY:-}" "${GATEWAY_PUBKEY:-}"; do
    if [ -n "${PUBKEY}" ]; then
      echo "Creating ATA for ${PUBKEY}..."
      spl-token create-account "${USDC_MINT}" \
        --owner "${PUBKEY}" \
        --fee-payer "${MINT_AUTHORITY_FILE}" \
        --url http://127.0.0.1:8899 || true
    fi
  done

  # Mint USDC to the gateway wallet (it needs tokens to pay backtest via x402)
  if [ -n "${GATEWAY_PUBKEY:-}" ]; then
    echo "Minting ${MINT_AMOUNT} USDC to gateway ${GATEWAY_PUBKEY}..."
    spl-token mint "${USDC_MINT}" "${MINT_AMOUNT}" \
      --recipient-owner "${GATEWAY_PUBKEY}" \
      --mint-authority "${MINT_AUTHORITY_FILE}" \
      --fee-payer "${MINT_AUTHORITY_FILE}" \
      --url http://127.0.0.1:8899 || true
  fi

  # --- M2M token mint (user-facing payment token) ---
  M2M_MINT_ADDRESS_FILE="${LEDGER_DIR}/m2m-mint-address.txt"
  if [ ! -f "${M2M_MINT_ADDRESS_FILE}" ]; then
    spl-token create-token \
      --decimals "${M2M_MINT_DECIMALS}" \
      --mint-authority "${MINT_AUTHORITY_FILE}" \
      --fee-payer "${MINT_AUTHORITY_FILE}" \
      --url http://127.0.0.1:8899 \
      2>&1 | grep "Creating token" | awk '{print $3}' > "${M2M_MINT_ADDRESS_FILE}"
    echo "Created M2M mint: $(cat "${M2M_MINT_ADDRESS_FILE}")"
  fi

  M2M_MINT=$(cat "${M2M_MINT_ADDRESS_FILE}")

  # Create M2M ATAs and mint tokens for the client
  if [ -n "${CLIENT_PUBKEY:-}" ]; then
    echo "Creating M2M ATA for client ${CLIENT_PUBKEY}..."
    spl-token create-account "${M2M_MINT}" \
      --owner "${CLIENT_PUBKEY}" \
      --fee-payer "${MINT_AUTHORITY_FILE}" \
      --url http://127.0.0.1:8899 || true

    echo "Minting ${M2M_MINT_AMOUNT} M2M tokens to client..."
    spl-token mint "${M2M_MINT}" "${M2M_MINT_AMOUNT}" \
      --recipient-owner "${CLIENT_PUBKEY}" \
      --mint-authority "${MINT_AUTHORITY_FILE}" \
      --fee-payer "${MINT_AUTHORITY_FILE}" \
      --url http://127.0.0.1:8899 || true
  fi

  # Create M2M ATA for gateway
  if [ -n "${GATEWAY_PUBKEY:-}" ]; then
    echo "Creating M2M ATA for gateway ${GATEWAY_PUBKEY}..."
    spl-token create-account "${M2M_MINT}" \
      --owner "${GATEWAY_PUBKEY}" \
      --fee-payer "${MINT_AUTHORITY_FILE}" \
      --url http://127.0.0.1:8899 || true
  fi

  # --- Seed wizard profile in laconicd registry ---
  if [ -n "${LACONICD_GQL:-}" ]; then
    echo "Waiting for laconicd GQL at ${LACONICD_GQL}..."
    for i in $(seq 1 120); do
      if curl -sf "${LACONICD_GQL}" \
           -H 'Content-Type: application/json' \
           -d '{"query":"{ __typename }"}' >/dev/null 2>&1; then
        echo "laconicd GQL is ready (attempt ${i})"
        break
      fi
      sleep 2
    done

    WIZARD_WALLET="${CLIENT_PUBKEY:-seed-wizard-wallet}"
    echo "Seeding WizardProfile wiz_seed_001..."
    SEED_RESULT=$(curl -sf "${LACONICD_GQL}" \
      -H 'Content-Type: application/json' \
      -d '{
        "query": "mutation SetRecord($input: SetRecordInput!) { setRecord(input: $input) { id } }",
        "variables": {
          "input": {
            "record": {
              "type": "WizardProfile",
              "attributes": {
                "wizardId": "wiz_seed_001",
                "name": "Seed Wizard",
                "handle": "seed_wizard",
                "bio": "Fixturenet seed wizard for E2E testing",
                "winRate": "72",
                "avgReturn": "15",
                "signalsPerMonth": "8",
                "verified": "true",
                "walletAddress": "'"${WIZARD_WALLET}"'",
                "createdAt": "2024-01-01T00:00:00Z"
              }
            }
          }
        }
      }' 2>&1) || true
    echo "Wizard seed result: ${SEED_RESULT}"
  fi

  touch "${SETUP_MARKER}"
  echo "Setup complete. USDC mint: ${USDC_MINT}, M2M mint: ${M2M_MINT}"
fi

# Write mint addresses to well-known paths for other containers
if [ -f "${LEDGER_DIR}/usdc-mint-address.txt" ]; then
  cp "${LEDGER_DIR}/usdc-mint-address.txt" /tmp/usdc-mint-address.txt
fi
if [ -f "${LEDGER_DIR}/m2m-mint-address.txt" ]; then
  cp "${LEDGER_DIR}/m2m-mint-address.txt" /tmp/m2m-mint-address.txt
fi

# Signal that all mints, airdrops, ATAs, and file writes are done.
# Other containers wait on this file before reading /ledger/ outputs.
touch /ledger/.init-complete
echo "Initialization complete"

# Expose RPC/WS on all interfaces so other Docker containers can reach us.
# The validator only listens on 127.0.0.1 (gossip panics on 0.0.0.0).
socat TCP-LISTEN:18899,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:8899 &
socat TCP-LISTEN:18900,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:8900 &

echo "solana-test-validator running (PID ${VALIDATOR_PID}), socat proxies on :18899/:18900"
wait ${VALIDATOR_PID}
