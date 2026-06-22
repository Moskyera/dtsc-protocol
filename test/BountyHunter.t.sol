// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {RedemptionHandler} from "../src/core/RedemptionHandler.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @title Regression tests for bounty-hunter findings (all fixed)
contract BountyHunterTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    MockPair pair;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(10_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));

        primeOracle(sys, pair);
        seedMinStabilityPool(sys);
    }

    function test_BOUNTY01_claimRewardsPaysAccrued() public {
        uint256 spSeed = sys.stabilityPool.totalDeposits();
        if (spSeed > 0) {
            vm.prank(SP_LP);
            sys.stabilityPool.withdraw(spSeed);
        }

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(alice, 1000e18);
        vm.startPrank(alice);
        sys.dtsc.approve(address(sys.stabilityPool), type(uint256).max);
        sys.stabilityPool.deposit(1000e18);
        vm.stopPrank();

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(address(sys.penaltyRouter), 100e18);
        vm.prank(address(sys.vaultManager));
        sys.penaltyRouter.routePenalty(100e18);

        assertGt(sys.stabilityPool.claimableReward(alice), 0);

        vm.prank(alice);
        uint256 paid = sys.stabilityPool.claimRewards();
        assertEq(paid, 80e18);
        assertEq(sys.dtsc.balanceOf(alice), 80e18);
    }

    function test_BOUNTY02_crCacheUpdatesOnRefresh() public {
        hexToken.seedStake(alice, 300_000e8, 4500, 1001);
        hexToken.seedStake(bob, 300_000e8, 4500, 1002);
        hexToken.mint(alice, 300_000e8);
        hexToken.mint(bob, 300_000e8);

        uint256 vaultAlice = _openVaultOnly(alice, 200_000e8);
        uint256 vaultBob = _openVaultOnly(bob, 200_000e8);
        mintToTargetCr(sys, alice, vaultAlice, 0, 16_800);
        mintToTargetCr(sys, bob, vaultBob, 1, 16_500);
        prepareRedemption(sys);

        (uint256 cachedId,) = sys.vaultManager.findLowestCrActiveVault();
        assertEq(cachedId, vaultBob, "bob slightly more debt");

        pair.setReserves(uint112(10_000_000e8), uint112(6000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultAlice);

        assertLt(
            sys.vaultManager.getVaultCollateralRatio(vaultAlice),
            sys.vaultManager.getVaultCollateralRatio(vaultBob),
            "alice lowest after selective refresh"
        );

        (uint256 cachedAfter,) = sys.vaultManager.findLowestCrActiveVault();
        assertEq(cachedAfter, vaultAlice, "cache recomputed after refreshVault");
    }

    function test_BOUNTY03_registeredVaultSkippedInRedemption() public {
        DTSCDeployer deployer = new DTSCDeployer();
        DTSCSystem memory sysReg = deployer.deployWithOptions(
            address(hexToken), address(hexToken), address(0xDAA1), address(pair), address(0x1001), true
        );
        primeOracle(sysReg, pair);
        seedMinStabilityPool(sysReg);

        hexToken.seedStake(alice, 200_000e8, 4500, 1001);
        vm.prank(alice);
        uint256 vaultId = sysReg.vaultManager.openVaultWithExistingStake(0);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sysReg.oracle.update();
        (uint256 maxMint,) = sysReg.valuation.maxBorrowable(alice, 0, false);
        vm.prank(alice);
        sysReg.vaultManager.mintDtsc(vaultId, maxMint / 2);

        (uint256 lowestId,) = sysReg.vaultManager.findLowestCrActiveVault();
        assertEq(lowestId, 0);

        vm.prank(address(sysReg.vaultManager));
        sysReg.dtsc.mint(attacker, 100e18);
        vm.startPrank(attacker);
        sysReg.dtsc.approve(address(sysReg.redemptionHandler), type(uint256).max);
        vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
        sysReg.redemptionHandler.redeem(50e18, 5);
        vm.stopPrank();
    }

    function test_BOUNTY04_recoveryExitsWhenCrHealthy() public {
        DTSCDeployer deployer = new DTSCDeployer();
        DTSCSystem memory sysReg = deployer.deployWithOptions(
            address(hexToken), address(hexToken), address(0xDAA1), address(pair), address(0x1001), true
        );
        primeOracle(sysReg, pair);
        seedMinStabilityPool(sysReg);
        hexToken.seedStake(alice, 100_000e8, 4500, 1001);

        vm.prank(alice);
        uint256 vaultId = sysReg.vaultManager.openVaultWithExistingStake(0);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sysReg.oracle.update();
        (uint256 maxMint,) = sysReg.valuation.maxBorrowable(alice, 0, false);
        vm.prank(alice);
        sysReg.vaultManager.mintDtsc(vaultId, maxMint / 2);

        uint256 total = sysReg.stabilityPool.totalDeposits();
        vm.prank(SP_LP);
        sysReg.stabilityPool.withdraw(total);

        VaultManager.Vault memory v0 = sysReg.vaultManager.getVault(vaultId);
        vm.prank(alice);
        hexToken.endStake(0, uint48(v0.stakeId));
        sysReg.vaultManager.reportEarlyUnstake(vaultId);

        assertGe(sysReg.recovery.totalBadDebtDtsc(), C.BAD_DEBT_RECOVERY_THRESHOLD_DTSC);
        assertFalse(sysReg.recovery.isRecoveryMode(), "recovery exits when system CR healthy");
        assertTrue(sysReg.recovery.unbackedDebtBlocksMint());

        seedMinStabilityPool(sysReg);
        hexToken.seedStake(bob, 100_000e8, 4500, 1002);
        vm.prank(bob);
        uint256 v2 = sysReg.vaultManager.openVaultWithExistingStake(0);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sysReg.oracle.update();
        vm.prank(bob);
        vm.expectRevert(VaultManager.UnbackedDebtRestriction.selector);
        sysReg.vaultManager.mintDtsc(v2, 1e18);
    }

    function _openVaultOnly(address user, uint256 hearts) internal returns (uint256 vaultId) {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), hearts);
        vaultId = sys.vaultManager.openVaultWithNewStake(hearts, 4500);
        vm.stopPrank();
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
    }

    function _openAndMint(address user, uint256 hearts, uint256 mintAmt) internal returns (uint256 vaultId) {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), hearts);
        vaultId = sys.vaultManager.openVaultWithNewStake(hearts, 4500);
        vm.stopPrank();
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        vm.prank(user);
        sys.vaultManager.mintDtsc(vaultId, mintAmt);
    }
}