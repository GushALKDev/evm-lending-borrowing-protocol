# Absorb Liquidation (Phase 6)

**Suites:** [`AbsorbLiquidationTest`](../../test/unit/AbsorbLiquidation.t.sol) (20 unit) · [`AbsorbLiquidationFuzzTest`](../../test/fuzz/AbsorbLiquidation.t.sol) (2 fuzz)
**Covers:** roadmap items 6.1 to 6.8 · [Guide 2, Sections 7-9](../02-mathematics.md#8-liquidation-math-absorb)

---

> The solvency valve. An account that crosses the liquidation threshold must be closable, in full, in one call, by anyone — and the collateral resale must recapitalize reserves at a bounded discount. Every test here is about one question: does the two-step (absorb, then buyCollateral) leave the protocol whole, with any loss recognized as bad debt the instant it occurs rather than lingering as an unliquidatable dust position?

## Reference position

```
10 WETH, liquidateCF 85%, LF 93%, storeFront 50%, base 1 USD
liq capacity at 2,000 = 10 * 2,000 * 0.85 = 17,000 USD    (absorbable above this)
```

The three settlement cases are driven by moving the WETH price after the borrow opens:

| Case      | Price | Seize  | Credit (× 0.93) | Debt   | Outcome                                    |
| :-------- | ----: | -----: | --------------: | -----: | :----------------------------------------- |
| Surplus   | 1,760 | 17,600 | 16,368          | 15,000 | +1,368 base credited to the account        |
| Exact     | 1,000 |  9,300 |  9,300          |  9,300 | account zeroed, reserves fall by the debt  |
| Shortfall | 1,400 | 14,000 | 13,020          | 15,000 | account zeroed, 1,980 recognized bad debt  |

---

## Eligibility (6.1)

| Test | Asserts |
| :--- | :------ |
| [`test_isLiquidatable_falseWhenHealthy`](../../test/unit/AbsorbLiquidation.t.sol#L91) | A position within the liquidation threshold is not absorbable |
| [`test_isLiquidatable_trueBelowThreshold`](../../test/unit/AbsorbLiquidation.t.sol#L96) | Debt above `liqCapacity` (10 × 1,760 × 0.85 = 14,960 < 15,000) flips it liquidatable |
| [`test_isLiquidatable_usesHighEdgeOfConfidenceBand`](../../test/unit/AbsorbLiquidation.t.sol#L103) | Confidence widens the collateral valuation to `price + conf`, so a noisy tick does not make an account absorbable |
| [`test_absorb_revertsWhenNotLiquidatable`](../../test/unit/AbsorbLiquidation.t.sol#L110) | `absorb` on a healthy account reverts `NotLiquidatable` with the debt and liq-capacity |

`_liquidationCapacity` is the twin of `_borrowCapacity`: same shape, but collateral valued at the *high* edge with `liquidateCF` instead of the low edge with `borrowCF`. Both directions are borrower-favorable, the opposite of the borrow check.

---

## Settlement (6.2-6.4)

| Test | Asserts |
| :--- | :------ |
| [`test_absorb_surplusCreditsAccountAndSeizesCollateral`](../../test/unit/AbsorbLiquidation.t.sol#L125) | Surplus: debt wiped, all collateral seized, bit cleared, `+1,368` base credited; the user claim leaves `totalsCollateral` (now 0) while `getCollateralReserves` holds the 10 WETH; reserves fall by the credit |
| [`test_absorb_shortfallRecognizesBadDebtAndZeroesAccount`](../../test/unit/AbsorbLiquidation.t.sol#L149) | Shortfall: account zeroed with no surplus, reserves fall by the *full debt* — the `1,980` gap is recognized bad debt |
| [`test_absorb_exactLeavesAccountAndReservesFlat`](../../test/unit/AbsorbLiquidation.t.sol#L165) | Exact: credit equals debt, account zeroed, reserves fall by exactly the debt |
| [`test_absorb_emitsDebtAndCollateralEvents`](../../test/unit/AbsorbLiquidation.t.sol#L179) | `AbsorbCollateral` (per asset, mid-price value) and `AbsorbDebt` (with the bad-debt figure) both fire |

Settlement routes through the single accounting path (`_updateBasePrincipal`), so the debt wipe and any surplus credit reconcile the totals exactly the same way supply, withdraw, and borrow do. Seizure decrements `totalsCollateral` in step with the zeroed user balance, so the seized inventory lives in `balanceOf(market) - totalsCollateral` and is recovered through `buyCollateral` ([Guide 3, ADR-7](../03-architecture.md#adr-7-collateral-total-as-user-claims-vs-whole-pool)).

---

## Multi-collateral

[`test_absorb_seizesEveryHeldCollateral`](../../test/unit/AbsorbLiquidation.t.sol#L196) redeploys with WETH + wBTC, opens a position against both, crashes the dominant leg, and asserts the seize loop clears *every* held asset and both `assetsIn` bits in one absorb.

---

## Quote and buy (6.5-6.6)

| Test | Asserts |
| :--- | :------ |
| [`test_quoteCollateral_appliesStorefrontDiscount`](../../test/unit/AbsorbLiquidation.t.sol#L245) | `discount = 0.50 × (1 − 0.93) = 3.5%`, askPrice `2,000 × 0.965 = 1,930`, so 1,930 base quotes 1 WETH |
| [`test_buyCollateral_sellsInventoryWhenReservesLow`](../../test/unit/AbsorbLiquidation.t.sol#L252) | With reserves below target, a buyer drains the seized inventory at the discounted ask |
| [`test_buyCollateral_revertsWhenReservesAtTarget`](../../test/unit/AbsorbLiquidation.t.sol#L272) | Above `targetReserves` the sale is closed: `NotForSale`. Inventory is only sold when reserves need it |
| [`test_buyCollateral_slippageGuard`](../../test/unit/AbsorbLiquidation.t.sol#L287) | `quote < minAmount` reverts `TooMuchSlippage` |
| [`test_buyCollateral_revertsOnInsufficientInventory`](../../test/unit/AbsorbLiquidation.t.sol#L301) | A buy exceeding `getCollateralReserves` reverts `InsufficientInventory` with the seized inventory available |
| [`test_buyCollateral_pausable`](../../test/unit/AbsorbLiquidation.t.sol#L358) | The `BUY` flag halts sales |

`buyCollateral` moves only cash and the physical collateral: the base paid in raises reserves through the derived formula (no principal changes, so no supplier is credited), and the collateral out touches no total. The inventory it may sell is `getCollateralReserves = balanceOf(market) - totalsCollateral`, never user-owned collateral ([Guide 3, ADR-7](../03-architecture.md#adr-7-collateral-total-as-user-claims-vs-whole-pool)). CEI ordering pulls base in before sending collateral out.

---

## Round-trip reserves (6.8)

[`test_absorbThenSell_neverReducesReservesAtStablePrices`](../../test/unit/AbsorbLiquidation.t.sol#L321) absorbs at 1,760 and sells the full 10 WETH back at the same price, asserting reserves end no lower than before the absorb — the protocol keeps the penalty-minus-discount margin.

## Collateral reserves semantics (ADR-7)

These pin the user-claims-only meaning of `totalsCollateral` and the derived-inventory guard on `buyCollateral` ([Guide 3, ADR-7](../03-architecture.md#adr-7-collateral-total-as-user-claims-vs-whole-pool)).

| Test | Asserts |
| :--- | :------ |
| [`test_buyCollateral_cannotSellUserOwnedCollateral`](../../test/unit/AbsorbLiquidation.t.sol#L375) | **Regression pin.** With a live 10 WETH user claim next to 10 WETH of seized inventory, a buy for 11 WETH (fits the old 20 WETH raw total, exceeds the seized inventory) reverts `InsufficientInventory`; a buy for exactly the seized 10 WETH succeeds and the user still withdraws their full claim |
| [`test_supplyCap_countsUserClaimsNotSeizedInventory`](../../test/unit/AbsorbLiquidation.t.sol#L418) | After an absorb removes 990 WETH of claims, the cap frees up: a fresh 1,000 WETH deposit is accepted even with 990 WETH of seized inventory custodied. The cap bounds user claims, not the whole pool |
| [`test_absorbBuyWithdraw_sequenceKeepsUserWhole`](../../test/unit/AbsorbLiquidation.t.sol#L444) | The absorb → buyCollateral → withdrawCollateral path the old semantics made unsafe: draining the seized inventory leaves an untouched user claim fully withdrawable |

## Pause flags (6.7)

[`test_absorb_pausable`](../../test/unit/AbsorbLiquidation.t.sol#L346) and [`test_buyCollateral_pausable`](../../test/unit/AbsorbLiquidation.t.sol#L358) confirm the guardian's `ABSORB`/`BUY` bits halt each path.

---

## Fuzz (6.8)

| Test | Asserts |
| :--- | :------ |
| [`testFuzz_absorb_settlesConsistently`](../../test/fuzz/AbsorbLiquidation.t.sol#L76) | For any liquidatable price, absorb always wipes the debt, seizes all collateral, clears the bit, never leaves the account owing, and reserves fall by `max(debt, creditBase)` |
| [`testFuzz_absorbThenSell_proceedsCoverCredit`](../../test/fuzz/AbsorbLiquidation.t.sol#L109) | A buy raises reserves by exactly the base paid in, and selling the whole seized inventory always returns at least the absorb *credit* |

> **Why `proceeds >= credit`, not `>= debt`.** Guide 2 Section 9's reserve-non-negativity claim holds only in the surplus/exact case. In the shortfall case, selling the inventory recovers the credit but not the full wiped debt; the gap is exactly the bad debt already recognized at absorb time. The unified property that holds across the *whole* price range is `proceeds >= creditBase`, so that is what the fuzz asserts, alongside the exact per-buy identity `dReserves == baseAmount`.
