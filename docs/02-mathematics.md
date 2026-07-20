# 🧮 Guide 2: Protocol Mathematics

**Version:** 1.0
**Prerequisites:** [Guide 1: Fundamentals](./01-fundamentals.md)
**Next:** [Guide 3: Technical Architecture](./03-architecture.md)

---

## 📋 Table of Contents

1. [Notation and Units](#1-notation-and-units)
2. [Index Accounting (Principal and Present Value)](#2-index-accounting-principal-and-present-value)
3. [Interest Accrual](#3-interest-accrual)
4. [Utilization](#4-utilization)
5. [Jump-Rate Interest Model](#5-jump-rate-interest-model)
6. [Interest Split and Reserve Growth](#6-interest-split-and-reserve-growth)
7. [Collateralization and Health](#7-collateralization-and-health)
8. [Liquidation Math (Absorb)](#8-liquidation-math-absorb)
9. [buyCollateral Pricing](#9-buycollateral-pricing)
10. [Rounding Policy](#10-rounding-policy)
11. [Configurable Parameters](#11-configurable-parameters)

---

> ⚠️ **Precision rules used throughout:** multiply before dividing; every division states its rounding direction (`floor` or `ceil`); every rounding direction favors the protocol. `floor(x)` is Solidity's default truncating division, `ceil(x) = floor((numerator + denominator - 1) / denominator)`.

---

## 1. Notation and Units

| Symbol / name           | Meaning                                              | Scale                          |
| :----------------------- | :---------------------------------------------------- | :------------------------------ |
| `BASE_SCALE`            | Base asset unit (USDC)                               | `1e6`                          |
| `BASE_INDEX_SCALE`      | Initial value of both indexes                        | `1e15`                         |
| `FACTOR_SCALE`          | Collateral factors, penalties, discounts             | `10_000` (basis points)        |
| `RATE_SCALE`            | Per-second interest rates, reserve factor            | `1e18`                         |
| `PRICE_SCALE`           | Oracle prices (USD per whole token)                  | `1e18`                         |
| `collateralScale_i`     | `10^decimals` of collateral asset i                  | `1e18` WETH, `1e8` wBTC        |
| `p`                     | Signed principal of an account (`int104`)            | base units at index-0 scale    |
| `pv`                    | Present value of a balance                           | base units (`1e6`)             |
| `S`, `B`                | `baseSupplyIndex`, `baseBorrowIndex`                 | `1e15`                         |
| `U`                     | Utilization                                          | `1e18`                         |
| `r`, `s`                | Borrow rate, supply rate (per second)                | `1e18`                         |
| `RF`                    | Reserve factor                                       | `1e18`                         |
| `dt`                    | Seconds elapsed since last accrual                   | seconds                        |

Health math is carried out in USD at `1e18` scale: `value_i = amount_i * price_i / collateralScale_i`.

---

## 2. Index Accounting (Principal and Present Value)

Accounts never store balances. They store a **principal**, fixed at write time, and the protocol derives the live balance (**present value**) by scaling with the relevant global index. Interest accrues for every account simultaneously by advancing two numbers ([Guide 3, Section 3](./03-architecture.md#3-state-layout)).

### Present value (principal to live balance)

```
presentValue(p):
    if p >= 0:  pv =  floor(  p  * S / BASE_INDEX_SCALE )     // supply rounds DOWN
    if p <  0:  pv = -ceil( (-p) * B / BASE_INDEX_SCALE )     // debt magnitude rounds UP
```

### Principal value (live balance to principal)

```
principalValue(pv):
    if pv >= 0:  p =  floor(  pv  * BASE_INDEX_SCALE / S )    // supply principal rounds DOWN
    if pv <  0:  p = -ceil( (-pv) * BASE_INDEX_SCALE / B )    // debt principal rounds UP
```

Both directions are chosen so a round trip can never favor the account:

```
presentValue(principalValue(pv)) <= pv          for pv >= 0   (supplier never gains)
|presentValue(principalValue(pv))| >= |pv|      for pv <  0   (borrower never owes less)
```

### Worked example

`S = 1.05e15` (supply index has grown 5%), `B = 1.08e15`:

| Action                              | Computation                                       | Result                        |
| :----------------------------------- | :-------------------------------------------------- | :----------------------------- |
| Supply 10,000 USDC (`1e10` units)   | `p = floor(1e10 * 1e15 / 1.05e15)`                | `p = 9,523,809,523` (9,523.81) |
| Read balance one accrual later      | `pv = floor(9,523,809,523 * 1.0501e15 / 1e15)`    | `10,000,952,380` (10,000.95)   |
| Borrow 15,000 USDC (`1.5e10`)       | `p = -ceil(1.5e10 * 1e15 / 1.08e15)`              | `p = -13,888,888,889`          |
| Read debt                           | `pv = -ceil(13,888,888,889 * 1.08e15 / 1e15)`     | `-15,000,000,001` (owes 1 unit more, rounding favors protocol) |

Global totals `totalSupplyBase` and `totalBorrowBase` are stored as principal too, so:

```
sum over accounts of max(p, 0)  == totalSupplyBase     // exact integer equality
sum over accounts of max(-p, 0) == totalBorrowBase     // exact integer equality
```

This pair of equalities is the load-bearing accounting invariant of the protocol (see [Guide 6, INV-1](./06-security.md#2-system-invariants)): it is exact, integer, index-free, and testable at any moment.

---

## 3. Interest Accrual

`accrue()` runs before any balance is read or written in every state-changing function:

```
dt = block.timestamp - lastAccrualTime          // 0 => early return
U  = getUtilization()                            // Section 4
r  = getBorrowRate(U)                            // Section 5
s  = getSupplyRate(U)                            // Section 5

S += floor( S * s * dt / RATE_SCALE )            // supply index rounds DOWN
B += ceil(  B * r * dt / RATE_SCALE )            // borrow index rounds UP

lastAccrualTime = block.timestamp
```

Properties:

- **Monotonicity.** `s >= 0` and `r >= 0`, so both indexes are non-decreasing and never fall below `BASE_INDEX_SCALE`.
- **No retroactive rate manipulation.** Every mutating operation accrues *before* changing balances, so the `U` used for the window `[lastAccrualTime, now]` is exactly the utilization that held throughout that window. Depositing a large supply cannot retroactively crush the rate someone else already earned.
- **Discrete compounding.** Interest is linear within one accrual window and compounds across windows. More frequent accrual yields marginally more compounding; the difference over any realistic window is far below the rounding budget and always in the same protocol-favorable direction as the index rounding.

---

## 4. Utilization

```
totalSupplyPV = presentValue(totalSupplyBase)    // floor (supply side)
totalBorrowPV = presentValue(totalBorrowBase)    // ceil  (borrow side)

U = 0                                            if totalSupplyPV == 0
U = floor( totalBorrowPV * 1e18 / totalSupplyPV )   otherwise
```

`U` rounds down; Section 6 shows this direction is safe for reserves.

**`U > 1e18` is a reachable state, not a bug.** Cash available for withdrawal is `cash = reserves + totalSupplyPV - totalBorrowPV`. With positive reserves, suppliers can withdraw more than `totalSupplyPV - totalBorrowPV`, leaving `totalBorrowPV > totalSupplyPV`:

```
totalSupplyPV = 1,000,000   totalBorrowPV = 900,000   reserves = 50,000
cash = 150,000
suppliers withdraw 150,000  =>  totalSupplyPV = 850,000, U = 900,000/850,000 = 1.0588
```

The rate curve simply evaluates past the kink and the interest split (Section 6) remains valid at any `U`.

---

## 5. Jump-Rate Interest Model

One kinked borrow curve, implemented in the immutable `InterestRateModel.sol` ([Guide 3, Section 4](./03-architecture.md#4-interest-rate-model)). All rates per second, `1e18` scale.

```
getBorrowRate(U):
    if U <= kink:
        r = baseRate + floor( slopeLow * U / 1e18 )
    else:
        r = baseRate + floor( slopeLow * kink / 1e18 )
                     + floor( slopeHigh * (U - kink) / 1e18 )
```

```
getSupplyRate(U):
    s = floor( floor( r * U / 1e18 ) * (1e18 - RF) / 1e18 )
```

Every division floors. Flooring `s` only lowers what suppliers receive, which Section 6 shows is reserve-safe. The curve is continuous at the kink (both branches agree at `U == kink`) and monotone in `U` (all slopes non-negative).

### Reference parameterization (annualized for readability)

`baseRate = 0`, `slopeLow` such that the borrow rate is 4% at the kink, `kink = 80%`, `slopeHigh = 100%/year`, `RF = 10%`:

| U      | Borrow rate (APR)          | Supply rate (APR)                | Regime            |
| :------ | :-------------------------- | :-------------------------------- | :----------------- |
| 0%     | 0.0%                       | 0.0%                             | Idle              |
| 50%    | 2.5%                       | `2.5 * 0.5 * 0.9` = 1.125%       | Normal            |
| 80%    | 4.0%                       | `4.0 * 0.8 * 0.9` = 2.88%        | At the kink       |
| 90%    | 4.0 + 100*(0.10) = 14.0%   | `14.0 * 0.9 * 0.9` = 11.34%      | Jump regime       |
| 100%   | 4.0 + 100*(0.20) = 24.0%   | `24.0 * 1.0 * 0.9` = 21.6%       | Exit liquidity defense |

Per-second conversion: `4%/year = 0.04e18 / 31,536,000 ≈ 1.268e9` at `RATE_SCALE`.

---

## 6. Interest Split and Reserve Growth

This section states the central solvency relationship of the rate system. It is a **directional inequality, not an exact equality**: the two indexes scale two independent principal bases with opposite rounding, so no exact integer identity between borrower interest and supplier interest plus the reserve cut exists or should be claimed. What the design guarantees is that the rounding residual always accrues to reserves.

### Real-valued identity (motivation)

In real arithmetic, with `s = r * U * (1 - RF)` and `U = totalBorrowPV / totalSupplyPV`:

```
supplierInterest = totalSupplyPV * s * dt
                 = totalSupplyPV * r * (totalBorrowPV / totalSupplyPV) * (1 - RF) * dt
                 = (1 - RF) * totalBorrowPV * r * dt
                 = (1 - RF) * borrowerInterest
```

`totalSupplyPV` cancels, so the identity holds for any `U`, including `U > 1` (Section 4).

### Integer-valued theorem (what the code guarantees)

Fix one accrual. Let `r` and `s` be the integer rates actually returned (computed from the floored `U`), and let `dSupplyPV` and `dBorrowPV` be the changes in present-value totals caused by the index updates.

```
Credited to suppliers (all floors):
    s <= r * U_real * (1 - RF) / 1e36                    (flooring U and s only reduces s)
    dSupplyPV <= totalSupplyPV * s * dt / 1e18
              <= (1 - RF) * totalBorrowPV * r * dt / 1e36

Charged to borrowers (index update ceils):
    dBorrowPV >= totalBorrowPV * r * dt / 1e18

Therefore:
    dReserves = dBorrowPV - dSupplyPV
             >= RF * totalBorrowPV * r * dt / 1e36
             >= 0
```

**Reading:** every accrual grows reserves by *at least* the reserve-factor share of borrower interest; every floor on the supplier side and every ceil on the borrower side pushes the residual into reserves, never out of them. Reserves never decrease from rounding, under any parameters and any utilization.

### Reserves are derived

```
reserves = baseToken.balanceOf(market) + totalBorrowPV - totalSupplyPV     // int256, may be negative
```

There is no stored counter to drift ([Guide 3, Section 3.4](./03-architecture.md#34-reserves-are-derived-never-stored)). Combining the theorem above with the directed rounding of every user operation gives the per-operation monotonicity table:

| Operation          | Effect on `getReserves()`                                   | Why                                                              |
| :------------------ | :----------------------------------------------------------- | :----------------------------------------------------------------- |
| `accrue`           | `>= RF share of borrower interest >= 0`                     | Theorem above                                                     |
| `supply` (base)    | `>= 0`                                                      | Cash in = amount; supply PV credited rounds down                  |
| `withdraw` (base)  | `>= 0`                                                      | Cash out = amount; supply PV removed rounds up                    |
| Borrow             | `>= 0`                                                      | Cash out = amount; debt PV added rounds up                        |
| Repay              | `>= 0`                                                      | Cash in = amount; debt PV removed rounds down                     |
| ERC20 `transfer`   | `>= 0`                                                      | Sender principal burn rounds up, receiver credit rounds down      |
| `buyCollateral`    | `> 0` (base side)                                           | Cash in, no base PV change (collateral leaves separately)         |
| `absorb`           | `<= 0`, bounded (Section 8)                                 | The only operation designed to spend reserves                     |
| `withdrawReserves` | `< 0` by owner intent                                       | Explicit treasury withdrawal                                      |

This table, not the derived-reserves formula itself, is what the invariant suite asserts ([Guide 6](./06-security.md#7-testing-plan)).

---

## 7. Collateralization and Health

All health math values collateral in USD (`1e18`) using the confidence-adjusted oracle price for the context ([Guide 3, Section 5](./03-architecture.md#5-oracle-system-pyth--chainlink)).

### Borrowing capacity (used by `withdraw`, protocol-favorable prices)

```
capacityUSD(a) = sum over collateral i held by a of:
    floor( userCollateral[a][i] * (price_i - conf_i) * borrowCF_i
           / (collateralScale_i * FACTOR_SCALE) )                     // floor

debtUSD(a) = ceil( borrowPV(a) * (priceBase + confBase) / BASE_SCALE )  // ceil

isBorrowCollateralized(a):  debtUSD(a) <= capacityUSD(a)
```

Collateral is valued at the low edge of the confidence band and rounds down; debt is valued at the high edge and rounds up. An account can only be *under*-estimated as healthy, never over-estimated.

Every `withdraw` that leaves or creates debt requires `isBorrowCollateralized` to hold afterwards, and `|borrowPV| >= minBorrow` (dust guard). `supply` needs no check: it can only improve health.

### Liquidation threshold (used by `absorb`, borrower-favorable prices)

```
liqCapacityUSD(a) = sum over collateral i held by a of:
    floor( userCollateral[a][i] * (price_i + conf_i) * liquidateCF_i
           / (collateralScale_i * FACTOR_SCALE) )

isLiquidatable(a):  debtUSD(a) > liqCapacityUSD(a)
```

Collateral is valued at the *high* edge for absorb eligibility: an account is never absorbed because of a noisy tick. The buffer `liquidateCF - borrowCF` (e.g. 85% vs 80%) is the price move an account can suffer between the last allowed borrow and absorbability.

### Worked example

10 WETH at 2,000 USD (conf 0), `borrowCF = 80%`, `liquidateCF = 85%`:

```
capacity     = 10 * 2,000 * 0.80 = 16,000 USD    (max debt at borrow time)
liq capacity = 10 * 2,000 * 0.85 = 17,000 USD    (absorbable above this)

borrow 15,000 USDC  =>  healthy, headroom 1,000 USD of capacity
price falls to 1,760 =>  liq capacity = 10 * 1,760 * 0.85 = 14,960 < 15,000  => absorbable
```

---

## 8. Liquidation Math (Absorb)

`absorb(account)` settles an underwater account in full: all collateral is seized into protocol ownership, the debt is wiped, and the account is credited the seized value after a penalty. See the flow in [Guide 3, Section 6.6](./03-architecture.md#66-absorb-liquidation-step-1).

### Seize valuation and settlement

Seize valuation uses the **mid** oracle price (eligibility already used `price + conf`; the penalty and discount factors price the residual execution risk):

```
seizeValueUSD  = sum over i of floor( amount_i * price_i / collateralScale_i )               // floor
creditValueUSD = sum over i of floor( amount_i * price_i * liquidationFactor_i
                                      / (collateralScale_i * FACTOR_SCALE) )                 // floor

creditBase = floor( creditValueUSD * BASE_SCALE / priceBase )                                // floor

newBalance = -debtPV + creditBase
if newBalance < 0:
    badDebt    = -newBalance        // recognized immediately against reserves
    newBalance = 0

principal(account) = principalValue(newBalance)     // floor (supply side)
```

The penalty retained by the protocol is `(1 - liquidationFactor)` of the seized value; it compensates the protocol for taking price risk on the collateral inventory between absorb and sale.

### Reserves impact

`absorb` reduces `totalBorrowPV` by `debtPV` and increases `totalSupplyPV` by any surplus credited back, with no cash movement, so:

```
dReserves(absorb) = -max( debtPV, creditBase )
```

| Case                          | Condition               | Reserves fall by | Account ends with            | Bad debt        |
| :----------------------------- | :----------------------- | :---------------- | :---------------------------- | :--------------- |
| Surplus                       | `creditBase > debtPV`   | `creditBase`     | `creditBase - debtPV` supplied | 0               |
| Exact                         | `creditBase == debtPV`  | `debtPV`         | 0                            | 0               |
| Shortfall                     | `creditBase < debtPV`   | `debtPV`         | 0                            | `debtPV - creditBase` |

In exchange, the protocol now owns collateral worth `seizeValueUSD = creditValueUSD / liquidationFactor > creditValueUSD` at mark, to be recovered through `buyCollateral` (Section 9).

### Coverage at the eligibility boundary (confidence-band interaction)

Absorb eligibility uses `price + conf` while seize valuation uses mid price, so it must be shown that a *promptly absorbed* account (one absorbed just as it crosses the threshold) is covered even under the widest confidence the oracle accepts. At the crossing point, per unit of collateral value:

```
debt ≈ (price + conf) * liquidateCF        (just crossed the threshold)
credit =  price * liquidationFactor        (mid-price seize, credited at LF)

credit >= debt  ⇔  price * LF >= (price + conf) * liquidateCF
              ⇔  LF >= liquidateCF * (1 + conf/price)
```

Since the oracle rejects any price with `conf/price > MAX_CONFIDENCE_BPS`, the **parameterization invariant** enforced at construction ([Guide 5](./05-implementation.md#7-pre-deployment-checklist), [Guide 6, INV-13](./06-security.md#2-system-invariants)) is:

```
liquidationFactor >= liquidateCollateralFactor * (10_000 + MAX_CONFIDENCE_BPS) / 10_000
```

With the reference parameters (`liquidateCF = 85%`, `MAX_CONFIDENCE_BPS = 200`): required `LF >= 86.7%`; chosen `LF = 93%` leaves a margin of `93% - 86.7% = 6.3%` of collateral value per unit, covering rounding and the gap between the threshold and the actual absorb price.

**When the condition cannot save you:** if the price gaps *through* the buffer before anyone absorbs (a crash faster than liquidators, or an oracle outage during which `absorb` reverts by policy), `creditBase < debtPV` and the residual is **recognized bad debt**, on the books immediately, in the shortfall row above. The protocol never hides it in an unliquidatable account; the adversarial scenarios in [Guide 6](./06-security.md#4-adversarial-scenarios) quantify it.

### Worked example (continuing Section 7)

`debtPV = 15,000`, 10 WETH seized, `LF = 93%`, `priceBase = 1.0`:

```
Prompt absorb at 1,760:
    seizeValue  = 17,600      credit = 17,600 * 0.93 = 16,368
    newBalance  = -15,000 + 16,368 = +1,368   (surplus, credited as base supply)
    dReserves   = -16,368;  protocol holds 10 WETH worth 17,600

Gapped absorb at 1,400 (price crashed before absorption):
    seizeValue  = 14,000      credit = 14,000 * 0.93 = 13,020
    newBalance  = -15,000 + 13,020 = -1,980  =>  badDebt = 1,980, account zeroed
    dReserves   = -15,000;  protocol holds 10 WETH worth 14,000
```

---

## 9. buyCollateral Pricing

Seized collateral is sold to anyone for base at a discount to the mid oracle price, only while `getReserves() < targetReserves` ([Guide 3, Section 6.7](./03-architecture.md#67-buy-collateral-liquidation-step-2)).

```
discount = floor( storeFrontPriceFactor * (FACTOR_SCALE - liquidationFactor) / FACTOR_SCALE )   // bps, floor

askPriceUSD = floor( price * (FACTOR_SCALE - discount) / FACTOR_SCALE )                          // floor

quote = floor( baseAmount * priceBase * collateralScale / (BASE_SCALE * askPriceUSD) )           // collateral out, floor
require quote >= minAmount                                                                        // buyer slippage guard
```

Flooring `discount` shrinks the discount and flooring `quote` gives the buyer less collateral: both favor the protocol.

### Round-trip bound (absorb then sell, stable prices)

Because `storeFrontPriceFactor <= FACTOR_SCALE`:

```
discount <= (1 - liquidationFactor)   =>   (1 - discount) >= liquidationFactor
saleProceeds = seizeValue * (1 - discount) >= seizeValue * LF = creditValue
```

- **Surplus/exact case:** reserves fell by `creditBase` at absorb; selling all collateral returns `>= creditBase`. The round trip is reserve-non-negative, and the protocol nets the penalty minus the discount: `seizeValue * (1 - LF) * (1 - storeFrontPriceFactor)` plus rounding dust.
- **Shortfall case:** reserves fell by `debtPV > creditBase`; proceeds are `>= creditBase` but may not reach `debtPV`. The residual loss is bounded by the already-recognized bad debt: `debtPV - proceeds <= badDebt`.

### Worked example (continuing Section 8, prompt absorb)

`LF = 93%`, `storeFrontPriceFactor = 50%`:

```
discount = 0.50 * (1 - 0.93) = 3.5%
askPrice = 1,760 * 0.965 = 1,698.40
proceeds for 10 WETH = 16,984 USDC

reserves: -16,368 (absorb) + 16,984 (sale) = +616
check: penalty kept = 17,600 * (0.07 - 0.035) = 616  ✓
```

---

## 10. Rounding Policy

Single rule: **when the protocol and an account are on opposite sides of a division, round toward the protocol.** The complete catalogue:

| Quantity                                   | Direction        | Loser of the wei     |
| :------------------------------------------ | :---------------- | :-------------------- |
| `baseSupplyIndex` accrual                  | floor            | Suppliers            |
| `baseBorrowIndex` accrual                  | ceil             | Borrowers            |
| `presentValue` of supply                   | floor            | Supplier             |
| `presentValue` of debt (magnitude)         | ceil             | Borrower             |
| Supply principal credited on deposit       | floor            | Supplier             |
| Supply principal burned on withdrawal      | ceil             | Supplier             |
| Debt principal added on borrow (magnitude) | ceil             | Borrower             |
| Debt principal after repay (magnitude)     | ceil             | Borrower             |
| Utilization                                | floor            | Suppliers (rate side, reserve-safe per Section 6) |
| `getSupplyRate` (every step)               | floor            | Suppliers            |
| Collateral value in borrow capacity        | floor + `price - conf` | Borrower       |
| Debt value in health checks                | ceil + `price + conf`  | Borrower       |
| Seize credit at absorb                     | floor            | Absorbed account     |
| `buyCollateral` discount                   | floor            | Buyer                |
| `buyCollateral` quote (collateral out)     | floor            | Buyer                |

Consequences worth stating:

- Rounding dust accumulates in reserves (Section 6 table); it is never claimable by any account.
- Directional rounding, not magnitude, is the invariant: fuzz tests assert direction on every operation, not dust size ([Guide 6, Testing Plan](./06-security.md#7-testing-plan)).
- With 6-decimal USDC one wei of rounding is `1e-6` USDC; `minBorrow` (100 USDC) keeps positions far above the scale where dust is user-visible.

---

## 11. Configurable Parameters

All values fixed at deployment (immutable, [ADR-3](./03-architecture.md#adr-3-immutable-deployment-vs-upgradeable-proxy)).

### Interest rate model

| Parameter   | Reference value      | Constraint                       |
| :----------- | :-------------------- | :-------------------------------- |
| `baseRate`  | 0%/year              | `>= 0`                           |
| `slopeLow`  | 5%/year (4% at kink) | `>= 0`                           |
| `slopeHigh` | 100%/year            | `>= slopeLow`                    |
| `kink`      | 80%                  | `0 < kink < 1e18`                |
| `RF`        | 10%                  | `0 <= RF < 1e18`                 |

### Per-collateral (WETH / wBTC reference)

| Parameter               | WETH   | wBTC   | Constraint                                                        |
| :----------------------- | :------ | :------ | :------------------------------------------------------------------ |
| `borrowCollateralFactor` | 80%    | 75%    | `0 < borrowCF < liquidateCF`                                      |
| `liquidateCollateralFactor` | 85% | 80%    | `borrowCF < liquidateCF < 100%`                                   |
| `liquidationFactor`     | 93%    | 93%    | `>= liquidateCF * (10_000 + MAX_CONFIDENCE_BPS) / 10_000` (Section 8) |
| `storeFrontPriceFactor` | 50%    | 50%    | `0 < SF <= 100%`                                                  |
| `supplyCap`             | sized per market | sized per market | `> 0`                                           |

### Market

| Parameter        | Reference value | Purpose                                            |
| :---------------- | :--------------- | :--------------------------------------------------- |
| `minBorrow`      | 100 USDC        | No dust debts cheaper to ignore than to absorb      |
| `targetReserves` | 100,000 USDC    | `buyCollateral` only sells while reserves are below |

### Oracle

| Parameter            | Reference value | Purpose                                  |
| :-------------------- | :--------------- | :----------------------------------------- |
| `MAX_STALENESS`      | 60 s            | Reject old Pyth prices                    |
| `MAX_CONFIDENCE_BPS` | 200 (2%)        | Reject uncertain prices; bounds Section 8 coverage condition |
| `MAX_DEVIATION_BPS`  | 300 (3%)        | Pyth vs Chainlink anchor circuit breaker  |

---

**See also:**

- [Guide 3: Technical Architecture](./03-architecture.md), where each formula executes
- [Guide 4: Trade-offs and Risk Matrix](./04-tradeoffs.md), what happens when assumptions fail
- [Guide 6: Security](./06-security.md), the invariants these formulas must uphold
