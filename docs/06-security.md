# 🔒 Guide 6: Security

**Version:** 1.0
**Prerequisites:** [Guide 5: Solidity Implementation](./05-implementation.md)
**Next:** [Documentation Index](./README.md)

---

## 📋 Table of Contents

1. [Threat Model](#1-threat-model)
2. [System Invariants](#2-system-invariants)
3. [Attack Vectors and Mitigations](#3-attack-vectors-and-mitigations)
4. [Adversarial Scenarios](#4-adversarial-scenarios)
5. [Pause and Circuit-Breaker Philosophy](#5-pause-and-circuit-breaker-philosophy)
6. [Audit Checklist](#6-audit-checklist)
7. [Testing Plan](#7-testing-plan)

---

## 1. Threat Model

### System Actors

| Actor                | Description                                  | Trust level  | Capabilities                                                    |
| :-------------------- | :--------------------------------------------- | :------------ | :----------------------------------------------------------------- |
| **Base supplier**    | Deposits USDC, holds lmUSDC                  | Untrusted    | Any call sequence, timing attacks, dust games                    |
| **Borrower**         | Posts collateral, borrows USDC               | Untrusted    | Health-boundary gaming, self-liquidation attempts                |
| **Liquidator bot**   | Calls `absorb` / `buyCollateral`             | Untrusted    | MEV, selective absorption, storefront timing                     |
| **Owner (multisig)** | Reserve withdrawal, pause set/clear          | Trusted, bounded | Cannot touch balances, parameters, or code ([Guide 5, Section 6](./05-implementation.md#6-access-control-matrix)) |
| **Pause guardian**   | Pause set only                               | Semi-trusted | Can freeze flows (including absorb); cannot unfreeze or steal    |
| **Pyth publishers**  | Primary price source                         | Semi-trusted | Bounded by confidence checks, deviation anchor, staking slashing |
| **Chainlink**        | Deviation anchor                             | Semi-trusted | A stalled anchor blocks prices (fails closed)                    |
| **Circle (USDC)**    | Base token issuer                            | Trusted external | Can blacklist the market address or upgrade the token: accepted platform risk |
| **Attacker**         | Any external agent                           | Untrusted    | All of the above combined, flash loans, reorgs                   |

### Critical Assets

| Asset                  | Location             | Value at risk        | Protection                                              |
| :---------------------- | :-------------------- | :-------------------- | :-------------------------------------------------------- |
| Base cash (USDC)       | `LendingMarket.sol`  | Total pool           | CEI + reentrancy guard, directed rounding, health checks |
| Collateral (WETH/wBTC) | `LendingMarket.sol`  | All posted collateral | Internal ledgers, absorb-only seizure, no owner access   |
| Accounting integrity   | Principals + indexes | Everything, indirectly | INV-1..5 below, single accounting path                  |
| Price integrity        | Oracle pipeline      | Everything, indirectly | 4-check pipeline, dual source, confidence bands         |
| Owner key              | External multisig    | Reserves + liveness  | 2-step transfer, powers minimized by construction        |

Out of scope of this model: L1 consensus failures, Solidity compiler bugs, and Circle acting maliciously against its own token holders.

### Asset-listing restrictions

Collateral inventory available to `buyCollateral` is derived as `token.balanceOf(market) - totalsCollateral` ([Guide 3, ADR-7](./03-architecture.md#adr-7-collateral-total-as-user-claims-vs-whole-pool)). This derivation constrains which collateral tokens may be listed:

1. **No transfer callbacks.** A token with a pre-transfer hook (ERC-777 style) could reenter `buyCollateral` while its balance is momentarily stale and read too large an inventory. The `nonReentrant` guard closes the direct reentrancy path; the listing restriction closes the residual stale-balance surface. This is the same caveat and mitigation Comet documents for its own derived reserves.

2. **`totalsCollateral` must never overstate the physical balance.** Every protocol path preserves `balanceOf(market) >= totalsCollateral`, so the derivation's checked subtraction never underflows. Two token behaviors break that:
   - **Balance that falls outside a protocol call** (a rebasing-down LST after a slashing event): `balanceOf` drops below `totalsCollateral` with no protocol action.
   - **Fee-on-transfer**: `_supplyCollateral` credits the requested `amount` to `totalsCollateral` but the token delivers less, so the total overstates the balance from the first deposit.

   In both cases `getCollateralReserves` reverts. The failure mode is **availability, not solvency**: `buyCollateral` becomes unusable for that asset because the checked math reverts rather than corrupting any accounting, and user claims (`totalsCollateral`, `userCollateral`) stay intact and withdrawable. Such tokens must not be listed.

Only plain ERC-20 collateral satisfying both is listable. The reference set (WETH, wBTC) does.

---

## 2. System Invariants

These properties must hold after every transaction. They are the specification the invariant suite (Section 7) executes.

**A definitional note first.** The identity `cash + totalBorrow(PV) == totalSupply(PV) + reserves` is *not* listed as an invariant: `getReserves()` is defined as `cash + totalBorrowPV - totalSupplyPV` ([Guide 3, Section 3.4](./03-architecture.md#34-reserves-are-derived-never-stored)), so the identity holds by definition and testing it would test nothing. The load-bearing, falsifiable content lives in INV-1 (exact principal sums), INV-3/INV-4 (directed rounding), and INV-5 (cash conservation): together they imply the solvency statement the identity is usually taken to mean.

### Accounting invariants

```
INV-1 (LOAD-BEARING, exact integer equality):
    sum over all accounts of max(principal, 0)  == totalSupplyBase
    sum over all accounts of max(-principal, 0) == totalBorrowBase

INV-2: baseSupplyIndex and baseBorrowIndex are monotonically non-decreasing
       and always >= BASE_INDEX_SCALE

INV-3 (directed rounding): for every conversion round trip,
    presentValue(principalValue(pv)) <= pv            for supply balances
    |presentValue(principalValue(pv))| >= |pv|        for debt balances

INV-4 (rounding residual accrues to reserves): getReserves() is
    non-decreasing under every operation except absorb and withdrawReserves;
    accrue() increases it by at least the reserve-factor share of borrower
    interest (the directional inequality of Guide 2, Section 6)

INV-5 (cash conservation): baseToken.balanceOf(market) equals the ghost-tracked
    net of all recorded inflows and outflows: no base moves without an
    accounting entry
```

INV-1 is exact, index-free, and integer: it is the anchor every other accounting property leans on, and the first thing an auditor should try to break (sign-crossing paths, absorb settlement, ERC-20 transfers).

### Collateral invariants

```
INV-6: for every collateral asset (see Guide 3, ADR-7):
    totalsCollateral[asset] == sum of userCollateral[*][asset]      (exact, by construction)
    token.balanceOf(market)  >= totalsCollateral[asset]             (gap = seized inventory
                                                                     + donations; O(1) solvency)

INV-7: userCollateral[a][i] > 0  <=>  assetsIn bit i of account a is set

INV-8: totalsCollateral[asset] <= supplyCap at every supply acceptance
```

### Position invariants

```
INV-9:  every mutating call that can reduce an account's health ends with
        isBorrowCollateralized(account) == true; health-improving calls
        (supply, repay, transfers received) are legal on any account

INV-10: after any user-initiated action: borrowBalanceOf(account) == 0
        or borrowBalanceOf(account) >= minBorrow

INV-11: totalSupplyBase == 0  =>  totalBorrowBase == 0
        (debt cannot exist against an empty pool)
```

### Static configuration invariants (constructor-enforced, hold forever by immutability)

```
INV-12: 0 < borrowCF < liquidateCF < FACTOR_SCALE for every collateral;
        0 < kink < 1e18;  slopeHigh >= slopeLow;  RF < 1e18

INV-13 (absorb coverage condition, Guide 2 Section 8):
    liquidationFactor >= liquidateCollateralFactor
                         * (FACTOR_SCALE + MAX_CONFIDENCE_BPS) / FACTOR_SCALE
```

### Rate invariants

```
INV-14: getSupplyRate(U) <= getBorrowRate(U) for all U in [0, 1e18];
        both monotone non-decreasing in U; continuous at the kink;
        both return for every utilization the market can produce (bounded to
        ~[0, 1e18] by the accounting), the unclamped kinked curve as in Aave
```

---

## 3. Attack Vectors and Mitigations

| # | Vector                             | Mitigation                                                                                  | Status              |
| :- | :---------------------------------- | :--------------------------------------------------------------------------------------------- | :------------------- |
| 1 | Reentrancy via token callbacks     | CEI everywhere + `nonReentrant` on token-moving functions; USDC/WETH/wBTC have no hooks anyway | Structural          |
| 2 | Oracle price manipulation          | Dual source + confidence + deviation checks; no AMM spot reads ([Guide 4, Risk 1](./04-tradeoffs.md#risk-1-oracle-manipulation)) | Mitigated, bounded residual |
| 3 | Stale-price execution              | Staleness checks on both sources; fails closed                                              | Structural          |
| 4 | Confidence-band gaming (tiny manipulations flipping health) | Band edges assigned against the user in every context ([Guide 2, Section 7](./02-mathematics.md#7-collateralization-and-health)) | Structural |
| 5 | Share-price inflation / first depositor | No share price exists ([Guide 4, Risk 9](./04-tradeoffs.md#risk-9-first-depositor--share-inflation-attack)) | Absent by construction |
| 6 | Donation-based accounting distortion | All ledgers internal; base donations become reserves ([Guide 4, Risk 10](./04-tradeoffs.md#risk-10-donation-attacks)) | Absent by construction |
| 7 | Rounding-direction money pump      | Global protocol-favorable policy + INV-3/INV-4                                              | Structural          |
| 8 | Absorbing a healthy account (griefing) | `isLiquidatable` at `price + conf` checked on-chain; reverts `NotLiquidatable`           | Structural          |
| 9 | Profitable self-absorption         | The absorbed account always loses the `(1 - liquidationFactor)` penalty; absorbing yourself burns value | Economic |
| 10 | Storefront drain (buying inventory below replacement) | Discount capped by the penalty already charged; sale gated by `reserves < targetReserves`; quote floors ([Guide 2, Section 9](./02-mathematics.md#9-buycollateral-pricing)) | Structural |
| 11 | Utilization / rate manipulation    | Accrue-before-action ordering; attacker pays the distorted rate ([Guide 4, Risk 5](./04-tradeoffs.md#risk-5-interest-rate-and-utilization-manipulation)) | Economic |
| 12 | Dust-debt griefing (debts too small to absorb) | `minBorrow` (INV-10)                                                             | Structural          |
| 13 | Unbounded loops                    | Health/absorb iterate the `assetsIn` bitmap: at most the number of listed collaterals (2)   | Structural          |
| 14 | Index overflow                     | `uint64` at `1e15` reverts on overflow (checked math) rather than wrapping; bound analyzed in [Guide 5, Section 2](./05-implementation.md#2-core-data-structures) | Accepted (revert-safe) |
| 15 | Owner key compromise               | Powers bounded to reserves + pause; no parameter, code, or balance access ([Guide 5, Section 6](./05-implementation.md#6-access-control-matrix)) | Bounded |
| 16 | Guardian key compromise            | Can pause (including absorb) but never unpause-block the owner, steal, or reconfigure; worst case converts to Scenario S2-style delayed absorption | Bounded |
| 17 | USDC blacklist of the market       | None possible on-chain; accepted platform risk, disclosed in the threat model               | Accepted            |
| 18 | Pyth fee griefing (underpaid updates) | `InsufficientFee` revert + surplus refund path; caller funds their own update           | Structural          |

---

## 4. Adversarial Scenarios

Explicit modeling of the states the protocol is designed to survive. Reference parameters from [Guide 2, Section 11](./02-mathematics.md#11-configurable-parameters); the running position is the [Guide 2 worked example](./02-mathematics.md#8-liquidation-math-absorb) (10 WETH collateral, 15,000 USDC debt, absorbable below 1,764 USD).

### S1: Fast collateral crash (liquidation stress)

**Setup.** WETH falls 20% in minutes: 2,000 -> 1,600. The account crosses the absorb threshold at 1,764.

**Prompt path.** A bot absorbs at 1,750: credit `= 17,500 * 0.93 = 16,275 > 15,000` debt. Surplus 1,275 credited to the borrower, zero bad debt, reserves dip by 16,275 and recover 16,887 at sale (discount 3.5%). Protocol nets positive. INV-4 unaffected (absorb is the permitted exception).

**Gapped path.** No absorb until 1,600: credit `= 16,000 * 0.93 = 14,880 < 15,000`. Bad debt `= 120` recognized instantly, reserves fall by 15,000, sale recovers `15,440`. Net protocol gain still positive here; a fall to 1,400 (Guide 2 example) leaves a net reserve loss of 1,490. **The bound:** per absorbed account, reserve loss `<= debtPV - seizeValue * (1 - discount)`, monotone in the gap size, and never hidden: `AbsorbDebt.badDebt` emits it.

### S2: Oracle outage during a drawdown

**Setup.** Pyth halts for 30 minutes while WETH drifts down 6%. All absorbs revert by policy ([Guide 3, Oracle Failure Policy](./03-architecture.md#oracle-failure-policy-accepted-risk)).

**During.** Borrowers can still repay and supply collateral (no oracle needed): rational ones save themselves. Nobody can borrow or withdraw collateral against stale prices: the attack surface is closed, not open.

**After.** Absorbs resume at post-drop prices. Accounts that crossed the threshold mid-outage are absorbed as in S1's gapped path; the extra bad debt is bounded by (drift beyond the `liquidateCF -> LF` margin) x (debt that crossed during the window). With the reference margin of 6.3% ([Guide 2, Section 8](./02-mathematics.md#8-liquidation-math-absorb)), a 6% outage drift produces near-zero bad debt; a 15% flash crash during an outage does not, and lands on reserves.

**Judgment encoded.** Liquidating at unverifiable prices would convert *every* outage into potential wrongful liquidations; refusing converts *severe* outages into bounded reserve losses. The protocol chooses the second, explicitly.

### S3: Correlated crash and reserve exhaustion (insolvency modeling)

**Setup.** WETH and wBTC fall 30% together; total absorbed bad debt 180,000 USDC against 100,000 of reserves.

**Mechanics.** Absorbs still execute (they need reserves accounting-wise, not cash): `getReserves()` goes to `-80,000`. The market keeps operating: accrual, repayments, and the reserve factor keep pulling reserves back up; every `buyCollateral` of remaining inventory helps.

**Who bears it.** With negative reserves, `cash < totalSupplyPV - totalBorrowPV`: if every supplier exited now, the last `80,000` USDC of claims could not be paid. It is a visible, on-chain number, not a hidden hole: suppliers can price it, and the deficit shrinks every block that interest accrues. Recovery paths: organic (RF share + penalties + rounding residue), or manual (treasury donation, which by construction is a reserve injection).

**What does NOT happen.** No socialization writes down balances, no freeze of repayments, no minting. INV-1..3, INV-5 all hold throughout; insolvency is a *reserves* state, never an *accounting* state.

### S4: Bank run at high utilization

**Setup.** Panic withdrawals push `U` from 80% to 100%; remaining suppliers cannot exit.

**Mechanics.** Withdrawals revert on cash, never misaccount. The curve now charges 24% APR and pays 21.6%: borrowers are strongly pushed to repay (their debt compounds visibly), and external capital is pulled in by the highest supply rate available anywhere in the market's life. Each repayment frees exit liquidity in strict arrival order (no queue exists, gas priority decides).

**Bound.** Suppliers face delay, not loss: their claim keeps accruing the elevated rate while locked. The state is self-extinguishing unless every borrower simultaneously refuses to repay while paying 24% APR against overcollateralized positions, which is self-punishing.

### S5: Base asset (USDC) depeg

**Setup.** USDC trades at 0.95 USD; both Pyth and Chainlink track it (a real depeg, not an oracle error, so the deviation anchor stays quiet).

**Mechanics.** Debt is valued at `priceBase + conf` in USD: a falling base price *shrinks* every debt in USD terms, so borrower health improves and no wrongful absorbs occur. Suppliers hold claims denominated in USDC itself; the protocol owes them USDC and has USDC: no protocol-level insolvency is created by the depeg. The losers are whoever holds base exposure, exactly as if they held USDC in a wallet.

**Edge.** During the depeg's volatile window, wide confidence on the USDC feed may push `conf` past `MAX_CONFIDENCE_BPS` and revert price-consuming actions: the S2 analysis applies for that window.

---

## 5. Pause and Circuit-Breaker Philosophy

Principles, in priority order:

1. **Pause stops bleeding; it never seizes.** No pause flag touches balances, prices, or parameters. The maximum effect of any flag combination is "this market stands still".
2. **Exits and repayments are sacred.** `supply` (repayment path) and `accrue` are the mechanisms by which users and the protocol heal; pausing supply is justified only to stop deposits *into* a market with a confirmed accounting or oracle bug.
3. **Guardian adds, owner clears.** The guardian is a fast key that can only increase the paused set ([Guide 5](./05-implementation.md#6-access-control-matrix)); unpausing (declaring the incident over) requires the slower multisig. A compromised guardian is an availability problem, never a theft.
4. **`PAUSE_ABSORB` is the last resort.** Absorb is the solvency valve: pausing it with honest prices manufactures bad debt (S2 dynamics, by choice instead of outage). The only justified use is a *confirmed corrupted oracle that is passing its own checks*, where absorbs would be executing at wrong prices.
5. **Views and `accrue` are never pausable.** Observability during an incident is part of the security model.

Scenario playbook:

| Incident                                        | Flags to set                       | Rationale                                            |
| :----------------------------------------------- | :---------------------------------- | :----------------------------------------------------- |
| Suspected accounting bug                        | `SUPPLY + TRANSFER + WITHDRAW + BUY` | Freeze exposure both ways; absorb stays live         |
| Oracle passing checks but confirmed wrong       | all five including `ABSORB`        | The one case where absorbing is worse than waiting   |
| Collateral token exploit (e.g. wBTC bridge)     | `SUPPLY + BUY`                     | Stop new exposure and inventory sales; exits continue |
| Governance/owner key incident                   | none (guardian watches)            | Owner powers cannot reach balances; rotate via 2-step |
| Market migration (end of life)                  | `SUPPLY`, later `+ TRANSFER`       | Wind down inflows, let positions close naturally     |

---

## 6. Audit Checklist

### Accounting

- [ ] INV-1 provable on every path that writes `principal`, `totalSupplyBase`, or `totalBorrowBase` (especially both sign-crossing directions and absorb settlement)
- [ ] Every division site matches the [Guide 2, Section 10](./02-mathematics.md#10-rounding-policy) direction catalogue
- [ ] `presentValue`/`principalValue` are the only conversion sites (no inline index math anywhere)
- [ ] `accrue()` is the first effect of every mutating function
- [ ] `type(uint256).max` repay path leaves exactly zero debt

### Solvency and liquidation

- [x] INV-13 coverage condition enforced in the constructor (reads `MAX_CONFIDENCE_BPS` from the oracle; tested at, below, and above the floor)
- [ ] Absorb settlement handles surplus, exact, and shortfall cases; bad debt emitted
- [ ] `buyCollateral` cannot sell user-owned collateral (guard is `quote <= getCollateralReserves = balanceOf(market) - totalsCollateral`, ADR-7)
- [ ] Storefront discount bounded by the liquidation penalty for every parameter combination
- [x] `withdrawReserves` bounded by both `getReserves()` and cash (onlyOwner, nonReentrant, accrues first)

### Oracle

- [ ] All four checks execute on both `updateAndGetPrice` and view `getPrice`
- [ ] Confidence band edge matches context (`- conf` capacity, `+ conf` absorb eligibility)
- [ ] Decimal normalization correct for every feed (Pyth expo, Chainlink 8)
- [ ] Surplus ETH refund cannot be hijacked (refund to `msg.sender` only, after effects)

### Access control and tokens

- [ ] Matrix in [Guide 5, Section 6](./05-implementation.md#6-access-control-matrix) matches the code exactly
- [ ] Guardian cannot clear any flag; owner two-step verified
- [ ] `SafeERC20` on all transfers; no code path assumes transfer return values
- [ ] ERC-20 `transfer` cannot push sender principal negative
- [ ] No function accepts `address(0)` where funds could burn

### Meta

- [ ] All Slither/Aderyn findings triaged in writing
- [ ] Test suite from Section 7 green with coverage >95%
- [ ] Every ADR in [Guide 3](./03-architecture.md#8-architecture-decision-records) still matches the implemented behavior

---

## 7. Testing Plan

Four layers, mapping directly to [ROADMAP Phase 8](./ROADMAP.md#phase-8-invariant--fuzz-testing--audit-prep): unit, fuzz, invariant, and fork.

**Scope of fork testing.** The lending logic is original and self-contained, and is covered by the unit, fuzz, and invariant layers. Fork testing exists for a narrower purpose: validating the two real external dependencies the protocol integrates with, against a mainnet fork. It is not a fork of any lending protocol, and no lending logic is inherited from one. The mocked oracle stack remains the right tool for driving adversarial feed states (stale timestamps, wide confidence, deviating anchor) that healthy mainnet feeds never produce; fork testing is complementary, covering what a mock cannot reproduce.

### Invariant testing (Foundry stateful fuzzing)

**Handler design.** One handler contract wrapping every public mutating function with bounded random inputs, driving a cast of actors (3 suppliers, 3 borrowers, 1 liquidator, owner, guardian) plus a `warp` action (time jumps up to 30 days) and a `movePrice` action (oracle mock steps within and beyond confidence bounds). Ghost variables track: every base inflow/outflow (for INV-5), reserve values before/after each call (for INV-4), and per-account principal sums (for INV-1).

**Asserted properties per run:** INV-1 through INV-11 verbatim, plus: absorb-only-when-liquidatable, no action strands `0 < debt < minBorrow`, and `getReserves()` deltas match the per-operation monotonicity table in [Guide 2, Section 6](./02-mathematics.md#6-interest-split-and-reserve-growth).

**Config target:** `runs = 1000`, `depth = 100`, fail-on-revert off with reason allowlisting, plus one dedicated run with `PAUSE_*` flags randomly toggled to prove invariants hold under partial pauses.

### Fuzz testing (stateless, per function)

| Target                                | Property fuzzed                                                            |
| :------------------------------------- | :---------------------------------------------------------------------------- |
| `presentValue`/`principalValue`       | Round trips never favor the account (INV-3), across full index/principal domain |
| `getBorrowRate`/`getSupplyRate`       | INV-14: monotone, continuous at kink, supply <= borrow on `[0, 1e18]`, return for every reachable utilization (overflow only at a U ~1e33x full utilization, unconstructible) |
| Accrual                               | Index monotonicity over arbitrary `dt`; reserve delta >= RF share            |
| Health checks                         | Band-edge monotonicity: raising `conf` never improves capacity, never blocks absorb eligibility |
| Absorb settlement                     | `newBalance` reconstruction exact in all three cases; INV-1 preserved         |
| `quoteCollateral`                     | Quote monotone in `baseAmount`; discount <= penalty for all factor pairs      |
| Sign-crossing supply/withdraw         | Split accounting equals the sum of its parts, INV-1 after every crossing      |

### Integration testing (local, mocked oracle stack)

- Deploy the full stack (market, rate model, oracle) on a local anvil node with the Phase 5 mocks: a Pyth mock honoring the SDK interfaces and `MockChainlinkFeed` aggregators
- End-to-end lifecycle: supply, borrow, warp, repay with real accrual; absorb + buyCollateral through the payable price-update path, including the fee refund
- Adversarial feed states exercised through mock configuration: stale publish times, confidence beyond `MAX_CONFIDENCE_BPS`, anchor deviation beyond `MAX_DEVIATION_BPS`, mixed decimals (`1e18` WETH vs `1e8` wBTC)
- Rehearse the deployment script itself ([Guide 5, Section 7](./05-implementation.md#7-pre-deployment-checklist)) on the local node before sign-off

### Fork testing (mainnet fork, real external dependencies)

Two targets, and only two: the oracle integration and the token integration. Everything else is covered by the layers above.

**Oracle (`PythChainlinkOracle` against live Pyth and Chainlink).** This is the highest-value integration test in the project, because the Pyth pull mechanics cannot be faithfully mocked. Against the live Pyth pull contract and live Chainlink feeds on a mainnet fork:

- Real Pyth price update data (Hermes VAAs) accepted by `updatePriceFeeds`, not a mock that skips verification
- The real `updatePriceFeeds` fee: quoting it, forwarding `msg.value`, and sweeping the surplus refund back to the caller
- Pyth expo handling and decimal normalization to 18 decimals against real published expos
- Real Chainlink `latestRoundData` with its actual heartbeat and round metadata
- Staleness, confidence, and deviation checks evaluated against real values rather than hand-set ones

**Tokens (real USDC, WETH, wBTC).** `supply`, `withdraw`, `borrow`, `repay`, `absorb`, and `buyCollateral` exercised against the real mainnet token contracts (USDC as base, WETH and wBTC as collateral), funding accounts via `deal` or impersonation. This catches real-token behavior that `MockERC20` hides: USDC's proxy and 6-decimal semantics, the actual return-value and approval conventions of each token, and per-token transfer behavior on the paths that move value.

### Static analysis and coverage

- Slither + Aderyn in CI, zero unreviewed findings policy
- `forge coverage` >95% lines and branches on `src/`
- Mutation-style spot checks on the rounding sites: flip a `mulDivDown` to `mulDivUp` and confirm the suite fails (validates that the tests actually pin the direction)

---

**See also:**

- [Guide 2: Protocol Mathematics](./02-mathematics.md), the formulas behind every invariant
- [Guide 4: Trade-offs and Risk Matrix](./04-tradeoffs.md), risk-level view of the same material
- [ROADMAP Phase 8](./ROADMAP.md#phase-8-invariant--fuzz-testing--audit-prep), when each layer gets built
