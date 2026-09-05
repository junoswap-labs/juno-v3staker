#!/usr/bin/env bash
# usage: script/deploy.sh testnet|mainnet
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

# Immutable caps, mirroring the UniswapV3Staker already live on KUB mainnet.
LEAD_TIME=2592000    # 30 days: how far ahead an incentive may be scheduled
MAX_DURATION=63072000 # 2 years: how long one incentive may run

case "${1:-}" in
  testnet)
    RPC=$KUB_TESTNET_RPC; VERIFIER_URL=$KUB_TESTNET_VERIFIER_URL; CHAIN=25925
    FACTORY=0xCBd41F872FD46964bD4Be4d72a8bEBA9D656565b
    POSITION_MANAGER=0x690f45C21744eCC4ac0D897ACAC920889c3cFa4b
    ;;
  mainnet)
    RPC=$KUB_MAINNET_RPC; VERIFIER_URL=$KUB_MAINNET_VERIFIER_URL; CHAIN=96
    FACTORY=0x090C6E5fF29251B1eF9EC31605Bdd13351eA316C
    POSITION_MANAGER=0xb6b76870549893c6b59E7e979F254d0F9Cca4Cc9
    ;;
  *) echo "usage: $0 testnet|mainnet" >&2; exit 1 ;;
esac

: "${PRIVATE_KEY:?}"

forge create contracts/JunoswapV3Staker.sol:JunoswapV3Staker \
  --rpc-url "$RPC" --chain "$CHAIN" --private-key "$PRIVATE_KEY" --broadcast --legacy \
  --verify --verifier blockscout --verifier-url "$VERIFIER_URL" \
  --constructor-args "$FACTORY" "$POSITION_MANAGER" "$LEAD_TIME" "$MAX_DURATION"
