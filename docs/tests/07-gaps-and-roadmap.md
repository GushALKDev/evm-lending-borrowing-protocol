# 🚧 Gaps & Roadmap

**Section:** [Testing Documentation](./README.md)
**Prev:** [Mutation Checks](./06-mutation-checks.md)

---

## Known Gaps at Phase 5 Close

**Underwater positions have no remedy.** An account can go below the liquidation threshold on a price move alone ([`test_capacity_priceDropCanLeaveAnOpenPositionUncollateralized`](../../test/unit/BorrowRepay.t.sol#L249)), and nothing in the protocol can yet act on it. `absorb` and `buyCollateral` are Phase 6; until then bad debt has no recognition path and `isLiquidatable` is still a reverting stub on the harness.

**Branch coverage is 82.14% on the market**, below the 95% target. The uncovered branches are predominantly the remaining Phase 6-7 stubs. The gate applies at Phase 8, not before. The oracle itself is at 95.45% branch / 98.46% line.

**Two unreachable lines.** The fallthrough `revert UnknownAsset` in `_offsetOf` cannot be hit (every caller passes `_requireListed` first), and the positive-`targetExpo` scale-up branch of `PythChainlinkOracle._scalePyth` for the *confidence* value is unreachable with realistic feeds. Both stay as defensive guards rather than being removed to buy coverage points.

**The oracle is validated against mocks, not live feeds.** Phase 5 proves the pipeline (staleness, confidence, deviation, normalization, fee/refund) against the SDK's `MockPyth` and `MockChainlinkFeed`, where each adversarial state can be produced on demand. What mocks cannot reproduce — real Hermes update data, the real `updatePriceFeeds` fee, expo/decimal normalization against real published values, and real `latestRoundData` heartbeats — is the mainnet-fork suite in Phase 8.

**INV-5 (cash conservation) has no assertion at all.** It needs ghost-variable tracking across a handler comparing `baseToken.balanceOf(market)` against the net of every recorded inflow and outflow. That is invariant-suite work and lands in Phase 8.

**INV-6/7/8 are covered only at the unit level.** Individual supplies and withdrawals assert the ledger, the bitmap, and the cap, but nothing yet asserts the *summed* statements (`totalsCollateral[asset] == sum of userCollateral[*][asset]`) across an adversarial call sequence.

**One integration test exists; fork tests do not yet.** `OracleMarketBorrowTest` wires the real oracle into a real market to prove the payable price path (Phase 5, item 5.8). The full end-to-end lifecycle suite and the mainnet-fork suite are Phase 8.

---

## Testing Deliverable per Remaining Phase

| Phase | Testing deliverable                                                                                      |
| :---- | :-------------------------------------------------------------------------------------------------------- |
| **6** | Surplus / exact / shortfall absorptions, multi-collateral absorb, the discount round trip never reducing reserves at stable prices, seize-math fuzz. |
| **7** | Reserve withdrawal bounds, owner/guardian role separation, the constructor revert matrix completed, INV-13 (the absorb coverage condition, which needs `MAX_CONFIDENCE_BPS`). |
| **8** | The invariant suite proper — INV-1 through INV-11 under adversarial sequencing with `fail_on_revert = false` — end-to-end integration on a local deployment, mainnet-fork tests against live Pyth/Chainlink and real USDC/WETH/wBTC, Slither + Aderyn clean, and >95% coverage across all four columns. |

### Shipped

**Phase 5** delivered 28 unit, 3 fuzz, and 2 integration tests ([inventory](./09-oracle.md)) for `PythChainlinkOracle`: the four-stage validation pipeline, 1e18 normalization from Pyth expo and Chainlink decimals, the fee/refund path against the SDK's real `MockPyth`, the constructor guard matrix, and the market integration. The integration test surfaced a latent Phase 4 bug — the market had no `receive()` for the oracle's per-asset fee refund — now fixed. No new invariant from INV-1..14 is closed: the oracle is validated by its own pipeline, and INV-13 stays Phase 7.

**Phase 4** delivered 37 unit and 6 fuzz tests ([inventory](./08-unit-borrow-repay.md)), closing INV-9 and INV-10 at the single-account level. Both remain open for the multi-account, adversarially-sequenced form in Phase 8: the fuzz properties drive one borrower at a time, so nothing yet asserts that a *sequence* of interleaved actions across many accounts preserves them.

---

## Maintenance

This section is updated at the close of every phase:

1. Re-run `forge test --summary` and `forge coverage --no-match-coverage "test|script"`, and update the tables in the [index](./README.md).
2. Add the new tests to the matching inventory file, with a line-anchored link to the code.
3. Move any newly covered invariant out of ⏳ in the [invariant coverage map](./README.md#-invariant-coverage-map).
4. Move the phase's row out of the table above and record what shipped.

**On the line anchors:** the links in these files point at line numbers, which drift when a test file is edited. Regenerate them with:

```bash
grep -nE "^\s*function (test|testFuzz)" test/unit/*.t.sol test/fuzz/*.t.sol
```
