# ⚖️ Guide 4: Trade-offs and Risk Matrix

**Version:** 1.0
**Prerequisites:** [Guide 3: Technical Architecture](./03-architecture.md)
**Next:** [Guide 5: Solidity Implementation](./05-implementation.md)

---

## 📋 Table of Contents

1. [How to Read This Document](#1-how-to-read-this-document)
2. [Risk 1: Oracle Manipulation](#risk-1-oracle-manipulation)
3. [Risk 2: Oracle Failure](#risk-2-oracle-failure)
4. [Risk 3: Bad Debt and Insolvency](#risk-3-bad-debt-and-insolvency)
5. [Risk 4: Liquidation Front-Running and MEV](#risk-4-liquidation-front-running-and-mev)
6. [Risk 5: Interest-Rate and Utilization Manipulation](#risk-5-interest-rate-and-utilization-manipulation)
7. [Risk 6: The 100% Utilization Edge](#risk-6-the-100-utilization-edge)
8. [Risk 7: Reserve Depletion](#risk-7-reserve-depletion)
9. [Risk 8: Rounding and Precision](#risk-8-rounding-and-precision)
10. [Risk 9: First-Depositor / Share-Inflation Attack](#risk-9-first-depositor--share-inflation-attack)
11. [Risk 10: Donation Attacks](#risk-10-donation-attacks)
12. [Risk 11: Rebasing Token Integrations](#risk-11-rebasing-token-integrations)
13. [Risk 12: Immutability](#risk-12-immutability)
14. [Risk Matrix](#14-risk-matrix)
15. [Future Work](#15-future-work)

---

## 1. How to Read This Document

Each risk is stated as: **the risk** (what breaks and how), **the mitigation** (what the design does about it), and **the residual risk** (what remains after the mitigation, stated honestly). Severity in the final matrix follows impact x likelihood.

A structural note up front: several classic lending-protocol risks are *absent by construction* here rather than mitigated, because of the single-base model and derived accounting (Risks 9 and 10 in particular). Absence-by-construction is stronger than mitigation and is called out explicitly where it applies.

---

## Risk 1: Oracle Manipulation

**The risk.** An attacker who moves the reported price of a collateral asset upward mints borrowing capacity out of nothing (borrow against inflated WETH, walk away when the price corrects, leaving bad debt). Moving it downward triggers absorbs of healthy accounts, transferring their penalty to the protocol and cheap collateral to `buyCollateral` buyers. Lending protocols die this way more often than any other way.

**The mitigation.** Defense in depth in the oracle pipeline ([Guide 3, Section 5](./03-architecture.md#5-oracle-system-pyth--chainlink)):

- Pyth aggregates 100+ first-party publishers under slashing (Oracle Integrity Staking); no on-chain AMM state is ever read, so flash-loan spot manipulation is structurally irrelevant.
- The Chainlink deviation anchor rejects any Pyth price further than `MAX_DEVIATION_BPS` from an independent source: manipulating the protocol requires corrupting two unrelated oracle systems simultaneously.
- The confidence check rejects prices during publisher disagreement, exactly when manipulation is most feasible.
- Band-edge valuation (capacity at `price - conf`, absorb eligibility at `price + conf`, [Guide 2, Section 7](./02-mathematics.md#7-collateralization-and-health)) means small manipulations within the confidence interval cannot flip a health decision in the attacker's favor.

**The residual risk.** A coordinated corruption of both Pyth and Chainlink for the same asset, or a manipulation smaller than both the deviation and confidence bounds. The latter is capped: a price error of at most `MAX_DEVIATION_BPS` (3%) against a collateral factor buffer of 15 to 20% cannot on its own make a healthy account absorbable or an underwater account healthy. Bounded, accepted.

---

## Risk 2: Oracle Failure

**The risk.** Pyth stops publishing (or Wormhole halts), Chainlink stalls past its heartbeat, or the two sources diverge past the deviation bound during a violent move. Every price-consuming function reverts: no new borrows, no collateral withdrawals with debt, and critically, **no absorbs**.

**The mitigation.** The failure policy is explicit and chosen, not accidental ([Guide 3, Oracle Failure Policy](./03-architecture.md#oracle-failure-policy-accepted-risk)):

- Reverting beats mispricing: the protocol never liquidates or lends against an unverifiable price.
- Health-improving actions (`supply`, repay, debt-free withdrawals) never touch the oracle and keep working through any outage: borrowers can always save themselves.
- Absorb needs only one fresh Hermes update to resume; outages are bounded by Pyth/Wormhole recovery time, historically minutes.

**The residual risk.** Collateral that crashes *during* an outage is absorbed late at post-crash prices; the difference between the threshold price and the resumption price becomes bad debt (quantified in [Guide 6, Scenario S2](./06-security.md#4-adversarial-scenarios)). This is the price of refusing to liquidate blind, and it is absorbed by reserves (Risk 7).

---

## Risk 3: Bad Debt and Insolvency

**The risk.** Debt exceeds what the backing collateral can repay. In many protocols bad debt is invisible: it lives in accounts nobody liquidates, silently socialized among suppliers who discover it in a bank run.

**The mitigation.** This design's core claim is not "bad debt cannot happen" (no overcollateralized protocol can claim that under gap risk); it is "bad debt is bounded, recognized instantly, and visible":

- **Bounded** by the buffer stack: `borrowCF < liquidateCF` (price buffer), `liquidationFactor` coverage condition guaranteeing prompt absorbs are covered even at maximum confidence width ([Guide 2, Section 8](./02-mathematics.md#8-liquidation-math-absorb)), and `minBorrow` guaranteeing every debt is worth absorbing.
- **Recognized instantly**: `absorb` books the shortfall against reserves at settlement, and `getReserves()` can go negative, so insolvency is a readable on-chain number, never a hidden one.
- **Absorbed by a funded buffer**: reserves grow every accrual by at least the reserve-factor share plus all rounding residue ([Guide 2, Section 6](./02-mathematics.md#6-interest-split-and-reserve-growth)), plus liquidation penalties.

**The residual risk.** A gap larger than the whole buffer stack (collateral falls >15-20% before absorption) creates bad debt that reserves may not cover. With negative reserves, the market keeps operating but the last suppliers to exit bear the hole: `cash < totalSupplyPV - totalBorrowPV`. There is no Layer-2 backstop (no safety module, no bonding) in this PoC; that is stated, not hidden. See [Guide 6, Scenario S1/S4](./06-security.md#4-adversarial-scenarios).

---

## Risk 4: Liquidation Front-Running and MEV

**The risk.** In close-factor designs, the liquidation transaction itself carries the profit, so it is the most front-run transaction in DeFi: bots outbid each other for the bonus, and the borrower pays for a gas auction. Failed races strand accounts underwater.

**The mitigation.** The absorb model restructures the MEV rather than pretending to remove it ([Guide 3, ADR-2](./03-architecture.md#adr-2-absorb-liquidation-vs-close-factor-liquidation)):

- `absorb` pays its caller nothing, so there is nothing to front-run in the solvency-critical step. Racing to absorb first is racing to do the protocol a favor.
- Profit sits in `buyCollateral` at a *fixed* discount: competition between bots is on speed, not price, and cannot worsen the protocol's execution below the storefront price.
- The discount is bounded above by the penalty already charged to the borrower (`storeFrontPriceFactor <= 100%`), so MEV extraction is capped by construction ([Guide 2, Section 9](./02-mathematics.md#9-buycollateral-pricing)).

**The residual risk.** Who calls `absorb` at all, if it pays nothing? The rational absorber is whoever intends to buy the collateral next block (vertical integration of the two steps), which works when the discount exceeds two transactions of gas: `minBorrow` and the storefront margin are sized for that. In a dead-mempool chain state, absorbs may lag; the lag converts into Risk 3. Additionally, a `buyCollateral` buyer can be sandwiched on the open market when hedging; that is their MEV problem, not the protocol's.

---

## Risk 5: Interest-Rate and Utilization Manipulation

**The risk.** An attacker manipulates `U` to distort rates: spiking utilization to punish borrowers or gouge a rate-sensitive integration, or crushing it right before an accrual to retroactively cheapen their own interest window.

**The mitigation.**

- **No retroactive window exists.** Every mutating operation accrues *before* changing balances, so each accrual window is priced at the utilization that actually held during it ([Guide 2, Section 3](./02-mathematics.md#3-interest-accrual)). Sandwiching an accrual is impossible by ordering.
- **Manipulating U costs real money for real time.** Pushing U up means borrowing at the jump rate (24% APR at U=1 in the reference curve) with overcollateralization; pushing it down means supplying capital that earns the crushed rate. The attacker pays the distorted rate themselves for every second the distortion lasts.
- The kink design self-corrects: distorted rates immediately incentivize the opposite flow.

**The residual risk.** Short-lived rate spikes can still grief borrowers with thin health margins (higher debt accrual per second), but the effect over any realistic manipulation window is orders of magnitude below the `liquidateCF - borrowCF` buffer. Accepted.

---

## Risk 6: The 100% Utilization Edge

**The risk.** At `U = 1` there is no cash: suppliers cannot withdraw and new borrows revert. If sustained, this is a soft bank-run trap, and in protocols that mishandle it, an attacker can park utilization at 100% cheaply to lock suppliers in.

**The mitigation.**

- Withdrawals and borrows revert on insufficient cash rather than misaccounting; funds are never lost, only queued behind repayments ([Guide 3, Section 6.3](./03-architecture.md#63-withdraw-base-also-borrow)).
- The jump rate makes camping at high utilization expensive: at `U = 1` the reference curve charges 24% APR while paying suppliers 21.6%, a spread that attracts supply and forces repayment. Sustaining the lock costs the attacker the full jump-rate spread on the entire borrowed amount.
- `U > 1` (reachable when reserves have been paid out, [Guide 2, Section 4](./02-mathematics.md#4-utilization)) steepens rates further rather than breaking any formula.

**The residual risk.** Suppliers face liquidity risk, not solvency risk: temporary inability to exit during demand spikes. No queueing or emergency-rate mechanism exists in this PoC. Accepted and disclosed.

---

## Risk 7: Reserve Depletion

**The risk.** Reserves are the absorb model's working capital: every absorption spends them before the collateral sale replenishes them. Depleted or negative reserves mean bad debt lands directly on suppliers, and heavy absorption during a crash can deplete them exactly when needed most.

**The mitigation.**

- Three inflows, all protocol-favorable: the reserve-factor share of every accrual plus all rounding residue ([Guide 2, Section 6](./02-mathematics.md#6-interest-split-and-reserve-growth)), the liquidation penalty margin on every prompt absorb round trip (proven reserve-non-negative at stable prices, [Guide 2, Section 9](./02-mathematics.md#9-buycollateral-pricing)), and direct funding: any donation of base is, by the derived-reserves definition, a reserve contribution, so the deployer can seed reserves with a plain transfer.
- One outflow gate: `withdrawReserves` is owner-only, and `buyCollateral` only operates while `getReserves() < targetReserves`, so collateral inventory converts to reserves precisely when reserves are low.
- Supply caps per collateral bound the maximum simultaneous absorption load.

**The residual risk.** A correlated crash across WETH and wBTC can absorb faster than penalties replenish; reserves go negative and the market runs insolvent-but-operating (Risk 3). Recovery is then organic (interest and penalties over time) or manual (treasury re-donation). No automatic recapitalization layer exists in this PoC.

---

## Risk 8: Rounding and Precision

**The risk.** Index-based accounting performs divisions on every operation. A single division rounded toward the user is a money pump: repeat it in a loop until the drained dust exceeds gas. USDC's 6 decimals make each wei worth `1e-6` dollars, so the loop only needs to be cheap.

**The mitigation.** A single global policy, not per-case judgment: every division where the protocol and an account are on opposite sides rounds toward the protocol, catalogued exhaustively in [Guide 2, Section 10](./02-mathematics.md#10-rounding-policy). The consequence is structural: every operation's net effect on reserves is non-negative except `absorb` and `withdrawReserves` ([Guide 2, Section 6 table](./02-mathematics.md#6-interest-split-and-reserve-growth)), which turns "no rounding leak exists" into a machine-checkable invariant instead of a review opinion. Fuzz tests assert the direction of every rounding site; the invariant suite asserts the reserve monotonicity globally ([Guide 6, Testing Plan](./06-security.md#7-testing-plan)).

**The residual risk.** Users systematically lose the dust (fractions of a cent per operation); `minBorrow` keeps this economically invisible. Round-trip losses on tiny amounts are the accepted cost of the direction policy.

---

## Risk 9: First-Depositor / Share-Inflation Attack

**The risk.** The classic ERC-4626 kill: the first depositor mints 1 wei of shares, donates assets to inflate the share price, and rounds subsequent depositors' shares down to zero, stealing their deposits. Any protocol whose balances are `shares * totalAssets / totalShares` must confront it.

**The mitigation.** **Absent by construction.** There is no share price. A deposit credits `principal = floor(amount * BASE_INDEX_SCALE / baseSupplyIndex)` where the index starts at a known constant and grows only through rate accrual ([Guide 2, Section 2](./02-mathematics.md#2-index-accounting-principal-and-present-value)). No term in that formula depends on the contract's token balance or on other users' deposits, so there is nothing a first depositor or donor can inflate. The exchange rate between principal and balance is a function of time and rates, not of pool composition.

**The residual risk.** None from this vector. The index does grow over the market's life, so very late, very small deposits lose proportionally more to the floor; bounded by one wei per deposit, protocol-favorable.

---

## Risk 10: Donation Attacks

**The risk.** Sending tokens directly to a protocol contract (no function call) to distort any accounting derived from `balanceOf`: share prices, utilization, fee calculations, or solvency checks.

**The mitigation.** All accounting is internal; `balanceOf` appears in exactly one derived quantity:

- **Base donations** enter `getReserves() = cash + totalBorrowPV - totalSupplyPV` and nowhere else: a donation is a gift to reserves (this is the deliberate reserve-seeding mechanism of Risk 7). Utilization uses present values, not cash, so donations cannot move rates.
- **Collateral donations** touch nothing: `userCollateral` and `totalsCollateral` are internal ledgers, health checks read them and never `balanceOf`. Donated collateral is simply unattributed inventory (`balanceOf >= totalsCollateral` is the corresponding invariant, [Guide 6, INV-6](./06-security.md#2-system-invariants)). Since [ADR-7](./03-architecture.md#adr-7-collateral-total-as-user-claims-vs-whole-pool) that inventory (donated or seized) is exactly what `getCollateralReserves` derives and `buyCollateral` may sell; the flip side is that the supply cap now bounds only the sum of user claims, not the protocol's total physical holdings of a collateral, and that the derivation restricts listing to tokens whose `balanceOf` never falls below `totalsCollateral` outside a protocol call (no rebasing-down, no fee-on-transfer; [Guide 6, asset listing](./06-security.md#asset-listing-restrictions)).

**The residual risk.** Donated collateral is permanently stuck (no sweep function; adding one would create an owner power over the custody balance, deliberately avoided). Cosmetic only.

---

## Risk 11: Rebasing Token Integrations

**The risk.** `lmUSDC` balances grow in place ([Guide 3, ADR-5](./03-architecture.md#adr-5-signed-principal-and-rebasing-erc20)). Contracts that cache balances (AMM pools, vaults computing `balanceOf` deltas, escrows) silently strand the accrued interest or misprice the token. This is inherent to any rebasing asset (Aave's aTokens share it).

**The mitigation.** Not solvable at the token layer without changing the model (a wrapper vault is the standard fix, out of scope). The protocol's own surface is kept safe: `transfer` cannot create debt (sender principal may never go negative), so no integration can accidentally borrow.

**The residual risk.** Integrators must be warned in every interface doc; naive integrations lose yield, never principal. Accepted for a PoC.

---

## Risk 12: Immutability

**The risk.** The flip side of [ADR-3](./03-architecture.md#adr-3-immutable-deployment-vs-upgradeable-proxy): a bug in the market, curve, or oracle cannot be patched, and parameters cannot track reality (a collateral factor safe at deployment may be reckless after the asset's liquidity migrates elsewhere; a dead Chainlink feed bricks the deviation anchor forever).

**The mitigation.** The incident path is pause-and-migrate: the guardian freezes the affected flows (granular flags, [Guide 6, Pause Philosophy](./06-security.md#5-pause-and-circuit-breaker-philosophy)), repayments and exits stay open, and liquidity moves to a corrected redeployment. Immutability is also itself a mitigation: no upgrade key exists to compromise, and what was audited is what runs.

**The residual risk.** Migration is slow, reputationally costly, and strands anyone inattentive in a paused market. A production version would pay for a Comet-style Configurator behind a timelocked governance to get parameter agility back (Future Work); the PoC accepts the trade explicitly.

---

## 14. Risk Matrix

Severity from the impact x likelihood matrix (H/M/L).

| # | Risk                                | Impact | Likelihood | Severity | Primary mitigation                                        | Residual                                  |
| :- | :----------------------------------- | :------ | :---------- | :-------- | :---------------------------------------------------------- | :------------------------------------------ |
| 1 | Oracle manipulation                 | High   | Low        | M        | Dual-source anchor + confidence bands                     | Sub-bound manipulation, capped by buffers  |
| 2 | Oracle failure                      | Medium | Medium     | M        | Revert-not-misprice; repayments never blocked             | Late absorbs during outage become bad debt |
| 3 | Bad debt / insolvency               | High   | Low        | M        | Buffer stack + instant recognition + funded reserves      | Gap risk beyond buffers, negative reserves |
| 4 | Liquidation front-running / MEV     | Low    | High       | M        | Absorb decouples solvency from profit; fixed-price sale   | Absorb latency when unprofitable           |
| 5 | Rate / utilization manipulation     | Low    | Low        | L        | Accrue-before-action; manipulation pays its own cost      | Short-lived rate griefing                  |
| 6 | 100% utilization                    | Medium | Medium     | M        | Jump rate + revert-on-cash                                | Supplier liquidity risk (no loss)          |
| 7 | Reserve depletion                   | High   | Low        | M        | RF + penalties + rounding inflows; targetReserves gate    | Correlated-crash depletion, manual refill  |
| 8 | Rounding / precision                | High   | Low        | M        | Global protocol-favorable direction policy + invariants   | User-side dust                             |
| 9 | First-depositor inflation           | High   | Low*       | L        | Absent by construction (no share price)                   | None                                       |
| 10 | Donation attacks                   | Low    | Medium     | L        | Internal ledgers; donations become reserves               | Stuck donated collateral (cosmetic)        |
| 11 | Rebasing integrations              | Medium | Medium     | M        | Debt-safe transfers; integrator warnings                  | Third-party yield loss                     |
| 12 | Immutability                       | Medium | Medium     | M        | Granular pause + migrate; no upgrade key to steal         | Slow incident recovery, parameter drift    |

\* Likelihood reflects the attack being attempted against a design where it cannot succeed.

---

## 15. Future Work

Deliberately out of scope for this PoC, in dependency order for a production path:

1. **Governance and protocol token.** Timelocked parameter management replacing the immutable configuration; prerequisite for everything below.
2. **Upgradeability path.** Comet-style Configurator + proxy under governance, restoring parameter agility (Risk 12) at the cost of a governed upgrade key.
3. **Rewards distribution.** Supplier/borrower incentive accrual with per-account tracking indexes (the `baseTrackingIndex` half of Comet deliberately omitted here).
4. **Operator flows.** `supplyTo` / `withdrawFrom` with allowances, enabling managers, routers, and account abstraction.
5. **Flash loans** on idle base cash, fee-accruing to reserves.
6. **Multi-chain and multi-market.** Additional deployments (a WETH-base market) and cross-chain considerations.
7. **Backstop layer.** A safety module or bonding mechanism giving Risk 3/7 an automatic recapitalization path instead of a manual one.

---

**See also:**

- [Guide 2: Protocol Mathematics](./02-mathematics.md), the formulas these risks stress
- [Guide 6: Security](./06-security.md), invariants, adversarial scenarios, and the testing plan
