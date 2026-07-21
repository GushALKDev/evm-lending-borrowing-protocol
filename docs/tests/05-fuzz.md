# 🎲 Fuzz Tests

**Section:** [Testing Documentation](./README.md)
**Suites:** [`ConversionRounding.t.sol`](../../test/fuzz/ConversionRounding.t.sol) (19) · [`InterestRateModel.t.sol`](../../test/fuzz/InterestRateModel.t.sol) (6) · [`IndexPrecision.t.sol`](../../test/fuzz/IndexPrecision.t.sol) (4)
**Phases:** 1-2
**Prev:** [Unit: Interest Rate Model](./04-unit-rate-model.md) · **Next:** [Mutation Checks](./06-mutation-checks.md)

---

Default profile runs each of these 1,000 times; the `deep` CI profile runs 10,000. This is where the solvency thesis is argued: every assertion pins a rounding *direction*, never a dust magnitude.

---

## 1. `ConversionRounding.t.sol` — 19 tests

Indexes bounded to `[1e15, uint64.max]` (they only grow, and `uint64` at 1e15 caps growth at ~18,446×), principals to the `int104` domain.

### INV-3: Round Trips Favor the Protocol

| Test                                                                                                          | Asserts                                                                                  |
| :-------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------- |
| [`testFuzz_supplyRoundTrip_neverFavorsTheSupplier`](../../test/fuzz/ConversionRounding.t.sol#L51)             | `presentValue(principalValue(pv)) <= pv` for every supply amount and index.                |
| [`testFuzz_borrowRoundTrip_neverFavorsTheBorrower`](../../test/fuzz/ConversionRounding.t.sol#L65)             | `\|presentValue(principalValue(pv))\| >= \|pv\|` for every debt amount and index.          |
| [`testFuzz_supplyPrincipalRoundTrip_neverGrows`](../../test/fuzz/ConversionRounding.t.sol#L78)                | The reverse direction: principal → PV → principal never grows on the supply side.           |
| [`testFuzz_borrowPrincipalRoundTrip_neverShrinks`](../../test/fuzz/ConversionRounding.t.sol#L90)              | And never shrinks on the debt side.                                                        |

### Directed Rounding, Per Site

Round trips alone are too weak: a flipped `presentValueSupply` partially cancels against `principalValueSupply`'s floor and survives them. These pin each division against a locally computed exact value, so any single flipped direction fails the suite. See [Mutation Checks](./06-mutation-checks.md) for the mutation that made this necessary.

| Test                                                                                                       | Asserts                                                                                      |
| :------------------------------------------------------------------------------------------------------------ | :--------------------------------------------------------------------------------------------- |
| [`testFuzz_presentValueSupply_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L112)                | Equals `(principal * supplyIndex) / 1e15` truncated.                                            |
| [`testFuzz_presentValueBorrow_ceilsExactly`](../../test/fuzz/ConversionRounding.t.sol#L122)                 | Equals the same quotient rounded away from zero.                                                |
| [`testFuzz_principalValueSupply_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L133)              | Equals `(pv * 1e15) / supplyIndex` truncated.                                                   |
| [`testFuzz_principalValueBorrow_ceilsExactly`](../../test/fuzz/ConversionRounding.t.sol#L143)               | Equals the same quotient ceiled.                                                                |

### Cross-Side and Structural Properties

| Test                                                                                                          | Asserts                                                                                   |
| :-------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------ |
| [`testFuzz_borrowSideNeverValuedBelowSupplySide`](../../test/fuzz/ConversionRounding.t.sol#L154)              | At equal indexes, debt is always valued at least as high as supply: the asymmetry points one way only. |
| [`testFuzz_debtPrincipalNeverBelowSupplyPrincipal`](../../test/fuzz/ConversionRounding.t.sol#L168)            | The mirror statement on the principal side.                                                 |
| [`testFuzz_conversionsAreMonotone`](../../test/fuzz/ConversionRounding.t.sol#L182)                            | More present value never yields less principal, on either side: no non-monotone region an attacker could sit on. |
| [`testFuzz_signedConversionsMatchPrimitives`](../../test/fuzz/ConversionRounding.t.sol#L198)                  | The signed wrappers agree with the unsigned primitives on both branches, and the sign of the result matches the sign of the input. |
| [`testFuzz_utilization_floorsExactly`](../../test/fuzz/ConversionRounding.t.sol#L221)                         | Utilization floors, the direction [Guide 2, Section 6](../02-mathematics.md#6-interest-split-and-reserve-growth) proves reserve-safe. |

### INV-2: Index Monotonicity

| Test                                                                                                          | Asserts                                                                                  |
| :-------------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------------------------- |
| [`testFuzz_accrual_indexesAreMonotone`](../../test/fuzz/ConversionRounding.t.sol#L240)                        | Over arbitrary gaps up to a year, neither index ever decreases or falls below the seed.    |
| [`testFuzz_accrual_borrowIndexOutgrowsSupplyIndex`](../../test/fuzz/ConversionRounding.t.sol#L263)            | With `supplyRate <= borrowRate`, the borrow index never falls behind: the reserve cut can only accumulate. |
| [`testFuzz_accrual_indexRoundingIsDirected`](../../test/fuzz/ConversionRounding.t.sol#L278)                   | The supply index floors and the borrow index ceils on every accrual, pinned against exact locally computed values. |
| [`testFuzz_accrual_isIdempotentWithinABlock`](../../test/fuzz/ConversionRounding.t.sol#L298)                  | A second `accrue()` in the same block moves nothing, for any rate: accrual is not double-applicable. |

### INV-1: Single Accounting Path

| Test                                                                                                                        | Asserts                                                                        |
| :------------------------------------------------------------------------------------------------------------------------------ | :-------------------------------------------------------------------------------- |
| [`testFuzz_accountingPath_totalsMatchPrincipalsAcrossCrossings`](../../test/fuzz/ConversionRounding.t.sol#L320)               | Three consecutive arbitrary principals (any sign, any order) leave the totals exactly matching the split principal after every write. |
| [`testFuzz_accountingPath_totalsMatchTwoAccounts`](../../test/fuzz/ConversionRounding.t.sol#L341)                             | INV-1 across two accounts moving independently, including opposite signs.        |

---

## 2. `InterestRateModel.t.sol` — 6 tests

| Test                                                                                                        | Asserts                                                                                |
| :-------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------- |
| [`testFuzz_borrowRate_isMonotone`](../../test/fuzz/InterestRateModel.t.sol#L38)                             | The borrow rate never decreases as utilization rises, across the reachable domain and far past it, up to a ceiling below the `fullMulDiv` overflow. |
| [`testFuzz_supplyRate_isMonotoneInTheRealDomain`](../../test/fuzz/InterestRateModel.t.sol#L48)              | The supply rate is monotone over `[0, 1e18]`. Bounded deliberately: past U = 1 the derived `s = r * U` grows super-linearly, so pointwise monotonicity there carries no meaning. |
| [`testFuzz_supplyRateNeverExceedsBorrowRate`](../../test/fuzz/InterestRateModel.t.sol#L60)                  | INV-14's core inequality, for every utilization in the covered domain.                    |
| [`testFuzz_interestSplit_reserveShareIsNonNegative`](../../test/fuzz/InterestRateModel.t.sol#L76)           | Normalized to one unit of supply, borrower interest `r * U` is always at least supplier interest `s`: the reserve cut can never be negative. Asserted as a directional inequality, never an equality — the two rates floor independently, so no integer identity exists ([Guide 2, Section 6](../02-mathematics.md#6-interest-split-and-reserve-growth)). |
| [`testFuzz_interestSplit_supplyRateIsFloored`](../../test/fuzz/InterestRateModel.t.sol#L92)                 | Flooring never rounds the supply rate above the real-valued `r * U * (1 - RF)`.            |
| [`testFuzz_continuity_noDownwardStepAcrossTheKink`](../../test/fuzz/InterestRateModel.t.sol#L111)           | Sweeping deltas around the kink, the curve never steps downward anywhere.                  |

---

## 3. `IndexPrecision.t.sol` — 4 tests

The executable justification for the `1e15` index scale over a RAY (1e27) alternative ([Guide 5, Section 2](../05-implementation.md#2-core-data-structures)). This is the one suite where magnitude, not direction, is part of the claim — because the claim *is* about how much precision the coarse scale gives up.

| Test                                                                                                        | Asserts                                                                                |
| :-------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------- |
| [`testFuzz_indexScale_neverFavorsTheSupplier`](../../test/fuzz/IndexPrecision.t.sol#L66)                    | Against the same accrual carried at RAY precision and floored identically at each step, the coarse scale never over-credits (the load-bearing half), and the gap is bounded by a single base unit, 1e-6 USDC (the magnitude half). |
| [`testFuzz_indexScale_relativeErrorShrinksWithSize`](../../test/fuzz/IndexPrecision.t.sol#L98)              | The absolute gap stays at one base unit regardless of position size, so the relative gap falls below one part per billion for any position at or above `minBorrow`. |
| [`test_indexScale_assumesSixDecimalBase`](../../test/fuzz/IndexPrecision.t.sol#L124)                        | Pins the analysis to a 6-decimal base: the conclusion is coupled to that assumption and does not transfer to an 18-decimal base market unexamined. |
| [`test_indexScale_reportErrorAcrossPositionSizes`](../../test/fuzz/IndexPrecision.t.sol#L134)               | A reporting test that logs the measured gap across position sizes; the console output is the deliverable. The two indexes agree digit for digit — the RAY trailing zeros are padding, not signal. |
