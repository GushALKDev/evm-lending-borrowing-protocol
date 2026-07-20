// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {ILendingMarket} from "./interfaces/ILendingMarket.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

/**
 * @title LendingMarket
 * @author GushALKDev
 * @notice Single base asset money market in the style of Compound III: one borrowable base asset,
 *         inert supply-only collateral, index based interest accrual, and derived reserves.
 * @dev Phase 1 scope: storage layout, the principal / present value conversion pair, index accrual,
 *      utilization, the rebasing views, and the single accounting path every base balance change
 *      must route through. User facing actions arrive in later phases.
 *
 *      Rounding policy (Guide 2, Section 10) is load bearing: every division where the protocol and
 *      an account sit on opposite sides rounds toward the protocol. Supply side rounds down, borrow
 *      side rounds up, without exception.
 */
abstract contract LendingMarket is ILendingMarket {
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

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Global accounting state: indexes, accrual timestamp, pause flags, principal totals.
    MarketState internal marketState;

    /// @notice Per account signed base principal and collateral membership bitmap.
    mapping(address account => UserBasic basic) internal userBasic;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Wires the immutable dependencies and seeds both indexes at BASE_INDEX_SCALE.
     * @dev Base decimals are read from the token rather than passed in: a mismatched literal would
     *      corrupt every base denominated quantity (minBorrow, absorb settlement, buyCollateral
     *      quotes) silently instead of reverting. A token without decimals() reverts here, which is
     *      the same outcome validating a passed in value would produce.
     * @param baseToken The single borrowable base asset.
     * @param interestRateModel Immutable rate policy contract.
     */
    constructor(address baseToken, address interestRateModel) {
        if (baseToken == address(0)) revert InvalidConfiguration("baseToken");
        if (interestRateModel == address(0)) revert InvalidConfiguration("interestRateModel");

        BASE_TOKEN = baseToken;
        BASE_SCALE = 10 ** IERC20Metadata(baseToken).decimals();
        INTEREST_RATE_MODEL = IInterestRateModel(interestRateModel);

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
        return IERC20Metadata(BASE_TOKEN).balanceOf(address(this));
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
