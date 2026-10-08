#!/usr/bin/env bash
# usage: script/verify.sh testnet|mainnet <address>
# Re-runs verification for an already deployed staker (constructor args are rebuilt
# from the same per-network values deploy.sh used).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

NET=${1:?net}; ADDR=${2:?address}
LEAD_TIME=2592000
MAX_DURATION=63072000

case "$NET" in
  testnet)
    VERIFIER_URL=$KUB_TESTNET_VERIFIER_URL; CHAIN=25925
    FACTORY=0xCBd41F872FD46964bD4Be4d72a8bEBA9D656565b
    POSITION_MANAGER=0x690f45C21744eCC4ac0D897ACAC920889c3cFa4b
    ;;
  mainnet)
    VERIFIER_URL=$KUB_MAINNET_VERIFIER_URL; CHAIN=96
    FACTORY=0x090C6E5fF29251B1eF9EC31605Bdd13351eA316C
    POSITION_MANAGER=0xb6b76870549893c6b59E7e979F254d0F9Cca4Cc9
    ;;
  *) echo "usage: $0 testnet|mainnet <address>" >&2; exit 1 ;;
esac

ARGS=$(cast abi-encode "c(address,address,uint256,uint256)" \
  "$FACTORY" "$POSITION_MANAGER" "$LEAD_TIME" "$MAX_DURATION")

forge verify-contract "$ADDR" contracts/JunoswapV3Staker.sol:JunoswapV3Staker \
  --chain "$CHAIN" --verifier blockscout --verifier-url "$VERIFIER_URL" \
  --constructor-args "$ARGS" --watch
