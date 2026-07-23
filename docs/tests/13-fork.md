# Fork Tests (Phase 8)

**Suite:** [`ForkLifecycleTest`](../../test/fork/ForkLifecycle.t.sol) (2 tests) · [fixtures](../../test/fork/fixtures/)
**Covers:** roadmap item 8.7 · [Guide 6, Section 7](../06-security.md#7-testing-plan)
**Config:** Ethereum mainnet fork pinned at block 25595265; runs only when `FORK_RPC_URL` is set

---

> The market run against the **real** external dependencies. A `LendingMarket` is deployed fresh on an Ethereum mainnet fork over real USDC (base) and real WETH (collateral), priced by the real `PythChainlinkOracle` wired to the real Pyth pull oracle and the real Chainlink ETH/USD and USDC/USD aggregators. Everything the unit and integration suites mock — the Pyth read, the Chainlink `latestRoundData`, expo/decimal normalization, the confidence and deviation checks, the tokens themselves — is the genuine article here.

## How prices reach the fork: a cached VAA

The real Pyth contract rejects a price older than its validity window, so a fresh price has to be *pushed* by replaying signed Hermes update data (a VAA) through `updatePriceFeeds`. Rather than fetch that data live at test time (which needs `ffi` and makes the test non-deterministic and CI-fragile), the VAA is fetched once and cached in [`test/fork/fixtures/pyth_usdc_weth.hex`](../../test/fork/fixtures/pyth_usdc_weth.hex); the test replays it against the real Pyth. `ffi` stays off.

The cached VAA carries **both** feeds (USDC/USD and ETH/USD) at one shared `publishTime`. That shared timestamp is the point: each market operation reads base *and* collateral, and a single `block.timestamp` cannot satisfy the reference 60s staleness window for two feeds with different publish times. One combined update, one `vm.warp` to that publish time, and both prices are fresh together. The VAA still verifies against the Wormhole guardian set at the pinned block, and the real fee/refund path runs (`getUpdateFee`, the surplus refund), so this is the real push, not a mock.

## Tests

| Test | What it proves |
| :--- | :------------- |
| [`test_fork_realOraclePricesBothAssets`](../../test/fork/ForkLifecycle.t.sol) | The real oracle prices USDC (~$1) and WETH (~$1,900s) through the full validation pipeline — real Pyth read, real Chainlink anchor, expo/decimal normalization to 1e18, confidence and deviation checks — without reverting |
| [`test_fork_supplyBorrowAccrueRepay`](../../test/fork/ForkLifecycle.t.sol) | The full accounting lifecycle against real prices: an LP supplies real USDC, a borrower posts real WETH and borrows, 30 days of interest accrues (debt grows), and the debt is repaid to zero. The market ends holding no ETH (the oracle refunded the fee surplus) |

## What is deliberately out of scope, and why

**absorb and buyCollateral do not run on the fork.** With real, fixed fork prices the only lever to drive an account underwater is interest accrual over time — but warping forward makes the cached VAA stale (its `publishTime` is fixed and cannot be refetched for a future block), and the constructor forbids `borrowCF >= liquidateCF`, so an account cannot be borrowed straight into liquidation either. buyCollateral in turn needs the seized inventory that only an absorb produces. Both paths are covered exhaustively at unit ([Absorb Liquidation](./10-absorb-liquidation.md)), fuzz, and invariant level against controlled prices, where forcing a price move is trivial. The fork test targets the paths where a *real* price is load-bearing: the validation pipeline, borrow capacity, and accrual.

**wBTC was dropped.** Its Pyth feed on the fork is chronically stale (the feed is thinly updated), so its cached price deviates from the live Chainlink BTC/USD anchor by more than the reference 300 bps and the real deviation check rejects it. USDC + WETH is the pair whose real Pyth and Chainlink prices actually agree at the pinned block. This is itself a finding the fork test surfaces: not every listed-looking feed is fresh enough to price against.

## Running

The suite reads `FORK_RPC_URL` from the environment (an Ethereum mainnet RPC). When it is unset — as in CI — every test returns early as a green no-op, so the fork tests never break a run that lacks an RPC. To run them:

```bash
FORK_RPC_URL=<eth-mainnet-rpc> forge test --match-path "test/fork/*"
```

If the pinned block is changed, refresh the cached VAA per [the fixtures README](../../test/fork/fixtures/README.md).
