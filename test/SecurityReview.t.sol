// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {StabilityPool} from "../src/core/StabilityPool.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

contract SecurityReviewTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    MockPair pair;
    address user = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(1_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deployWithOptions(
            address(hexToken), address(hexToken), quote, address(pair), address(0x1001), true
        );

        sys.oracle.update();
        pair.bumpCumulative(1e18, 0);
        vm.warp(block.timestamp + 1 days);
        sys.oracle.update();

        seedMinStabilityPool(sys);

        hexToken.seedStake(user, 100_000e8, 4500, 1001);
    }

    function test_notifyReward_rejectsUnauthorizedCaller() public {
        vm.expectRevert(StabilityPool.Unauthorized.selector);
        sys.stabilityPool.notifyReward(100e18);
    }

    function test_stakeKey_clearedAfterEarlyUnstakeReport() public {
        vm.prank(user);
        uint256 vaultId = sys.vaultManager.openVaultWithExistingStake(0);

        VaultManager.Vault memory v0 = sys.vaultManager.getVault(vaultId);
        bytes32 key = keccak256(abi.encodePacked(user, v0.stakeId));

        vm.prank(user);
        hexToken.endStake(0, uint48(v0.stakeId));

        sys.vaultManager.reportEarlyUnstake(vaultId);
        assertEq(sys.vaultManager.stakeKeyToVaultId(key), 0);
    }

    function test_stakeIndex_resyncAfterListReorder() public {
        uint40 secondStakeId = hexToken.seedStake(user, 50_000e8, 3000, 1001);
        secondStakeId;

        vm.prank(user);
        uint256 vaultId = sys.vaultManager.openVaultWithExistingStake(0);
        VaultManager.Vault memory v0 = sys.vaultManager.getVault(vaultId);

        vm.prank(user);
        hexToken.endStake(1, uint48(secondStakeId));

        sys.vaultManager.refreshVault(vaultId);
        VaultManager.Vault memory v1 = sys.vaultManager.getVault(vaultId);
        assertEq(v1.stakeId, v0.stakeId);
        assertTrue(v1.active);
        assertGt(v1.effectiveValueUsd, 0);
    }

    function test_finalizeSetup_blocksOpenSetters() public {
        vm.expectRevert();
        sys.vaultManager.setRedemptionHandler(attacker);
    }

    function test_redemption_targetsLowestCrNotJustUnderwater() public {
        _drainStabilityPool(sys);
        seedMinStabilityPool(sys);
        hexToken.mint(user, 320_000e8);

        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 320_000e8);
        uint256 v1 = sys.vaultManager.openVaultWithNewStake(160_000e8, 4200);
        uint256 v2 = sys.vaultManager.openVaultWithNewStake(160_000e8, 4200);
        vm.stopPrank();

        vm.warp(block.timestamp + 61 days);
        sys.oracle.update();

        (uint256 max1,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        (uint256 max2,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 1, false);

        vm.startPrank(user);
        sys.vaultManager.mintDtsc(v1, max1 / 2);
        sys.vaultManager.mintDtsc(v2, max2);
        vm.stopPrank();

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(attacker, 500e18);
        vm.prank(attacker);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);

        prepareRedemption(sys);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(10e18, 5);

        uint256 debt1 = sys.vaultManager.getVault(v1).debtDtsc;
        uint256 debt2 = sys.vaultManager.getVault(v2).debtDtsc;
        assertLt(debt2, max2);
        assertGe(debt1, max1 / 2 - 10e18);
    }

    function test_spOffsetBurnsDtscAndReducesCompoundedDeposit() public {
        // Keep seeded MIN_SP_COVERAGE; user adds separate deposit to observe offset loss
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(user, 1000e18);
        vm.prank(user);
        sys.dtsc.approve(address(sys.stabilityPool), type(uint256).max);
        vm.prank(user);
        sys.stabilityPool.deposit(1000e18);

        vm.prank(user);
        uint256 vaultId = sys.vaultManager.openVaultWithExistingStake(0);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        vm.prank(user);
        sys.vaultManager.mintDtsc(vaultId, 100e18);

        VaultManager.Vault memory v0 = sys.vaultManager.getVault(vaultId);
        vm.prank(user);
        hexToken.endStake(0, uint48(v0.stakeId));
        sys.vaultManager.reportEarlyUnstake(vaultId);

        assertLt(sys.stabilityPool.getCompoundedDeposit(user), 1000e18);
    }

    function _drainStabilityPool(DTSCSystem memory s) internal {
        uint256 total = s.stabilityPool.totalDeposits();
        if (total == 0) return;
        vm.prank(SP_LP);
        s.stabilityPool.withdraw(total);
    }
}