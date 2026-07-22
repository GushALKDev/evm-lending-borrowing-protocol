# 🚧 Gaps & Roadmap

**Section:** [Testing Documentation](./README.md)
**Prev:** [Mutation Checks](./06-mutation-checks.md)

---

## Known Gaps at Phase 6 Close

**Underwater positions are now closable.** `absorb` and `buyCollateral` ship this phase: an account past the liquidation threshold is absorbable permissionlessly in full, bad debt is recognized at absorb time against reserves (which may go negative), and the seized inventory recapitalizes reserves on resale. What remains open is the *sequenced* form — the invariant suite that drives absorb interleaved with the other actions across many accounts is Phase 8.

**`withdrawReserves` is still a reverting harness stub.** It is the last of the Phase 4-7 stubs; Phase 7 fills it in the production contract, alongside the constructor's INV-13 coverage condition.

**Branch coverage is 81.54% on the market**, below the 95% target. The uncovered branches are now predominantly the Phase 7 `withdrawReserves` stub and a few defensive guards. The gate applies at Phase 8, not before. The oracle itself is at 95.45% branch / 98.46% line.

**Two unreachable lines.** The fallthrough `revert UnknownAsset` in `_offsetOf` cannot be hit (every caller passes `_requireListed` first), and the positive-`targetExpo` scale-up branch of `PythChainlinkOracle._scalePyth` for the *confidence* value is unreachable with realistic feeds. Both stay as defensive guards rather than being removed to buy coverage points.

**The oracle is validated against mocks, not live feeds.** Phase 5 proves the pipeline (staleness, confidence, deviation, normalization, fee/refund) against the SDK's `MockPyth` and `MockChainlinkFeed`, where each adversarial state can be produced on demand. What mocks cannot reproduce — real Hermes update data, the real `updatePriceFeeds` fee, expo/decimal normalization against real published values, and real `latestRoundData` heartbeats — is the mainnet-fork suite in Phase 8.

**INV-5 (cash conservation) has no assertion at all.** It needs ghost-variable tracking across a handler comparing `baseToken.balanceOf(market)` against the net of every recorded inflow and outflow. That is invariant-suite work and lands in Phase 8.

**INV-6/7/8 are covered only at the unit level.** Individual supplies and withdrawals assert the ledger, the bitmap, and the cap, but nothing yet asserts the *summed* statements (`totalsCollateral[asset] == sum of userCollateral[*][asset]`) across an adversarial call sequence.

**One integration test exists; fork tests do not yet.** `OracleMarketBorrowTest` wires the real oracle into a real market to prove the payable price path (Phase 5, item 5.8). The full end-to-end lifecycle suite and the mainnet-fork suite are Phase 8.

---

## Testing Deliverable per Remaining Phase

| Phase | Testing deliverable                                                                                      |
| :---- | :-------------------------------------------------------------------------------------------------------- |
| **7** | Reserve withdrawal bounds, owner/guardian role separation, the constructor revert matrix completed, INV-13 (the absorb coverage condition, which needs `MAX_CONFIDENCE_BPS`). |
| **8** | The invariant suite proper — INV-1 through INV-11 under adversarial sequencing with `fail_on_revert = false` — end-to-end integration on a local deployment, mainnet-fork tests against live Pyth/Chainlink and real USDC/WETH/wBTC, Slither + Aderyn clean, and >95% coverage across all four columns. |

### Shipped

**Phase 6** delivered 17 unit and 2 fuzz tests ([inventory](./10-absorb-liquidation.md)) for the two-step liquidation: eligibility at `price + conf`, the surplus/exact/shortfall settlements with explicit bad debt, multi-collateral absorb, the storefront quote, `buyCollateral` gated on the reserve deficit, the `ABSORB`/`BUY` pause flags, and the round-trip reserve bound. The round-trip fuzz pins the correct universal property — proceeds `>= creditBase`, since the shortfall gap to the full debt is the already-recognized bad debt. No invariant-suite INV is closed (those are Phase 8); INV-13's parameterization check is Phase 7.

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
