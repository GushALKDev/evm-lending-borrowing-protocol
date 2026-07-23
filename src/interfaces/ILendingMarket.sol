// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ILendingMarket
 * @author GushALKDev
 * @notice Single base asset money market: one borrowable asset (base) and inert, supply-only
 *         collateral assets. The market is itself the rebasing ERC20 claim on the base supply.
 * @dev Function contracts, units, and rounding directions are specified in the protocol docs
 *      (Guide 2 for the math, Guide 3 for the flows, Guide 5 for this surface).
 */
interface ILendingMarket {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Global market accounting state.
     * @dev Indexes start at BASE_INDEX_SCALE and only ever grow. Totals are stored as principal,
     *      not present value, which keeps sum(user principals) == totals an exact integer equality.
     */
    struct MarketState {
        uint64 baseSupplyIndex; //  8 bytes ─┐
        uint64 baseBorrowIndex; //  8 bytes  │  Slot 0 (22 bytes)
        uint40 lastAccrualTime; //  5 bytes  │
        uint8 pauseFlags; //        1 byte  ─┘
        uint104 totalSupplyBase; // 13 bytes ─┐  Slot 1 (26 bytes)
        uint104 totalBorrowBase; // 13 bytes ─┘
    }

    /**
     * @notice Per account base position and collateral membership.
     * @dev principal is signed: positive is a base supplier, negative is a borrower. The two states
     *      are mutually exclusive by construction. assetsIn is a bitmap of collateral offsets held,
     *      so health checks iterate only the assets actually in use.
     */
    struct UserBasic {
        int104 principal; // 13 bytes ─┐  Slot 0 (15 bytes)
        uint16 assetsIn; //  2 bytes ─┘
    }

    /**
     * @notice Immutable per collateral risk configuration, fixed at deployment.
     * @dev All factors are basis points against FACTOR_SCALE (10_000 = 100%).
     */
    struct CollateralConfig {
        address asset; // 20 bytes ─┐
        uint16 borrowCollateralFactor; //  2 bytes  │
        uint16 liquidateCollateralFactor; //  2 bytes  │  Slot 0 (28 bytes)
        uint16 liquidationFactor; //  2 bytes  │
        uint16 storeFrontPriceFactor; //  2 bytes ─┘
        uint128 supplyCap; // 16 bytes ─┐  Slot 1 (17 bytes)
        uint8 decimals; //  1 byte  ─┘
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Base supplied, covering both the pure supply and the repay branches.
     * @param from Account whose principal increased.
     * @param amount Base amount supplied.
     */
    event Supply(address indexed from, uint256 amount);

    /**
     * @notice Base withdrawn, covering both the pure withdrawal and the borrow branches.
     * @param to Account whose principal decreased.
     * @param amount Base amount withdrawn.
     */
    event Withdraw(address indexed to, uint256 amount);

    /**
     * @notice Collateral posted into the market.
     * @param from Account posting the collateral.
     * @param asset Collateral asset supplied.
     * @param amount Amount in the asset's native decimals.
     */
    event SupplyCollateral(address indexed from, address indexed asset, uint256 amount);

    /**
     * @notice Collateral withdrawn from the market.
     * @param to Account receiving the collateral.
     * @param asset Collateral asset withdrawn.
     * @param amount Amount in the asset's native decimals.
     */
    event WithdrawCollateral(address indexed to, address indexed asset, uint256 amount);

    /**
     * @notice Debt settlement half of an absorb, carrying the recognized bad debt explicitly.
     * @param absorber Caller that triggered the absorb.
     * @param account Account absorbed.
     * @param debtAbsorbed Debt present value wiped against reserves.
     * @param badDebt Shortfall the seized collateral did not cover, zero on a covered absorb.
     */
    event AbsorbDebt(address indexed absorber, address indexed account, uint256 debtAbsorbed, uint256 badDebt);

    /**
     * @notice Seizure half of an absorb, emitted once per collateral asset held.
     * @param absorber Caller that triggered the absorb.
     * @param account Account absorbed.
     * @param asset Collateral asset seized into protocol ownership.
     * @param amount Amount seized in the asset's native decimals.
     * @param usdValue Mid price value of the seized amount at 1e18 scale.
     */
    event AbsorbCollateral(
        address indexed absorber, address indexed account, address indexed asset, uint256 amount, uint256 usdValue
    );

    /**
     * @notice Discounted sale of protocol held collateral inventory.
     * @param buyer Caller paying base.
     * @param asset Collateral asset sold.
     * @param baseAmount Base paid in.
     * @param collateralAmount Collateral sent out.
     */
    event BuyCollateral(address indexed buyer, address indexed asset, uint256 baseAmount, uint256 collateralAmount);

    /**
     * @notice Owner withdrawal of accumulated reserves.
     * @param to Recipient of the reserves.
     * @param amount Base amount withdrawn.
     */
    event WithdrawReserves(address indexed to, uint256 amount);

    /**
     * @notice Pause bitfield changed.
     * @param by Caller that set the flags, owner or guardian.
     * @param flags New pause bitfield.
     */
    event PauseFlagsSet(address indexed by, uint8 flags);

    /*//////////////////////////////////////////////////////////////
                        ERRORS: INPUT AND STATE
    //////////////////////////////////////////////////////////////*/

    error Paused(uint8 flag);
    error ZeroAmount();
    error UnknownAsset(address asset);
    error InvalidRecipient(address recipient);
    error SupplyCapExceeded(address asset, uint128 cap, uint256 attempted);
    error InsufficientCash(uint256 requested, uint256 available);
    error InsufficientCollateral(address account, address asset, uint128 balance, uint256 amount);
    error RefundFailed(address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                        ERRORS: HEALTH AND DEBT
    //////////////////////////////////////////////////////////////*/

    error NotCollateralized(address account, uint256 debtUSD, uint256 capacityUSD);
    error MinBorrowNotMet(uint256 borrowPV, uint256 minBorrow);
    error NotLiquidatable(address account, uint256 debtUSD, uint256 liqCapacityUSD);
    error TransferWouldBorrow(address from, uint256 balance, uint256 amount);
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                    ERRORS: STOREFRONT AND RESERVES
    //////////////////////////////////////////////////////////////*/

    error NotForSale(int256 reserves, uint256 targetReserves);
    error TooMuchSlippage(uint256 quoted, uint256 minAmount);
    error InsufficientInventory(address asset, uint256 requested, uint256 available);
    error InsufficientReserves(int256 reserves, uint256 requested);

    /*//////////////////////////////////////////////////////////////
                    ERRORS: ACCESS AND CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    error Unauthorized(address caller);
    error GuardianCannotUnpause(uint8 current, uint8 requested);
    error InvalidConfiguration(bytes32 what);

    /*//////////////////////////////////////////////////////////////
                             USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Supplies base (crediting supply, repaying debt first if the account is negative) or
     *         collateral. Never consults the oracle: supplying can only improve health.
     * @param asset Base asset or a listed collateral asset.
     * @param amount Amount in the asset's native decimals. For base, type(uint256).max repays the
     *        full debt exactly and supplies nothing beyond it.
     */
    function supply(address asset, uint256 amount) external;

    /**
     * @notice Withdraws base (opening or increasing a borrow past zero) or collateral.
     * @dev Payable: consults the oracle and forwards the update fee only when the action can reduce
     *      account health. Surplus msg.value is refunded to the caller.
     * @param asset Base asset or a listed collateral asset.
     * @param amount Amount in the asset's native decimals.
     * @param priceUpdate Signed oracle update payloads, empty when no price is needed.
     */
    function withdraw(address asset, uint256 amount, bytes[] calldata priceUpdate) external payable;

    /**
     * @notice Absorbs an underwater account: wipes its debt against reserves and seizes all of its
     *         collateral into protocol ownership. Pays the caller nothing by design.
     * @param account Account to absorb, must be liquidatable at price + conf.
     * @param priceUpdate Signed oracle update payloads for the base and every held collateral.
     */
    function absorb(address account, bytes[] calldata priceUpdate) external payable;

    /**
     * @notice Buys protocol-held collateral at a discount to the oracle price, paying base.
     * @dev Only available while getReserves() is below targetReserves.
     * @param asset Collateral asset to buy.
     * @param minAmount Minimum collateral out, slippage guard.
     * @param baseAmount Base paid in.
     * @param recipient Receiver of the collateral.
     * @param priceUpdate Signed oracle update payloads for the asset and the base.
     */
    function buyCollateral(
        address asset,
        uint256 minAmount,
        uint256 baseAmount,
        address recipient,
        bytes[] calldata priceUpdate
    ) external payable;

    /**
     * @notice Advances the supply and borrow indexes to the current block timestamp.
     * @dev Permissionless, never pausable, idempotent within a block.
     */
    function accrue() external;

    /*//////////////////////////////////////////////////////////////
                          ERC20 (REBASING BASE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Standard ERC20 transfer event; mint uses address(0) as from, burn as to.
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice Standard ERC20 approval event for the rebasing base claim.
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /**
     * @notice Transfers base supply, moving principal between accounts.
     * @dev Reverts if it would push the sender's principal negative: transfers cannot create debt,
     *      so no oracle is consulted.
     * @param to Recipient.
     * @param amount Base amount to move.
     * @return Always true on success (reverts otherwise).
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @notice Transfers base supply on behalf of `from`, spending the caller's allowance.
     * @param from Account whose supply moves.
     * @param to Recipient.
     * @param amount Base amount to move.
     * @return Always true on success (reverts otherwise).
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /**
     * @notice Sets the caller's allowance for a spender.
     * @param spender Approved spender.
     * @param amount Allowance, type(uint256).max for an unlimited approval.
     * @return Always true.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @notice Remaining allowance a spender may move on an owner's behalf.
     * @param owner Token owner.
     * @param spender Approved spender.
     * @return Remaining allowance.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                              GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraws accumulated base reserves to the treasury.
     * @param to Recipient of the reserves.
     * @param amount Base amount, bounded by both getReserves() and available cash.
     */
    function withdrawReserves(address to, uint256 amount) external;

    /**
     * @notice Sets the pause bitfield.
     * @dev The owner may set or clear any flag. The guardian may only add flags, never clear them.
     * @param flags New pause bitfield.
     */
    function setPauseFlags(uint8 flags) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Present value of an account's positive base principal, zero while borrowing.
     * @param account Account to query.
     * @return Base units at the base asset's decimals.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Present value of an account's debt, zero while supplying.
     * @param account Account to query.
     * @return Base units at the base asset's decimals.
     */
    function borrowBalanceOf(address account) external view returns (uint256);

    /**
     * @notice Present value of the global supply principal.
     * @return Base units at the base asset's decimals.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Present value of the global borrow principal.
     * @return Base units at the base asset's decimals.
     */
    function totalBorrow() external view returns (uint256);

    /**
     * @notice Ratio of borrows to supply in present value.
     * @dev May exceed 1e18 once reserves have been paid out (see Guide 2, Section 4).
     * @return Utilization at 1e18 scale.
     */
    function getUtilization() external view returns (uint256);

    /**
     * @notice Protocol equity, derived as cash + totalBorrow - totalSupply.
     * @dev Signed: bad debt recognized at absorb time can push it negative.
     * @return Reserves in base units.
     */
    function getReserves() external view returns (int256);

    /**
     * @notice Seized collateral inventory available for sale through buyCollateral.
     * @dev Derived as token.balanceOf(market) - totalsCollateral[asset]. With totalsCollateral
     *      meaning the sum of user claims, the difference is exactly the collateral the protocol
     *      owns after an absorb, plus any donations. buyCollateral can never sell below this into
     *      user-owned collateral.
     * @param asset Collateral asset to query.
     * @return Seized inventory in the asset's native decimals.
     */
    function getCollateralReserves(address asset) external view returns (uint256);

    /**
     * @notice Whether an account's debt is within its borrowing capacity.
     * @dev Collateral valued at price - conf, debt at price + conf.
     * @param account Account to query.
     * @return True when the account may borrow or withdraw collateral.
     */
    function isBorrowCollateralized(address account) external view returns (bool);

    /**
     * @notice Whether an account may be absorbed.
     * @dev Collateral valued at price + conf, borrower favorable: no absorb on a noisy tick.
     * @param account Account to query.
     * @return True when the account is absorbable.
     */
    function isLiquidatable(address account) external view returns (bool);

    /**
     * @notice Collateral received for a given base amount at the discounted storefront price.
     * @param asset Collateral asset to buy.
     * @param baseAmount Base paid in.
     * @return Collateral amount in the asset's native decimals.
     */
    function quoteCollateral(address asset, uint256 baseAmount) external view returns (uint256);

    /**
     * @notice Raw collateral balance an account has posted for an asset.
     * @param account Account to query.
     * @param asset Collateral asset to query.
     * @return Amount in the asset's native decimals.
     */
    function userCollateral(address account, address asset) external view returns (uint128);
}
