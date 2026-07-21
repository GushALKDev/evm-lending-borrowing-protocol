# 📈 Unit: Interest Rate Model & Accrual Bounds

**Section:** [Testing Documentation](./README.md)
**Suites:** [`InterestRateModel.t.sol`](../../test/unit/InterestRateModel.t.sol) (18) · [`MarketAccrualWithRealCurve.t.sol`](../../test/unit/MarketAccrualWithRealCurve.t.sol) (4) · [`AccrualOverflow.t.sol`](../../test/unit/AccrualOverflow.t.sol) (3)
**Phase:** 2 (plus the Phase 1 accrual bounds)
**Prev:** [Unit: Supply & Withdraw](./03-unit-supply-withdraw.md) · **Next:** [Fuzz](./05-fuzz.md)

---

Three suites covering the rate curve: in isolation, wired into the market, and at the arithmetic boundary of accrual. Reference: [Guide 2, Section 5](../02-mathematics.md#5-jump-rate-interest-model), [ADR-4](../03-architecture.md#adr-4-derived-supply-rate-vs-dual-curves).

---

## 1. `InterestRateModel.t.sol` — 18 tests

The curve in isolation, against the reference parameters: kink 80%, reserve factor 10%, slopes sized so the borrow rate is exactly 4% APR at the kink.

### Constructor (2.2, INV-12)

| Test                                                                                                     | Asserts                                                                                  |
| :--------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------- |
| [`test_constructor_storesParameters`](../../test/unit/InterestRateModel.t.sol#L41)                       | All five immutables stored as passed.                                                      |
| [`test_constructor_revertsOnZeroKink`](../../test/unit/InterestRateModel.t.sol#L49)                      | `0 < kink`.                                                                                |
| [`test_constructor_revertsOnKinkAtOrAboveOne`](../../test/unit/InterestRateModel.t.sol#L54)              | `kink < 1e18`: a kink at or above full utilization would make the jump regime unreachable.  |
| [`test_constructor_revertsWhenSlopeHighBelowSlopeLow`](../../test/unit/InterestRateModel.t.sol#L59)      | `slopeHigh >= slopeLow`, or the curve would bend downward past the kink.                    |
| [`test_constructor_revertsOnReserveFactorAtOrAboveOne`](../../test/unit/InterestRateModel.t.sol#L64)     | `RF < 1e18`.                                                                                |
| [`test_constructor_allowsEqualSlopes`](../../test/unit/InterestRateModel.t.sol#L72)                      | `slopeHigh == slopeLow` is legal (a straight line); only strictly below is rejected. Pins that the check is `>=`, not `>`. |

### Reference Curve (2.3, 2.4)

The documented table from [Guide 2, Section 5](../02-mathematics.md#5-jump-rate-interest-model), with tolerances absorbing per-second truncation.

| Test                                                                                                        | Asserts                                                        |
| :------------------------------------------------------------------------------------------------------------ | :--------------------------------------------------------------- |
| [`test_borrowRate_isBaseRateAtZeroUtilization`](../../test/unit/InterestRateModel.t.sol#L83)                | At U = 0 both rates are the base rate (zero in the reference config). |
| [`test_curve_matchesDocumentedTableAtHalfUtilization`](../../test/unit/InterestRateModel.t.sol#L88)         | U = 50%: 2.5% borrow, 1.125% supply.                            |
| [`test_curve_matchesDocumentedTableAtTheKink`](../../test/unit/InterestRateModel.t.sol#L93)                 | U = 80%: 4% borrow, 2.88% supply.                                |
| [`test_curve_matchesDocumentedTableInTheJumpRegime`](../../test/unit/InterestRateModel.t.sol#L98)           | U = 90%: 14% borrow, 11.34% supply.                              |
| [`test_curve_matchesDocumentedTableAtFullUtilization`](../../test/unit/InterestRateModel.t.sol#L103)        | U = 100%: 24% borrow, 21.6% supply.                              |

### Continuity at the Kink

| Test                                                                                                    | Asserts                                                                                      |
| :--------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------- |
| [`test_continuity_branchesAgreeAtTheKink`](../../test/unit/InterestRateModel.t.sol#L113)                | One wei below and above the kink, the rate is non-decreasing and the step is bounded by `slopeHigh`: the curve has no jump discontinuity a borrower could be gamed across. |
| [`test_continuity_upperBranchStartsFromTheKinkRate`](../../test/unit/InterestRateModel.t.sol#L126)      | The upper branch is anchored on the lower branch's exact value at the kink, `slopeLow * kink / 1e18`. |

### Reachable Domain and Overflow

The rate functions are **not clamped**. Utilization is bounded by the accounting, not by the curve, so it sits in `~[0, 1e18]`; the `fullMulDiv` overflow is many orders of magnitude beyond any constructible state, and Aave does not clamp either. These tests document that gap — they do not defend a reachable state ([Guide 5, Section 3.2](../05-implementation.md#3-interfaces-and-function-contracts)).

| Test                                                                                                            | Asserts                                                                              |
| :---------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------- |
| [`test_domain_doesNotRevertThroughOverUtilization`](../../test/unit/InterestRateModel.t.sol#L145)               | Past U = 1 the rate keeps rising, and at 1000% utilization both functions still return. |
| [`test_domain_overflowIsUnreachablyFarAboveRealUtilization`](../../test/unit/InterestRateModel.t.sol#L156)      | The supply rate's `fullMulDiv` overflow sits at U ≈ 1.9e51, about 33 orders of magnitude above anything the accounting can produce. Pinned from both sides: returns at 1e51, reverts at 2e51. |
| [`test_domain_borrowRateToleratesEvenHigherUtilization`](../../test/unit/InterestRateModel.t.sol#L174)          | The borrow rate, with one multiplication instead of two, still returns at 1e40 × full utilization. |

### Reserve Factor Edge

| Test                                                                                                        | Asserts                                                                                   |
| :------------------------------------------------------------------------------------------------------------ | :------------------------------------------------------------------------------------------ |
| [`test_reserveFactor_zeroPassesEverythingToSuppliers`](../../test/unit/InterestRateModel.t.sol#L184)        | With RF = 0 at U = 1, the supply rate equals the borrow rate exactly: nothing is diverted.  |
| [`test_reserveFactor_divertsTheDocumentedShare`](../../test/unit/InterestRateModel.t.sol#L192)              | With RF = 10% at U = 1, the supply rate is 90% of the borrow rate.                           |

---

## 2. `MarketAccrualWithRealCurve.t.sol` — 4 tests

The integration seam between market and rate model: the real `InterestRateModel` wired into `accrue()`, rather than the mock the other suites use.

| Test                                                                                                              | Asserts                                                                             |
| :-------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------ |
| [`test_accrual_atKinkGrowsBorrowIndexByReferenceRate`](../../test/unit/MarketAccrualWithRealCurve.t.sol#L49)      | 800 borrowed against 1,000 supplied (U = 80%, the kink) grows the borrow index ~4% over a year and the supply index ~2.88%, matching the curve read in isolation. |
| [`test_accrual_inJumpRegimeGrowsFaster`](../../test/unit/MarketAccrualWithRealCurve.t.sol#L67)                    | At U = 90% the borrow index grows at the 14% APR jump-regime rate: the market reads the steep branch, not just the shallow one. |
| [`test_accrual_idleMarketDoesNotAccrue`](../../test/unit/MarketAccrualWithRealCurve.t.sol#L82)                    | With no borrows, utilization is zero, so the curve returns zero and neither index moves — the market does not manufacture interest from nothing. |
| [`test_wiring_marketUsesTheRealModel`](../../test/unit/MarketAccrualWithRealCurve.t.sol#L94)                      | The immutable points at the deployed model.                                            |

---

## 3. `AccrualOverflow.t.sol` — 3 tests

Pins the one multiplication in `_accrue` that sits outside `fullMulDiv`'s 512-bit intermediate: the `rate * elapsed` product. It stays checked rather than unchecked, so the failure mode is a revert, never a wrapped index.

| Test                                                                                                        | Asserts                                                                            |
| :------------------------------------------------------------------------------------------------------------ | :----------------------------------------------------------------------------------- |
| [`test_accrue_revertsWhenRateTimesElapsedOverflows`](../../test/unit/AccrualOverflow.t.sol#L39)             | At the smallest rate whose product with elapsed exceeds `uint256`, checked arithmetic panics: a revert, never a corrupted index. |
| [`test_accrue_revertsOnIndexCastWhenRateIsMerelyAbsurd`](../../test/unit/AccrualOverflow.t.sol#L53)         | Just below that threshold the product fits but the resulting index does not fit `uint64`, and `SafeCastLib` reverts. The second guard behind the first. |
| [`test_accrue_realisticRatesAreFarFromTheBound`](../../test/unit/AccrualOverflow.t.sol#L66)                 | At 1000% APR per second — far above anything the reference curve produces — the headroom against the overflow threshold is over 50 orders of magnitude. |

This is the one documented reachable revert in the liveness guarantee: `accrue()` does not revert for any reachable state, and its residual out-of-domain case is this product, not the rate lookup.
