# Fork test fixtures

Cached Pyth Hermes update data (VAA) replayed by [`ForkLifecycle.t.sol`](../ForkLifecycle.t.sol)
against the real mainnet Pyth contract on a pinned fork. Caching the VAA keeps the fork test
deterministic and CI-stable: no live Hermes fetch at run time, so `ffi` stays off.

## `pyth_usdc_weth.hex`

A single hex-encoded VAA covering **both** the USDC/USD and ETH/USD feeds at one shared
`publishTime`, so the market's base + collateral prices can be pushed fresh together (a single
`block.timestamp` cannot satisfy the 60s staleness window for two feeds with different publish
times, which is why one combined update is used).

| Field | Value |
| :---- | :---- |
| Source | `https://hermes.pyth.network/v2/updates/price/latest?ids[]=<usdc>&ids[]=<weth>&encoding=hex` |
| Fork block | 25595265 (Ethereum mainnet) |
| USDC/USD | price `99990999`, conf `50901`, expo `-8`, publishTime `1784807706` |
| ETH/USD  | price `192473207776`, conf `67147635`, expo `-8`, publishTime `1784807706` |
| Feed IDs | USDC `0xeaa020c6…c94a`, ETH `0xff61491a…0ace` |

## Refreshing

If the pinned block changes, refetch the VAA at (or near) that block's timestamp and overwrite the
file with the `binary.data[0]` hex, `0x`-prefixed. The VAA must verify against the Wormhole guardian
set active at the fork block, so it should be dated close to that block.
