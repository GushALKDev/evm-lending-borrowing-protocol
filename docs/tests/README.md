# 🧪 Testing Documentation

**Version:** 1.0
**Prerequisites:** [Guide 6: Security](../06-security.md)
**Status:** Updated at the close of every roadmap phase (current: Phase 4)

---

> This section is the executable counterpart of [Guide 6, Section 7](../06-security.md#7-testing-plan). Guide 6 states the invariants; this documents which test asserts each one, why the assertion is shaped the way it is, and links every entry to the code.

---

## 📖 Contents

| Document                                       | Covers                                                                     |
| :--------------------------------------------- | :-------------------------------------------------------------------------- |
| **[Strategy](./01-strategy.md)**               | Test layers, principles, infrastructure and mocks, how to run the suite     |
| **[Unit: Accounting](./02-unit-accounting.md)**| Phase 1 core: construction, conversions, accounting path, utilization, views, reserves, accrual |
| **[Unit: Supply & Withdraw](./03-unit-supply-withdraw.md)** | Phase 3 surface: base and collateral flows, ERC20, pause flags, constructor validation |
| **[Unit: Interest Rate Model](./04-unit-rate-model.md)** | Phase 2: the curve in isolation and wired into market accrual, accrual overflow bounds |
| **[Unit + Fuzz: Borrow & Repay](./08-unit-borrow-repay.md)** | Phase 4: sign crossings, capacity boundaries, the dust guard, accrue-before-action |
| **[Fuzz](./05-fuzz.md)**                       | Conversion rounding, index monotonicity, rate properties, index-scale precision |
| **[Mutation Checks](./06-mutation-checks.md)** | Which flipped rounding direction each test catches, and the one that round trips missed |
| **[Gaps & Roadmap](./07-gaps-and-roadmap.md)** | What is not covered yet, and the testing deliverable of each remaining phase |

---

## 📊 Current Status

**169 tests, all green** (Phase 4 close).

| Suite                                                                | Layer | Tests | Phase |
| :------------------------------------------------------------------- | :---- | ----: | :---- |
| [`LendingMarketAccountingTest`](../../test/unit/LendingMarketAccounting.t.sol) | Unit  |    36 | 1     |
| [`SupplyWithdrawTest`](../../test/unit/SupplyWithdraw.t.sol)          | Unit  |    36 | 3     |
| [`BorrowRepayTest`](../../test/unit/BorrowRepay.t.sol)                | Unit  |    37 | 4     |
| [`InterestRateModelTest`](../../test/unit/InterestRateModel.t.sol)    | Unit  |    18 | 2     |
| [`MarketAccrualWithRealCurveTest`](../../test/unit/MarketAccrualWithRealCurve.t.sol) | Unit |  4 | 2     |
| [`AccrualOverflowTest`](../../test/unit/AccrualOverflow.t.sol)        | Unit  |     3 | 1     |
| [`ConversionRoundingTest`](../../test/fuzz/ConversionRounding.t.sol)  | Fuzz  |    19 | 1     |
| [`InterestRateModelFuzzTest`](../../test/fuzz/InterestRateModel.t.sol)| Fuzz  |     6 | 2     |
| [`BorrowCapacityFuzzTest`](../../test/fuzz/BorrowCapacity.t.sol)      | Fuzz  |     6 | 4     |
| [`IndexPrecisionTest`](../../test/fuzz/IndexPrecision.t.sol)          | Fuzz  |     4 | 1     |
| **Total**                                                            |       | **169** |     |

### Coverage

| File                        | Lines            | Statements       | Branches       | Functions       |
| :-------------------------- | :--------------- | :--------------- | :------------- | :-------------- |
| `src/InterestRateModel.sol` | 100.00% (17/17)  | 100.00% (25/25)  | 100.00% (4/4)  | 100.00% (3/3)   |
| `src/LendingMarket.sol`     | 99.61% (255/256) | 96.93% (316/326) | 82.14% (46/56) | 100.00% (48/48) |

The single uncovered line in `LendingMarket.sol` is the fallthrough `revert UnknownAsset` in `_offsetOf`, which is unreachable in practice: every caller passes through `_requireListed` first, so it is a defensive guard rather than a live path. Branch coverage remains the metric below target, and the uncovered branches are now predominantly the Phase 5-7 stubs (`absorb`, `buyCollateral`, `withdrawReserves`); the >95% gate applies at Phase 8. Details in [Gaps & Roadmap](./07-gaps-and-roadmap.md).

---

## 🔗 Invariant Coverage Map

Every invariant from [Guide 6, Section 2](../06-security.md#2-system-invariants), and what currently asserts it.

| Invariant | Statement (abridged)                              | Asserted by                                                                                        |
| :-------- | :------------------------------------------------ | :------------------------------------------------------------------------------------------------- |
| INV-1     | Principal sums equal the totals, split by sign    | [`testFuzz_accountingPath_totalsMatchPrincipalsAcrossCrossings`](../../test/fuzz/ConversionRounding.t.sol#L320), [`testFuzz_accountingPath_totalsMatchTwoAccounts`](../../test/fuzz/ConversionRounding.t.sol#L341), and the [six unit tests](./02-unit-accounting.md#single-accounting-path) on the accounting path |
| INV-2     | Indexes monotone, never below seed                | [`testFuzz_accrual_indexesAreMonotone`](../../test/fuzz/ConversionRounding.t.sol#L240), [`testFuzz_accrual_borrowIndexOutgrowsSupplyIndex`](../../test/fuzz/ConversionRounding.t.sol#L263) |
| INV-3     | Round trips never favor the account               | The four [round-trip tests](./05-fuzz.md#inv-3-round-trips-favor-the-protocol) plus the four [per-site exact-value tests](./05-fuzz.md#directed-rounding-per-site) |
| INV-4     | Rounding residual accrues to reserves             | [`testFuzz_interestSplit_reserveShareIsNonNegative`](../../test/fuzz/InterestRateModel.t.sol#L76), [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L278), [`testFuzz_indexScale_neverFavorsTheSupplier`](../../test/fuzz/IndexPrecision.t.sol#L66) |
| INV-5     | Cash conservation via ghost tracking              | ⏳ Phase 8 (invariant suite) — no assertion yet                                                     |
| INV-6/7/8 | Collateral ledgers, bitmap, supply cap            | Unit level only: [`test_supplyCollateral_*`](./03-unit-supply-withdraw.md#supply-collateral-32), [`test_withdrawCollateral_*`](./03-unit-supply-withdraw.md#withdraw-collateral-34); ⏳ Phase 8 for the summed invariants |
| INV-9     | No action ends undercollateralized                | [`testFuzz_acceptedBorrowAlwaysLeavesTheAccountCollateralized`](../../test/fuzz/BorrowCapacity.t.sol#L73), [`testFuzz_repayNeverReducesHealth`](../../test/fuzz/BorrowCapacity.t.sol#L139), and the [nine capacity unit tests](./08-unit-borrow-repay.md#capacity-check-42); ⏳ Phase 8 for the multi-account invariant |
| INV-10    | `minBorrow` dust guard                            | [`testFuzz_acceptedBorrowNeverLandsInTheDustBand`](../../test/fuzz/BorrowCapacity.t.sol#L196) and the [four dust-guard unit tests](./08-unit-borrow-repay.md#minborrow-dust-guard-43-inv-10) |
| INV-11    | No debt against an empty pool                     | [`test_utilization_isZeroWhenSupplyIsZero`](../../test/unit/LendingMarketAccounting.t.sol#L245) covers the divide-by-zero guard only; ⏳ Phase 8 for the invariant |
| INV-12    | Static configuration ordering                     | The [eight constructor tests](./03-unit-supply-withdraw.md#constructor-validation-inv-12) in `SupplyWithdrawTest` and the [six](./04-unit-rate-model.md#constructor-22-inv-12) in `InterestRateModelTest` |
| INV-13    | Absorb coverage condition                         | ⏳ Phase 7 (needs `MAX_CONFIDENCE_BPS` from the oracle)                                             |
| INV-14    | `supplyRate <= borrowRate`, monotone, continuous  | [`testFuzz_supplyRateNeverExceedsBorrowRate`](../../test/fuzz/InterestRateModel.t.sol#L60), both [monotonicity fuzz tests](./05-fuzz.md#2-interestratemodeltsol--6-tests), [`testFuzz_continuity_noDownwardStepAcrossTheKink`](../../test/fuzz/InterestRateModel.t.sol#L111) |

---

## 📚 References

- [Documentation Index](../README.md)
- [Guide 2: Mathematics](../02-mathematics.md) — the formulas every rounding test pins
- [Guide 5: Implementation](../05-implementation.md) — the function contracts under test
- [Guide 6: Security](../06-security.md) — the invariants this suite executes
- [ROADMAP](../ROADMAP.md) — phase status
