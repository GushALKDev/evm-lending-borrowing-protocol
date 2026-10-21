// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {TestnetFaucet, TestnetToken} from "../TestnetFaucet.sol";

/**
 * @title TestnetFaucetTest
 * @notice Daily claims, owner minting, and that only the faucet can mint the tokens.
 * @dev Run with FOUNDRY_PROFILE=testnet.
 */
contract TestnetFaucetTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant VISITOR = address(0xB0B);

    TestnetFaucet internal faucet;

    function setUp() public {
        vm.warp(1_800_000_000);
        faucet = new TestnetFaucet(OWNER);
    }

    function test_tokens_haveTheRealDecimals() public view {
        assertEq(faucet.USDC().decimals(), 6, "USDC");
        assertEq(faucet.WETH().decimals(), 18, "WETH");
        assertEq(faucet.WBTC().decimals(), 8, "WBTC");
    }

    function test_claim_sendsTheThreeDrips() public {
        vm.prank(VISITOR);
        faucet.claim();

        assertEq(faucet.USDC().balanceOf(VISITOR), 10_000e6, "USDC drip");
        assertEq(faucet.WETH().balanceOf(VISITOR), 5e18, "WETH drip");
        assertEq(faucet.WBTC().balanceOf(VISITOR), 0.2e8, "WBTC drip");
        assertEq(faucet.nextClaimAt(VISITOR), block.timestamp + 1 days, "next claim in a day");
    }

    function test_claim_revertsUntilTheCooldownHasPassed() public {
        vm.prank(VISITOR);
        faucet.claim();
        uint256 next = block.timestamp + 1 days;

        vm.warp(next - 1);
        vm.prank(VISITOR);
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.ClaimTooSoon.selector, VISITOR, next));
        faucet.claim();

        vm.warp(next);
        vm.prank(VISITOR);
        faucet.claim();
        assertEq(faucet.USDC().balanceOf(VISITOR), 20_000e6, "second drip");
    }

    function test_mint_ownerOnly() public {
        address usdc = address(faucet.USDC());

        vm.prank(OWNER);
        faucet.mint(usdc, VISITOR, 1_000_000e6);
        assertEq(faucet.USDC().balanceOf(VISITOR), 1_000_000e6, "owner mint");

        vm.prank(VISITOR);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, VISITOR));
        faucet.mint(usdc, VISITOR, 1);
    }

    function test_mint_rejectsATokenTheFaucetDidNotDeploy() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.UnknownToken.selector, address(0xDEAD)));
        faucet.mint(address(0xDEAD), VISITOR, 1);
    }

    function test_token_onlyTheFaucetCanMint() public {
        TestnetToken usdc = faucet.USDC();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(TestnetToken.OnlyMinter.selector, OWNER));
        usdc.mint(OWNER, 1);
    }
}
