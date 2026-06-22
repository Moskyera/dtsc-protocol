// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";
import {VaultManager} from "../src/core/VaultManager.sol";

contract VaultManagerTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    address user = address(0xA11CE);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        MockPair pair = new MockPair(address(hexToken), quote, uint112(1_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(
            address(hexToken),
            address(hexToken),
            quote,
            address(pair),
            address(0x1001)
        );

        primeOracle(sys, pair);

        seedMinStabilityPool(sys);

        hexToken.mint(user, 100_000e8);
    }

    function test_openVaultAndMintAfterCooldown() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        (uint256 maxDtsc,) =
            sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        uint256 mintAmount = maxDtsc / 2;
        assertGt(mintAmount, 0);

        vm.prank(user);
        sys.vaultManager.mintDtsc(vaultId, mintAmount);

        assertEq(sys.dtsc.balanceOf(user), mintAmount);
    }

    function test_cooldownBlocksMint() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert();
        sys.vaultManager.mintDtsc(vaultId, 10e18);
    }

    function test_registeredVaultsDisabledByDefault() public {
        hexToken.seedStake(user, 100_000e8, 4500, 1001);
        vm.prank(user);
        vm.expectRevert(VaultManager.RegisteredVaultsDisabled.selector);
        sys.vaultManager.openVaultWithExistingStake(0);
    }

    function test_custodialCloseReturnsHex() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        vm.prank(user);
        sys.vaultManager.closeVault(vaultId);

        assertEq(hexToken.balanceOf(user), 100_000e8);
        assertEq(hexToken.stakeCount(address(sys.vaultManager)), 0);
    }
}