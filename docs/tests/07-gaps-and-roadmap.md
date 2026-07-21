# 🚧 Gaps & Roadmap

**Section:** [Testing Documentation](./README.md)
**Prev:** [Mutation Checks](./06-mutation-checks.md)

---

## Known Gaps at Phase 4 Close

**Underwater positions have no remedy.** An account can now go below the liquidation threshold on a price move alone ([`test_capacity_priceDropCanLeaveAnOpenPositionUncollateralized`](../../test/unit/BorrowRepay.t.sol#L249)), and nothing in the protocol can yet act on it. `absorb` and `buyCollateral` are Phase 6; until then bad debt has no recognition path and `isLiquidatable` is still a reverting stub on the harness.

**Branch coverage is 82.14% on the market**, below the 95% target. The uncovered branches are predominantly the remaining Phase 5-7 stubs. The gate applies at Phase 8, not before.

**One unreachable line.** The fallthrough `revert UnknownAsset` in `_offsetOf` cannot be hit: every caller passes `_requireListed` first. It stays as a defensive guard rather than being removed to buy a coverage point.

**`MockPriceOracle` is exercised only for the values it returns.** Phase 4 reads prices and confidence bands through it, but the mock has no staleness, deviation, or fee behaviour to assert against — it returns whatever was set. The real validation pipeline and its test matrix are Phase 5, and until then no test proves the market rejects a stale or deviant price, only that it uses the price it is given.

**INV-5 (cash conservation) has no assertion at all.** It needs ghost-variable tracking across a handler comparing `baseToken.balanceOf(market)` against the net of every recorded inflow and outflow. That is invariant-suite work and lands in Phase 8.

**INV-6/7/8 are covered only at the unit level.** Individual supplies and withdrawals assert the ledger, the bitmap, and the cap, but nothing yet asserts the *summed* statements (`totalsCollateral[asset] == sum of userCollateral[*][asset]`) across an adversarial call sequence.

**No integration or fork tests exist yet.** Both directories are empty by design until Phase 8.

---

## Testing Deliverable per Remaining Phase

| Phase | Testing deliverable                                                                                      |
| :---- | :-------------------------------------------------------------------------------------------------------- |
| **5** | Oracle pipeline: staleness, confidence, Chainlink deviation, Pyth expo and Chainlink 8-decimal normalization, `updatePriceFeeds` fee and surplus refund, plus fuzz on normalization. |
| **6** | Surplus / exact / shortfall absorptions, multi-collateral absorb, the discount round trip never reducing reserves at stable prices, seize-math fuzz. |
| **7** | Reserve withdrawal bounds, owner/guardian role separation, the constructor revert matrix completed, INV-13 (the absorb coverage condition, which needs `MAX_CONFIDENCE_BPS`). |
| **8** | The invariant suite proper — INV-1 through INV-11 under adversarial sequencing with `fail_on_revert = false` — end-to-end integration on a local deployment, mainnet-fork tests against live Pyth/Chainlink and real USDC/WETH/wBTC, Slither + Aderyn clean, and >95% coverage across all four columns. |

### Shipped

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
