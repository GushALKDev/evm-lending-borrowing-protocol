// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestnetToken
 * @author GushALKDev
 * @notice Testnet stand-in for USDC, WETH or wBTC, mintable only by the faucet that deployed it.
 */
contract TestnetToken is ERC20 {
    error OnlyMinter(address caller);

    /// @notice The faucet, the only account that can mint.
    address public immutable MINTER;

    uint8 private immutable DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        MINTER = msg.sender;
        DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Mints new tokens. Faucet only.
    function mint(address to, uint256 amount) external {
        if (msg.sender != MINTER) revert OnlyMinter(msg.sender);
        _mint(to, amount);
    }
}

/**
 * @title TestnetFaucet
 * @author GushALKDev
 * @notice Deploys the three testnet tokens of the demo market and hands out a fixed amount of each,
 *         once a day per address. Testnet only.
 * @dev The daily limit slows how fast any one address can pile up tokens; it is per address, so it
 *      does not stop someone using many. The owner (the deployer) can mint any amount, which the deploy
 *      script uses to seed the market.
 */
contract TestnetFaucet is Ownable {
    error ClaimTooSoon(address account, uint256 nextClaimAt);
    error UnknownToken(address token);

    /// @notice Emitted on every claim.
    event Claimed(address indexed account);

    /// @notice Minimum time between two claims from the same address.
    uint256 public constant COOLDOWN = 1 days;

    /// @notice Amounts handed out per claim, in each token's native decimals.
    uint256 public constant USDC_DRIP = 10_000e6;
    uint256 public constant WETH_DRIP = 5e18;
    uint256 public constant WBTC_DRIP = 0.2e8;

    TestnetToken public immutable USDC;
    TestnetToken public immutable WETH;
    TestnetToken public immutable WBTC;

    /// @notice Timestamp of each address's last claim.
    mapping(address account => uint256 timestamp) public lastClaim;

    constructor(address owner_) Ownable(owner_) {
        USDC = new TestnetToken("Testnet USD Coin", "USDC", 6);
        WETH = new TestnetToken("Testnet Wrapped Ether", "WETH", 18);
        WBTC = new TestnetToken("Testnet Wrapped BTC", "WBTC", 8);
    }

    /// @notice Sends USDC_DRIP, WETH_DRIP and WBTC_DRIP to the caller, at most once per COOLDOWN.
    function claim() external {
        uint256 next = nextClaimAt(msg.sender);
        if (block.timestamp < next) revert ClaimTooSoon(msg.sender, next);
        lastClaim[msg.sender] = block.timestamp;

        USDC.mint(msg.sender, USDC_DRIP);
        WETH.mint(msg.sender, WETH_DRIP);
        WBTC.mint(msg.sender, WBTC_DRIP);

        emit Claimed(msg.sender);
    }

    /// @notice Mints any amount of one of the three tokens. Owner only, used to seed the market.
    function mint(address token, address to, uint256 amount) external onlyOwner {
        if (token != address(USDC) && token != address(WETH) && token != address(WBTC)) revert UnknownToken(token);
        TestnetToken(token).mint(to, amount);
    }

    /// @notice Earliest timestamp at which an address can claim again (0 if it never claimed).
    function nextClaimAt(address account) public view returns (uint256) {
        uint256 last = lastClaim[account];
        return last == 0 ? 0 : last + COOLDOWN;
    }
}
