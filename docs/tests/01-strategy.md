# 🎯 Testing Strategy

**Section:** [Testing Documentation](./README.md)
**Next:** [Unit: Accounting](./02-unit-accounting.md)

---

## 1. Layers

The suite is layered, and each layer answers a different question.

| Layer           | Directory           | Question it answers                                            | Status                  |
| :-------------- | :------------------ | :------------------------------------------------------------- | :---------------------- |
| **Unit**        | `test/unit/`        | Does this function do exactly what its contract says?          | ✅ Phases 1-3           |
| **Fuzz**        | `test/fuzz/`        | Does the property hold for every input in the domain?          | ✅ Phases 1-2           |
| **Invariant**   | `test/invariant/`   | Do the system invariants survive adversarial call sequencing?  | ⏳ Phase 8              |
| **Integration** | `test/integration/` | Does the full lifecycle work end to end on a local deployment? | ⏳ Phase 8              |
| **Fork**        | `test/fork/`        | Do the real external dependencies behave as assumed?           | ⏳ Phase 8              |

---

## 2. Principles

**Assert directions, not magnitudes.** Rounding tests never assert "the dust is small". They assert which way the division rounds, because a bounded-dust assertion passes just as happily on a flipped rounding direction ([Guide 2, Section 10](../02-mathematics.md#10-rounding-policy)). Magnitude is asserted only where the magnitude itself is the claim, as in the [index-scale analysis](./05-fuzz.md#3-indexprecisiontsol--4-tests).

**Round trips are necessary but not sufficient.** A flipped `presentValueSupply` partially cancels against `principalValueSupply`'s floor and can survive a round-trip assertion. Every rounding site therefore also has an exact-value fuzz test pinning that single division against a locally computed expectation. This is not hypothetical: see [Mutation Checks](./06-mutation-checks.md).

**Test the reachable domain; document the rest.** The protocol does not defend against states its types and invariants forbid. Where a theoretical failure boundary exists (index overflow, `fullMulDiv` overflow at absurd utilization), a test pins where the boundary is and how many orders of magnitude separate it from anything constructible. Those tests are documentation of a gap, not a defense of a reachable state.

**Mocks isolate the unit under test.** The rate model is mocked when testing the market's accrual, so index behavior can be driven directly; a [separate suite](./04-unit-rate-model.md#2-marketaccrualwithrealcurvetsol--4-tests) then wires the *real* curve into the market to prove the integration. The same split will apply to the oracle from Phase 5 on.

---

## 3. Infrastructure

All shared scaffolding lives in [`test/mocks/`](../../test/mocks).

| File                       | Role                                                                                                                                                                                        |
| :------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`LendingMarketHarness.sol`](../../test/mocks/LendingMarketHarness.sol) | Extends `LendingMarket` to expose internals. Wraps the `internal` conversion primitives as `exposed*`, exposes the single accounting path (`exposedUpdateBasePrincipal`, `setPrincipal`), allows overwriting indexes (`setIndexes`), and reads packed state (`getIndexes`, `getTotals`, `getAssetsIn`). It also implements the Phase 4-7 interface functions as `NotImplementedYet` stubs so the market stays deployable while those phases are pending. |
| [`MarketBuilder.sol`](../../test/mocks/MarketBuilder.sol) | Library producing a `MarketConfig` and `CollateralConfig` at reference defaults, overridable field by field. Constructor-revert tests mutate exactly one field, so the assertion is unambiguous about which check fired. |
| [`MockERC20.sol`](../../test/mocks/MockERC20.sol) | Minimal ERC20 with configurable `decimals()` and open `mint`/`burn`. Used as USDC (6 dec) and WETH (18 dec).                                                                                 |
| [`MockInterestRateModel.sol`](../../test/mocks/MockInterestRateModel.sol) | Returns rates set directly via `setRates`, ignoring utilization. Lets accrual tests drive index growth without going through the curve.                              |
| [`MockPriceOracle.sol`](../../test/mocks/MockPriceOracle.sol) | Per-asset `(price18, conf18)` set via `setPrice`. Wired since Phase 3; exercised from Phase 4 on, when health checks start reading prices.                                  |

**Why the harness exists.** The conversion primitives are `internal` because none of them is part of `ILendingMarket`; they were public only because tests called them. Moving them behind the harness shrank the deployed public surface from 15 methods to 9 without losing a single assertion.

---

## 4. Running the Suite

```bash
forge test                      # default profile: 1000 fuzz runs
forge test --summary            # per-suite pass/fail table
FOUNDRY_PROFILE=lite forge test # 64 fuzz runs, for fast local iteration
FOUNDRY_PROFILE=deep forge test # 10,000 fuzz runs, the pre-merge gate
forge coverage --no-match-coverage "test|script"
forge test --match-path test/unit/SupplyWithdraw.t.sol -vvv
```

Profiles are declared in [`foundry.toml`](../../foundry.toml). `deep` is what CI runs before a merge; `lite` exists so a local edit-run cycle stays under a second.
