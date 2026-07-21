# 🧮 Unit: Accounting Core

**Section:** [Testing Documentation](./README.md)
**Suite:** [`test/unit/LendingMarketAccounting.t.sol`](../../test/unit/LendingMarketAccounting.t.sol) — 36 tests
**Phase:** 1
**Prev:** [Strategy](./01-strategy.md) · **Next:** [Unit: Supply & Withdraw](./03-unit-supply-withdraw.md)

---

Phase 1 accounting core, tested against a mocked rate model so index behavior can be driven directly rather than through the curve. Reference: [Guide 2](../02-mathematics.md), [Guide 3, Section 3](../03-architecture.md#3-state-layout).

---

## Construction (1.2)

| Test                                                                                                        | Asserts                                                                                      |
| :---------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------- |
| [`test_constructor_seedsBothIndexesAtScale`](../../test/unit/LendingMarketAccounting.t.sol#L58)             | Both indexes start at `BASE_INDEX_SCALE` (1e15), so conversions are the identity at t=0.      |
| [`test_constructor_wiresImmutables`](../../test/unit/LendingMarketAccounting.t.sol#L64)                      | `BASE_TOKEN`, `BASE_SCALE`, `INTEREST_RATE_MODEL`, `ORACLE`, `GUARDIAN` all point where configured. |
| [`test_constructor_revertsOnZeroBaseToken`](../../test/unit/LendingMarketAccounting.t.sol#L72)               | `InvalidConfiguration("baseToken")` on the zero address.                                      |
| [`test_constructor_revertsOnZeroRateModel`](../../test/unit/LendingMarketAccounting.t.sol#L77)               | `InvalidConfiguration("interestRateModel")` on the zero address.                              |
| [`test_constructor_derivesBaseScaleFromTheToken`](../../test/unit/LendingMarketAccounting.t.sol#L85)         | Deploying against an 18-decimal token yields `BASE_SCALE == 1e18`: the scale is read from the token, never passed in, so a wrong literal cannot silently corrupt every base-denominated quantity. |
| [`test_constructor_revertsWhenBaseTokenHasNoDecimals`](../../test/unit/LendingMarketAccounting.t.sol#L94)    | `decimals()` is optional in the ERC20 standard, so a token without it fails at deployment rather than mid-operation. |

---

## Conversions (1.3)

| Test                                                                                                    | Asserts                                                                                      |
| :------------------------------------------------------------------------------------------------------ | :-------------------------------------------------------------------------------------------- |
| [`test_presentValue_isIdentityAtSeedIndexes`](../../test/unit/LendingMarketAccounting.t.sol#L104)       | At the seed indexes, present value equals principal on both sides.                             |
| [`test_presentValue_matchesDocumentedWorkedExample`](../../test/unit/LendingMarketAccounting.t.sol#L110) | The [Guide 2, Section 2](../02-mathematics.md#2-index-accounting-principal-and-present-value) worked example reproduced digit for digit: 10,000 supplied becomes principal 9,523,809,523; 15,000 borrowed becomes 13,888,888,889, and reading that debt back owes 15,000,000,001 — one unit more than borrowed, in the protocol's favor. |
| [`test_presentValueSupply_roundsDown`](../../test/unit/LendingMarketAccounting.t.sol#L125)              | Supply PV floors: principal 1 at index 1.05e15 reads 1, not 2.                                |
| [`test_presentValueBorrow_roundsUp`](../../test/unit/LendingMarketAccounting.t.sol#L131)                | Debt PV ceils: principal 1 at index 1.05e15 reads 2.                                          |
| [`test_principalValueSupply_roundsDown`](../../test/unit/LendingMarketAccounting.t.sol#L137)            | Supply principal floors: 1 unit of PV records as principal 0.                                 |
| [`test_principalValueBorrow_roundsUp`](../../test/unit/LendingMarketAccounting.t.sol#L143)              | Debt principal ceils: 1 unit of PV records as principal 1.                                    |
| [`test_signedConversions_dispatchOnSign`](../../test/unit/LendingMarketAccounting.t.sol#L149)           | The signed wrappers route positive principals to the supply primitive, negative to the borrow one, and map zero to zero in both directions. |

These four rounding sites are the ones that were mutation-verified; see [Mutation Checks](./06-mutation-checks.md).

---

## Single Accounting Path

Every phase routes principal writes through `updateBasePrincipal()`, so INV-1 has exactly one place it can break ([Guide 3, Section 7.4](../03-architecture.md#7-design-patterns)).

| Test                                                                                                              | Asserts                                                                             |
| :---------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------ |
| [`test_accountingPath_creditsSupplyTotal`](../../test/unit/LendingMarketAccounting.t.sol#L181)                    | A positive principal moves only `totalSupplyBase`.                                    |
| [`test_accountingPath_creditsBorrowTotal`](../../test/unit/LendingMarketAccounting.t.sol#L190)                    | A negative principal moves only `totalBorrowBase`.                                    |
| [`test_accountingPath_crossesSupplyToBorrow`](../../test/unit/LendingMarketAccounting.t.sol#L199)                 | The supply-to-debt crossing in a single write zeroes the supply side and opens the borrow side. This is the crossing INV-1 is most likely to break on. |
| [`test_accountingPath_crossesBorrowToSupply`](../../test/unit/LendingMarketAccounting.t.sol#L208)                 | The mirror crossing, debt to supply.                                                  |
| [`test_accountingPath_keepsTotalsPerAccountIndependent`](../../test/unit/LendingMarketAccounting.t.sol#L217)      | Two accounts on opposite sides do not contaminate each other's total.                 |
| [`test_accountingPath_zeroingClearsBothTotals`](../../test/unit/LendingMarketAccounting.t.sol#L226)               | Zeroing every account returns both totals to zero: no residue accumulates.             |

The same path is fuzzed across arbitrary sign crossings in [`ConversionRoundingTest`](./05-fuzz.md#inv-1-single-accounting-path).

---

## Utilization (1.5)

| Test                                                                                              | Asserts                                                                                          |
| :------------------------------------------------------------------------------------------------ | :------------------------------------------------------------------------------------------------ |
| [`test_utilization_isZeroOnEmptyMarket`](../../test/unit/LendingMarketAccounting.t.sol#L241)      | No division by zero on an empty market.                                                            |
| [`test_utilization_isZeroWhenSupplyIsZero`](../../test/unit/LendingMarketAccounting.t.sol#L245)   | Debt against zero supply cannot arise through user actions (INV-11), but the view still must not divide by zero if it is ever reached. |
| [`test_utilization_halfBorrowed`](../../test/unit/LendingMarketAccounting.t.sol#L252)             | 500 borrowed against 1,000 supplied gives exactly `0.5e18`.                                        |
| [`test_utilization_canExceedOne`](../../test/unit/LendingMarketAccounting.t.sol#L259)             | `U > 1e18` is reachable once reserves have been paid out ([Guide 2, Section 4](../02-mathematics.md#4-utilization)); the value matches the documented ~1.0588e18 example. |

---

## Rebasing Views (1.6)

| Test                                                                                             | Asserts                                                                                          |
| :----------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------ |
| [`test_views_reportOnlyTheMatchingSide`](../../test/unit/LendingMarketAccounting.t.sol#L272)     | A supplier reads zero debt and a borrower reads zero balance: the signed principal is never double-counted. |
| [`test_views_totalsTrackPrincipalTotals`](../../test/unit/LendingMarketAccounting.t.sol#L282)    | `totalSupply()` / `totalBorrow()` mirror the stored principal totals.                              |
| [`test_views_balancesRebaseWithIndexes`](../../test/unit/LendingMarketAccounting.t.sol#L291)     | Advancing the indexes to 1.05e15 / 1.08e15 grows a supplier's balance 5% and a borrower's debt 8%, with no per-account write: the rebasing property itself ([ADR-5](../03-architecture.md#adr-5-signed-principal-and-rebasing-erc20)). |

---

## Reserves (1.7)

| Test                                                                                                | Asserts                                                                                          |
| :-------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------ |
| [`test_reserves_areZeroOnEmptyMarket`](../../test/unit/LendingMarketAccounting.t.sol#L305)          | Empty market, zero reserves.                                                                       |
| [`test_reserves_countDonatedCashAsReserves`](../../test/unit/LendingMarketAccounting.t.sol#L309)    | A direct token donation lands in reserves rather than distorting any ledger ([Guide 4, Risk 10](../04-tradeoffs.md#risk-10-donation-attacks)). |
| [`test_reserves_areDerivedFromCashAndTotals`](../../test/unit/LendingMarketAccounting.t.sol#L314)   | Cash 400 + borrows 600 − supply 1,000 = 0: the fully lent, unprofitable state.                     |
| [`test_reserves_canBeNegative`](../../test/unit/LendingMarketAccounting.t.sol#L324)                 | `getReserves()` is signed on purpose: bad debt must be representable, not clamped away.            |

---

## Accrual (1.4)

| Test                                                                                                  | Asserts                                                                                       |
| :---------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------- |
| [`test_accrue_isNoopWithinTheSameBlock`](../../test/unit/LendingMarketAccounting.t.sol#L333)          | Zero elapsed time leaves both indexes untouched even with rates configured.                     |
| [`test_accrue_advancesBothIndexes`](../../test/unit/LendingMarketAccounting.t.sol#L342)               | One year at 4%/2% APR lands the borrow index near 1.04e15 and the supply index near 1.02e15, with the borrow index strictly ahead. |
| [`test_accrue_updatesLastAccrualTime`](../../test/unit/LendingMarketAccounting.t.sol#L355)            | `lastAccrualTime` advances to the current block timestamp.                                      |
| [`test_accrue_atZeroRatesLeavesIndexesUntouched`](../../test/unit/LendingMarketAccounting.t.sol#L361) | A year at zero rates moves nothing: no drift from the accrual arithmetic itself.                |
| [`test_accrue_borrowIndexCeilsOnDustInterest`](../../test/unit/LendingMarketAccounting.t.sol#L371)    | At 1 wei/second for one second, the supply index floors to no change while the borrow index ceils up by 1: the rounding split at its smallest possible magnitude. |
| [`test_accrue_compoundsAcrossWindows`](../../test/unit/LendingMarketAccounting.t.sol#L382)            | The second half-year window grows the index by more than the first: accrual compounds rather than accumulating linearly. |

The arithmetic boundaries of `_accrue` are pinned separately in [`AccrualOverflowTest`](./04-unit-rate-model.md#3-accrualoverflowtsol--3-tests).
