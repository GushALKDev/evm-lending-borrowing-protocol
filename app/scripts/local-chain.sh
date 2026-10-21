#!/usr/bin/env bash
# Local rehearsal of the testnet deployment: anvil, three mock Chainlink feeds, DeployTestnet, SeedBorrow.
# Writes app/src/config/deployments/31337.json; start the app with VITE_CHAIN_ID=31337.
# Requires Foundry. Run from anywhere: ./app/scripts/local-chain.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC="${RPC:-http://127.0.0.1:8545}"
# anvil's first default account, public test key
KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cd "$ROOT"

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "Starting anvil on $RPC"
  anvil --silent --chain-id 31337 &
  for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
fi

now=$(cast block latest --field timestamp --rpc-url "$RPC")
feed() {
  forge create test/mocks/MockChainlinkFeed.sol:MockChainlinkFeed --rpc-url "$RPC" --private-key "$KEY" \
    --broadcast --constructor-args 8 "$1" "$now" | awk '/Deployed to:/ {print $3}'
}
export USDC_CL_FEED=$(feed 100000000)
export WETH_CL_FEED=$(feed 400000000000)
export WBTC_CL_FEED=$(feed 10000000000000)
echo "Feeds: USDC $USDC_CL_FEED, WETH $WETH_CL_FEED, WBTC $WBTC_CL_FEED"

forge script script/testnet/DeployTestnet.s.sol --rpc-url "$RPC" --private-key "$KEY" --broadcast -q
echo "Wrote app/src/config/deployments/31337.json"
forge script script/testnet/SeedBorrow.s.sol --rpc-url "$RPC" --private-key "$KEY" --broadcast -q
echo "Opened the seed borrow"
