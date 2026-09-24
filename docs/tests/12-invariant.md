# Invariant Suite (Phase 8)

**Suites:** [`InvariantsTest`](../../test/invariant/Invariants.t.sol) (17 invariants) · [`Handler`](../../test/invariant/Handler.sol)
**Covers:** roadmap items 8.1 to 8.4, 8.11 · [Guide 6, Section 2](../06-security.md#2-system-invariants)
**Config:** `runs = 1000`, `depth = 100`, `fail_on_revert = false` (foundry.toml `[invariant]`)

---

> The thesis of the project, run as executable stateful fuzzing. A single `Handler` drives the market through 100,000 bounded random calls per invariant (1,000 runs of 100 calls), and after every step the system invariants of Guide 6 must hold. A reverting handler call (an undercollateralized borrow, a withdrawal past cash) is a valid no-op, provided it reverts with one of the market's declared errors; everything else is latched and fails the suite. On its first full run this suite found a critical minting bug; see below.

## Handler design

One `Handler` contract wraps every mutating function with bounded random inputs, driving a fixed cast: 3 suppliers, 3 borrowers, 1 liquidator, plus owner and guardian. Actions: `supplyBase`, `withdrawBase`, `supplyCollateral`, `withdrawCollateral`, `transferBase`, `absorb`, `buyCollateral`, `withdrawReserves`, `warp` (time jumps up to 30 days, running a pure `accrue`), `movePrice` (oracle steps within and beyond the confidence band), `togglePause` (the owner sets a random flag set over all six bits, `WITHDRAW` and `BORROW` on about a sixteenth of the time and the other four about a quarter, weighted twice so guardian flags get cleared), `guardianPause` (the guardian adds one flag on top of the current set; a drawn `WITHDRAW` or `BORROW` is kept one time in four and otherwise swapped for one of the other four), and `repayWhileSupplyPaused` (see [below](#repay-under-pause_supply)). While reserves are positive, one `withdrawBase` call in four is a supplier exit sized to the smaller of the actor's balance and the cash on hand, the only way to drain cash to zero and push utilization above 100% (see [reachability](#reachability-across-seeds)). Ghost variables track every base inflow/outflow (for INV-5) and the reserves around every action (for INV-4). Per-action properties (the reserve table, INV-9, INV-10, absorb eligibility, a repay refused under `PAUSE_SUPPLY`, new risk under `PAUSE_BORROW`, undeclared reverts) are latched by the handler right after the action and asserted by a global invariant. The WETH supply cap is 500, low enough that the borrowers' supplies reach it inside a run, so INV-8 is exercised at the bound. Seed liquidity is 100,000 USDC and `supplyBase` is bounded to 50,000 per call, small against the borrowers' capacity, so sequences sweep utilization from zero through the kink to above 100% (see below). The suite uses the **real** `InterestRateModel`, not a rate mock, so INV-4 tests the derived-rate theorem rather than an arbitrary rate.

## Invariants asserted

| Invariant | Property |
| :-------- | :------- |
| [`invariant_INV1_principalSumsMatchTotals`](../../test/invariant/Invariants.t.sol) | Exact integer equality: summed per-account principal (by sign) equals the stored `totalSupplyBase` / `totalBorrowBase`. The anchor every other accounting property leans on |
| [`invariant_INV2_indexesMonotoneAboveSeed`](../../test/invariant/Invariants.t.sol) | Both indexes stay at or above the seed. The suite used to also assert `borrowIndex >= supplyIndex`, which is false above `U = 1 / (1 - RF)` (see [utilization](#utilization-must-actually-move)) and held only because utilization never got there |
| [`invariant_INV4_pureAccrueDoesNotBleedReserves`](../../test/invariant/Invariants.t.sol) | A pure accrue does not lower reserves beyond a 1-wei rounding wobble (see note below) |
| [`invariant_INV5_cashConservation`](../../test/invariant/Invariants.t.sol) | The market's base balance equals the seed plus the ghost-tracked net of every recorded inflow and outflow: no base moves without an accounting entry |
| [`invariant_INV6_collateralTotalsMatchAndSolvent`](../../test/invariant/Invariants.t.sol) | `totalsCollateral == Σ userCollateral` (exact) and `balanceOf(market) >= totalsCollateral` (physical solvency), the ADR-7 property across sequences |
| [`invariant_INV7_bitmapMatchesCollateral`](../../test/invariant/Invariants.t.sol) | An `assetsIn` bit is set iff the account holds a positive collateral balance |
| [`invariant_INV9_noActionLeavesUndercollateralized`](../../test/invariant/Invariants.t.sol) | No successful health-reducing action leaves the acting account below the line (see note below) |
| [`invariant_INV11_noDebtWithoutSupply`](../../test/invariant/Invariants.t.sol) | `totalSupplyBase == 0` implies `totalBorrowBase == 0` |
| [`invariant_INV4_reserveDeltasMatchTheTable`](../../test/invariant/Invariants.t.sol#L242) | Every successful action moved reserves as the [Guide 2 Section 6 table](../02-mathematics.md#6-interest-split-and-reserve-growth) allows, exactly: supply, repay, withdraw, borrow, and transfer `>= 0`; collateral moves `== 0`; `buyCollateral` `== +baseAmount`; `absorb` `<= 0`; `withdrawReserves` `== -amount` |
| [`invariant_INV3_roundTripsFavorTheProtocolAtLiveIndexes`](../../test/invariant/Invariants.t.sol#L252) | Supply and debt round trips never favor the account at the indexes the sequence actually evolved, on every actor's real balance and debt plus fixed probes |
| [`invariant_INV8_collateralWithinSupplyCap`](../../test/invariant/Invariants.t.sol#L277) | `totalsCollateral <= supplyCap`, held as a global state since only a capped supply raises the total |
| [`invariant_INV10_noActionCreatesDustDebt`](../../test/invariant/Invariants.t.sol#L288) | The borrow branch of `withdraw` never leaves the acting account with `0 < debt < minBorrow` (see note below) |
| [`invariant_INV14_supplyRateAtMostBorrowRate`](../../test/invariant/Invariants.t.sol#L299) | `supplyRate <= borrowRate` at the utilization the sequence produced, within the promised domain `U <= 1e18` |
| [`invariant_absorbOnlyWhenLiquidatable`](../../test/invariant/Invariants.t.sol#L311) | `absorb` succeeded only on accounts `isLiquidatable` reported eligible, and never refused one it reported eligible |
| [`invariant_repayAlwaysAvailableWhileSupplyPaused`](../../test/invariant/Invariants.t.sol#L323) | While `PAUSE_SUPPLY` is set, a debtor with tokens and approval can always repay: no repay the handler attempted under the pause reverted (see note below) |
| [`invariant_noNewRiskWhileBorrowPaused`](../../test/invariant/Invariants.t.sol#L337) | While `PAUSE_BORROW` is set, no account's debt principal grows and no indebted account's collateral falls except through absorb (see note below) |
| [`invariant_everyRevertIsADeclaredError`](../../test/invariant/Invariants.t.sol#L347) | Every handler revert carried one of the 21 allowlisted errors, all declared by `ILendingMarket`: no panic, empty revert, or token error hid as a no-op |

### The INV-4 one-wei tolerance

INV-4 is a directional inequality, not an exact equality (Guide 2, Section 6): the residual of borrower interest minus supplier interest accrues to reserves, but `getReserves()` is read as the difference of two independently-rounded present values. At extreme fuzz states that difference can dip by a single wei on a pure accrue without any solvency loss. A separate deterministic test confirmed the dip never accumulates over repeated accruals (reserves grow cleanly in realistic positions), so 1 wei is the exact, justified tolerance, not a papered-over failure.

### Utilization must actually move

The suite originally seeded 10,000,000 USDC and let `supplyBase` add up to 1,000,000 per call. Against at most a few hundred WETH of borrower collateral, that diluted every borrow: temporary probe invariants showed utilization **never reached 10%** in 1.5M calls. The kink, the jump-rate regime, cash scarcity, and `U > 1` were never exercised, and a stateful INV-14 would have been vacuous (a mutant flipping the reserve-factor sign, which only bites above 91% utilization, passed it). Rebalanced to a 100,000 seed and 50,000 per supply, the same probes fail within a run at 50%, at the kink, and at 100% utilization, so sequences now reach each regime, and all 15 invariants hold there. Reaching `U > 1 / (1 - RF)` immediately broke one pre-existing assertion: INV-2 also required `borrowIndex >= supplyIndex`, which Guide 6 never states and which is false there, since the per-unit supply rate `r * U * (1 - RF)` exceeds `r`. Suppliers still earn less in total than borrowers pay, so reserves keep growing and both INV-4 invariants hold; the ordering assertion was removed, and the stateful INV-14 is restricted to the `U <= 1e18` domain Guide 6 promises.

### The reserve table has no tolerance

Only `warp` moves time, and it accrues, so every other action runs with `elapsed == 0`: its internal accrue is a no-op and its reserve delta is the directed conversion alone. The table bounds that exactly, so unlike the pure accrue it is asserted with no tolerance, and it holds over the 1,700,000 calls of a full default run. It is also the stateful check that pins rounding direction where the round trip cannot: with `presentValueBorrow` flipped to floor, the debt round trip `presentValue(principalValue(pv))` still lands at or above `pv` (a ceiled principal cannot floor back below an integer `pv`), so the live-index INV-3 passes by construction, while the table fails. The same blind spot of round trips is described in [Mutation Checks](./06-mutation-checks.md#the-finding-that-shaped-the-suite); the per-site exact-value fuzz tests remain the primary pin on each rounding direction.

### INV-10 binds the borrow branch only

Guide 6 used to state INV-10 over "any user-initiated action". The design never enforced that: a repay is health-improving, and blocking a partial repay that would leave `0 < debt < minBorrow` would stop a borrower who cannot close from reducing exposure. The dust guard lives only on the borrow branch of `withdraw`, and [`test_minBorrow_doesNotBlockAPartialRepayIntoTheDustBand`](../../test/unit/BorrowRepay.t.sol#L400) pins the repay side. The invariant asserts the enforced form, and Guide 6 now states it.

### Repay under PAUSE_SUPPLY

A supply pause must stop new exposure without stranding borrowers, since `absorb` stays live. `repayWhileSupplyPaused` makes that a stateful property instead of a unit example: it picks a borrower with debt, sets `PAUSE_SUPPLY` itself as the guardian (so the property is exercised on every call rather than only when a random toggle lands on it), mints the debt to a random payer (the debtor or a third party) and repays through `supplyTo` either a bounded amount in `[1, debt]` or the full-debt sentinel. Under those preconditions no revert is acceptable, so any revert is latched and `invariant_repayAlwaysAvailableWhileSupplyPaused` fails. The owner then restores the flags that were set before the call, so the rest of the sequence is not left paused.

A first draft let the guardian OR a random set of flags and left `PAUSE_SUPPLY` on after each repay, which made successful absorbs rare; the guardian now adds one flag per call and the repay action restores the flags it found. How early each state is reached is measured across seeds in [Reachability across seeds](#reachability-across-seeds). The success path also feeds INV-5 (the paid amount is a ghost inflow) and the reserve table (a repay never lowers reserves). Falsified by a mutant that reverts every base supply while paused: the invariant failed within its first ten runs with `Paused(1)`.

### No new risk under PAUSE_BORROW

Every handler action runs inside a `borrowGuard` modifier that snapshots the principal and WETH collateral of every actor before the action and, if `PAUSE_BORROW` was set when the action started, latches a violation when any actor's debt principal grew or an indebted actor's collateral fell, unless the action was `absorb`. Principal is the right measure: interest moves the borrow index, never the principal, so accrual cannot trip it. Before the market enforced the flag the invariant failed at run 169 with "debt principal increased"; with the flag it holds. Removing the collateral check fails it with "indebted account's collateral decreased", and checking only existing debt, or only opening debt, fails it with "debt principal increased".

Adding the sixth bit to the toggles, with each bit set half the time, left borrowing open about a quarter of the time and starved the absorb path; the toggle weights now in use are described under [Reachability across seeds](#reachability-across-seeds).

### Reachability across seeds

A green invariant says nothing if the handler never reaches the state it guards, so four temporary probe invariants are added, run per seed, and removed. Each one fails as soon as its state is reached, and the run at which it fails is recorded (`>1000` means never reached in 1,000 runs of 100 calls). Each seed was run three times: forge 1.7.1 does not repeat a campaign exactly even with a fixed seed, so a cell lists every value observed, the most frequent first (`231 / 525` means 231 in two of the three runs and 525 in the other):

```solidity
function invariant_probeAbsorb() public view { assertEq(market.getCollateralReserves(address(weth)), 0); }
function invariant_probeCap450() public view { assertLt(market.totalsCollateral(address(weth)), 450e18); }
function invariant_probeKink() public view { assertLt(market.getUtilization(), 0.8e18); }
function invariant_probeOver100() public view { assertLe(market.getUtilization(), 1e18); }
```

```bash
# once per seed; clearing the cache stops forge from replaying a failure persisted by an earlier run
rm -rf cache/invariant && forge test --match-test invariant_probe --fuzz-seed <seed>
```

Handler at the start of this measurement (each bit toggled about a quarter of the time, no supplier exits):

| Seed | Absorb | 450 WETH of the 500 cap | Kink (U >= 80%) | U > 100% |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 325 | 9 | 32 | >1000 |
| 2 | 22 | 0 | 57 | 653 |
| 3 | 58 | 2 | 17 | >1000 |
| 4 | 803 | 1 | 51 | >1000 |
| 5 | 552 | 3 | 78 | >1000 |
| 6 | 430 | 4 | 124 / 49 | >1000 |

Current handler (`WITHDRAW` and `BORROW` toggled about a sixteenth of the time, the guardian keeping a drawn `WITHDRAW` or `BORROW` one time in four, and full-cash supplier exits in one `withdrawBase` call in four while reserves are positive):

| Seed | Absorb | 450 WETH of the 500 cap | Kink (U >= 80%) | U > 100% |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 44 / 78 | 23 | 32 | 687 |
| 2 | 22 | 0 | 10 | 400 |
| 3 | 167 | 2 | 9 | 311 |
| 4 | 231 / 525 | 1 | 44 | 44 |
| 5 | 95 | 3 | 43 | 360 |
| 6 | 339 / 594 | 5 | 34 | 45 |

Utilization above 100% needs positive reserves and cash drained to zero, since cash equals supply minus borrows plus reserves. Random withdrawal amounts almost never leave cash at zero, which is why it was reached in one seed of six before. Lowering the pause frequencies alone did not change that (still one seed of six in a single run per seed); the full-cash exits did, and it is now reached in every seed, between run 44 and run 687. Draining cash while reserves were at or below zero only starved borrowers and lost the absorb in two seeds, hence the positive-reserves condition. The handler as of commit `af1bf51`, before the pause work, reached utilization above 100% in one seed of six as well (one run per seed):

| Seed | Absorb | 450 WETH of the 500 cap | Kink (U >= 80%) | U > 100% |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 203 | 12 | 8 | >1000 |
| 2 | 2 | 6 | 8 | >1000 |
| 3 | 277 | 3 | 6 | >1000 |
| 4 | 123 | 2 | 9 | 228 |
| 5 | 14 | 8 | 62 | >1000 |
| 6 | 469 | 2 | 48 | >1000 |

Earlier versions of this page reported utilization above 100% "within the first run". Those figures came from failures that forge had persisted in `cache/invariant` and replayed; they were not reproducible and are replaced by the tables above.

### Revert-reason allowlist

`fail_on_revert = false` is what lets a rejected action be a harmless no-op, but it also lets an arithmetic panic or a token error pass silently. Every handler `catch` therefore inspects the revert data and latches anything whose selector is not one of the market's declared errors. None fires over the 1,700,000 calls of a full default run.

### Falsification

Each new invariant was checked against a targeted mutant of `src/`, or of the handler for the allowlist, run at the default depth on the rebalanced liquidity and then reverted:

| Mutant | Fails |
| :----- | :---- |
| `_principalValueSupply` floor flipped to ceil | `invariant_INV4_reserveDeltasMatchTheTable` (on `supplyBase`, by run 18 in seeds 1 to 6) and `invariant_INV3_roundTripsFavorTheProtocolAtLiveIndexes` (at runs 212 to 508 in seeds 1 to 6) |
| `_presentValueBorrow` ceil flipped to floor | `invariant_INV4_reserveDeltasMatchTheTable` only; the live-index INV-3 passes by construction (see above) |
| `minBorrow` guard removed from `_withdrawBase` | `invariant_INV10_noActionCreatesDustDebt` |
| Supply-cap check removed from `_supplyCollateral` | `invariant_INV8_collateralWithinSupplyCap` (total reached 558 WETH) |
| `absorb` eligibility check removed | `invariant_absorbOnlyWhenLiquidatable` (absorbed a healthy account) |
| `isLiquidatable` view valued with `borrowCF` instead of `liquidateCF` | `invariant_absorbOnlyWhenLiquidatable` (the view and the check disagree) |
| Reserve-factor sign flipped in `getSupplyRate` | `invariant_INV14_supplyRateAtMostBorrowRate` (needs utilization above 91%, unreachable before the rebalance) |
| `NotCollateralized` dropped from the allowlist | `invariant_everyRevertIsADeclaredError` |
| Every base supply reverts `Paused` while `PAUSE_SUPPLY` is set | `invariant_repayAlwaysAvailableWhileSupplyPaused` |
| `PAUSE_BORROW` not enforced on collateral withdrawals | `invariant_noNewRiskWhileBorrowPaused` |
| `PAUSE_BORROW` enforced only on existing debt, not on opening it | `invariant_noNewRiskWhileBorrowPaused` |

A separate probe (temporary invariants asserting that `absorb`, `buyCollateral`, and a borrow never succeed) failed within 65 calls each, confirming the liquidation and borrow paths are reached, not just called.

### INV-9 is per-action, not global

INV-9 ("no action ends undercollateralized") is not a global state invariant: a `movePrice` down-step can legitimately push an existing position below the health line with no action at fault; that is exactly the absorb-eligible state the liquidation path exists to clear. Asserting `isBorrowCollateralized` over every actor after every step would false-fail on healthy protocol behavior. So the handler latches a violation **only** when a successful health-reducing action (the borrow branch of `withdrawBase`, or `withdrawCollateral`) leaves the *acting* account below the line, and the global `invariant_INV9_noActionLeavesUndercollateralized` asserts that latch never tripped. `fail_on_revert = false` also forces the latch pattern: a bare `require` inside a handler is swallowed as a discarded call, so the check has to survive to a real invariant assertion. Falsified (temporarily latching on any opened borrow makes it fail), which also confirms the borrow branch is reached and the check is not vacuous.

## Bug found: self-transfer minted balance

On its first full run the suite broke INV-1. The shrunk sequence was a single `transfer(self)`: an account transferring base to itself.

**Cause.** In `_transferBase`, with `from == to` the read-both-then-write-both path read the same stale principal twice and the second `_updateBasePrincipal` clobbered the first, so the account's balance rose by `amount` out of thin air and `totalSupplyBase` rose with it. A holder could double their balance repeatedly.

**Severity.** Impact HIGH (unbounded balance minting, protocol insolvency), likelihood HIGH (one call, trivial to trigger).

**Fix.** A `from == to` guard in `_transferBase` returns after the balance check and emits `Transfer`, touching no state. Pinned by the deterministic regression [`test_transfer_toSelfIsANoOp`](../../test/unit/SupplyWithdraw.t.sol) in `SupplyWithdrawTest`.

This is exactly what the provable-solvency thesis is for: the invariant suite justified its existence on its first run.
