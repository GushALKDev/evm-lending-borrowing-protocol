// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {ILendingMarket} from "./interfaces/ILendingMarket.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title LendingMarket
 * @author GushALKDev
 * @notice Single base asset money market in the style of Compound III: one borrowable base asset,
 *         inert supply-only collateral, index based interest accrual, and derived reserves. The
 *         market is itself the rebasing ERC20 claim on the base supply (lmUSDC).
 * @dev Rounding policy (Guide 2, Section 10) is load bearing: every division where the protocol and
 *      an account sit on opposite sides rounds toward the protocol. Supply side rounds down, borrow
 *      side rounds up, without exception.
 *
 *      Every state-changing function accrues first, then follows checks-effects-interactions with a
 *      nonReentrant guard on the token-moving paths.
 */
abstract contract LendingMarket is ILendingMarket, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initial value of both indexes. Indexes only grow from here.
    uint64 internal constant BASE_INDEX_SCALE = 1e15;

    /// @notice Scale of per second interest rates and the reserve factor.
    uint256 internal constant RATE_SCALE = 1e18;

    /// @notice Scale of collateral factors, penalties, and discounts (basis points).
    uint256 internal constant FACTOR_SCALE = 10_000;

    /// @notice Pause bitfield offsets.
    uint8 internal constant PAUSE_SUPPLY = 1 << 0;
    uint8 internal constant PAUSE_TRANSFER = 1 << 1;
    uint8 internal constant PAUSE_WITHDRAW = 1 << 2;
    uint8 internal constant PAUSE_ABSORB = 1 << 3;
    uint8 internal constant PAUSE_BUY = 1 << 4;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The single borrowable asset. All debt, yield, and reserves are denominated in it.
    address public immutable BASE_TOKEN;

    /// @notice 10 ** decimals of the base asset.
    uint256 public immutable BASE_SCALE;

    /// @notice Immutable rate policy driving every accrual.
    IInterestRateModel public immutable INTEREST_RATE_MODEL;

    /// @notice Immutable price source consulted on health-reducing actions.
    IPriceOracle public immutable ORACLE;

    /// @notice Fast key that may add pause flags but never clear them.
    address public immutable GUARDIAN;

    /// @notice Smallest debt an account may hold, guarding against dust debts.
    uint256 public immutable MIN_BORROW;

    /// @notice Reserve level below which buyCollateral sells inventory.
    uint256 public immutable TARGET_RESERVES;

    /// @notice Number of listed collateral assets.
    uint8 public immutable NUM_ASSETS;

    /*//////////////////////////////////////////////////////////////
                              ERC20 METADATA
    //////////////////////////////////////////////////////////////*/

    string internal constant NAME = "Lending Market USDC";
    string internal constant SYMBOL = "lmUSDC";

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Global accounting state: indexes, accrual timestamp, pause flags, principal totals.
    MarketState internal marketState;

    /// @notice Per account signed base principal and collateral membership bitmap.
    mapping(address account => UserBasic basic) internal userBasic;

    /// @notice Per account, per asset posted collateral in the asset's native decimals.
    mapping(address account => mapping(address asset => uint128 amount)) internal userCollateralBalance;

    /// @notice Total collateral posted per asset, protocol-held inventory included.
    mapping(address asset => uint128 total) public totalsCollateral;

    /// @notice Immutable per collateral risk config, keyed by asset, populated in the constructor.
    mapping(address asset => CollateralConfig config) internal collateralConfig;

    /// @notice Listed collateral assets, indexed by their assetsIn bit offset.
    mapping(uint8 offset => address asset) internal assetByOffset;

    /// @notice ERC20 allowances for the rebasing base claim.
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration bundle for the market deployment.
     * @dev Grouped into a struct to keep the constructor signature readable and stack-safe.
     */
    struct MarketConfig {
        address baseToken;
        address interestRateModel;
        address oracle;
        address owner;
        address guardian;
        uint256 minBorrow;
        uint256 targetReserves;
    }

    /**
     * @notice Wires the immutable dependencies, lists the collateral assets, and seeds both indexes.
     * @dev Base decimals are read from the token rather than passed in: a mismatched literal would
     *      corrupt every base denominated quantity silently instead of reverting. Collateral factor
     *      ordering (INV-12) and per-asset sanity are enforced here; the absorb coverage condition
     *      (INV-13) is enforced in Phase 7 once the oracle supplies MAX_CONFIDENCE_BPS.
     * @param cfg Market-level immutable configuration.
     * @param collaterals Per collateral risk configs, in assetsIn bit-offset order (at most 16).
     */
    constructor(MarketConfig memory cfg, CollateralConfig[] memory collaterals) Ownable(cfg.owner) {
        if (cfg.baseToken == address(0)) revert InvalidConfiguration("baseToken");
        if (cfg.interestRateModel == address(0)) revert InvalidConfiguration("interestRateModel");
        if (cfg.oracle == address(0)) revert InvalidConfiguration("oracle");
        if (cfg.guardian == address(0)) revert InvalidConfiguration("guardian");
        if (cfg.minBorrow == 0) revert InvalidConfiguration("minBorrow");
        // assetsIn is a uint16 bitmap, so at most 16 collateral assets can be listed.
        if (collaterals.length > 16) revert InvalidConfiguration("numAssets");

        BASE_TOKEN = cfg.baseToken;
        BASE_SCALE = 10 ** IERC20Metadata(cfg.baseToken).decimals();
        INTEREST_RATE_MODEL = IInterestRateModel(cfg.interestRateModel);
        ORACLE = IPriceOracle(cfg.oracle);
        GUARDIAN = cfg.guardian;
        MIN_BORROW = cfg.minBorrow;
        TARGET_RESERVES = cfg.targetReserves;
        NUM_ASSETS = uint8(collaterals.length);

        for (uint8 i = 0; i < collaterals.length; i++) {
            CollateralConfig memory c = collaterals[i];
            if (c.asset == address(0)) revert InvalidConfiguration("collateralAsset");
            // INV-12: 0 < borrowCF < liquidateCF < FACTOR_SCALE.
            if (c.borrowCollateralFactor == 0 || c.borrowCollateralFactor >= c.liquidateCollateralFactor) {
                revert InvalidConfiguration("borrowCF");
            }
            if (c.liquidateCollateralFactor >= FACTOR_SCALE) revert InvalidConfiguration("liquidateCF");
            if (c.liquidationFactor == 0 || c.liquidationFactor > FACTOR_SCALE) {
                revert InvalidConfiguration("liquidationFactor");
            }
            if (c.storeFrontPriceFactor == 0 || c.storeFrontPriceFactor > FACTOR_SCALE) {
                revert InvalidConfiguration("storeFrontPriceFactor");
            }
            if (c.supplyCap == 0) revert InvalidConfiguration("supplyCap");
            if (c.decimals != IERC20Metadata(c.asset).decimals()) revert InvalidConfiguration("decimals");

            collateralConfig[c.asset] = c;
            assetByOffset[i] = c.asset;
        }

        marketState.baseSupplyIndex = BASE_INDEX_SCALE;
        marketState.baseBorrowIndex = BASE_INDEX_SCALE;
        marketState.lastAccrualTime = uint40(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          CONVERSION PRIMITIVES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Present value of a positive base principal.
     * @dev Rounds down: the supplier loses the wei (Guide 2, Section 10).
     * @param principal Supply principal, index invariant.
     * @return Present value in base units.
     */
    function _presentValueSupply(uint104 principal) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(principal, marketState.baseSupplyIndex, BASE_INDEX_SCALE);
    }

    /**
     * @notice Present value magnitude of a negative base principal.
     * @dev Rounds up: the borrower owes the wei (Guide 2, Section 10).
     * @param principal Debt principal magnitude, index invariant.
     * @return Debt present value in base units.
     */
    function _presentValueBorrow(uint104 principal) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(principal, marketState.baseBorrowIndex, BASE_INDEX_SCALE);
    }

    /**
     * @notice Supply principal for a positive present value.
     * @dev Rounds down: crediting less principal favors the protocol.
     * @param present Present value in base units.
     * @return Supply principal, index invariant.
     */
    function _principalValueSupply(uint256 present) internal view returns (uint104) {
        return FixedPointMathLib.fullMulDiv(present, BASE_INDEX_SCALE, marketState.baseSupplyIndex).toUint104();
    }

    /**
     * @notice Debt principal magnitude for a debt present value.
     * @dev Rounds up: recording more debt principal favors the protocol.
     * @param present Debt present value in base units.
     * @return Debt principal magnitude, index invariant.
     */
    function _principalValueBorrow(uint256 present) internal view returns (uint104) {
        return FixedPointMathLib.fullMulDivUp(present, BASE_INDEX_SCALE, marketState.baseBorrowIndex).toUint104();
    }

    /**
     * @notice Signed present value of a signed principal.
     * @dev Dispatches to the sign appropriate primitive so both rounding directions stay in one
     *      place. This and _principalValue are the only conversion sites in the protocol.
     * @param principal Signed principal: positive supplies, negative borrows.
     * @return Signed present value in base units.
     */
    function _presentValue(int104 principal) internal view returns (int256) {
        if (principal >= 0) {
            return _presentValueSupply(_supplyPart(principal)).toInt256();
        }
        return -_presentValueBorrow(_borrowPart(principal)).toInt256();
    }

    /**
     * @notice Signed principal for a signed present value.
     * @param present Signed present value in base units.
     * @return Signed principal: positive supplies, negative borrows.
     */
    function _principalValue(int256 present) internal view returns (int104) {
        if (present >= 0) {
            return uint256(_principalValueSupply(uint256(present))).toInt104();
        }
        return -uint256(_principalValueBorrow(uint256(-present))).toInt104();
    }

    /**
     * @notice Supply side magnitude of a signed principal, zero when the account is borrowing.
     * @param principal Signed principal.
     * @return Supply principal magnitude.
     */
    function _supplyPart(int104 principal) internal pure returns (uint104) {
        return principal > 0 ? uint104(principal) : 0;
    }

    /**
     * @notice Borrow side magnitude of a signed principal, zero when the account is supplying.
     * @dev Negates in int256 so the type(int104).min edge cannot overflow.
     * @param principal Signed principal.
     * @return Debt principal magnitude.
     */
    function _borrowPart(int104 principal) internal pure returns (uint104) {
        return principal < 0 ? SafeCastLib.toUint104(uint256(-int256(principal))) : 0;
    }

    /*//////////////////////////////////////////////////////////////
                        SINGLE ACCOUNTING PATH
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The one place a base principal and the global totals change together.
     * @dev Every base balance change in the protocol (supply, withdraw, borrow, repay, transfer,
     *      absorb settlement) routes through here. Splitting the delta by sign is what keeps
     *      INV-1 (sum of principals equals the totals, split by sign) an exact integer equality
     *      across sign crossings: the old and new principals are decomposed into their supply and
     *      borrow parts independently, so a crossing is just one part going to zero and the other
     *      leaving zero.
     * @param account Account whose principal changes.
     * @param oldPrincipal Principal before the change.
     * @param newPrincipal Principal after the change.
     */
    function _updateBasePrincipal(address account, int104 oldPrincipal, int104 newPrincipal) internal {
        userBasic[account].principal = newPrincipal;

        // Decompose both endpoints by sign, then move each total by its own delta. No branch on the
        // crossing itself is needed: a crossing decomposes into one side zeroing and the other rising.
        // Negation happens in int256 so the type(int104).min edge cannot overflow.
        uint104 oldSupply = _supplyPart(oldPrincipal);
        uint104 newSupply = _supplyPart(newPrincipal);
        uint104 oldBorrow = _borrowPart(oldPrincipal);
        uint104 newBorrow = _borrowPart(newPrincipal);

        // Narrowing goes through SafeCastLib: a silent truncation here is an accounting corruption.
        if (newSupply != oldSupply) {
            marketState.totalSupplyBase = (uint256(marketState.totalSupplyBase) + newSupply - oldSupply).toUint104();
        }
        if (newBorrow != oldBorrow) {
            marketState.totalBorrowBase = (uint256(marketState.totalBorrowBase) + newBorrow - oldBorrow).toUint104();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingMarket
    function accrue() external {
        _accrue();
    }

    /**
     * @notice Advances both indexes over the elapsed window at the utilization that held throughout.
     * @dev Rates are read once against the pre update utilization, so no operation can retroactively
     *      reprice a window that has already elapsed. Supply index rounds down and borrow index
     *      rounds up, which is what pushes the rounding residual into reserves every accrual.
     */
    function _accrue() internal {
        uint40 nowTime = uint40(block.timestamp);
        uint256 elapsed = nowTime - marketState.lastAccrualTime;
        if (elapsed == 0) return;

        uint256 utilization = getUtilization();
        uint256 supplyRate = INTEREST_RATE_MODEL.getSupplyRate(utilization);
        uint256 borrowRate = INTEREST_RATE_MODEL.getBorrowRate(utilization);

        uint64 supplyIndex = marketState.baseSupplyIndex;
        uint64 borrowIndex = marketState.baseBorrowIndex;

        // `rate * elapsed` is computed in plain uint256, outside fullMulDiv's 512 bit intermediate,
        // so it is the one product here not covered by that helper, and the single documented
        // residual revert of accrue() over the reachable domain (Guide 5, Section 3.2). It is left
        // checked rather than unchecked on purpose: it is a corruption guard, not a liveness path.
        // Overflow would need `rate > type(uint256).max / elapsed`, roughly 3.6e69 over a one year
        // window, against ~3.2e11 for a 1000% APR. If a pathological model ever exceeded it, checked
        // arithmetic reverts and the index stays intact rather than wrapping.
        marketState.baseSupplyIndex =
            (supplyIndex + FixedPointMathLib.fullMulDiv(supplyIndex, supplyRate * elapsed, RATE_SCALE)).toUint64();
        marketState.baseBorrowIndex =
            (borrowIndex + FixedPointMathLib.fullMulDivUp(borrowIndex, borrowRate * elapsed, RATE_SCALE)).toUint64();

        marketState.lastAccrualTime = nowTime;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingMarket
    function getUtilization() public view returns (uint256) {
        uint256 totalSupply_ = _presentValueSupply(marketState.totalSupplyBase);
        if (totalSupply_ == 0) return 0;

        // May exceed 1e18 once reserves have been paid out. That is a valid market state: the rate
        // curve simply evaluates past the kink (Guide 2, Section 4).
        return FixedPointMathLib.fullMulDiv(_presentValueBorrow(marketState.totalBorrowBase), RATE_SCALE, totalSupply_);
    }

    /// @inheritdoc ILendingMarket
    function balanceOf(address account) public view returns (uint256) {
        return _presentValueSupply(_supplyPart(userBasic[account].principal));
    }

    /// @inheritdoc ILendingMarket
    function borrowBalanceOf(address account) public view returns (uint256) {
        return _presentValueBorrow(_borrowPart(userBasic[account].principal));
    }

    /// @inheritdoc ILendingMarket
    function totalSupply() public view returns (uint256) {
        return _presentValueSupply(marketState.totalSupplyBase);
    }

    /// @inheritdoc ILendingMarket
    function totalBorrow() public view returns (uint256) {
        return _presentValueBorrow(marketState.totalBorrowBase);
    }

    /// @inheritdoc ILendingMarket
    function getReserves() public view returns (int256) {
        // Derived, never stored: every reserve movement changes exactly one of these three terms,
        // so there is no counter that can drift from reality (Guide 3, Section 3.4).
        return _balanceOfBaseToken().toInt256() + totalBorrow().toInt256() - totalSupply().toInt256();
    }

    /**
     * @notice Base token cash currently held by the market.
     * @dev Isolated so later phases and tests can reason about the single balanceOf read.
     * @return Cash in base units.
     */
    function _balanceOfBaseToken() internal view virtual returns (uint256) {
        // Deliberately not defensive: an unreadable base balance means reserves are unknowable, and
        // reporting zero would understate them. Bubbling the revert fails closed instead.
        return IERC20(BASE_TOKEN).balanceOf(address(this));
    }

    /// @inheritdoc ILendingMarket
    function userCollateral(address account, address asset) external view returns (uint128) {
        return userCollateralBalance[account][asset];
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts if the given pause flag is set.
    modifier notPaused(uint8 flag) {
        _requireNotPaused(flag);
        _;
    }

    /// @dev Modifier body kept in an internal function so the check is not inlined at every use site.
    function _requireNotPaused(uint8 flag) internal view {
        if (marketState.pauseFlags & flag != 0) revert Paused(flag);
    }

    /*//////////////////////////////////////////////////////////////
                                SUPPLY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingMarket
    function supply(address asset, uint256 amount) external nonReentrant notPaused(PAUSE_SUPPLY) {
        _accrue();
        if (asset == BASE_TOKEN) {
            _supplyBase(msg.sender, amount);
        } else {
            _supplyCollateral(msg.sender, asset, amount);
        }
    }

    /**
     * @notice Credits base supply (repaying debt first if the account is negative).
     * @dev type(uint256).max repays the full current debt exactly and supplies nothing beyond it.
     */
    function _supplyBase(address account, uint256 amount) internal {
        int104 oldPrincipal = userBasic[account].principal;

        // Full-repay sentinel: cap the pulled amount at exactly the outstanding debt.
        if (amount == type(uint256).max) {
            uint256 debt = _presentValueBorrow(_borrowPart(oldPrincipal));
            if (debt == 0) revert ZeroAmount();
            amount = debt;
        }
        if (amount == 0) revert ZeroAmount();

        int256 newBalance = _presentValue(oldPrincipal) + amount.toInt256();
        int104 newPrincipal = _principalValue(newBalance);
        _updateBasePrincipal(account, oldPrincipal, newPrincipal);

        // CEI: pull tokens last.
        IERC20(BASE_TOKEN).safeTransferFrom(msg.sender, address(this), amount);

        emit Supply(account, amount);

        // Balances are derived from principal, so the write above already changed balanceOf. This
        // log only reports that implicit mint so indexers can track it. A pure repay leaves
        // supplyPart at zero on both sides: nothing was minted, so nothing is logged.
        uint256 supplyBefore = _presentValueSupply(_supplyPart(oldPrincipal));
        uint256 supplyAfter = _presentValueSupply(_supplyPart(newPrincipal));
        if (supplyAfter > supplyBefore) emit Transfer(address(0), account, supplyAfter - supplyBefore);
    }

    /**
     * @notice Posts collateral into inert custody, enforcing the per-asset supply cap.
     */
    function _supplyCollateral(address account, address asset, uint256 amount) internal {
        CollateralConfig memory config = _requireListed(asset);
        if (amount == 0) revert ZeroAmount();

        uint128 amount128 = amount.toUint128();
        uint128 newTotal = totalsCollateral[asset] + amount128;
        if (newTotal > config.supplyCap) revert SupplyCapExceeded(asset, config.supplyCap, newTotal);

        totalsCollateral[asset] = newTotal;
        userCollateralBalance[account][asset] += amount128;
        _setAssetIn(account, asset);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit SupplyCollateral(account, asset, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingMarket
    function withdraw(address asset, uint256 amount, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        notPaused(PAUSE_WITHDRAW)
    {
        _accrue();
        if (asset == BASE_TOKEN) {
            _withdrawBase(msg.sender, amount, priceUpdate);
        } else {
            _withdrawCollateral(msg.sender, asset, amount, priceUpdate);
        }
        _refundExcessValue();
    }

    /**
     * @notice Withdraws base, opening or increasing a borrow once the balance crosses below zero.
     * @dev This is the protocol's single borrowing entry point: there is no separate borrow()
     *      function, and the sign crossing needs no special case because the accounting path
     *      decomposes both endpoints by sign. Reverts if the market lacks the cash to honor the
     *      withdrawal, and, on the borrow branch, if the resulting debt is dust or uncollateralized.
     */
    function _withdrawBase(address account, uint256 amount, bytes[] calldata priceUpdate) internal {
        if (amount == 0) revert ZeroAmount();

        int104 oldPrincipal = userBasic[account].principal;
        int256 newBalance = _presentValue(oldPrincipal) - amount.toInt256();

        uint256 cash = _balanceOfBaseToken();
        if (amount > cash) revert InsufficientCash(amount, cash);

        int104 newPrincipal = _principalValue(newBalance);
        _updateBasePrincipal(account, oldPrincipal, newPrincipal);

        // Borrow branch: the checks run against the post-write state, so the health check sees
        // exactly the position the account is left holding.
        if (newPrincipal < 0) {
            // Dust guard: a debt too small to be worth absorbing must never be created. The bound is
            // on the resulting debt, not on the borrowed amount, so it also catches a repay that
            // would leave dust behind.
            uint256 borrowPV = _presentValueBorrow(_borrowPart(newPrincipal));
            if (borrowPV < MIN_BORROW) revert MinBorrowNotMet(borrowPV, MIN_BORROW);

            _requireBorrowCollateralized(account, priceUpdate);
        }

        IERC20(BASE_TOKEN).safeTransfer(account, amount);

        emit Withdraw(account, amount);

        // Mirror of the supply path: reports the implicit burn that the principal write above
        // already applied to balanceOf.
        uint256 supplyBefore = _presentValueSupply(_supplyPart(oldPrincipal));
        uint256 supplyAfter = _presentValueSupply(_supplyPart(newPrincipal));
        if (supplyBefore > supplyAfter) emit Transfer(account, address(0), supplyBefore - supplyAfter);
    }

    /**
     * @notice Withdraws collateral, running the health check only if the account has debt.
     */
    function _withdrawCollateral(address account, address asset, uint256 amount, bytes[] calldata priceUpdate)
        internal
    {
        _requireListed(asset);
        if (amount == 0) revert ZeroAmount();

        uint128 amount128 = amount.toUint128();
        uint128 balance = userCollateralBalance[account][asset];
        if (amount128 > balance) revert InsufficientCollateral(account, asset, balance, amount);

        uint128 newBalance = balance - amount128;
        userCollateralBalance[account][asset] = newBalance;
        totalsCollateral[asset] -= amount128;
        if (newBalance == 0) _clearAssetIn(account, asset);

        // Only a borrower can be made unhealthy by removing collateral.
        if (userBasic[account].principal < 0) {
            _requireBorrowCollateralized(account, priceUpdate);
        }

        IERC20(asset).safeTransfer(account, amount);

        emit WithdrawCollateral(account, asset, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingMarket
    function absorb(address account, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        notPaused(PAUSE_ABSORB)
    {
        _accrue();

        // CHECKS: push every price the position depends on, then require eligibility at those prices.
        _pushPrices(account, priceUpdate);
        uint256 debtUSD = _debtUSD(account);
        uint256 liqCapacityUSD = _liquidationCapacity(account);
        if (debtUSD <= liqCapacityUSD) revert NotLiquidatable(account, debtUSD, liqCapacityUSD);

        // EFFECTS: seize every held collateral into protocol ownership, accumulating the mid-price
        // credit at the liquidation factor. totalsCollateral is untouched: the protocol now owns it.
        uint256 creditValueUSD = _seizeCollateral(account);

        (uint256 basePrice,) = ORACLE.getPrice(BASE_TOKEN);
        uint256 creditBase = FixedPointMathLib.fullMulDiv(creditValueUSD, BASE_SCALE, basePrice);

        int104 oldPrincipal = userBasic[account].principal;
        uint256 debtPV = _presentValueBorrow(_borrowPart(oldPrincipal));

        // Settlement through the single accounting path. A shortfall zeroes the account and is
        // recognized as bad debt against reserves immediately; a surplus is credited as base supply.
        uint256 badDebt = creditBase < debtPV ? debtPV - creditBase : 0;
        int256 newBalance = -int256(debtPV) + int256(creditBase);
        if (newBalance < 0) newBalance = 0;

        _updateBasePrincipal(account, oldPrincipal, _principalValue(newBalance));

        emit AbsorbDebt(msg.sender, account, debtPV, badDebt);

        _refundExcessValue();
    }

    /**
     * @notice Seizes every collateral the account holds into protocol ownership.
     * @dev Zeroes each userCollateral balance and clears the assetsIn bit, but leaves totalsCollateral
     *      unchanged: the inventory is now the protocol's, to be recovered through buyCollateral.
     *      Seize value is marked at the mid price; the credit applies the per-asset liquidationFactor.
     * @param account Account being absorbed.
     * @return creditValueUSD Sum of seized value times liquidationFactor, USD at 1e18 scale, floored.
     */
    function _seizeCollateral(address account) internal returns (uint256 creditValueUSD) {
        uint16 assetsIn = userBasic[account].assetsIn;
        for (uint8 i = 0; i < NUM_ASSETS; i++) {
            if (assetsIn & uint16(1 << i) == 0) continue;

            address asset = assetByOffset[i];
            uint128 amount = userCollateralBalance[account][asset];
            CollateralConfig memory config = collateralConfig[asset];
            (uint256 price,) = ORACLE.getPrice(asset);

            uint256 collateralScale = 10 ** config.decimals;
            uint256 seizeValueUSD = FixedPointMathLib.fullMulDiv(amount, price, collateralScale);
            creditValueUSD += FixedPointMathLib.fullMulDiv(
                amount * config.liquidationFactor, price, collateralScale * FACTOR_SCALE
            );

            userCollateralBalance[account][asset] = 0;
            _clearAssetIn(account, asset);

            emit AbsorbCollateral(msg.sender, account, asset, amount, seizeValueUSD);
        }
    }

    /// @inheritdoc ILendingMarket
    function buyCollateral(
        address asset,
        uint256 minAmount,
        uint256 baseAmount,
        address recipient,
        bytes[] calldata priceUpdate
    ) external payable nonReentrant notPaused(PAUSE_BUY) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        if (baseAmount == 0) revert ZeroAmount();
        _requireListed(asset);

        _accrue();

        // CHECKS: push the base and asset prices, then gate on the reserve deficit and the quote.
        _pushBuyPrices(asset, priceUpdate);

        int256 reserves = getReserves();
        if (reserves >= int256(TARGET_RESERVES)) revert NotForSale(reserves, TARGET_RESERVES);

        uint256 quote = quoteCollateral(asset, baseAmount);
        if (quote < minAmount) revert TooMuchSlippage(quote, minAmount);

        uint128 inventory = totalsCollateral[asset];
        if (quote > inventory) revert InsufficientInventory(asset, quote, inventory);

        // EFFECTS: the inventory leaves protocol ownership.
        totalsCollateral[asset] = inventory - uint128(quote);

        // INTERACTIONS (CEI: base in before collateral out). The base raises cash, hence reserves,
        // through the derived formula; no principal changes, so no supplier is credited.
        IERC20(BASE_TOKEN).safeTransferFrom(msg.sender, address(this), baseAmount);
        IERC20(asset).safeTransfer(recipient, quote);

        emit BuyCollateral(msg.sender, asset, baseAmount, quote);

        _refundExcessValue();
    }

    /// @inheritdoc ILendingMarket
    function quoteCollateral(address asset, uint256 baseAmount) public view returns (uint256) {
        CollateralConfig memory config = _requireListed(asset);
        (uint256 price,) = ORACLE.getPrice(asset);
        (uint256 basePrice,) = ORACLE.getPrice(BASE_TOKEN);

        // discount = storeFront * (1 - LF), floored; a smaller discount favors the protocol.
        uint256 discount = FixedPointMathLib.mulDiv(
            config.storeFrontPriceFactor, FACTOR_SCALE - config.liquidationFactor, FACTOR_SCALE
        );
        // askPrice = price * (1 - discount), floored: the buyer pays no less than this per unit.
        uint256 askPrice = FixedPointMathLib.mulDiv(price, FACTOR_SCALE - discount, FACTOR_SCALE);

        // quote = baseAmount * basePrice * collateralScale / (BASE_SCALE * askPrice), floored: the
        // buyer receives no more collateral than the ask supports.
        uint256 collateralScale = 10 ** config.decimals;
        return FixedPointMathLib.fullMulDiv(baseAmount * basePrice, collateralScale, BASE_SCALE * askPrice);
    }

    /**
     * @notice Pushes the base and one collateral asset price on chain for a buyCollateral call.
     * @dev buyCollateral has no account, so it cannot reuse the assetsIn-driven _pushPrices; it needs
     *      exactly the base (for reserves and the quote's base leg) and the asset being bought.
     * @param asset Collateral asset whose price is needed.
     * @param priceUpdate Signed oracle update payloads.
     */
    function _pushBuyPrices(address asset, bytes[] calldata priceUpdate) internal {
        ORACLE.updateAndGetPrice{value: address(this).balance}(BASE_TOKEN, priceUpdate);
        ORACLE.updateAndGetPrice{value: address(this).balance}(asset, priceUpdate);
    }

    /*//////////////////////////////////////////////////////////////
                           HEALTH AND CAPACITY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingMarket
    function isBorrowCollateralized(address account) external view returns (bool) {
        return _debtUSD(account) <= _borrowCapacity(account);
    }

    /**
     * @notice Health check enforced after any action that can reduce an account's health.
     * @dev Two steps on purpose: push every price the account's position depends on, then run the
     *      same pure-read capacity math the public view runs. Splitting them is what lets one
     *      implementation of the formula serve both callers even though the view is `view` and the
     *      push is not: the only state-changing part is the push itself.
     * @param account Account whose health must hold.
     * @param priceUpdate Signed oracle update payloads for the base and every held collateral.
     */
    function _requireBorrowCollateralized(address account, bytes[] calldata priceUpdate) internal virtual {
        _pushPrices(account, priceUpdate);

        uint256 debtUSD = _debtUSD(account);
        uint256 capacityUSD = _borrowCapacity(account);
        if (debtUSD > capacityUSD) revert NotCollateralized(account, debtUSD, capacityUSD);
    }

    /**
     * @notice Pushes the caller's price update on chain for the base and every collateral held.
     * @dev Forwards the remaining ETH balance as the fee budget on each call; the oracle refunds its
     *      surplus and _refundExcessValue sweeps the rest back to the caller at the end of the
     *      external function. Return values are discarded: _borrowCapacity re-reads the stored
     *      prices these calls just wrote.
     * @param account Account whose held assets determine which feeds to update.
     * @param priceUpdate Signed oracle update payloads.
     */
    function _pushPrices(address account, bytes[] calldata priceUpdate) internal {
        ORACLE.updateAndGetPrice{value: address(this).balance}(BASE_TOKEN, priceUpdate);

        uint16 assetsIn = userBasic[account].assetsIn;
        for (uint8 i = 0; i < NUM_ASSETS; i++) {
            if (assetsIn & uint16(1 << i) == 0) continue;
            ORACLE.updateAndGetPrice{value: address(this).balance}(assetByOffset[i], priceUpdate);
        }
    }

    /**
     * @notice Present value of an account's debt in USD at 1e18 scale.
     * @dev The one place debt is valued (Guide 2, Section 7). Debt is taken at the high edge of the
     *      confidence band and rounded up: an uncertain base price makes the debt count for more,
     *      never less. Shared by _borrowCapacity and _liquidationCapacity so both weigh debt identically.
     * @param account Account to value.
     * @return debtUSD Debt present value at price + conf, rounded up.
     */
    function _debtUSD(address account) internal view returns (uint256 debtUSD) {
        uint256 borrowPV = _presentValueBorrow(_borrowPart(userBasic[account].principal));
        (uint256 basePrice, uint256 baseConf) = ORACLE.getPrice(BASE_TOKEN);
        debtUSD = FixedPointMathLib.fullMulDivUp(borrowPV, basePrice + baseConf, BASE_SCALE);
    }

    /**
     * @notice Borrowing capacity of an account in USD at 1e18 scale.
     * @dev The one place the borrow-capacity formula lives (Guide 2, Section 7). Collateral is valued
     *      at the low edge of the confidence band and floored, erring toward calling a healthy account
     *      unhealthy, never the reverse. Debt is valued separately by _debtUSD; callers compose the two.
     * @param account Account to value.
     * @return capacityUSD Sum of collateral value at price - conf times borrowCF, each term floored.
     */
    function _borrowCapacity(address account) internal view returns (uint256 capacityUSD) {
        uint16 assetsIn = userBasic[account].assetsIn;
        for (uint8 i = 0; i < NUM_ASSETS; i++) {
            if (assetsIn & uint16(1 << i) == 0) continue;

            address asset = assetByOffset[i];
            CollateralConfig memory config = collateralConfig[asset];
            (uint256 price, uint256 conf) = ORACLE.getPrice(asset);

            // conf may exceed price only if the oracle passed a price it should have rejected; the
            // subtraction reverting is the correct failure mode, not a clamp to zero.
            uint256 lowEdge = price - conf;
            uint256 balance = userCollateralBalance[account][asset];

            // Floors once over the whole product rather than per factor: two flooring steps would
            // discard more of the borrower's capacity than the policy calls for.
            capacityUSD += FixedPointMathLib.fullMulDiv(
                balance * config.borrowCollateralFactor, lowEdge, 10 ** config.decimals * FACTOR_SCALE
            );
        }
    }

    /// @inheritdoc ILendingMarket
    function isLiquidatable(address account) external view returns (bool) {
        return _debtUSD(account) > _liquidationCapacity(account);
    }

    /**
     * @notice Liquidation capacity of an account in USD at 1e18 scale.
     * @dev The eligibility twin of _borrowCapacity (Guide 2, Section 7.1). Collateral is valued at
     *      the *high* edge of the confidence band with liquidateCF, so an account is never absorbed
     *      on a noisy tick; erring toward calling an unhealthy account healthy, the borrower-favorable
     *      choice. Debt is valued separately by _debtUSD; callers compose the two.
     * @param account Account to value.
     * @return liqCapacityUSD Sum of collateral value at price + conf times liquidateCF, each floored.
     */
    function _liquidationCapacity(address account) internal view returns (uint256 liqCapacityUSD) {
        uint16 assetsIn = userBasic[account].assetsIn;
        for (uint8 i = 0; i < NUM_ASSETS; i++) {
            if (assetsIn & uint16(1 << i) == 0) continue;

            address asset = assetByOffset[i];
            CollateralConfig memory config = collateralConfig[asset];
            (uint256 price, uint256 conf) = ORACLE.getPrice(asset);

            uint256 highEdge = price + conf;
            uint256 balance = userCollateralBalance[account][asset];

            liqCapacityUSD += FixedPointMathLib.fullMulDiv(
                balance * config.liquidateCollateralFactor, highEdge, 10 ** config.decimals * FACTOR_SCALE
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ERC20 (REBASING BASE)
    //////////////////////////////////////////////////////////////*/

    function name() external pure returns (string memory) {
        return NAME;
    }

    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }

    /// @notice Matches the base asset so wallets display lmUSDC like USDC.
    function decimals() external view returns (uint8) {
        return IERC20Metadata(BASE_TOKEN).decimals();
    }

    /// @inheritdoc ILendingMarket
    function transfer(address to, uint256 amount) external nonReentrant notPaused(PAUSE_TRANSFER) returns (bool) {
        _transferBase(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc ILendingMarket
    function transferFrom(address from, address to, uint256 amount)
        external
        nonReentrant
        notPaused(PAUSE_TRANSFER)
        returns (bool)
    {
        _spendAllowance(from, msg.sender, amount);
        _transferBase(from, to, amount);
        return true;
    }

    /// @inheritdoc ILendingMarket
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Moves base supply between accounts as principal, never creating debt.
     * @dev Accrues first, then requires the sender stay non-negative: transfers cannot borrow, so
     *      no oracle is consulted. Sender burn rounds up, receiver credit rounds down (via the
     *      conversion pair), both protocol-favorable.
     */
    function _transferBase(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidRecipient(to);
        if (amount == 0) revert ZeroAmount();

        _accrue();

        uint256 fromBalance = balanceOf(from);
        if (amount > fromBalance) revert TransferWouldBorrow(from, fromBalance, amount);

        int104 fromOld = userBasic[from].principal;
        int104 toOld = userBasic[to].principal;

        int104 fromNew = _principalValue(_presentValue(fromOld) - amount.toInt256());
        int104 toNew = _principalValue(_presentValue(toOld) + amount.toInt256());

        _updateBasePrincipal(from, fromOld, fromNew);
        _updateBasePrincipal(to, toOld, toNew);

        emit Transfer(from, to, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = allowance[owner][spender];
        if (current != type(uint256).max) {
            if (amount > current) revert InsufficientAllowance(owner, spender, current, amount);
            allowance[owner][spender] = current - amount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          GOVERNANCE / PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingMarket
    function setPauseFlags(uint8 flags) external {
        if (msg.sender == owner()) {
            // Owner may set or clear any flag.
        } else if (msg.sender == GUARDIAN) {
            // Guardian may only add flags: the new set must be a superset of the current one.
            uint8 current = marketState.pauseFlags;
            if (flags & current != current) revert GuardianCannotUnpause(current, flags);
        } else {
            revert Unauthorized(msg.sender);
        }

        marketState.pauseFlags = flags;
        emit PauseFlagsSet(msg.sender, flags);
    }

    /*//////////////////////////////////////////////////////////////
                          COLLATERAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the config for a listed collateral asset, reverting if unlisted.
    function _requireListed(address asset) internal view returns (CollateralConfig memory) {
        CollateralConfig memory config = collateralConfig[asset];
        if (config.asset == address(0)) revert UnknownAsset(asset);
        return config;
    }

    /// @notice Sets the account's assetsIn bit for a collateral asset.
    function _setAssetIn(address account, address asset) internal {
        userBasic[account].assetsIn |= uint16(1 << _offsetOf(asset));
    }

    /// @notice Clears the account's assetsIn bit for a collateral asset.
    function _clearAssetIn(address account, address asset) internal {
        userBasic[account].assetsIn &= ~uint16(1 << _offsetOf(asset));
    }

    /// @notice Bit offset of a listed collateral asset in the assetsIn bitmap.
    function _offsetOf(address asset) internal view returns (uint8) {
        for (uint8 i = 0; i < NUM_ASSETS; i++) {
            if (assetByOffset[i] == asset) return i;
        }
        revert UnknownAsset(asset);
    }

    /*//////////////////////////////////////////////////////////////
                                REFUND
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Accepts ETH so the oracle can refund its per-asset fee surplus back to the market.
     * @dev _pushPrices forwards the whole balance to the oracle on each per-asset call; the oracle
     *      consumes only the Pyth fee and refunds the rest here. The market re-forwards that balance
     *      on the next call and _refundExcessValue sweeps the final remainder to the caller, so the
     *      market never retains ETH across a transaction.
     */
    receive() external payable {}

    /**
     * @notice Sweeps any leftover msg.value back to the caller so the market never holds ETH.
     * @dev Sweeping the whole balance rather than `msg.value - spent` is deliberate. Any ETH that
     *      reaches this contract, whether the oracle's refund, a forced selfdestruct, or a pre-deploy
     *      transfer, is swept to the caller. An exact refund would strand the latter two instead,
     *      requiring an owner-only rescue function: more governance surface for no user benefit.
     */
    function _refundExcessValue() internal {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool ok,) = msg.sender.call{value: balance}("");
            if (!ok) revert RefundFailed(msg.sender, balance);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          STATE INTROSPECTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Full global market state.
     * @return Current MarketState struct.
     */
    function getMarketState() external view returns (MarketState memory) {
        return marketState;
    }

    /**
     * @notice Signed base principal of an account.
     * @param account Account to query.
     * @return Signed principal: positive supplies, negative borrows.
     */
    function getPrincipal(address account) external view returns (int104) {
        return userBasic[account].principal;
    }
}
