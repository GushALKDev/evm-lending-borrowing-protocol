# Unit: Borrow & Repay (Phase 4)

**Suites:** [`BorrowRepayTest`](../../test/unit/BorrowRepay.t.sol) (38 unit) · [`BorrowCapacityFuzzTest`](../../test/fuzz/BorrowCapacity.t.sol) (6 fuzz)
**Covers:** roadmap items 4.1 to 4.7 · invariants INV-9, INV-10

---

> The negative-principal paths. Phase 3 could only move an account between zero and a positive balance; this phase opens the other half of the number line, so every test here is ultimately about one question: can an account end a call in a state the protocol would not have allowed it to enter?

## Reference position

Every unit test builds on one position, so the arithmetic stays checkable by hand:

```
10 WETH at 2,000 USD, borrowCollateralFactor 80%, base at 1 USD
capacity = 10 * 2,000 * 0.80 = 16,000 USD
```

Bob supplies 500,000 base in `setUp`, because a borrow draws on *someone else's* cash: without a funded pool the cash check fires before the capacity check and the test would be asserting the wrong guard. This bit the suite during development — see [`test_borrow_revertsWhenCashInsufficient`](../../test/unit/BorrowRepay.t.sol#L173), which pins that ordering deliberately.

---

## Borrow path (4.1)

| Test | Asserts |
| :--- | :------ |
| [`test_borrow_fromZeroOpensDebtAndSendsTokens`](../../test/unit/BorrowRepay.t.sol#L91) | A borrow from a zero balance leaves a negative principal, a debt, and tokens in the wallet |
| [`test_borrow_updatesGlobalTotals`](../../test/unit/BorrowRepay.t.sol#L103) | `totalBorrow` tracks the debt while `totalSupply` is untouched: borrowing moves cash, not the supply book |
| [`test_borrow_increasingAnExistingDebtStaysOnOnePath`](../../test/unit/BorrowRepay.t.sol#L112) | A second borrow accumulates rather than replacing |
| [`test_borrow_crossingFromSupplyToDebtInOneWithdrawal`](../../test/unit/BorrowRepay.t.sol#L123) | The sign crossing: supply side zeroed, debt equal to the overshoot, in one call |
| [`test_borrow_crossingKeepsTotalsSplitBySign`](../../test/unit/BorrowRepay.t.sol#L135) | **INV-1 across a crossing**: the account leaves the supply total *entirely* and arrives on the borrow total *whole* |
| [`test_borrow_emitsWithdraw`](../../test/unit/BorrowRepay.t.sol#L150) | The domain event fires with the borrowed amount |
| [`test_borrow_emitsNoTransferWhenNoSupplyIsBurned`](../../test/unit/BorrowRepay.t.sol#L160) | A pure borrow burns no supply, so the ERC20 mirror stays silent |
| [`test_borrow_revertsWhenCashInsufficient`](../../test/unit/BorrowRepay.t.sol#L173) | Capacity is not liquidity: a fully collateralized borrow still fails if the pool is drained |

The crossing tests are the load-bearing ones. There is no `borrow()` function and no branch on the crossing itself: `_updateBasePrincipal` decomposes both endpoints by sign, so a crossing is just one part going to zero as the other leaves zero. These two tests are what prove that decomposition is exact rather than merely plausible.

---

## Capacity check (4.2)

| Test | Asserts |
| :--- | :------ |
| [`test_capacity_borrowExactlyAtCapacitySucceeds`](../../test/unit/BorrowRepay.t.sol#L189) | The boundary is inclusive: `debt <= capacity` |
| [`test_capacity_borrowOneWeiPastCapacityReverts`](../../test/unit/BorrowRepay.t.sol#L199) | One wei past it is refused, with both values in the revert payload |
| [`test_capacity_confidenceBandShrinksCollateralValue`](../../test/unit/BorrowRepay.t.sol#L211) | Collateral valued at `price - conf`: a 100 USD band drops capacity to 15,200 |
| [`test_capacity_confidenceBandInflatesDebtValue`](../../test/unit/BorrowRepay.t.sol#L223) | Debt valued at `price + conf`: a 10% band makes 15,000 count as 16,500 |
| [`test_capacity_isZeroWithoutCollateral`](../../test/unit/BorrowRepay.t.sol#L234) | No collateral is no capacity, not an unbounded borrow |
| [`test_capacity_ignoresCollateralNotPosted`](../../test/unit/BorrowRepay.t.sol#L244) | Only assets in the `assetsIn` bitmap count; wallet holdings grant nothing |
| [`test_capacity_priceDropCanLeaveAnOpenPositionUncollateralized`](../../test/unit/BorrowRepay.t.sol#L251) | An open position can go underwater on price alone, with no action by the account |
| [`test_capacity_viewAgreesWithTheEnforcedCheck`](../../test/unit/BorrowRepay.t.sol#L263) | The public view never disagrees with the check that gated the borrow |
| [`test_capacity_sumsAcrossAssetsWithDifferentDecimals`](../../test/unit/BorrowRepay.t.sol#L284) | Capacity sums across assets, each scaled by *its own* decimals |

Two of these deserve their reasoning recorded.

**The view/check agreement test** exists because `isBorrowCollateralized` is `view` in `ILendingMarket` while pushing a price update is not. The implementation resolves that by splitting `_requireBorrowCollateralized` into a transactional `_pushPrices` followed by the `view` `_borrowCapacity` that both callers share. A view that could drift from the enforced check would be actively misleading to every integrator, so the agreement is asserted rather than assumed.

**The multi-decimal test** deploys a second market with 8-decimal wBTC alongside 18-decimal WETH. The capacity loop divides by `10 ** config.decimals` per asset; a scaling error there would be wrong by orders of magnitude, not by dust, and the single-collateral reference position cannot detect it. wBTC contributes `1 * 30,000 * 0.75 = 22,500` on top of WETH's 16,000, and the test pins both the accepted borrow at 38,500 and the refusal one wei past it.

---

## `minBorrow` dust guard (4.3, INV-10)

| Test | Asserts |
| :--- | :------ |
| [`test_minBorrow_revertsOnADustBorrow`](../../test/unit/BorrowRepay.t.sol#L357) | A 1 USDC borrow is refused despite ample capacity |
| [`test_minBorrow_borrowExactlyAtTheMinimumSucceeds`](../../test/unit/BorrowRepay.t.sol#L365) | The bound is inclusive |
| [`test_minBorrow_revertsWhenACrossingWouldLeaveDust`](../../test/unit/BorrowRepay.t.sol#L374) | A crossing landing between zero and `minBorrow` is dust too, even though nothing was "borrowed" |
| [`test_minBorrow_doesNotBlockRepayingToZero`](../../test/unit/BorrowRepay.t.sol#L386) | Repaying a position to exactly zero stays reachable |
| [`test_minBorrow_doesNotBlockAPartialRepayIntoTheDustBand`](../../test/unit/BorrowRepay.t.sol#L399) | Repaying 100 of a 150 debt succeeds and leaves 50, below `minBorrow`: repays are never dust-guarded |

The guard is enforced against the **resulting debt**, not the borrowed amount. That placement is what makes the third test pass, and the fourth and fifth are its necessary counterweight: a guard on "any debt below `minBorrow`" applied indiscriminately would trap a borrower in a position they could neither shrink nor close. Dust is forbidden on the way down, never on the way out, which is the form of INV-10 the invariant suite asserts.

---

## Repay path (4.4)

| Test | Asserts |
| :--- | :------ |
| [`test_repay_partialReducesDebt`](../../test/unit/BorrowRepay.t.sol#L413) | A partial repay shrinks the debt and creates no supply side |
| [`test_repay_exactAmountClosesThePosition`](../../test/unit/BorrowRepay.t.sol#L424) | An exact repay lands on principal zero, not near it |
| [`test_repay_overpaymentCrossesIntoSupply`](../../test/unit/BorrowRepay.t.sol#L436) | Overpaying crosses the sign the other way; the excess becomes supply |
| [`test_repay_crossingKeepsTotalsSplitBySign`](../../test/unit/BorrowRepay.t.sol#L447) | INV-1 across the reverse crossing |
| [`test_repay_maxSentinelRepaysExactlyTheDebt`](../../test/unit/BorrowRepay.t.sol#L459) | `type(uint256).max` pulls exactly the debt and not one wei more |
| [`test_repay_maxSentinelRevertsWithoutDebt`](../../test/unit/BorrowRepay.t.sol#L472) | The sentinel with no debt is an error, not a no-op |
| [`test_repay_maxSentinelClearsAccruedInterest`](../../test/unit/BorrowRepay.t.sol#L480) | The sentinel clears the debt *as accrued*, not as opened |
| [`test_repay_worksWithoutAnyPrice`](../../test/unit/BorrowRepay.t.sol#L499) | Repayment needs no oracle at all |

The last one is a liveness property worth stating plainly: repaying can only improve health, so it must never consult a price. The test wipes both feeds — making every `getPrice` call revert — and repays anyway. A borrower must be able to exit a position during exactly the oracle outage that would otherwise trap them.

---

## Accrue before action (4.5)

| Test | Asserts |
| :--- | :------ |
| [`test_accrual_growsDebtOverTime`](../../test/unit/BorrowRepay.t.sol#L518) | Interest compounds on the debt |
| [`test_accrual_borrowAccruesBeforeTheCapacityCheck`](../../test/unit/BorrowRepay.t.sol#L531) | `withdraw` values the debt *after* accrual when checking capacity |
| [`test_accrual_repayAccruesBeforeSettling`](../../test/unit/BorrowRepay.t.sol#L557) | `supply` settles the accrued debt, leaving no interest behind |

The borrow test is shaped to fail if the accrual were removed rather than merely to pass with it. It first asserts the *stale* reading would leave room to borrow, then asserts the call reverts `NotCollateralized` — an outcome only the accrued reading can produce. Asserting the post-state alone would pass just as happily against a contract that never accrued.

---

## Collateral withdrawal under debt

| Test | Asserts |
| :--- | :------ |
| [`test_withdrawCollateral_revertsWhenItWouldUndercollateralizeTheDebt`](../../test/unit/BorrowRepay.t.sol#L331) | Pulling collateral that the debt still needs is refused |
| [`test_withdrawCollateral_allowedWhileTheDebtStaysCovered`](../../test/unit/BorrowRepay.t.sol#L341) | Excess collateral is released while the position stays healthy |

Phase 3 wired this hook against the oracle but could never reach it, since debt was impossible. These are the first tests to execute it with a real negative principal.

---

## Pause interaction

| Test | Asserts |
| :--- | :------ |
| [`test_pause_withdrawFlagBlocksBorrowing`](../../test/unit/BorrowRepay.t.sol#L575) | `PAUSE_WITHDRAW` stops borrowing, since borrowing *is* withdrawing |
| [`test_pausedSupply_fullRepayCloses`](../../test/unit/BorrowRepay.t.sol#L596) | Under `PAUSE_SUPPLY` an exact repay closes the debt and leaves principal at zero |
| [`test_pausedSupply_partialRepayReducesDebt`](../../test/unit/BorrowRepay.t.sol#L608) | Under the pause a partial repay reduces the debt |
| [`test_pausedSupply_overRepayReverts`](../../test/unit/BorrowRepay.t.sol#L619) | One wei over the debt reverts `RepayExceedsDebtWhilePaused(amount, debt)`: the excess would open new supply |
| [`test_pausedSupply_repayAllSentinelClearsAccruedDebt`](../../test/unit/BorrowRepay.t.sol#L634) | The `type(uint256).max` sentinel pulls exactly the debt as accrued inside the call (6,576.8 USDC after a year at 1e10/s), leaving principal at zero |
| [`test_pausedSupply_repayBoundIsTheAccruedDebt`](../../test/unit/BorrowRepay.t.sol#L654) | The repay bound is the post-accrual debt, not the stale stored one: 6,000 USDC passes although it exceeds the pre-accrual 5,000, and the error carries the accrued 6,576.8 |
| [`test_pausedSupply_repayOnBehalfUsesTheDestination`](../../test/unit/BorrowRepay.t.sol#L678) | The pause is judged on `dst`: a supplier cannot supply to their own account, yet repays a debtor through `supplyTo`, paying exactly the debt with their own position untouched; a debtor cannot add supply to a non-debtor |
| [`test_pausedSupply_baseSupplyToANonDebtorReverts`](../../test/unit/BorrowRepay.t.sol#L701) | Positive and zero principal both revert `Paused`; the sentinel on a non-debtor reports the pause, not `ZeroAmount` |
| [`test_pausedSupply_debtorCanTopUpCollateral`](../../test/unit/BorrowRepay.t.sol#L715) | A debtor posts more collateral while paused; ledger and totals follow |
| [`test_pausedSupply_nonDebtorCollateralSupplyReverts`](../../test/unit/BorrowRepay.t.sol#L728) | An account with collateral but no debt cannot post more: that is exposure, not health |
| [`test_pausedSupply_supplyCapStillBindsForADebtor`](../../test/unit/BorrowRepay.t.sol#L737) | The pause exception does not lift the supply cap: `SupplyCapExceeded` still fires |
| [`test_pausedSupply_absorbStillRuns`](../../test/unit/BorrowRepay.t.sol#L753) | `absorb` keeps running on an underwater account while supply is paused |

`PAUSE_SUPPLY` stops new exposure, never risk reduction. Repay shares its entry point with supply, and until this was split a supply pause also froze every borrower out of repaying or adding collateral while `absorb` stayed live, so a debtor could be liquidated with no way to defend the position. The market now lets a repay (up to the debt, evaluated on `dst` after accrual) and a collateral top-up of an indebted account through the pause. Two mutants were run against these tests: failing every base supply under the pause fails the repay tests (and the stateful [`invariant_repayAlwaysAvailableWhileSupplyPaused`](./12-invariant.md#repay-under-pause_supply)), and accruing after the pause checks instead of before fails the two accrued-debt tests.

---

## Reentrancy

| Test | Asserts |
| :--- | :------ |
| [`test_reentrancy_hostileOracleCannotBorrowTwice`](../../test/unit/BorrowRepay.t.sol#L774) | A hostile oracle calling back into `withdraw` is refused, leaving no debt and no tokens moved |

This phase put an external call in the middle of a state-changing path: the borrow branch writes the principal, calls the oracle to push prices, and only then transfers tokens. That ordering is deliberate — the health check must see the position the account is actually left holding — but it means a hostile oracle receives control while the principal is already updated and the cash has not yet left. Without the `nonReentrant` guard on `withdraw`, it could borrow a second time against a single capacity check.

[`ReentrantPriceOracle`](../../test/mocks/ReentrantPriceOracle.sol) is that adversary: it reenters `withdraw` once from `updateAndGetPrice`. The test asserts the whole outer call reverts and the position is untouched, so the guard is demonstrated rather than argued from the modifier list.

---

## Fuzz properties (4.7, INV-9)

[`BorrowCapacityFuzzTest`](../../test/fuzz/BorrowCapacity.t.sol), 1,000 runs each.

| Property | Statement |
| :------- | :-------- |
| [`testFuzz_acceptedBorrowAlwaysLeavesTheAccountCollateralized`](../../test/fuzz/BorrowCapacity.t.sol#L73) | **INV-9.** Any borrow the market accepts leaves the account collateralized and above `minBorrow` |
| [`testFuzz_borrowAtOrBelowCapacityIsAccepted`](../../test/fuzz/BorrowCapacity.t.sol#L98) | The boundary from the other side: what fits is not refused |
| [`testFuzz_widerConfidenceNeverIncreasesCapacity`](../../test/fuzz/BorrowCapacity.t.sol#L122) | A wider confidence band can only lower capacity |
| [`testFuzz_repayNeverReducesHealth`](../../test/fuzz/BorrowCapacity.t.sol#L139) | Repaying never turns a healthy account unhealthy, nor increases the debt |
| [`testFuzz_crossingRoundTripNeverFavorsTheAccount`](../../test/fuzz/BorrowCapacity.t.sol#L167) | Borrow past a supply balance, repay the same amount: never lands ahead |
| [`testFuzz_acceptedBorrowNeverLandsInTheDustBand`](../../test/fuzz/BorrowCapacity.t.sol#L196) | **INV-10.** Every accepted borrow leaves a debt of zero or `>= minBorrow` |

The INV-9 property asserts on the calls that **succeed** rather than predicting which ones should. The contract decides what fits; the test only checks it never lies about the result. A test that recomputed capacity itself and asserted acceptance would be asserting its own arithmetic — and would pass even if both it and the contract were wrong in the same direction.

The two capacity properties bracket the boundary from opposite sides, which is what keeps them honest together: the first alone is satisfied by a contract that refuses *every* borrow, and the second alone by one that accepts every borrow. Neither is a useful property without the other.

`testFuzz_widerConfidenceNeverIncreasesCapacity` finds the true boundary by binary-searching the real contract with `withdraw`, reverting to a snapshot per probe. Slower than recomputing the formula, and deliberately so: it measures what the contract actually enforces rather than restating the formula the contract already implements.

---

## What these tests do not cover

- **Liquidation.** An account can now go underwater ([`test_capacity_priceDropCanLeaveAnOpenPositionUncollateralized`](../../test/unit/BorrowRepay.t.sol#L251)) and nothing can yet be done about it. `absorb` is Phase 6.
- **Real prices.** Everything runs against `MockPriceOracle`. Staleness, deviation, and fee mechanics are Phase 5.
- **Multi-account invariants.** The summed INV-1/INV-5 assertions across many accounts remain Phase 8.

See [Gaps & Roadmap](./07-gaps-and-roadmap.md).

---

## References

- [Testing Index](./README.md)
- [Guide 2, Section 7](../02-mathematics.md#7-collateralization-and-health) — the capacity formula these tests pin
- [ROADMAP Phase 4](../ROADMAP.md#phase-4-borrow--repay) — items and the decisions recorded at close
