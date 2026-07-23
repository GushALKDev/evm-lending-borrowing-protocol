# Invariant Suite (Phase 8)

**Suites:** [`InvariantsTest`](../../test/invariant/Invariants.t.sol) (8 invariants) · [`Handler`](../../test/invariant/Handler.sol)
**Covers:** roadmap items 8.1 to 8.4 · [Guide 6, Section 2](../06-security.md#2-system-invariants)
**Config:** `runs = 1000`, `depth = 100`, `fail_on_revert = false` (foundry.toml `[invariant]`)

---

> The thesis of the project, run as executable stateful fuzzing. A single `Handler` drives the market through 100,000 bounded random calls per run, and after every step the system invariants of Guide 6 must hold. A reverting handler call (an undercollateralized borrow, a withdrawal past cash) is a valid no-op, so only the post-state invariants are load-bearing. On its first full run this suite found a critical minting bug; see below.

## Handler design

One `Handler` contract wraps every mutating function with bounded random inputs, driving a fixed cast: 3 suppliers, 3 borrowers, 1 liquidator, plus owner and guardian. Actions: `supplyBase`, `withdrawBase`, `supplyCollateral`, `withdrawCollateral`, `transferBase`, `absorb`, `buyCollateral`, `withdrawReserves`, `warp` (time jumps up to 30 days, running a pure `accrue`), `movePrice` (oracle steps within and beyond the confidence band), and `togglePause`. Ghost variables track every base inflow/outflow (for INV-5) and the reserves around each pure accrue (for INV-4). The suite uses the **real** `InterestRateModel`, not a rate mock, so INV-4 tests the derived-rate theorem rather than an arbitrary rate.

## Invariants asserted

| Invariant | Property |
| :-------- | :------- |
| [`invariant_INV1_principalSumsMatchTotals`](../../test/invariant/Invariants.t.sol) | Exact integer equality: summed per-account principal (by sign) equals the stored `totalSupplyBase` / `totalBorrowBase`. The anchor every other accounting property leans on |
| [`invariant_INV2_indexesMonotoneAboveSeed`](../../test/invariant/Invariants.t.sol) | Both indexes stay at or above the seed, and the borrow index never falls below the supply index |
| [`invariant_INV4_pureAccrueDoesNotBleedReserves`](../../test/invariant/Invariants.t.sol) | A pure accrue does not lower reserves beyond a 1-wei rounding wobble (see note below) |
| [`invariant_INV5_cashConservation`](../../test/invariant/Invariants.t.sol) | The market's base balance equals the seed plus the ghost-tracked net of every recorded inflow and outflow: no base moves without an accounting entry |
| [`invariant_INV6_collateralTotalsMatchAndSolvent`](../../test/invariant/Invariants.t.sol) | `totalsCollateral == Σ userCollateral` (exact) and `balanceOf(market) >= totalsCollateral` (physical solvency), the ADR-7 property across sequences |
| [`invariant_INV7_bitmapMatchesCollateral`](../../test/invariant/Invariants.t.sol) | An `assetsIn` bit is set iff the account holds a positive collateral balance |
| [`invariant_INV9_noActionLeavesUndercollateralized`](../../test/invariant/Invariants.t.sol) | No successful health-reducing action leaves the acting account below the line (see note below) |
| [`invariant_INV11_noDebtWithoutSupply`](../../test/invariant/Invariants.t.sol) | `totalSupplyBase == 0` implies `totalBorrowBase == 0` |

### The INV-4 one-wei tolerance

INV-4 is a directional inequality, not an exact equality (Guide 2, Section 6): the residual of borrower interest minus supplier interest accrues to reserves, but `getReserves()` is read as the difference of two independently-rounded present values. At extreme fuzz states that difference can dip by a single wei on a pure accrue without any solvency loss. A separate deterministic test confirmed the dip never accumulates over repeated accruals (reserves grow cleanly in realistic positions), so 1 wei is the exact, justified tolerance — not a papered-over failure.

### INV-9 is per-action, not global

INV-9 ("no action ends undercollateralized") is not a global state invariant: a `movePrice` down-step can legitimately push an existing position below the health line with no action at fault — that is exactly the absorb-eligible state the liquidation path exists to clear. Asserting `isBorrowCollateralized` over every actor after every step would false-fail on healthy protocol behavior. So the handler latches a violation **only** when a successful health-reducing action (the borrow branch of `withdrawBase`, or `withdrawCollateral`) leaves the *acting* account below the line, and the global `invariant_INV9_noActionLeavesUndercollateralized` asserts that latch never tripped. `fail_on_revert = false` also forces the latch pattern: a bare `require` inside a handler is swallowed as a discarded call, so the check has to survive to a real invariant assertion. Falsified (temporarily latching on any opened borrow makes it fail), which also confirms the borrow branch is reached and the check is not vacuous.

## Bug found: self-transfer minted balance

On its first full run the suite broke INV-1. The shrunk sequence was a single `transfer(self)`: an account transferring base to itself.

**Cause.** In `_transferBase`, with `from == to` the read-both-then-write-both path read the same stale principal twice and the second `_updateBasePrincipal` clobbered the first, so the account's balance rose by `amount` out of thin air and `totalSupplyBase` rose with it. A holder could double their balance repeatedly.

**Severity.** Impact HIGH (unbounded balance minting, protocol insolvency), likelihood HIGH (one call, trivial to trigger).

**Fix.** A `from == to` guard in `_transferBase` returns after the balance check and emits `Transfer`, touching no state. Pinned by the deterministic regression [`test_transfer_toSelfIsANoOp`](../../test/unit/SupplyWithdraw.t.sol) in `SupplyWithdrawTest`.

This is exactly what the provable-solvency thesis is for: the invariant suite justified its existence on its first run.
