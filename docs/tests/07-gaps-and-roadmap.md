# 🚧 Gaps & Roadmap

**Section:** [Testing Documentation](./README.md)
**Prev:** [Mutation Checks](./06-mutation-checks.md)

---

## Known Gaps at Phase 3 Close

**The borrow/repay health hook is a stub.** `withdraw(collateral)` calls `_requireBorrowCollateralized` only when the account has debt. In Phase 3 debt cannot exist, so the hook reverts `NotImplementedYet` and is never reached. Those are the five uncovered lines in `LendingMarket.sol`; Phase 4 replaces them with the real capacity math.

**Branch coverage is 78.85% on the market**, below the 95% target. The uncovered branches are predominantly the same Phase 4-7 stubs. The gate applies at Phase 8, not before.

**`MockPriceOracle` is wired but barely exercised.** No path reads a price until borrowing exists, so the mock's staleness and confidence surface has no assertions on it yet. Phase 5 builds the real oracle and its test matrix.

**INV-5 (cash conservation) has no assertion at all.** It needs ghost-variable tracking across a handler comparing `baseToken.balanceOf(market)` against the net of every recorded inflow and outflow. That is invariant-suite work and lands in Phase 8.

**INV-6/7/8 are covered only at the unit level.** Individual supplies and withdrawals assert the ledger, the bitmap, and the cap, but nothing yet asserts the *summed* statements (`totalsCollateral[asset] == sum of userCollateral[*][asset]`) across an adversarial call sequence.

**No integration or fork tests exist yet.** Both directories are empty by design until Phase 8.

---

## Testing Deliverable per Remaining Phase

| Phase | Testing deliverable                                                                                      |
| :---- | :-------------------------------------------------------------------------------------------------------- |
| **4** | Sign-crossing transitions through the single accounting path, capacity boundaries against the mocked oracle, `minBorrow` dust rejection, accrue-before-action enforced on every mutating path, and INV-9 (no allowed action leaves an account undercollateralized). |
| **5** | Oracle pipeline: staleness, confidence, Chainlink deviation, Pyth expo and Chainlink 8-decimal normalization, `updatePriceFeeds` fee and surplus refund, plus fuzz on normalization. |
| **6** | Surplus / exact / shortfall absorptions, multi-collateral absorb, the discount round trip never reducing reserves at stable prices, seize-math fuzz. |
| **7** | Reserve withdrawal bounds, owner/guardian role separation, the constructor revert matrix completed, INV-13 (the absorb coverage condition, which needs `MAX_CONFIDENCE_BPS`). |
| **8** | The invariant suite proper — INV-1 through INV-11 under adversarial sequencing with `fail_on_revert = false` — end-to-end integration on a local deployment, mainnet-fork tests against live Pyth/Chainlink and real USDC/WETH/wBTC, Slither + Aderyn clean, and >95% coverage across all four columns. |

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
