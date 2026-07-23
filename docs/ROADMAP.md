# 🗺️ ROADMAP: EVM Lending / Borrowing Protocol (PoC)

**Version:** 1.0
**Purpose:** Ordered implementation guide and progress tracker

---

## 📋 How to use this document

- **[ ]** = Pending
- **[~]** = In progress
- **[x]** = Completed
- **[!]** = Blocked / Requires decision

Each phase should be completed before moving to the next. Within each phase, the order is recommended but can be adjusted based on dependencies.

---

## 📊 Progress Summary

| Phase     | Name                                   | Items  | Completed | Progress |
| :-------- | :------------------------------------- | :----- | :-------- | :------- |
| 0         | Setup & Infrastructure                 | 6      | 6         | 100%     |
| 1         | Core: Index Accounting & Storage       | 8      | 8         | 100%     |
| 2         | Interest Rate Model                    | 6      | 6         | 100%     |
| 3         | Supply & Withdraw                      | 8      | 8         | 100%     |
| 4         | Borrow & Repay                         | 7      | 7         | 100%     |
| 5         | Oracle (Pyth + Chainlink)              | 10     | 10        | 100%     |
| 6         | Absorb Liquidation                     | 8      | 8         | 100%     |
| 7         | Reserves & Protocol Management         | 6      | 6         | 100%     |
| 8         | Invariant & Fuzz Testing + Audit Prep  | 11     | 5         | 45%      |
| 9         | Future Work (post-PoC)                 | 6      | 0         | 0%       |
| **TOTAL** |                                        | **76** | **64**    | **84%**  |

---

## Phase 0: Setup & Infrastructure

> **Objective:** Configure the development environment and base project structure.

- [x] **0.1** Initialize Foundry project (Solidity 0.8.26)
- [x] **0.2** Configure dependencies (OpenZeppelin v5, Solady, Pyth SDK)
- [x] **0.3** Folder structure (`src/`, `src/interfaces/`, `test/unit/`, `test/fuzz/`, `test/invariant/`, `test/integration/`, `test/fork/`, `script/`)
- [x] **0.4** Configure CI/CD (GitHub Actions: build, test, coverage)
- [x] **0.5** Setup linters (Solhint, Prettier)
- [x] **0.6** Repository documentation (README, LICENSE)

> **0.2 note:** OpenZeppelin v5.1.0 and Solady v0.1.26 are installed. The Pyth Solidity SDK is
> deliberately deferred to Phase 5, where the oracle is built; nothing before that phase imports it.

**Deliverables:**

- Repository configured and ready for development
- CI pipeline running tests automatically

---

## Phase 1: Core - Index Accounting & Storage

> **Objective:** The accounting skeleton of `LendingMarket.sol`: storage layout, principal/present-value conversions, and index accrual. No user-facing actions yet.
>
> **Dependencies:** Phase 0

- [x] **1.1** Interface `ILendingMarket` + custom error catalogue
- [x] **1.2** Storage layout: `MarketState`, `UserBasic` (signed `int104` principal + `assetsIn` bitmap), `CollateralConfig`, packed as documented
- [x] **1.3** Conversion pair `presentValue()` / `principalValue()` with directed rounding (supply rounds down, borrow rounds up)
- [x] **1.4** `accrue()`: supply/borrow index advancement over elapsed time (rates injected via `IInterestRateModel`, mockable)
- [x] **1.5** `getUtilization()`: handles `totalSupply == 0` and the `U > 1` edge
- [x] **1.6** Rebasing ERC20 views: `balanceOf`, `borrowBalanceOf`, `totalSupply`, `totalBorrow`
- [x] **1.7** `getReserves()`: derived `int256` reserves (`cash + totalBorrow - totalSupply`)
- [x] **1.8** Unit + fuzz tests: conversion round trips never favor the user, index monotonicity, accrual over arbitrary time gaps

> **1.6 note:** the rebasing balance views are implemented here. The full ERC20 surface
> (`transfer`, `approve`, `Transfer` event mirroring) belongs to Phase 3, item 3.5.
>
> **Single accounting path:** `updateBasePrincipal()` is built in this phase, ahead of any caller,
> so every later phase routes through it (Guide 3, Section 7.4).
>
> **Mutation checks:** all seven rounding sites (both `presentValue` directions, both
> `principalValue` directions, both index accruals, and utilization) were verified by flipping each
> direction and confirming the suite fails. Round-trip assertions alone did not catch a flipped
> `presentValueSupply`, so per-site exact-value fuzz assertions were added.

**Deliverables:**

- Deployable accounting core with indexes that accrue correctly
- Conversion math proven protocol-favorable under fuzzing

**Reference:** [02-mathematics.md](./02-mathematics.md), [03-architecture.md](./03-architecture.md)

---

## Phase 2: Interest Rate Model

> **Objective:** The kinked (jump-rate) borrow curve with derived supply rate, as a separate immutable contract.
>
> **Dependencies:** Phase 0 (parallel to Phase 1)

- [x] **2.1** Interface `IInterestRateModel`
- [x] **2.2** Contract `InterestRateModel.sol` with immutable parameters (`baseRate`, `slopeLow`, `slopeHigh`, `kink`, `reserveFactor`) and constructor sanity checks
- [x] **2.3** `getBorrowRate(utilization)`: kinked curve, per-second rates at 1e18 scale
- [x] **2.4** `getSupplyRate(utilization)`: `borrowRate * U * (1 - reserveFactor)`
- [x] **2.5** Wire the model into `LendingMarket.accrue()` (immutable address)
- [x] **2.6** Tests: continuity at the kink, monotonicity fuzz, `supplyRate <= borrowRate` for all U, rate identity (borrow interest == supply interest + reserve cut) fuzz

> **2.1 note:** the interface was written in Phase 1 alongside the other interfaces; verified here
> against the real curve.
>
> **2.6 note:** the "rate identity" is implemented as the **directional inequality** of
> [02-mathematics.md Section 6](./02-mathematics.md#6-interest-split-and-reserve-growth), not an exact
> equality: the two rates floor independently, so the residual accrues to reserves and no integer
> identity exists. Asserting equality would fail by construction.
>
> **No clamp on utilization:** the rate functions are the pure kinked curve, unclamped, as in Aave.
> Utilization is derived (`totalBorrowPV * 1e18 / totalSupplyPV`) and the accounting bounds it to
> `~[0, 1e18]`, while the `fullMulDiv` overflow sits at a `U ~1.9e33` times full utilization: a state
> the invariants forbid, so a clamp would be a magic number defending the unreachable. The liveness
> guarantee is refocused where it belongs: `accrue()` does not revert for any reachable state, and
> its one documented out-of-domain residual is the checked `rate * elapsed` index product, not the
> rate lookup. Documented in
> [05-implementation.md Section 3.2](./05-implementation.md#3-interfaces-and-function-contracts).

**Deliverables:**

- Stateless rate model, unit-tested in isolation
- Accrual in the market driven by the real curve

**Reference:** [02-mathematics.md](./02-mathematics.md) - Jump-Rate Section, [03-architecture.md ADR-4](./03-architecture.md#adr-4-derived-supply-rate-vs-dual-curves)

---

## Phase 3: Supply & Withdraw

> **Objective:** Deposits and withdrawals for base and collateral, without borrowing yet. Health checks are designed against the `IPriceOracle` interface and run on a mock until Phase 5.
>
> **Dependencies:** Phases 1, 2

- [x] **3.1** `supply(base)`: positive-principal path (transferFrom, principal credit through the single accounting path)
- [x] **3.2** `supply(collateral)`: supply cap check, `assetsIn` bitmap update
- [x] **3.3** `withdraw(base)`: positive-to-zero path (no borrow), cash sufficiency check
- [x] **3.4** `withdraw(collateral)`: balance decrement, bitmap clearing, health check hook (no-op while debt is impossible)
- [x] **3.5** ERC20 `transfer`/`transferFrom` of base restricted so the sender's principal never goes negative (no oracle needed)
- [x] **3.6** Pause flags (`SUPPLY`, `TRANSFER`, `WITHDRAW`) + pause guardian role
- [x] **3.7** Events: `Supply`, `Withdraw`, `SupplyCollateral`, `WithdrawCollateral`, ERC20 `Transfer` mirroring supply-side moves
- [x] **3.8** Unit tests (coverage >95% on the paths above)

> **Constructor change:** the market now takes a `MarketConfig` bundle plus a `CollateralConfig[]`,
> wiring the oracle, owner (`Ownable2Step`), guardian, `minBorrow`, and `targetReserves`, and listing
> collateral assets into the `assetsIn` bit-offset order. Per-asset INV-12 ordering, decimals, and
> supplyCap are enforced here; the absorb coverage condition (INV-13) is deferred to Phase 7, where
> the oracle supplies `MAX_CONFIDENCE_BPS`.
>
> **Health hook:** `withdraw(collateral)` calls `_requireBorrowCollateralized` only when the account
> has debt. In Phase 3 debt cannot exist, so the hook reverts `NotImplementedYet` and is never
> reached; Phase 4 replaces it with the real capacity math. This is why 4 lines of the borrow/repay
> path are the only uncovered lines in the market (97.84% line coverage, above the 95% target).
>
> **ERC20:** the full base surface (`transfer`, `transferFrom`, `approve`, `allowance`, metadata) is
> implemented, with the `Transfer` log mirroring supply-side principal moves (mint on increase, burn
> on decrease). `transfer` cannot push the sender negative, so it needs no oracle.

**Deliverables:**

- Users can deposit and withdraw base and collateral
- Rebasing `lmUSDC` balances grow with accrual

**Reference:** [03-architecture.md](./03-architecture.md) - Flows 6.1 to 6.4

---

## Phase 4: Borrow & Repay

> **Objective:** The negative-principal paths: borrowing via `withdraw(base)` past zero and repaying via `supply(base)`, with capacity checks against the (mocked) oracle.
>
> **Dependencies:** Phase 3

- [x] **4.1** `withdraw(base)` borrow path: open/increase borrow, sign-crossing transitions through the single accounting path
- [x] **4.2** `isBorrowCollateralized()`: per-asset `borrowCollateralFactor`, collateral valued at `price - conf`
- [x] **4.3** `minBorrow` dust guard (reverts borrows that would leave `0 < debt < minBorrow`)
- [x] **4.4** `supply(base)` repay path: negative-to-positive crossing, `type(uint256).max` full repay
- [x] **4.5** Accrue-before-action enforced and tested on every mutating path
- [x] **4.6** Events: `Supply`/`Withdraw` cover the repay and borrow branches (see note)
- [x] **4.7** Unit + fuzz tests: sign transitions, capacity boundaries, dust rejection, health never reduced below the borrow threshold by any allowed action

> **Health check shape:** `_requireBorrowCollateralized` runs in two steps: push every price the
> account's position depends on (`_pushPrices`, transactional, forwarding the fee budget), then
> evaluate `_borrowCapacity`, a `view` that re-reads the prices just written. The split exists
> because `isBorrowCollateralized` is `view` in `ILendingMarket` while the push is not, and both
> callers must run *one* implementation of the capacity formula: a view that could disagree with the
> check gating the borrow would be worse than no view at all.
>
> **4.6 events:** interface (frozen Phase 1) defines `Supply`/`Withdraw` with `amount` only; the
> repay/supply split is derivable from principal deltas, matching Comet and keeping the
> ERC20-adjacent shape. No event change.
>
> **Dust guard placement:** `minBorrow` is enforced against the *resulting* debt rather than the
> borrowed amount, so it also rejects a partial repay that would strand a position in the dust band.
> Repaying to exactly zero stays reachable, or a borrower could be trapped in a position they cannot
> close (`test_minBorrow_doesNotBlockRepayingToZero`).
>
> **`InsufficientBalance` on the base path is now unreachable:** crossing below zero is a borrow, not
> an error. The error remains declared for the collateral path.

**Deliverables:**

- Full lend/borrow cycle working against a mock oracle
- Accounts can never leave a mutating function undercollateralized

**Reference:** [02-mathematics.md](./02-mathematics.md) - Collateralization Section

---

## Phase 5: Oracle (Pyth + Chainlink)

> **Objective:** Real price infrastructure: Pyth pull model as primary source, Chainlink as deviation anchor, per-asset feeds for USDC, WETH, and wBTC.
>
> **Dependencies:** Phase 4 (which coded against `IPriceOracle`)

- [x] **5.1** Interface `IPriceOracle` (`updateAndGetPrice` payable + `getPrice` view, both returning `(price18, conf18)`)
- [x] **5.2** Contract `PythChainlinkOracle.sol`: Pyth pull integration (`updatePriceFeeds`, caller-funded fee via `msg.value`, surplus refund)
- [x] **5.3** Staleness check (`MAX_STALENESS`)
- [x] **5.4** Confidence check (`MAX_CONFIDENCE_BPS`)
- [x] **5.5** Chainlink deviation anchor (`MAX_DEVIATION_BPS`, per-feed heartbeat staleness check)
- [x] **5.6** Price normalization to 18 decimals (Pyth expo, Chainlink 8 dec)
- [x] **5.7** Per-asset feed config (`asset => {pythFeedId, chainlinkFeed, heartbeat}` for base + collaterals)
- [x] **5.8** `LendingMarket` integration: payable price-consuming functions batch-update all needed feeds, forward `msg.value`, sweep refunds to the caller
- [x] **5.9** `MockPriceOracle` + `MockChainlinkFeed` for local tests
- [x] **5.10** Oracle tests: staleness, confidence, deviation, normalization, fee refund, fuzz

> **5.1 note:** the interface was written in Phase 1 and kept its exact shape; verified here against
> the real contract. Both functions return `(price18, conf18)` and revert instead of degrading.
>
> **5.6 normalization:** Pyth carries a signed `expo` (`value * 10^expo`), normalized to the target
> `18 + expo` exponent (scale up when positive, down when negative). Chainlink answers normalize from
> the feed's own `decimals()` (8 for the reference feeds), rejecting a feed reporting more than 18.
>
> **5.8 receive() gap found and fixed:** the market forwards `address(this).balance` to the oracle
> once per asset; the real oracle consumes only the Pyth fee and refunds the surplus back to the
> market for the next per-asset call. The Phase 4 market had no `receive()`, so the refund reverted
> `RefundFailed` — a latent bug the mock never exposed because Phase 4 tests sent no ETH and the mock
> only refunds when `msg.value > 0`. Added `receive()` and corrected the `_refundExcessValue` comment,
> which had claimed ETH could only arrive by selfdestruct or pre-deploy transfer. No other market
> change: the `IPriceOracle` shape is unchanged, so `_pushPrices` / `_refundExcessValue` were already
> correct.
>
> **5.9 mocks:** the Pyth surface uses the SDK's `MockPyth` (`createPriceFeedUpdateData`,
> fee-charging `updatePriceFeeds`), so the fee/refund path is exercised for real. `MockChainlinkFeed`
> is a settable `AggregatorV3` stand-in for the anchor and its heartbeat. `MockPriceOracle` (the
> Phase 3/4 settable stand-in for the whole oracle) is retained for the market suites that do not
> need the real validation pipeline. Note MockPyth only stores a strictly newer `publishTime`, so a
> re-push at the same timestamp is silently a no-op — tests advance one second before re-pushing.

**Deliverables:**

- Validated prices with confidence intervals feeding health checks
- Stale or deviant prices revert, never a silent fallback
- Confidence-band policy applied (capacity at `price - conf`, absorb at `price + conf`)

**Reference:** [03-architecture.md](./03-architecture.md) - Oracle System + ADR-6

---

## Phase 6: Absorb Liquidation

> **Objective:** The two-step Comet liquidation: `absorb` (protocol wipes debt and seizes collateral) and `buyCollateral` (discounted resale to liquidators), with explicit bad-debt accounting.
>
> **Dependencies:** Phase 5

- [x] **6.1** `isLiquidatable()`: per-asset `liquidateCollateralFactor`, collateral valued at `price + conf` (borrower-favorable)
- [x] **6.2** `absorb(account, priceUpdate)`: seize all collateral, credit value at `liquidationFactor`, wipe debt through the single accounting path
- [x] **6.3** Shortfall path: remaining debt zeroed against reserves (explicit bad debt, `getReserves()` may go negative)
- [x] **6.4** Surplus path: excess seize value credited to the absorbed account as base supply
- [x] **6.5** `quoteCollateral()`: `discount = storeFrontPriceFactor * (1 - liquidationFactor)`, ask price below oracle price
- [x] **6.6** `buyCollateral()`: gated by `getReserves() < targetReserves`, `minAmount` slippage guard, CEI ordering (base in before collateral out)
- [x] **6.7** Pause flags (`ABSORB`, `BUY`)
- [x] **6.8** Tests: surplus/exact/shortfall absorptions, discount round trip never reduces reserves at stable prices, multi-collateral absorb, fuzz on seize math

> **Implemented in `LendingMarket` (not the harness):** the four functions (`absorb`, `buyCollateral`,
> `quoteCollateral`, `isLiquidatable`) move from reverting harness stubs into the production contract.
> Only `withdrawReserves` remains a stub, filled in Phase 7. `isLiquidatable` reuses the capacity
> shape of `_borrowCapacity` in a twin `_liquidationCapacity` that values collateral at the *high*
> edge (`price + conf`, floored) with `liquidateCF`, and debt at the high edge ceiled: the
> borrower-favorable direction, so no absorb on a noisy tick.
>
> **6.2-6.4 settlement:** `absorb` pushes prices, requires eligibility, then `_seizeCollateral`
> zeroes each held balance, decrements `totalsCollateral` by the same amount, and clears its
> `assetsIn` bit; the seized inventory then lives in `balanceOf(market) - totalsCollateral` ([Guide 3,
> ADR-7](./03-architecture.md#adr-7-collateral-total-as-user-claims-vs-whole-pool)). Seize value is
> marked at the mid price, credit at
> `liquidationFactor`. Settlement routes through the single accounting path: `newBalance = -debtPV +
> creditBase`, clamped at zero, with `badDebt = debtPV - creditBase` on a shortfall. Surplus is
> credited as base supply; a shortfall zeroes the account and reserves fall by the full debt.
>
> **6.6 buyCollateral moves only cash:** base in raises reserves through the derived formula (no
> principal change, no supplier credited); collateral out moves only the physical balance and touches
> no total. Gated on `getReserves() < TARGET_RESERVES`, with the `minAmount` slippage guard and an
> inventory check against `getCollateralReserves` (seized inventory only, ADR-7). A
> new `_pushBuyPrices` pushes base + the one asset, since buyCollateral has no account to drive the
> `assetsIn`-based `_pushPrices`. `receive()` (added Phase 5) lets the per-asset fee refund land.
>
> **6.8 round-trip fuzz shape:** the reserve-non-negativity claim of Guide 2 Section 9 holds *only*
> in the surplus/exact case; in the shortfall case proceeds reach the credit but not the full debt,
> the gap being the already-recognized bad debt. The fuzz asserts the unified true property, proceeds
> `>= creditBase`, plus the exact per-buy identity `dReserves == baseAmount`.

**Deliverables:**

- Underwater accounts absorbable permissionlessly, in full, in one call
- Bad debt recognized at absorption time instead of lingering as dust
- Collateral resale recapitalizes reserves at a bounded discount

**Reference:** [02-mathematics.md](./02-mathematics.md) - Liquidation Section, [03-architecture.md ADR-2](./03-architecture.md#adr-2-absorb-liquidation-vs-close-factor-liquidation)

---

## Phase 7: Reserves & Protocol Management

> **Objective:** Reserve governance surface and deployment: target reserves, owner withdrawal, roles, and the immutable deployment script.
>
> **Dependencies:** Phase 6

- [x] **7.1** `targetReserves` parameter wiring (gate on `buyCollateral`)
- [x] **7.2** `withdrawReserves(to, amount)` onlyOwner, bounded by `getReserves()` and available cash
- [x] **7.3** Roles final wiring: `Ownable2Step` owner + pause guardian (guardian can set flags, only owner can unset)
- [x] **7.4** Constructor parameter validation (factor ordering, non-zero addresses, decimals sanity) plus INV-13 absorb-coverage
- [x] **7.5** Deployment script: immutable config for USDC base + WETH/wBTC collateral, feed setup
- [x] **7.6** Management tests: reserve withdrawal bounds, role separation, constructor revert matrix

**Deliverables:**

- Complete, deployable market with the full owner/guardian surface
- One-command deployment with a checked configuration

**Reference:** [05-implementation.md](./05-implementation.md) - Access Control Matrix

---

## Phase 8: Invariant & Fuzz Testing + Audit Prep

> **Objective:** Prove the invariants under adversarial sequencing, validate the full stack end to end against the mocked oracle infrastructure, validate the real external dependencies on a mainnet fork, and complete the audit checklist. This phase is the thesis of the project: provable solvency. Fork testing here means testing against the protocol's real external dependencies (Pyth, Chainlink, and the real tokens); the lending logic itself is original and self-contained, covered by the unit, fuzz, and invariant layers.
>
> **Dependencies:** Phases 1-7

- [x] **8.1** Invariant: cash conservation via ghost tracking: `baseToken.balanceOf(market)` equals the net of every recorded inflow and outflow (no value moves without an accounting entry)
- [x] **8.2** Invariant: `sum(user principals) == totalSupplyBase - totalBorrowBase` split by sign, exact integer equality
- [x] **8.3** Invariant: index monotonicity, `supplyRate <= borrowRate`, reserves never decrease except by `absorb` shortfall/penalty timing or `withdrawReserves`
- [x] **8.4** Invariant: no handler action leaves an account below the borrow threshold; collateral totals match per-user sums
- [ ] **8.5** Fuzz: all conversion, rate, and quote math with directed-rounding assertions (rounding always favors the protocol)
- [ ] **8.6** End-to-end integration tests on a local deployment: full lifecycle (supply, borrow, warp, repay, absorb, buyCollateral) against MockPriceOracle-backed Pyth/Chainlink mocks, plus deployment script rehearsal on anvil
- [x] **8.7** Fork tests on an Ethereum mainnet fork against the real external dependencies: real USDC (base) and WETH (collateral) priced by the real Pyth pull oracle plus the real Chainlink ETH/USD and USDC/USD anchors, exercising supply, borrow, accrual, and repay end to end (a cached Hermes VAA replayed through the real `updatePriceFeeds` fee/refund path, real `getPriceUnsafe`, expo/decimal normalization, real `latestRoundData`; accounts funded via `deal`). absorb/buyCollateral are excluded on the fork: with real fixed prices the only lever to force liquidation is interest accrual, but warping forward makes the cached VAA stale and the constructor forbids `borrowCF >= liquidateCF`, so both paths are covered at unit/fuzz/invariant level against controlled prices instead. wBTC dropped: its Pyth feed on the fork is chronically stale and fails the real deviation check
- [ ] **8.8** Static analysis (Slither, Aderyn) with no criticals
- [ ] **8.9** Coverage >95% on all contracts
- [ ] **8.10** Audit checklist from [06-security.md](./06-security.md) completed + internal line-by-line review
- [ ] **8.11** Findings remediation and re-run of the full suite

**Deliverables:**

- Invariant suite encoding every system invariant from [06-security.md](./06-security.md)
- End-to-end validated flows against the mocked Pyth/Chainlink stack
- Oracle and token integration validated on a mainnet fork against live feeds and real tokens
- Clean static analysis and a completed audit checklist

**Reference:** [06-security.md](./06-security.md) - Invariants + Testing Plan

---

## Phase 9: Future Work (post-PoC)

> **Objective:** Explicitly out of scope for the PoC, recorded here so the boundary is deliberate.
>
> **Dependencies:** PoC complete

- [ ] **9.1** Governance and protocol token (timelocked parameter management, replacing the immutable config)
- [ ] **9.2** Upgradeability path (Comet-style Configurator + proxy behind governance)
- [ ] **9.3** Rewards distribution (supplier/borrower incentives with tracking indexes)
- [ ] **9.4** Operator flows (`supplyTo`, `withdrawFrom`, allowance-based managers)
- [ ] **9.5** Flash loans on idle base cash
- [ ] **9.6** Multi-chain deployments and additional markets (WETH-base market)

**Reference:** [04-tradeoffs.md](./04-tradeoffs.md) - Future Work discussion

---

## 📝 Changelog

| Date       | Changes                 |
| :--------- | :---------------------- |
| 2026-07-23 | Phase 8 in progress (8.1-8.4 invariant suite, 8.7 fork tests). The `StdInvariant` suite drives the market through 1000 x 100 bounded random calls per invariant and asserts 8 system invariants after every step (INV-1/2/4/5/6/7/9/11); it found a HIGH/HIGH self-transfer minting bug in `_transferBase` on its first run (a `from == to` no-op guard fixes it, pinned by a regression). Added the 8.7 fork tests: a market deployed on an Ethereum mainnet fork over real USDC (base) and WETH (collateral), priced by the real `PythChainlinkOracle` wired to the real Pyth pull oracle and the real Chainlink ETH/USD + USDC/USD anchors, running supply/borrow/accrual/repay against real on-chain prices. Prices are pushed by replaying a cached Hermes VAA (`test/fork/fixtures`) through the real `updatePriceFeeds` fee/refund path, so the test stays deterministic and `ffi` stays off; the VAA carries both feeds at one shared `publishTime` so a single warp leaves base and collateral fresh under the reference 60s window. absorb/buyCollateral are out of scope on the fork (forcing liquidation needs interest accrual, but warping makes the cached VAA stale, and `borrowCF < liquidateCF` is enforced, so neither can be reached without a fresh future price) and wBTC is dropped (its Pyth feed on the fork is chronically stale and fails the real deviation check); both are covered at unit/fuzz/invariant level instead. The fork suite no-ops green when `FORK_RPC_URL` is unset, so CI is unaffected. 250 total green |
| 2026-07-23 | Phase 7 complete: reserves and protocol management. `withdrawReserves(to, amount)` is `onlyOwner` + `nonReentrant`, accrues first, and is bounded independently by `getReserves()` (the accounting) and available cash (the balance): neither implies the other, since bad debt can push reserves above cash and supplier deposits push cash above reserves. INV-13 (absorb coverage, Guide 2 Section 8) is now enforced in the constructor: each collateral's `liquidationFactor` must dominate `liquidateCF * (FACTOR_SCALE + MAX_CONFIDENCE_BPS) / FACTOR_SCALE`, read from the oracle, so a promptly absorbed account eligible at the high confidence edge still credits enough at the mid price to cover its debt. `IPriceOracle` gained a `MAX_CONFIDENCE_BPS()` getter (satisfied by the existing immutable in `PythChainlinkOracle`, added to both mocks). `LendingMarket` is directly deployable (not abstract; its two internal read hooks are no longer `virtual`, since no test overrode them), and `script/Deploy.s.sol` wires the rate model, oracle, and market for USDC base + WETH/wBTC collateral with env-overridable addresses and reference risk params. The `withdrawReserves` harness stub is gone. 15 new management tests (withdrawal bounds, role separation, constructor revert matrix including INV-13 at, below, and above the coverage floor); 239 total green |
| 2026-07-22 | Changed the collateral-total semantics to match Comet ([Guide 3, ADR-7](./03-architecture.md#adr-7-collateral-total-as-user-claims-vs-whole-pool)). `totalsCollateral` now means the sum of user claims only: `absorb` decrements it in step with each seized balance, and the protocol's seized inventory is derived from the physical balance through a new `getCollateralReserves(asset) = balanceOf(market) - totalsCollateral`. `buyCollateral` gates on that derived inventory instead of the raw total and no longer writes any total, so it can never sell user-owned collateral. This turns the solvency property from a fragile, O(n)-only inequality (`totalsCollateral >= Σ userCollateral`, unenforced by the old guard) into an exact equality by construction plus an O(1) on-chain-assertable `balanceOf >= totalsCollateral`. The supply cap changed meaning with it: it now bounds the sum of user claims only, not the protocol's total physical holdings, so seized inventory no longer consumes cap room (after a large absorb the market can custody above the cap). Accepted trade-off: deriving inventory from `balanceOf` restricts listing to tokens whose `balanceOf` never falls below `totalsCollateral` outside a protocol call, which excludes transfer-hook, rebasing-down, and fee-on-transfer collateral; the failure mode for such a token would be availability (`buyCollateral` reverts), not a solvency corruption (documented in Guide 6). 3 new unit tests, including the regression pin that a buy exceeding the seized inventory reverts even when it fits the old raw total; INV-6 rewritten. 224 total green |
| 2026-07-22 | Phase 6 complete: the two-step Comet liquidation, moved from harness stubs into `LendingMarket`. `isLiquidatable` values collateral at the high confidence edge with `liquidateCF` (a `_liquidationCapacity` twin of `_borrowCapacity`), so no absorb on a noisy tick. `absorb` pushes prices, requires eligibility, seizes every held collateral into protocol ownership (`totalsCollateral` untouched), and settles through the single accounting path: `newBalance = -debtPV + creditBase` clamped at zero, surplus credited as base supply, shortfall zeroing the account with `badDebt = debtPV - creditBase` recognized against reserves immediately (`getReserves()` may go negative). Seize marked at mid price, credit at `liquidationFactor`. `quoteCollateral` applies `discount = storeFront * (1 - LF)` floored and an ask below the oracle price, both roundings protocol-favorable. `buyCollateral` moves only cash (base in raises reserves via the derived formula, no principal change), gated on `getReserves() < TARGET_RESERVES` with a `minAmount` slippage guard, inventory check, and CEI ordering; a new `_pushBuyPrices` pushes base + the one asset. `ABSORB`/`BUY` pause flags wired. Only `withdrawReserves` remains a harness stub (Phase 7). 19 new tests (17 unit, 2 fuzz); the round-trip fuzz asserts proceeds `>= creditBase` (the shortfall gap is the already-recognized bad debt) and the exact per-buy `dReserves == baseAmount`. 99.70% line coverage on the market; 221 total green |
| 2026-07-22 | Phase 5 complete: `PythChainlinkOracle.sol`, the real price infrastructure behind the frozen `IPriceOracle` shape. Pyth pull oracle as the primary source (caller-funded `updatePriceFeeds` fee via `msg.value`, surplus refunded), Chainlink as a deviation anchor only (never a fallback). The four-stage validation pipeline lives in one internal `_validate` shared by `updateAndGetPrice` and `getPrice` so a view can never disagree with the transactional check: non-zero, staleness (`MAX_STALENESS`, applied via `getPriceUnsafe` so lending's looser policy governs both paths), confidence (`conf/price <= MAX_CONFIDENCE_BPS`), and Chainlink deviation (`\|pyth-anchor\|/anchor <= MAX_DEVIATION_BPS`) with the anchor's own per-feed heartbeat. Prices normalize to 1e18 from Pyth `expo` and from the Chainlink feed's `decimals()`. Pure policy: immutable feed config, no owner, no setters. Reference params `MAX_STALENESS=60`, `MAX_CONFIDENCE_BPS=200`, `MAX_DEVIATION_BPS=300`. Added the Pyth SDK submodule (`@pythnetwork/pyth-sdk-solidity`), a minimal local `IChainlinkAggregator`, and `MockChainlinkFeed`; tests use the SDK's `MockPyth`. Found and fixed a latent Phase 4 bug the mock hid: the market forwards its whole ETH balance per asset and the real oracle refunds the surplus back to it, but the market had no `receive()` — added it. 33 new tests (28 unit, 3 fuzz, 2 integration), 98.46% line / 95.45% branch coverage on the oracle; 202 total green |
| 2026-07-22 | Phase 4 complete: the negative-principal paths. `withdraw(base)` past zero opens or increases a borrow through the same accounting path (no `borrow()` function, no branch on the sign crossing), `supply(base)` repays and crosses back with the `type(uint256).max` full-repay sentinel. Real capacity math replaces the `NotImplementedYet` hook: collateral at `price - conf` floored, debt at `price + conf` ceiled, summed per asset over the `assetsIn` bitmap. `_requireBorrowCollateralized` splits into a transactional `_pushPrices` plus the `view` `_borrowCapacity` that the public `isBorrowCollateralized` shares, so the view can never disagree with the check gating the borrow. `minBorrow` enforced against the resulting debt, not the borrowed amount, so it also catches a repay stranding a position in the dust band while leaving repay-to-zero reachable. Item 4.6 closed without an event change: the Phase 1 interface already defines `Supply`/`Withdraw` as covering both branches and the interface wins over the roadmap wording. `InsufficientBalance` is now unreachable on the base path. 43 new tests (37 unit, 6 fuzz), 99.61% line coverage on the market; 169 total green. INV-9 and INV-10 asserted at the single-account level |
| 2026-07-21 | Added the [testing documentation section](./tests/README.md): strategy and principles, a test-by-test inventory of all 126 tests with line-anchored links to the code, the invariant coverage map (which test asserts each of INV-1 to INV-14, and which are still unasserted), the mutation-check record including the flipped `presentValueSupply` that round trips failed to catch, and the per-phase testing deliverables. Updated at the close of every phase from here on |
| 2026-07-21 | Phase 3 complete: base and collateral supply/withdraw, the full rebasing ERC20 base surface, and the SUPPLY/TRANSFER/WITHDRAW pause flags with the guardian-adds/owner-clears rule (`Ownable2Step` owner). The constructor now takes a `MarketConfig` bundle plus `CollateralConfig[]`, enforcing INV-12 ordering, decimals, and supply caps per asset; INV-13 deferred to Phase 7. All token-moving paths accrue first, follow CEI, and carry a `nonReentrant` guard. 36 new tests, 97.84% line coverage on the market (the 4 uncovered lines are the Phase 4 borrow/repay hook); 126 total green |
| 2026-07-21 | Corrected an inaccurate totality claim in the rate model: Guide 5 Section 3.2 previously promised the rate functions were total over all `uint256`, which was both false (`fullMulDiv` overflows far out) and unnecessary. Utilization is bounded by the accounting to `~[0, 1e18]`, so no reachable state approaches overflow. Removed the earlier saturation clamp (`U_MAX_SANE`): no clamp is added, matching Aave. Refocused the liveness guarantee on the one reachable revert, the checked `rate * elapsed` index product in `accrue()`, and reworded INV-14 accordingly. Documentation and test correctness fix, no change to reachable behavior |
| 2026-07-20 | Phase 2 complete: `InterestRateModel` with the immutable kinked curve, the derived floored supply rate, and constructor sanity checks enforcing INV-12; wired into the market's accrual and verified against the real curve at the kink and in the jump regime. 30 tests (18 unit, 6 fuzz, 4 market-accrual), the supply-rate floor mutation-verified |
| 2026-07-20 | Internal functions prefixed with `_` (`accrueInternal` folded into `_accrue`); documented the `rate * elapsed` product in `_accrue` as the one multiplication outside `fullMulDiv`'s 512-bit intermediate, with its overflow bound and why it stays checked; added `test/unit/AccrualOverflow.t.sol` (3 tests) pinning the revert at the boundary |
| 2026-07-20 | Conversion primitives (`presentValue*`, `principalValue*`, both unsigned and signed) moved from `public` to `internal`: none of them is part of `ILendingMarket`, so they were exposed only because tests called them. `LendingMarketHarness` now wraps them as `exposed*`, shrinking the deployed public surface from 15 methods to 9 |
| 2026-07-20 | `LendingMarket` now derives `BASE_SCALE` from `IERC20Metadata(baseToken).decimals()` instead of taking `baseDecimals` as a constructor argument: a mismatched literal would corrupt every base-denominated quantity silently rather than reverting, and validating the argument would fail on a token without `decimals()` exactly as reading it does |
| 2026-07-20 | Documented and pinned the `1e15` index scale choice against a RAY (Aave style) alternative in [05-implementation.md](./05-implementation.md#2-core-data-structures): the extra digits carry no signal at a 6-decimal base, the residual is bounded at one base unit in the protocol-favorable direction, and the analysis is coupled to the base having 6 decimals. Added `test/fuzz/IndexPrecision.t.sol` (4 tests) as the executable justification |
| 2026-07-20 | Phase 1 complete: `ILendingMarket` with the full error catalogue, `IInterestRateModel`, `IPriceOracle`; storage layout and packing per Guide 3 Section 3; the directed-rounding conversion pair; `accrue()`; utilization including the `U > 1` edge; rebasing balance views; derived `getReserves()`; and the single accounting path `updateBasePrincipal()`. 53 tests green (34 unit, 19 fuzz at 1000 runs), all seven rounding sites mutation-verified |
| 2026-07-20 | Phase 0 complete: Foundry project on Solidity 0.8.26, OpenZeppelin v5.1.0 + Solady v0.1.26 as pinned submodules (Pyth SDK deferred to Phase 5), documented folder structure, Solhint + Prettier + `forge fmt`, and a GitHub Actions pipeline running build, test, lint, and coverage |
| 2026-07-20 | Restored mainnet fork testing, scoped to the real external dependencies (Pyth, Chainlink, real USDC/WETH/wBTC); the lending logic is original and stays covered by unit, fuzz, and invariant tests |
| 2026-07-20 | Removed mainnet fork testing (the PoC is never deployed against live infrastructure); replaced by end-to-end integration tests on a local mocked oracle stack |
| 2026-07-20 | Initial roadmap version |

---

## 📚 References

- [Documentation Index](./README.md)
- [Fundamental Concepts](./01-fundamentals.md)
- [Mathematics](./02-mathematics.md)
- [Technical Architecture](./03-architecture.md)
- [Trade-offs and Risk Matrix](./04-tradeoffs.md)
- [Solidity Implementation](./05-implementation.md)
- [Security](./06-security.md)
- [Testing Documentation](./tests/README.md)
