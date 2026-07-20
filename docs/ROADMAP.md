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
| 0         | Setup & Infrastructure                 | 6      | 0         | 0%       |
| 1         | Core: Index Accounting & Storage       | 8      | 0         | 0%       |
| 2         | Interest Rate Model                    | 6      | 0         | 0%       |
| 3         | Supply & Withdraw                      | 8      | 0         | 0%       |
| 4         | Borrow & Repay                         | 7      | 0         | 0%       |
| 5         | Oracle (Pyth + Chainlink)              | 10     | 0         | 0%       |
| 6         | Absorb Liquidation                     | 8      | 0         | 0%       |
| 7         | Reserves & Protocol Management         | 6      | 0         | 0%       |
| 8         | Invariant & Fuzz Testing + Audit Prep  | 11     | 0         | 0%       |
| 9         | Future Work (post-PoC)                 | 6      | 0         | 0%       |
| **TOTAL** |                                        | **76** | **0**     | **0%**   |

---

## Phase 0: Setup & Infrastructure

> **Objective:** Configure the development environment and base project structure.

- [ ] **0.1** Initialize Foundry project (Solidity 0.8.26)
- [ ] **0.2** Configure dependencies (OpenZeppelin v5, Solady, Pyth SDK)
- [ ] **0.3** Folder structure (`src/`, `src/interfaces/`, `test/unit/`, `test/fuzz/`, `test/invariant/`, `test/integration/`, `test/fork/`, `script/`)
- [ ] **0.4** Configure CI/CD (GitHub Actions: build, test, coverage)
- [ ] **0.5** Setup linters (Solhint, Prettier)
- [ ] **0.6** Repository documentation (README, LICENSE)

**Deliverables:**

- Repository configured and ready for development
- CI pipeline running tests automatically

---

## Phase 1: Core - Index Accounting & Storage

> **Objective:** The accounting skeleton of `LendingMarket.sol`: storage layout, principal/present-value conversions, and index accrual. No user-facing actions yet.
>
> **Dependencies:** Phase 0

- [ ] **1.1** Interface `ILendingMarket` + custom error catalogue
- [ ] **1.2** Storage layout: `MarketState`, `UserBasic` (signed `int104` principal + `assetsIn` bitmap), `CollateralConfig`, packed as documented
- [ ] **1.3** Conversion pair `presentValue()` / `principalValue()` with directed rounding (supply rounds down, borrow rounds up)
- [ ] **1.4** `accrue()`: supply/borrow index advancement over elapsed time (rates injected via `IInterestRateModel`, mockable)
- [ ] **1.5** `getUtilization()`: handles `totalSupply == 0` and the `U > 1` edge
- [ ] **1.6** Rebasing ERC20 views: `balanceOf`, `borrowBalanceOf`, `totalSupply`, `totalBorrow`
- [ ] **1.7** `getReserves()`: derived `int256` reserves (`cash + totalBorrow - totalSupply`)
- [ ] **1.8** Unit + fuzz tests: conversion round trips never favor the user, index monotonicity, accrual over arbitrary time gaps

**Deliverables:**

- Deployable accounting core with indexes that accrue correctly
- Conversion math proven protocol-favorable under fuzzing

**Reference:** [02-mathematics.md](./02-mathematics.md), [03-architecture.md](./03-architecture.md)

---

## Phase 2: Interest Rate Model

> **Objective:** The kinked (jump-rate) borrow curve with derived supply rate, as a separate immutable contract.
>
> **Dependencies:** Phase 0 (parallel to Phase 1)

- [ ] **2.1** Interface `IInterestRateModel`
- [ ] **2.2** Contract `InterestRateModel.sol` with immutable parameters (`baseRate`, `slopeLow`, `slopeHigh`, `kink`, `reserveFactor`) and constructor sanity checks
- [ ] **2.3** `getBorrowRate(utilization)`: kinked curve, per-second rates at 1e18 scale
- [ ] **2.4** `getSupplyRate(utilization)`: `borrowRate * U * (1 - reserveFactor)`
- [ ] **2.5** Wire the model into `LendingMarket.accrue()` (immutable address)
- [ ] **2.6** Tests: continuity at the kink, monotonicity fuzz, `supplyRate <= borrowRate` for all U, rate identity (borrow interest == supply interest + reserve cut) fuzz

**Deliverables:**

- Stateless rate model, unit-tested in isolation
- Accrual in the market driven by the real curve

**Reference:** [02-mathematics.md](./02-mathematics.md) - Jump-Rate Section, [03-architecture.md ADR-4](./03-architecture.md#adr-4-derived-supply-rate-vs-dual-curves)

---

## Phase 3: Supply & Withdraw

> **Objective:** Deposits and withdrawals for base and collateral, without borrowing yet. Health checks are designed against the `IPriceOracle` interface and run on a mock until Phase 5.
>
> **Dependencies:** Phases 1, 2

- [ ] **3.1** `supply(base)`: positive-principal path (transferFrom, principal credit through the single accounting path)
- [ ] **3.2** `supply(collateral)`: supply cap check, `assetsIn` bitmap update
- [ ] **3.3** `withdraw(base)`: positive-to-zero path (no borrow), cash sufficiency check
- [ ] **3.4** `withdraw(collateral)`: balance decrement, bitmap clearing, health check hook (no-op while debt is impossible)
- [ ] **3.5** ERC20 `transfer`/`transferFrom` of base restricted so the sender's principal never goes negative (no oracle needed)
- [ ] **3.6** Pause flags (`SUPPLY`, `TRANSFER`, `WITHDRAW`) + pause guardian role
- [ ] **3.7** Events: `Supply`, `Withdraw`, `SupplyCollateral`, `WithdrawCollateral`, ERC20 `Transfer` mirroring supply-side moves
- [ ] **3.8** Unit tests (coverage >95% on the paths above)

**Deliverables:**

- Users can deposit and withdraw base and collateral
- Rebasing `lmUSDC` balances grow with accrual

**Reference:** [03-architecture.md](./03-architecture.md) - Flows 6.1 to 6.4

---

## Phase 4: Borrow & Repay

> **Objective:** The negative-principal paths: borrowing via `withdraw(base)` past zero and repaying via `supply(base)`, with capacity checks against the (mocked) oracle.
>
> **Dependencies:** Phase 3

- [ ] **4.1** `withdraw(base)` borrow path: open/increase borrow, sign-crossing transitions through the single accounting path
- [ ] **4.2** `isBorrowCollateralized()`: per-asset `borrowCollateralFactor`, collateral valued at `price - conf`
- [ ] **4.3** `minBorrow` dust guard (reverts borrows that would leave `0 < debt < minBorrow`)
- [ ] **4.4** `supply(base)` repay path: negative-to-positive crossing, `type(uint256).max` full repay
- [ ] **4.5** Accrue-before-action enforced and tested on every mutating path
- [ ] **4.6** Events: `Withdraw`/`Supply` carrying the borrow/repay split
- [ ] **4.7** Unit + fuzz tests: sign transitions, capacity boundaries, dust rejection, health never reduced below the borrow threshold by any allowed action

**Deliverables:**

- Full lend/borrow cycle working against a mock oracle
- Accounts can never leave a mutating function undercollateralized

**Reference:** [02-mathematics.md](./02-mathematics.md) - Collateralization Section

---

## Phase 5: Oracle (Pyth + Chainlink)

> **Objective:** Real price infrastructure: Pyth pull model as primary source, Chainlink as deviation anchor, per-asset feeds for USDC, WETH, and wBTC.
>
> **Dependencies:** Phase 4 (which coded against `IPriceOracle`)

- [ ] **5.1** Interface `IPriceOracle` (`updateAndGetPrice` payable + `getPrice` view, both returning `(price18, conf18)`)
- [ ] **5.2** Contract `PythChainlinkOracle.sol`: Pyth pull integration (`updatePriceFeeds`, caller-funded fee via `msg.value`, surplus refund)
- [ ] **5.3** Staleness check (`MAX_STALENESS`)
- [ ] **5.4** Confidence check (`MAX_CONFIDENCE_BPS`)
- [ ] **5.5** Chainlink deviation anchor (`MAX_DEVIATION_BPS`, per-feed heartbeat staleness check)
- [ ] **5.6** Price normalization to 18 decimals (Pyth expo, Chainlink 8 dec)
- [ ] **5.7** Per-asset feed config (`asset => {pythFeedId, chainlinkFeed, heartbeat}` for base + collaterals)
- [ ] **5.8** `LendingMarket` integration: payable price-consuming functions batch-update all needed feeds, forward `msg.value`, sweep refunds to the caller
- [ ] **5.9** `MockPriceOracle` + `MockChainlinkFeed` for local tests
- [ ] **5.10** Oracle tests: staleness, confidence, deviation, normalization, fee refund, fuzz

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

- [ ] **6.1** `isLiquidatable()`: per-asset `liquidateCollateralFactor`, collateral valued at `price + conf` (borrower-favorable)
- [ ] **6.2** `absorb(account, priceUpdate)`: seize all collateral, credit value at `liquidationFactor`, wipe debt through the single accounting path
- [ ] **6.3** Shortfall path: remaining debt zeroed against reserves (explicit bad debt, `getReserves()` may go negative)
- [ ] **6.4** Surplus path: excess seize value credited to the absorbed account as base supply
- [ ] **6.5** `quoteCollateral()`: `discount = storeFrontPriceFactor * (1 - liquidationFactor)`, ask price below oracle price
- [ ] **6.6** `buyCollateral()`: gated by `getReserves() < targetReserves`, `minAmount` slippage guard, CEI ordering (base in before collateral out)
- [ ] **6.7** Pause flags (`ABSORB`, `BUY`)
- [ ] **6.8** Tests: surplus/exact/shortfall absorptions, discount round trip never reduces reserves at stable prices, multi-collateral absorb, fuzz on seize math

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

- [ ] **7.1** `targetReserves` parameter wiring (gate on `buyCollateral`)
- [ ] **7.2** `withdrawReserves(to, amount)` onlyOwner, bounded by `getReserves()` and available cash
- [ ] **7.3** Roles final wiring: `Ownable2Step` owner + pause guardian (guardian can set flags, only owner can unset)
- [ ] **7.4** Constructor parameter validation (factor ordering, non-zero addresses, decimals sanity)
- [ ] **7.5** Deployment script: immutable config for USDC base + WETH/wBTC collateral, feed setup
- [ ] **7.6** Management tests: reserve withdrawal bounds, role separation, constructor revert matrix

**Deliverables:**

- Complete, deployable market with the full owner/guardian surface
- One-command deployment with a checked configuration

**Reference:** [05-implementation.md](./05-implementation.md) - Access Control Matrix

---

## Phase 8: Invariant & Fuzz Testing + Audit Prep

> **Objective:** Prove the invariants under adversarial sequencing, validate the full stack end to end against the mocked oracle infrastructure, validate the real external dependencies on a mainnet fork, and complete the audit checklist. This phase is the thesis of the project: provable solvency. Fork testing here means testing against the protocol's real external dependencies (Pyth, Chainlink, and the real tokens); the lending logic itself is original and self-contained, covered by the unit, fuzz, and invariant layers.
>
> **Dependencies:** Phases 1-7

- [ ] **8.1** Invariant: cash conservation via ghost tracking: `baseToken.balanceOf(market)` equals the net of every recorded inflow and outflow (no value moves without an accounting entry)
- [ ] **8.2** Invariant: `sum(user principals) == totalSupplyBase - totalBorrowBase` split by sign, exact integer equality
- [ ] **8.3** Invariant: index monotonicity, `supplyRate <= borrowRate`, reserves never decrease except by `absorb` shortfall/penalty timing or `withdrawReserves`
- [ ] **8.4** Invariant: no handler action leaves an account below the borrow threshold; collateral totals match per-user sums
- [ ] **8.5** Fuzz: all conversion, rate, and quote math with directed-rounding assertions (rounding always favors the protocol)
- [ ] **8.6** End-to-end integration tests on a local deployment: full lifecycle (supply, borrow, warp, repay, absorb, buyCollateral) against MockPriceOracle-backed Pyth/Chainlink mocks, plus deployment script rehearsal on anvil
- [ ] **8.7** Fork tests on a mainnet fork against the real external dependencies: mainnet USDC (base), WETH, and wBTC with live Pyth + Chainlink feeds, exercising supply, borrow, absorb, and buyCollateral end to end (real Hermes update data, the real `updatePriceFeeds` fee and refund, expo/decimal normalization, real `latestRoundData`; accounts funded via `deal` or impersonation)
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
