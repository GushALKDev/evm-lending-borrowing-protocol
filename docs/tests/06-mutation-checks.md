# Mutation Checks

**Section:** [Testing Documentation](./README.md)
**Prev:** [Fuzz](./05-fuzz.md) · **Next:** [Gaps & Roadmap](./07-gaps-and-roadmap.md)

---

Coverage says a line ran; it does not say an assertion would have caught it changing. For the rounding logic, where the entire solvency argument lives, each direction was flipped by hand and the suite re-run to confirm it fails.

---

## Every Rounding Site

Every division and every `mulDiv` / `fullMulDiv` / `fullMulDivUp` in `LendingMarket.sol`, `InterestRateModel.sol` and `PythChainlinkOracle.sol` was flipped one at a time: floor to ceil, ceil to floor, and the oracle's two exact comparisons back to the floored ratio they replaced. Each mutant was run against the full non-fork suite at the default profile (fuzz 1,000 runs, invariants 1,000 runs of 100 calls), with `cache/invariant` cleared first so no stored counterexample was replayed. "Before" is the suite at the commit that made the oracle checks exact, before the per-site tests below were added; "Caught by" is the suite now. Linked names are the per-site exact-value tests; the rest also fail on that mutant, and can vary between runs with the fuzz seed.

```bash
# One row: edit the line in the Location column to the opposite direction, then
rm -rf cache/invariant && forge test --no-match-path 'test/fork/*'
git checkout -- src   # restore
```

| Site | Location | Policy | Mutant | Before | Caught by |
| :--- | :------- | :----- | :----- | :----- | :-------- |
| Constructor INV-13 coverage bound | [`LendingMarket.sol#L173`](../../src/LendingMarket.sol#L173) | ceil | floor | **survived** | [`test_constructor_coverageFloorRoundsUp`](../../test/unit/ProtocolManagement.t.sol#L236), [`testFuzz_coverageBound_ceilsExactly`](../../test/fuzz/ValuationRounding.t.sol#L237) |
| `_presentValueSupply` | [`LendingMarket.sol#L203`](../../src/LendingMarket.sol#L203) | floor | ceil | caught | [`testFuzz_presentValueSupply_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L113), [`test_presentValueSupply_roundsDown`](../../test/unit/LendingMarketAccounting.t.sol#L125), `testFuzz_indexScale_neverFavorsTheSupplier`, `testFuzz_indexScale_relativeErrorShrinksWithSize`, `invariant_INV4_reserveDeltasMatchTheTable` |
| `_presentValueBorrow` | [`LendingMarket.sol#L213`](../../src/LendingMarket.sol#L213) | ceil | floor | caught | [`testFuzz_presentValueBorrow_ceilsExactly`](../../test/fuzz/ConversionRounding.t.sol#L123), [`test_presentValueBorrow_roundsUp`](../../test/unit/LendingMarketAccounting.t.sol#L131), `test_pausedSupply_repayBoundIsTheAccruedDebt`, `invariant_INV4_reserveDeltasMatchTheTable`, `test_presentValue_matchesDocumentedWorkedExample`, `testFuzz_debtUSD_ceilsExactly` |
| `_principalValueSupply` | [`LendingMarket.sol#L223`](../../src/LendingMarket.sol#L223) | floor | ceil | caught | [`testFuzz_principalValueSupply_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L134), [`test_principalValueSupply_roundsDown`](../../test/unit/LendingMarketAccounting.t.sol#L137), `testFuzz_supplyRoundTrip_neverFavorsTheSupplier`, `invariant_INV4_reserveDeltasMatchTheTable`, `test_presentValue_matchesDocumentedWorkedExample` |
| `_principalValueBorrow` | [`LendingMarket.sol#L233`](../../src/LendingMarket.sol#L233) | ceil | floor | caught | [`testFuzz_principalValueBorrow_ceilsExactly`](../../test/fuzz/ConversionRounding.t.sol#L144), [`test_principalValueBorrow_roundsUp`](../../test/unit/LendingMarketAccounting.t.sol#L143), `test_pausedSupply_repayBoundIsTheAccruedDebt`, `testFuzz_borrowRoundTrip_neverFavorsTheBorrower`, `invariant_INV3_roundTripsFavorTheProtocolAtLiveIndexes`, `invariant_INV4_reserveDeltasMatchTheTable`, `test_presentValue_matchesDocumentedWorkedExample` |
| Supply index accrual | [`LendingMarket.sol#L352`](../../src/LendingMarket.sol#L352) | floor | ceil | caught | [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L279), `testFuzz_indexScale_neverFavorsTheSupplier`, `testFuzz_indexScale_relativeErrorShrinksWithSize`, `test_accrue_borrowIndexCeilsOnDustInterest` |
| Borrow index accrual | [`LendingMarket.sol#L354`](../../src/LendingMarket.sol#L354) | ceil | floor | caught | [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L279), [`test_accrue_borrowIndexCeilsOnDustInterest`](../../test/unit/LendingMarketAccounting.t.sol#L371) |
| `getUtilization` | [`LendingMarket.sol#L370`](../../src/LendingMarket.sol#L370) | floor | ceil | caught | [`testFuzz_utilization_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L222) |
| Absorb `creditBase` | [`LendingMarket.sol#L673`](../../src/LendingMarket.sol#L673) | floor | ceil | **survived** | [`testFuzz_absorb_creditBaseFloorsExactly`](../../test/fuzz/ValuationRounding.t.sol#L191), [`test_absorb_creditBaseRoundsDown`](../../test/fuzz/ValuationRounding.t.sol#L218) |
| Absorb `seizeValueUSD` (event only) | [`LendingMarket.sol#L712`](../../src/LendingMarket.sol#L712) | floor | ceil | **survived** | [`testFuzz_seizeCollateral_floorsSeizeAndCreditValue`](../../test/fuzz/ValuationRounding.t.sol#L159), [`test_seizeCollateral_roundsDown`](../../test/fuzz/ValuationRounding.t.sol#L175) |
| Absorb `creditValueUSD` | [`LendingMarket.sol#L713`](../../src/LendingMarket.sol#L713) | floor | ceil | **survived** | [`testFuzz_seizeCollateral_floorsSeizeAndCreditValue`](../../test/fuzz/ValuationRounding.t.sol#L159), [`test_seizeCollateral_roundsDown`](../../test/fuzz/ValuationRounding.t.sol#L175) |
| `quoteCollateral` discount | [`LendingMarket.sol#L772`](../../src/LendingMarket.sol#L772) | floor | ceil | caught | [`testFuzz_quoteCollateral_matchesDirectedRounding`](../../test/fuzz/QuoteRounding.t.sol#L84) |
| `quoteCollateral` ask price | [`LendingMarket.sol#L778`](../../src/LendingMarket.sol#L778) | floor | ceil | caught | [`testFuzz_quoteCollateral_matchesDirectedRounding`](../../test/fuzz/QuoteRounding.t.sol#L84) |
| `quoteCollateral` quote | [`LendingMarket.sol#L783`](../../src/LendingMarket.sol#L783) | floor | ceil | caught | [`testFuzz_quoteCollateral_matchesDirectedRounding`](../../test/fuzz/QuoteRounding.t.sol#L84), `test_buyCollateralAgainstRealOracle_sellsInventoryAndRefunds` |
| `_debtUSD` | [`LendingMarket.sol#L859`](../../src/LendingMarket.sol#L859) | ceil | floor | **survived** | [`testFuzz_debtUSD_ceilsExactly`](../../test/fuzz/ValuationRounding.t.sol#L83), [`test_debtUSD_roundsUp`](../../test/fuzz/ValuationRounding.t.sol#L101) |
| `_borrowCapacity` | [`LendingMarket.sol#L886`](../../src/LendingMarket.sol#L886) | floor | ceil | **survived** | [`testFuzz_borrowCapacity_floorsExactly`](../../test/fuzz/ValuationRounding.t.sol#L112), [`test_borrowCapacity_roundsDown`](../../test/fuzz/ValuationRounding.t.sol#L124) |
| `_liquidationCapacity` | [`LendingMarket.sol#L918`](../../src/LendingMarket.sol#L918) | floor | ceil | **survived** | [`testFuzz_liquidationCapacity_floorsExactly`](../../test/fuzz/ValuationRounding.t.sol#L131), [`test_liquidationCapacity_roundsDown`](../../test/fuzz/ValuationRounding.t.sol#L143) |
| `RATE_AT_KINK` (constructor) | [`InterestRateModel.sol#L79`](../../src/InterestRateModel.sol#L79) | floor | ceil | **survived** | [`testFuzz_borrowRate_floorsExactly`](../../test/fuzz/InterestRateModel.t.sol#L128), [`test_borrowRate_floorsOnBothBranches`](../../test/unit/InterestRateModel.t.sol#L128) |
| `getBorrowRate` below the kink | [`InterestRateModel.sol#L93`](../../src/InterestRateModel.sol#L93) | floor | ceil | caught | [`testFuzz_borrowRate_floorsExactly`](../../test/fuzz/InterestRateModel.t.sol#L128), [`test_borrowRate_floorsOnBothBranches`](../../test/unit/InterestRateModel.t.sol#L128), `testFuzz_continuity_noDownwardStepAcrossTheKink`, `testFuzz_supplyRate_isMonotoneInTheRealDomain`, `test_continuity_branchesAgreeAtTheKink`, `test_continuity_upperBranchStartsFromTheKinkRate` |
| `getBorrowRate` above the kink | [`InterestRateModel.sol#L95`](../../src/InterestRateModel.sol#L95) | floor | ceil | **survived** | [`testFuzz_borrowRate_floorsExactly`](../../test/fuzz/InterestRateModel.t.sol#L128), [`test_borrowRate_floorsOnBothBranches`](../../test/unit/InterestRateModel.t.sol#L128) |
| `getSupplyRate`, `r * U` step | [`InterestRateModel.sol#L102`](../../src/InterestRateModel.sol#L102) | floor | ceil | caught | [`testFuzz_interestSplit_supplyRateIsFloored`](../../test/fuzz/InterestRateModel.t.sol#L92) |
| `getSupplyRate`, `(1 - RF)` step | [`InterestRateModel.sol#L103`](../../src/InterestRateModel.sol#L103) | floor | ceil | caught | [`testFuzz_interestSplit_supplyRateIsFloored`](../../test/fuzz/InterestRateModel.t.sol#L92) |
| Oracle confidence check | [`PythChainlinkOracle.sol#L191`](../../src/PythChainlinkOracle.sol#L191) | exact | floored ratio (the pre-fix form) | caught | [`testFuzz_confidenceGate`](../../test/fuzz/PythChainlinkOracle.t.sol#L94), [`test_getPrice_revertsOnConfidenceJustAboveLimit`](../../test/unit/PythChainlinkOracle.t.sol#L184) |
| `ConfidenceTooWide` reported bps | [`PythChainlinkOracle.sol#L192`](../../src/PythChainlinkOracle.sol#L192) | ceil | floor | caught | [`testFuzz_confidenceGate`](../../test/fuzz/PythChainlinkOracle.t.sol#L94), [`test_getPrice_revertsOnConfidenceJustAboveLimit`](../../test/unit/PythChainlinkOracle.t.sol#L184), `test_confidenceTooWide_blocksAbsorb`, `test_confidenceTooWide_blocksBuyCollateral` |
| Oracle deviation check | [`PythChainlinkOracle.sol#L203`](../../src/PythChainlinkOracle.sol#L203) | exact | floored ratio (the pre-fix form) | caught | [`testFuzz_deviationGate`](../../test/fuzz/PythChainlinkOracle.t.sol#L126), [`test_getPrice_revertsOnDeviationJustAboveLimit`](../../test/unit/PythChainlinkOracle.t.sol#L207) |
| `PriceDeviationTooHigh` reported bps | [`PythChainlinkOracle.sol#L204`](../../src/PythChainlinkOracle.sol#L204) | ceil | floor | caught | [`testFuzz_deviationGate`](../../test/fuzz/PythChainlinkOracle.t.sol#L126), [`test_getPrice_revertsOnDeviationJustAboveLimit`](../../test/unit/PythChainlinkOracle.t.sol#L207), `test_absorbAgainstRealOracle_seizesSettlesAndRefunds`, `test_getPrice_revertsOnDeviation` |
| `_scalePyth` scale-down | [`PythChainlinkOracle.sol#L245`](../../src/PythChainlinkOracle.sol#L245) | floor | ceil | **survived** | [`testFuzz_normalizesBelowExpoMinus18_floors`](../../test/fuzz/PythChainlinkOracle.t.sol#L71), [`test_getPrice_expoBelowMinus18ScalesDownAndFloors`](../../test/unit/PythChainlinkOracle.t.sol#L96) |

Ten sites survived before: every assertion that touched them was an inequality, a boolean, a 1-unit tolerance, a 0.1% tolerance, or (for `_scalePyth`) never reached the division at all. Each now has a per-site test that computes the expected value with plain integer arithmetic, fuzzed at full precision rather than at round values, plus a fixed case with a known non-zero remainder ([`ValuationRounding.t.sol`](../../test/fuzz/ValuationRounding.t.sol), and additions to the oracle, rate-model and management suites). At the commit before the oracle fix the floored ratio was the code itself: the two `JustAboveLimit` tests fail against it ([oracle inventory](./09-oracle.md#confidence-54)).

**No site is unobservable.** `seizeValueUSD` only feeds the `AbsorbCollateral` event, so its test pins it through `vm.expectEmit`; every other site changes a value a test reads through the public surface or the [harness](../../test/mocks/LendingMarketHarness.sol).

**Three directions sit outside the single rule** and are kept as implemented: the `buyCollateral` ask price floors (a lower ask quotes the buyer more), `getBorrowRate` floors on both branches and at the kink (borrowers are charged less, still reserve-safe), and the Pyth scale-down floors both price and confidence. [Guide 2, Section 10](../02-mathematics.md#10-rounding-policy) lists who loses the wei at each.

Plus one rate-model site:

| Site                             | Mutated to      | Caught by                                                                                            |
| :------------------------------- | :-------------- | :----------------------------------------------------------------------------------------------------- |
| Supply rate floor                | removed         | [`testFuzz_interestSplit_supplyRateIsFloored`](../../test/fuzz/InterestRateModel.t.sol#L92)           |

Plus the stateful checks of roadmap 8.11, listed with their mutants in the [invariant suite](./12-invariant.md#falsification). One of them is the stateful counterpart of the finding below: a flipped `presentValueBorrow` survives the live-index round trip by construction, and among the stateful checks only the exact per-operation reserve table catches it.

---

## The Finding That Shaped the Suite

Round-trip assertions alone did **not** catch a flipped `presentValueSupply`, and no round trip can: each of the four holds for every input whichever way a `presentValue` conversion rounds, by construction.

- `pv -> principal -> pv` (supply): the first leg floors, so `principal * index / 1e15 <= pv`. The second leg cannot return a value above the integer `pv`, whichever way it rounds.
- `principal -> pv -> principal` (supply): since `index >= 1e15`, an error of less than one unit of present value maps back to less than one unit of principal, and the final floor removes it.
- The borrow side is the same with the inequalities reversed, which is also why the live-index INV-3 passes a flipped `presentValueBorrow` ([invariant suite](./12-invariant.md#the-reserve-table-has-no-tolerance)).

So a round trip pins at most the direction of its first leg, and never the direction of a `presentValue` conversion. With either `presentValue` mutant applied, all four round-trip tests in `ConversionRounding.t.sol` pass at 10,000 runs (`FOUNDRY_FUZZ_RUNS=10000 forge test --match-contract ConversionRoundingTest --match-test RoundTrip`).

That is why the four per-site exact-value tests exist. Each pins a single division against a locally computed expectation (`(principal * index) / 1e15` truncated, and so on), so any single flipped direction fails.

**The rule this produced:** every rounding site gets a per-site exact-value assertion, not only a round trip. A round trip is a useful sanity property, but it is not a specification of the rounding direction, and the rounding direction is what the solvency argument rests on ([Guide 2, Section 10](../02-mathematics.md#10-rounding-policy)).

---

## Scope and Limits

These checks are manual, not generated: there is no automated mutation-testing tool in the pipeline. The mutants chosen are the ones with a plausible failure mode: flipping a rounding direction is a one-character edit that a reviewer can miss and that silently transfers value on every operation.

Phase 8 (audit prep) is where the broader static-analysis pass lands (Slither, Aderyn). Automated mutation testing is not currently planned for the PoC.
