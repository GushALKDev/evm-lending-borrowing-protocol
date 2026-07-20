# 📖 Guide 1: Fundamental Concepts

**Version:** 1.0
**Prerequisites:** None (start here)
**Next:** [Guide 2: Protocol Mathematics](./02-mathematics.md)

---

## 📋 Table of Contents

1. [What Is a Money Market?](#1-what-is-a-money-market)
2. [Supply and Borrow Mechanics](#2-supply-and-borrow-mechanics)
3. [The Single-Base Model (Comet Style)](#3-the-single-base-model-comet-style)
4. [Actors and Incentives](#4-actors-and-incentives)
5. [How This Design Differs from Compound V2 and Aave V3](#5-how-this-design-differs-from-compound-v2-and-aave-v3)
6. [Key Terms](#6-key-terms)

---

## 1. What Is a Money Market?

A money market is a pooled, overcollateralized lending protocol. There are no matched counterparties and no order book: suppliers deposit an asset into a shared pool and earn interest; borrowers draw from that same pool against collateral and pay interest. Rates are not negotiated, they are set algorithmically from a single observable quantity, **utilization** (the fraction of supplied funds currently borrowed).

Three mechanisms make this work without trust between participants:

1. **Overcollateralization.** A borrower must lock collateral worth more than the debt. The protocol never extends unsecured credit.
2. **Algorithmic interest.** When utilization rises, rates rise, attracting suppliers and pushing borrowers to repay; when it falls, rates fall. Past a target utilization (the kink), rates jump steeply to defend the pool's exit liquidity (see [Guide 2](./02-mathematics.md#5-jump-rate-interest-model)).
3. **Liquidation.** If collateral value falls until it no longer safely covers the debt, anyone may trigger a forced settlement. The threat of liquidation, not the borrower's goodwill, is what keeps debt backed.

Interest accrues continuously (per second) through a pair of global indexes rather than per-account bookkeeping: each account stores a fixed **principal**, and the protocol scales it by an ever-growing index to obtain the current balance. This is the index accounting model, formalized in [Guide 2](./02-mathematics.md#2-index-accounting-principal-and-present-value).

---

## 2. Supply and Borrow Mechanics

The market has exactly one borrowable asset, the **base asset** (USDC), and a small set of **collateral assets** (WETH, wBTC) that can only be deposited, never borrowed.

### Supplying the base asset

A supplier deposits USDC and receives an interest-bearing claim: the market itself is a rebasing ERC20 (`lmUSDC`) whose `balanceOf` grows block by block as interest accrues. There is no exchange-rate share token; one lmUSDC unit always reads as one USDC of present value.

```
Supplier deposits 10,000 USDC
    -> principal recorded against the current supply index
    -> balanceOf grows with the index: 10,000.00 -> 10,001.37 -> ...
Supplier withdraws at any time, limited only by available cash in the pool
```

### Borrowing the base asset

A borrower first supplies collateral (WETH or wBTC), then withdraws USDC beyond a zero balance. Supplying and borrowing base are the same two functions: `supply(base)` while in debt repays it, and `withdraw(base)` past zero opens a borrow. One signed principal per account makes the two states mutually exclusive by construction ([Guide 3, ADR-5](./03-architecture.md#adr-5-signed-principal-and-rebasing-erc20)).

```
Borrower supplies 10 WETH (price 2,000 USD, collateral factor 80%)
    -> borrowing capacity = 10 * 2,000 * 0.80 = 16,000 USDC
Borrower withdraws 15,000 USDC
    -> principal is now negative, debt grows with the borrow index
```

The borrower's position stays healthy while the debt remains below the capacity implied by the **borrow collateral factor**. If collateral value falls until debt exceeds the higher **liquidate collateral factor** threshold, the account becomes absorbable ([Guide 2](./02-mathematics.md#7-collateralization-and-health)).

### Collateral is inert

Collateral assets earn no interest, cannot be borrowed, and are never lent out or rehypothecated. Every unit of collateral deposited sits in the market contract until its owner withdraws it or it is seized in a liquidation. This is a deliberate design property, not a missing feature: it is what bounds the blast radius of any single collateral asset failing.

---

## 3. The Single-Base Model (Comet Style)

This protocol follows the architecture of Compound III (Comet), not Compound V2. The difference is structural, not cosmetic:

```
CROSS-COLLATERAL POOL (V2 / Aave)          SINGLE-BASE MARKET (Comet / this PoC)

 every asset is both collateral             one borrowable asset (USDC)
 and borrowable                             collateral is deposit-only
        │                                          │
        ▼                                          ▼
┌──────────────────┐                       ┌──────────────────┐
│  USDC  <──> ETH  │                       │   USDC pool      │
│    ▲        ▲    │                       │  (only debt and  │
│    │        │    │                       │   only yield)    │
│  wBTC <──> DAI   │                       ├──────────────────┤
│                  │                       │  WETH custody    │
│  risk is N x N:  │                       │  wBTC custody    │
│  any asset can   │                       │  (inert, valued  │
│  drain any other │                       │   only in health │
└──────────────────┘                       │   checks)        │
                                           └──────────────────┘
```

Consequences of the single-base model:

- **Risk isolation.** A manipulated or depegged collateral asset can, at worst, leave bad debt equal to the borrows it backed. It cannot be borrowed and dumped, and it does not contaminate other markets. Cross-collateral pools have failed exactly this way (CREAM, Venus).
- **One solvency domain.** All debt and all yield are denominated in one asset, so the accounting reduces to two totals and one cash balance, which is what makes the solvency properties in [Guide 6](./06-security.md) provable with integer precision.
- **Specialized markets.** Want to borrow WETH? That is a different deployment with WETH as base. Each market is small enough to reason about completely.

The cost: collateral earns nothing (borrowers are typically hedgers or leverage seekers, not yield seekers), and suppliers of non-base assets must look elsewhere. Comet made this trade deliberately; this PoC follows it and documents the reasoning in [Guide 3, ADR-1](./03-architecture.md#adr-1-single-borrowable-base-vs-cross-collateral-pool).

---

## 4. Actors and Incentives

| Actor               | What they do                                                        | Incentive                                                             | Trust level |
| :------------------- | :------------------------------------------------------------------- | :--------------------------------------------------------------------- | :----------- |
| **Base supplier**   | Deposits USDC, holds rebasing lmUSDC                                | Supply interest: `borrowRate * U * (1 - reserveFactor)`               | Untrusted   |
| **Borrower**        | Deposits WETH/wBTC, borrows USDC                                    | Liquidity against collateral without selling it (leverage, hedging)   | Untrusted   |
| **Liquidator bot**  | Calls `absorb` on underwater accounts, then `buyCollateral`         | Buys seized collateral below oracle price (storefront discount)       | Untrusted   |
| **Owner (multisig)**| Withdraws reserves to treasury, sets/clears pause flags             | Protocol operator; powers deliberately minimal (no parameter changes) | Trusted     |
| **Pause guardian**  | Sets pause flags fast in an incident (cannot clear them)            | Incident response speed without full owner powers                     | Semi-trusted|
| **Pyth publishers** | Feed prices with confidence intervals                               | Oracle Integrity Staking (slashing)                                   | Semi-trusted|
| **Chainlink**       | Independent anchor price per asset                                  | Existing feed economics                                               | Semi-trusted|

Two incentive designs are worth calling out because they differ from most lending protocols:

- **Liquidators are paid by discount, not by bounty.** `absorb` transfers no reward to its caller; the profit is realized separately by buying the seized collateral below market through `buyCollateral`. This decouples the solvency-critical action (absorb) from the profit-taking action (buy), and removes the reverting-receiver and bounty-tuning failure modes of close-factor designs ([Guide 3, ADR-2](./03-architecture.md#adr-2-absorb-liquidation-vs-close-factor-liquidation)).
- **The protocol itself is an actor with a balance sheet.** Reserves absorb bad debt and take the reserve-factor cut of interest plus the liquidation penalty. Reserve health is a first-class quantity ([Guide 4](./04-tradeoffs.md#risk-7-reserve-depletion)).

---

## 5. How This Design Differs from Compound V2 and Aave V3

| Dimension              | This PoC (Comet-style)                                | Compound V2                                       | Aave V3                                            |
| :---------------------- | :----------------------------------------------------- | :-------------------------------------------------- | :--------------------------------------------------- |
| Borrowable assets      | 1 (the base, USDC)                                    | Every listed asset                                | Every listed asset (with caps and isolation mode)  |
| Collateral earns yield | No (inert custody)                                    | Yes (cTokens)                                     | Yes (aTokens)                                      |
| Position token         | Rebasing `lmUSDC` (market is the ERC20)               | cToken with a growing exchange rate               | Rebasing aToken (separate contract per asset)      |
| Account accounting     | One signed principal per account                      | Separate cToken balance and borrow snapshot       | Separate aToken and debt-token balances            |
| Liquidation model      | Absorb: protocol wipes debt, seizes, resells at discount | Close factor (50%) + fixed liquidator bonus     | Close factor + bonus, partial liquidations          |
| Bad debt recognition   | Explicit, at absorb time, against reserves            | Implicit, lingers as unliquidatable dust          | Umbrella/Safety Module backstop, governance-driven |
| Interest rate model    | One kinked borrow curve, derived supply rate          | Kinked borrow curve, derived supply rate          | Kinked dual-slope per asset, separate for stable   |
| Oracle                 | Pyth pull + Chainlink deviation anchor                | Chainlink push                                    | Chainlink push                                     |
| Upgradeability         | None (immutable deployment)                           | Upgradeable Comptroller, immutable cTokens        | Proxied, governance-upgradeable                    |
| Governance             | None (PoC; owner limited to pause + reserves)         | COMP token governance                             | AAVE token governance                              |

**Why these choices, in one paragraph each:**

- **Single base over cross-collateral** because risk should compose additively, not multiplicatively. In V2/Aave every new listing is a new borrowable liability backed by every other asset; here a new collateral listing is one config struct whose worst case is bounded by the debt it backs. See [ADR-1](./03-architecture.md#adr-1-single-borrowable-base-vs-cross-collateral-pool).
- **Absorb over close-factor liquidation** because it settles accounts fully and immediately, recognizes bad debt the moment it exists instead of letting dust rot, and moves the MEV auction out of the solvency-critical path. See [ADR-2](./03-architecture.md#adr-2-absorb-liquidation-vs-close-factor-liquidation).
- **Immutable over upgradeable** because this PoC has no governance, and an upgradeable proxy without governance is an admin key over user funds. What you audit is what runs, forever. See [ADR-3](./03-architecture.md#adr-3-immutable-deployment-vs-upgradeable-proxy).
- **Derived supply rate over Comet's dual curves** because it makes non-negative reserve accrual a theorem instead of a configuration assumption, which is the thesis of this project. See [ADR-4](./03-architecture.md#adr-4-derived-supply-rate-vs-dual-curves).
- **Pyth pull + Chainlink anchor over Chainlink push alone** because per-read confidence intervals let health checks value collateral conservatively, and a second source cross-checks every price. See [ADR-6](./03-architecture.md#adr-6-pyth-pull--chainlink-anchor-vs-chainlink-push-only).

---

## 6. Key Terms

| Term                  | Definition                                                                                       |
| :--------------------- | :-------------------------------------------------------------------------------------------------- |
| **Base asset**        | The single borrowable asset (USDC). All debt, yield, and reserves are denominated in it            |
| **Collateral asset**  | A deposit-only asset (WETH, wBTC) valued exclusively inside health checks                           |
| **Principal**         | The stored, index-invariant account balance; signed: positive = supplier, negative = borrower       |
| **Present value**     | Principal scaled by the current index: what the account is actually owed or owes now                |
| **Supply/borrow index** | Global multipliers that grow with interest; advancing them is how interest accrues                |
| **Utilization (U)**   | `totalBorrow / totalSupply` in present value                                                        |
| **Kink**              | The utilization at which the borrow rate slope jumps steeply                                        |
| **Reserve factor**    | The share of borrow interest diverted to protocol reserves                                          |
| **Reserves**          | `cash + totalBorrow - totalSupply`, derived, the protocol's own equity buffer                       |
| **Absorb**            | Protocol-absorbed liquidation: debt wiped against reserves, collateral seized into the protocol     |
| **Storefront discount** | The below-oracle price at which seized collateral is sold via `buyCollateral`                     |
| **Bad debt**          | Debt wiped in an absorb that seized collateral value did not cover; recognized against reserves     |

---

**See also:**

- [Guide 2: Protocol Mathematics](./02-mathematics.md), every formula with its rounding direction
- [Guide 3: Technical Architecture](./03-architecture.md), contracts, state, flows, and ADRs
- [Guide 4: Trade-offs and Risk Matrix](./04-tradeoffs.md), what can go wrong and what bounds it
