# solana-test-validator

Solana test validator with fixturenet bootstrap entrypoint.

Builds Agave v3.1.9 from source and layers a custom `entrypoint.sh` that:
- Creates wallets (facilitator, server, client, gateway) from pubkeys or generates new ones
- Airdrops SOL to each wallet
- Creates and mints SPL tokens (USDC-like + M2M)
- Seeds wizard data in laconicd registry
- Writes `.init-complete` sentinel when bootstrap is done

## Usage

```yaml
services:
  solana-test-validator:
    image: ghcr.io/laconicnetwork/solana-test-validator:latest
    environment:
      CLIENT_PUBKEY: ${CLIENT_PUBKEY:-}
      GATEWAY_PUBKEY: ${GATEWAY_PUBKEY:-}
      # ... see entrypoint.sh for all env vars
    volumes:
      - solana-ledger:/ledger
```

## Build

CI builds on push to main and publishes to `ghcr.io/laconicnetwork/solana-test-validator`.

To build locally:
```bash
docker build -t laconicnetwork/solana-test-validator:local .
```
