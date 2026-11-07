#!/usr/bin/env bash
# One-shot: deploy WheelSwap to Sepolia, verify on Sourcify, print address + block.
# Usage: KEYFILE=path/to/deployer.key ./script/deploy_sepolia.sh   (hex private key, with or without 0x)
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
KEYFILE="${KEYFILE:-deployer.key}"
K=$(tr -d '[:space:]' < "$KEYFILE"); case "$K" in 0x*) ;; *) K="0x$K";; esac

CORE=0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4
SQK=0xd78a3956cF63164d1Fa1C622ad3c66623162Fa1e

DEPLOYER=$(cast wallet address --private-key "$K")
echo "== deployer $DEPLOYER balance $(cast balance "$DEPLOYER" --rpc-url "$RPC" --ether) ETH"

# Sepolia runs Glamsterdam: state-creation repricing makes code deposit ~1.5k gas/byte, so this
# ~8 KB contract needs ~13M gas. Foundry's local EVM still estimates ~2.5M and a plain
# `forge script --broadcast` runs out of gas; ask the node and send with an explicit limit
# (must stay under the 16.7M per-transaction cap).
forge build --silent
ARGS=$(cast abi-encode "constructor(address,address)" $CORE $SQK)
INIT=$(forge inspect src/WheelSwap.sol:WheelSwap bytecode)$(echo "$ARGS" | cut -c3-)
EST=$(cast estimate --rpc-url "$RPC" --from "$DEPLOYER" --create "$INIT")
GAS=$(( EST + EST / 10 ))
echo "== node estimate $EST gas, sending with limit $GAS"
TXH=$(cast send --rpc-url "$RPC" --private-key "$K" --gas-limit "$GAS" --create "$INIT" --json \
  | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['status'] in ('0x1',1,'1'),r;print(r['transactionHash'])")
ADDR=$(cast receipt "$TXH" contractAddress --rpc-url "$RPC")
BLK=$(cast receipt "$TXH" blockNumber --rpc-url "$RPC")
echo "== WheelSwap $ADDR  tx $TXH  block $BLK  gasUsed $(cast receipt "$TXH" gasUsed --rpc-url "$RPC")"

echo "== verifying on Sourcify"
unset ETHERSCAN_API_KEY
forge verify-contract "$ADDR" src/WheelSwap.sol:WheelSwap --chain sepolia --verifier sourcify --constructor-args "$ARGS" 2>&1 | tail -4 || true

mkdir -p broadcast
printf '%s\n%s\n%s\n' "$ADDR" "$TXH" "$BLK" > broadcast/sepolia_deploy.txt
echo "== done: $ADDR @ $BLK"
