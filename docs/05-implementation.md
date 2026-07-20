# 💻 Guide 5: Solidity Implementation

**Version:** 1.0
**Prerequisites:** [Guide 4: Trade-offs and Risk Matrix](./04-tradeoffs.md)
**Next:** [Guide 6: Security](./06-security.md)

---

## 📋 Table of Contents

1. [Tech Stack](#1-tech-stack)
2. [Core Data Structures](#2-core-data-structures)
3. [Interfaces and Function Contracts](#3-interfaces-and-function-contracts)
4. [Precision and Decimals Handling](#4-precision-and-decimals-handling)
5. [Custom Errors](#5-custom-errors)
6. [Access Control Matrix](#6-access-control-matrix)
7. [Pre-Deployment Checklist](#7-pre-deployment-checklist)

---

> This guide specifies the implementation surface: signatures, contracts between caller and callee, units, errors, and permissions. It intentionally contains no function bodies; the formulas each function must implement live in [Guide 2](./02-mathematics.md) and the flows in [Guide 3](./03-architecture.md).

---

## 1. Tech Stack

| Component           | Technology                                        | Why                                                          |
| :------------------- | :-------------------------------------------------- | :-------------------------------------------------------------- |
| **Language**        | Solidity 0.8.26                                   | Checked arithmetic, custom errors, transient storage ready     |
| **Framework**       | Foundry                                           | Native fuzz/invariant testing, fast iteration                  |
| **Libraries**       | OpenZeppelin v5 (`Ownable2Step`, `SafeERC20`)     | Audited access control and token handling                     |
|                     | Solady (`FixedPointMathLib`, `SafeCastLib`)       | `mulDivDown`/`mulDivUp` for directed rounding, cheap safe casts |
| **Oracle SDK**      | Pyth Solidity SDK                                 | `updatePriceFeeds`, price struct decoding                      |
| **Standards**       | ERC-20 (the market itself is the rebasing token)  | [Guide 3, ADR-5](./03-architecture.md#adr-5-signed-principal-and-rebasing-erc20) |
| **Linters**         | Solhint + Prettier (solidity plugin)              | CI-enforced formatting                                          |

Contract layout:

```
src/
├── LendingMarket.sol            # Singleton: accounting, custody, ERC20
├── InterestRateModel.sol        # Stateless kinked curve
├── PythChainlinkOracle.sol      # Price validation pipeline
└── interfaces/
    ├── ILendingMarket.sol
    ├── IInterestRateModel.sol
    └── IPriceOracle.sol
```

---

## 2. Core Data Structures

Authoritative packing (documented rationale in [Guide 3, Section 3](./03-architecture.md#3-state-layout)):

```solidity
struct MarketState {
    uint64 baseSupplyIndex;   //  8 bytes ─┐
    uint64 baseBorrowIndex;   //  8 bytes  │  Slot 0 (22 bytes)
    uint40 lastAccrualTime;   //  5 bytes  │
    uint8 pauseFlags;         //  1 byte  ─┘
    uint104 totalSupplyBase;  // 13 bytes ─┐  Slot 1 (26 bytes)
    uint104 totalBorrowBase;  // 13 bytes ─┘
}

struct UserBasic {
    int104 principal;   // 13 bytes ─┐  Slot 0 (15 bytes)
    uint16 assetsIn;    //  2 bytes ─┘
}

struct CollateralConfig {
    address asset;                     // 20 bytes ─┐
    uint16 borrowCollateralFactor;     //  2 bytes  │
    uint16 liquidateCollateralFactor;  //  2 bytes  │  Slot 0 (28 bytes)
    uint16 liquidationFactor;          //  2 bytes  │
    uint16 storeFrontPriceFactor;      //  2 bytes ─┘
    uint128 supplyCap;                 // 16 bytes ─┐  Slot 1 (17 bytes)
    uint8 decimals;                    //  1 byte  ─┘
}
```

Bounds justification:

- `int104` principal: max `1.01e31` base units = `1e25` USDC at 6 decimals; unreachable.
- `uint104` totals: same bound as the sum of all principals of one sign (INV-1 keeps them equal, so neither can overflow before the other).
- `uint64` indexes at `1e15`: overflow at 18,446x growth; at a permanent 100% APR that is over 14 years of compounding, far beyond a PoC market's life, and the overflow reverts rather than corrupting.
- `uint40 lastAccrualTime`: overflows in the year 36812.

### Why `1e15` and not WAD or RAY for the index scale

Aave carries its `liquidityIndex` and `variableBorrowIndex` as `uint128` at RAY (`1e27`). This design uses `uint64` at `1e15` instead, and the reasoning is worth stating because "more precision is better" is the obvious intuition and it does not hold here.

**The scale is bounded by the type, and the type is bounded by the slot.** `type(uint64).max ≈ 1.845e19`, so a `1e15` seed allows 18,446x of index growth while a `1e18` seed would allow only 18.4x, which is reachable. Widening to `uint128` would remove that constraint, but it breaks the `MarketState` packing: two `uint128` indexes fill an entire slot on their own, pushing `lastAccrualTime` and `pauseFlags` into a second one. Since `accrue()` writes all three fields and runs at the top of every mutating function, that converts one `SSTORE` into two on the hottest path in the protocol.

**The extra digits carry no signal at a 6 decimal base.** Two independent quantizations sit below the index:

1. The per-second rate is itself quantized at `1e18`. At 4% APR, `rate ≈ 1.268e9`, roughly 9 significant digits. An index with 15 digits of scale already has more resolution than the rate can supply.
2. `presentValue` then quantizes the result to base units (`1e6`). At 6 decimals this is far coarser than either.

Measured against a RAY reference over a one-year accrual, the `1e15` index reproduces it digit for digit (`1039999999988944` vs `1039999999988944e12`). The residual in present value is **at most one base unit (`1e-6` USDC), always in the protocol-favorable direction**, at any position size. Aave needs RAY because its scaled balances represent 18-decimal tokens, where 12 more orders of resolution do exist below the index; here they do not.

> ⚠️ **This analysis is coupled to the base asset having 6 decimals.** An 18-decimal base (the WETH-base market in [ROADMAP Phase 9.6](./ROADMAP.md#phase-9-future-work-post-poc)) would have 12 more orders of resolution to preserve and would need a wider index scale, and therefore a wider type and a different packing. Revisit this decision before deploying any market whose base is not a 6-decimal asset.

The claims above are executable, not prose: `test/fuzz/IndexPrecision.t.sol` asserts the direction and the one-base-unit bound against a RAY reference under fuzzing, and pins `BASE_SCALE == 1e6` so a widened base fails the suite loudly.

Pause flag bits:

```solidity
uint8 constant PAUSE_SUPPLY   = 1 << 0;
uint8 constant PAUSE_TRANSFER = 1 << 1;
uint8 constant PAUSE_WITHDRAW = 1 << 2;
uint8 constant PAUSE_ABSORB   = 1 << 3;
uint8 constant PAUSE_BUY      = 1 << 4;
```

---

## 3. Interfaces and Function Contracts

### 3.1 `ILendingMarket`

```solidity
interface ILendingMarket {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount, bytes[] calldata priceUpdate) external payable;
    function absorb(address account, bytes[] calldata priceUpdate) external payable;
    function buyCollateral(address asset, uint256 minAmount, uint256 baseAmount, address recipient, bytes[] calldata priceUpdate) external payable;
    function accrue() external;
    function withdrawReserves(address to, uint256 amount) external;
    function setPauseFlags(uint8 flags) external;

    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrow() external view returns (uint256);
    function getUtilization() external view returns (uint256);
    function getReserves() external view returns (int256);
    function isBorrowCollateralized(address account) external view returns (bool);
    function isLiquidatable(address account) external view returns (bool);
    function quoteCollateral(address asset, uint256 baseAmount) external view returns (uint256);
    function userCollateral(address account, address asset) external view returns (uint128);
}
```

Plus the standard ERC-20 surface (`transfer`, `transferFrom`, `approve`, `allowance`, `name`, `symbol`, `decimals = 6`).

#### `supply(asset, amount)`

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | `amount > 0`; asset is base or listed collateral; `PAUSE_SUPPLY` clear; for collateral: `totalsCollateral + amount <= supplyCap`; caller approved this contract for `amount` |
| Effects (base)  | Accrues; `principal` increases through the single accounting path (repay branch first if negative); `amount == type(uint256).max` while in debt repays exactly the full debt |
| Effects (collateral) | `userCollateral` and `totalsCollateral` increase by `amount`; `assetsIn` bit set              |
| Postconditions  | Account health weakly improved; reserves weakly increased ([Guide 2, Section 6](./02-mathematics.md#6-interest-split-and-reserve-growth)); tokens pulled last (CEI) |
| Oracle          | Never consulted                                                                                    |

#### `withdraw(asset, amount, priceUpdate)`

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | `amount > 0`; `PAUSE_WITHDRAW` clear; base: resulting debt (if any) satisfies `|borrowPV| >= minBorrow` and `isBorrowCollateralized(msg.sender)` at `price - conf`; collateral: same health check iff account has debt; market cash sufficient |
| Effects         | Accrues; principal decreases (borrow branch past zero) or collateral ledgers decrease; `assetsIn` bit cleared on zero balance |
| Postconditions  | `isBorrowCollateralized(msg.sender)` holds; tokens sent last; surplus `msg.value` refunded         |
| Oracle          | Transactional (`updateAndGetPrice`) only when the action can reduce health                          |

#### `absorb(account, priceUpdate)`

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | `PAUSE_ABSORB` clear; `isLiquidatable(account)` at `price + conf` after accrual                     |
| Effects         | All of `account`'s collateral moves to protocol ownership (`userCollateral` zeroed, `totalsCollateral` unchanged); debt wiped; credit at `liquidationFactor` and mid price per [Guide 2, Section 8](./02-mathematics.md#8-liquidation-math-absorb); shortfall recognized as bad debt |
| Postconditions  | `principal(account) >= 0`; `assetsIn == 0`; `getReserves()` decreased by `max(debtPV, creditBase)`; no token transfers occur |
| Oracle          | Transactional, all assets in `assetsIn` plus base                                                   |

#### `buyCollateral(asset, minAmount, baseAmount, recipient, priceUpdate)`

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | `PAUSE_BUY` clear; `getReserves() < targetReserves`; protocol-held inventory (`totalsCollateral - sum of userCollateral`) `>= quote`; `quote >= minAmount` |
| Effects         | Accrues; `totalsCollateral` decreases by `quote`                                                    |
| Postconditions  | Base pulled before collateral sent (CEI); `getReserves()` increased by `baseAmount`                 |
| Oracle          | Transactional (asset + base)                                                                        |

#### `accrue()`

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | None (permissionless, idempotent within a block)                                                    |
| Postconditions  | Indexes advanced per [Guide 2, Section 3](./02-mathematics.md#3-interest-accrual); `getReserves()` weakly increased |

#### `transfer(to, amount)` / `transferFrom(from, to, amount)`

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | `PAUSE_TRANSFER` clear; `amount <= balanceOf(sender)` (sender principal may never go negative: transfers cannot create debt) |
| Effects         | Accrues; sender principal burn rounds up, receiver credit rounds down; receiver in debt is repaid first |
| Postconditions  | No health check needed (sender stays `>= 0`, receiver weakly improves); no oracle                    |

#### `withdrawReserves(to, amount)` (owner)

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | `msg.sender == owner`; `int256(amount) <= getReserves()` after accrual; `amount <= cash`            |
| Postconditions  | Base transferred to `to`; reserves reduced exactly by `amount`                                      |

#### `setPauseFlags(flags)` (owner or guardian)

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | Caller is owner, or caller is guardian and `flags` is a superset of the current flags (guardian can only add pauses, never clear them) |
| Postconditions  | `pauseFlags == flags`; event emitted with caller                                                    |

### 3.2 `IInterestRateModel`

```solidity
interface IInterestRateModel {
    function getBorrowRate(uint256 utilization) external view returns (uint256);
    function getSupplyRate(uint256 utilization) external view returns (uint256);
    function RESERVE_FACTOR() external view returns (uint256);
}
```

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | None; does not revert for any `utilization` the market can produce, which the accounting bounds to `[0, ~1e18]`, reaching only slightly above `1e18` under legitimate over-utilization ([Section 4](./02-mathematics.md#4-utilization)) |
| Postconditions  | `getSupplyRate(U) <= getBorrowRate(U)` for all `U <= 1e18`; both monotone non-decreasing; continuous at the kink; per-second rates at `1e18` |

**Domain, not saturation.** The rate functions are the pure kinked curve, unclamped, exactly as Aave's are. There is no utilization ceiling in the model because there is no need for one: utilization is not an arbitrary input but a derived quantity, `totalBorrowPV * 1e18 / totalSupplyPV`. In normal operation `totalBorrow <= totalSupply`, so `U <= 1e18`; it can rise modestly above `1e18` when suppliers withdraw against positive reserves, shrinking `totalSupplyPV` below `totalBorrowPV` ([Section 4](./02-mathematics.md#4-utilization) shows the worked example, `U = 1.0588`). Either way `U` stays a small multiple of `1e18`, because reserves are real base cash that someone contributed and cannot grow to the magnitudes that would push `totalSupplyPV` orders of magnitude below `totalBorrowPV`. The `fullMulDiv` overflow that an extreme `slopeHigh * U` or `r * U` would hit lives many orders of magnitude beyond any constructible state: the supply rate's `r * U` product overflows only near `U ~ 1.91e51` (about `1.9e33` times full utilization) for the reference `slopeHigh`, and the borrow rate near `U ~ 3.65e66`. A clamp would be a magic number defending against a utilization the accounting cannot construct, so none is used.

`getSupplyRate(U) <= getBorrowRate(U)` (INV-14) is scoped to `U in [0, 1e18]` on purpose: past `U = 1` the derived `s = r * U * (1 - RF)` grows with `U` and overtakes `r`. That is expected and harmless, because it only affects the reserve split at utilizations the market cannot reach, never a balance.

> **What `accrue()` actually guarantees.** The property that matters for liveness is not that the rate curve is total over `uint256`, but that `accrue()` cannot be bricked and block liquidation. `accrue()` runs first on every state-changing function, `absorb` included. Over the reachable domain (utilization bounded as above, indexes bounded by `uint64`, `elapsed` bounded by wall-clock time) it returns. The single documented residual revert is the index update itself, not the rate lookup: `baseIndex * (rate * elapsed) / 1e18` computes `rate * elapsed` in plain `uint256`, and checked arithmetic reverts rather than wrapping if a pathological rate model ever exceeded `type(uint256).max / elapsed` (~`3.6e69` over a one-year window, against ~`3.2e11` for a 1000% APR, a ~58 order margin). This is left checked because it is a corruption guard, not a liveness path. The docs do not claim `accrue()` never reverts; they claim it does not revert for any reachable state, and identify the one out-of-domain product that could.

### 3.3 `IPriceOracle`

```solidity
interface IPriceOracle {
    function updateAndGetPrice(address asset, bytes[] calldata priceUpdate) external payable returns (uint256 price18, uint256 conf18);
    function getPrice(address asset) external view returns (uint256 price18, uint256 conf18);
}
```

| Contract        | Statement                                                                                          |
| :--------------- | :--------------------------------------------------------------------------------------------------- |
| Preconditions   | Asset has a configured feed; `updateAndGetPrice`: `msg.value >= Pyth fee` (surplus refunded)        |
| Postconditions  | Returned price passed all four checks ([Guide 3, Section 5](./03-architecture.md#5-oracle-system-pyth--chainlink)) or the call reverted; `price18 > 0`; both values 18 decimals |

### 3.4 Events

```solidity
event Supply(address indexed from, uint256 amount);
event Withdraw(address indexed to, uint256 amount);
event SupplyCollateral(address indexed from, address indexed asset, uint256 amount);
event WithdrawCollateral(address indexed to, address indexed asset, uint256 amount);
event AbsorbDebt(address indexed absorber, address indexed account, uint256 debtAbsorbed, uint256 badDebt);
event AbsorbCollateral(address indexed absorber, address indexed account, address indexed asset, uint256 amount, uint256 usdValue);
event BuyCollateral(address indexed buyer, address indexed asset, uint256 baseAmount, uint256 collateralAmount);
event WithdrawReserves(address indexed to, uint256 amount);
event PauseFlagsSet(address indexed by, uint8 flags);
event Transfer(address indexed from, address indexed to, uint256 amount);   // ERC20; mint/burn use address(0)
```

Every base-moving path emits both its domain event and the ERC-20 `Transfer` mirror (mint on supply-side increase, burn on decrease), so indexers reconstruct balances from standard logs.

---

## 4. Precision and Decimals Handling

Unit discipline follows [Guide 2, Section 1](./02-mathematics.md#1-notation-and-units). Implementation rules:

| Rule | Detail                                                                                             |
| :--- | :--------------------------------------------------------------------------------------------------- |
| 1    | All directed divisions go through Solady `mulDivDown` / `mulDivUp`; a bare `/` is only legal where both operands are protocol-internal constants |
| 2    | Every rounding site's direction is asserted against the [Guide 2, Section 10 catalogue](./02-mathematics.md#10-rounding-policy) in fuzz tests |
| 3    | Multiply before dividing, always; intermediate products use 256-bit space (`mulDiv` handles the full-width product) |
| 4    | Narrowing casts only via `SafeCastLib` (`toUint104`, `toInt104`, `toUint128`); a silent truncation is an accounting corruption |
| 5    | Collateral amounts stay in native decimals (`1e18` WETH, `1e8` wBTC) until valued; USD values normalize at `1e18`; base stays at `1e6` |
| 6    | `unchecked` blocks require a comment proving the bound from an invariant (e.g. `assetsIn` iteration bounded by asset count) |
| 7    | The ERC-20 reports `decimals() == 6` (base-equivalent balance), so wallets display lmUSDC exactly like USDC |

---

## 5. Custom Errors

All reverts are custom errors carrying the values that failed the check ([Guide 3, Section 7.3](./03-architecture.md#73-custom-errors-with-parameters)).

```solidity
// LendingMarket: input and state
error Paused(uint8 flag);
error ZeroAmount();
error UnknownAsset(address asset);
error InvalidRecipient(address recipient);
error SupplyCapExceeded(address asset, uint128 cap, uint256 attempted);
error InsufficientCash(uint256 requested, uint256 available);

// LendingMarket: health and debt
error NotCollateralized(address account, uint256 debtUSD, uint256 capacityUSD);
error MinBorrowNotMet(uint256 borrowPV, uint256 minBorrow);
error NotLiquidatable(address account, uint256 debtUSD, uint256 liqCapacityUSD);
error TransferWouldBorrow(address from, uint256 balance, uint256 amount);

// LendingMarket: liquidation storefront and reserves
error NotForSale(int256 reserves, uint256 targetReserves);
error TooMuchSlippage(uint256 quoted, uint256 minAmount);
error InsufficientInventory(address asset, uint256 requested, uint256 available);
error InsufficientReserves(int256 reserves, uint256 requested);

// Access and configuration
error Unauthorized(address caller);
error GuardianCannotUnpause(uint8 current, uint8 requested);
error InvalidConfiguration(bytes32 what);

// PythChainlinkOracle
error StalePrice(address asset, uint256 publishTime, uint256 maxStaleness);
error ConfidenceTooWide(address asset, uint256 confBps, uint256 maxConfBps);
error ZeroPrice(address asset);
error PriceDeviationTooHigh(address asset, uint256 deviationBps, uint256 maxDeviationBps);
error StaleAnchor(address asset, uint256 updatedAt, uint256 heartbeat);
error InsufficientFee(uint256 provided, uint256 required);
```

---

## 6. Access Control Matrix

Roles: **PUBLIC** (anyone), **OWNER** (`Ownable2Step` multisig), **GUARDIAN** (pause-only address set at deployment).

### LendingMarket.sol

| Function             | PUBLIC | OWNER | GUARDIAN | Pause gate        |
| :-------------------- | :----- | :---- | :------- | :----------------- |
| `supply`             | ✅     | -     | -        | `PAUSE_SUPPLY`    |
| `withdraw`           | ✅     | -     | -        | `PAUSE_WITHDRAW`  |
| `transfer` / `transferFrom` | ✅ | -   | -        | `PAUSE_TRANSFER`  |
| `absorb`             | ✅     | -     | -        | `PAUSE_ABSORB` (last resort, see [Guide 6](./06-security.md#5-pause-and-circuit-breaker-philosophy)) |
| `buyCollateral`      | ✅     | -     | -        | `PAUSE_BUY`       |
| `accrue`             | ✅     | -     | -        | never pausable    |
| All views            | ✅     | -     | -        | never pausable    |
| `withdrawReserves`   | ❌     | ✅    | -        | -                 |
| `setPauseFlags`      | ❌     | ✅ (set/clear) | ✅ (set only) | -        |
| `transferOwnership` / `acceptOwnership` | ❌ | ✅ (2-step) | - | -            |

### InterestRateModel.sol / PythChainlinkOracle.sol

No privileged functions. All parameters immutable from the constructor; both contracts are pure policy with no owner, no setters, and no pause. The oracle's only state is inherited from the Pyth contract it reads.

**What the owner can NOT do** (deliberate, [ADR-3](./03-architecture.md#adr-3-immutable-deployment-vs-upgradeable-proxy)): change any factor, curve, cap, feed, or address; upgrade any code; touch any user balance or collateral; mint anything. The maximum damage of a fully compromised owner key is withdrawing accumulated reserves and freezing flows, never user principal or collateral.

---

## 7. Pre-Deployment Checklist

Constructor-enforced (deployment reverts otherwise):

- [ ] `0 < borrowCF < liquidateCF < 10_000` for every collateral
- [ ] `liquidationFactor >= liquidateCF * (10_000 + MAX_CONFIDENCE_BPS) / 10_000` (coverage condition, [Guide 2, Section 8](./02-mathematics.md#8-liquidation-math-absorb))
- [ ] `0 < storeFrontPriceFactor <= 10_000`
- [ ] `0 < kink < 1e18`, `slopeHigh >= slopeLow`, `RF < 1e18`
- [ ] `supplyCap > 0`, `minBorrow > 0`, non-zero owner, guardian, oracle, IRM, and token addresses
- [ ] Collateral `decimals` matches the token's `decimals()`

Operational, before deployment sign-off (local rehearsal on anvil, plus the mainnet-fork suite for the external dependencies):

- [ ] Pyth feed IDs and Chainlink aggregators verified against official registries for USDC, WETH, wBTC, and exercised live by the fork tests ([Guide 6, Testing Plan](./06-security.md#7-testing-plan))
- [ ] Chainlink heartbeats configured per feed (not one global value)
- [ ] Deployment script deploys IRM, oracle, market, and verifies wiring in one broadcast
- [ ] Seed reserves donated (base transfer to the market) so the first absorbs are funded
- [ ] Full test suite green: unit, fuzz, invariant, integration, fork ([ROADMAP Phase 8](./ROADMAP.md#phase-8-invariant--fuzz-testing--audit-prep))
- [ ] Slither + Aderyn reports clean of criticals
- [ ] Source verified on the block explorer; `Ownable2Step` ownership transferred to the multisig and accepted
- [ ] Guardian address is a separate, faster key than the owner multisig
- [ ] Audit checklist in [Guide 6](./06-security.md#6-audit-checklist) fully ticked

---

**See also:**

- [Guide 2: Protocol Mathematics](./02-mathematics.md), the formulas behind every contract above
- [Guide 6: Security](./06-security.md), invariants these contracts must never violate
