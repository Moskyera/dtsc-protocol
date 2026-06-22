// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {RedemptionHandler} from "../src/core/RedemptionHandler.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @title End-to-end protocol workflow tests — borrow, repay, redeem, liquidate, close
contract AttackWorkflowTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    MockPair pair;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address liquidator = address(0x1E4A);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(10_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));

        primeOracle(sys, pair);
        seedMinStabilityPool(sys);

        hexToken.mint(alice, 600_000e8);
        hexToken.mint(bob, 400_000e8);
    }

    /// FLOW01: Full borrow lifecycle — open → cooldown → mint → partial repay → full repay → close
    function test_FLOW01_borrowRepayClose_fullLifecycle() public {
        vm.startPrank(alice);
        hexToken.approve(address(sys.vaultManager), 250_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(250_000e8, 4500);
        vm.stopPrank();

        assertTrue(sys.vaultManager.getVault(vaultId).active);
        assertEq(sys.vaultManager.getVault(vaultId).debtDtsc, 0);

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        (uint256 maxBorrow,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        assertGt(maxBorrow, 0);

        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, maxBorrow);
        assertEq(sys.vaultManager.getVault(vaultId).debtDtsc, maxBorrow);
        assertEq(sys.dtsc.balanceOf(alice), maxBorrow);

        uint256 half = maxBorrow / 2;
        vm.startPrank(alice);
        sys.dtsc.approve(address(sys.vaultManager), half);
        sys.vaultManager.repayDtsc(vaultId, half);
        vm.stopPrank();

        assertEq(sys.vaultManager.getVault(vaultId).debtDtsc, maxBorrow - half);

        uint256 remaining = sys.vaultManager.getVault(vaultId).debtDtsc;
        vm.startPrank(alice);
        sys.dtsc.approve(address(sys.vaultManager), remaining);
        sys.vaultManager.repayDtsc(vaultId, remaining);
        sys.vaultManager.closeVault(vaultId);
        vm.stopPrank();

        assertFalse(sys.vaultManager.getVault(vaultId).active);
        assertEq(hexToken.balanceOf(alice), 600_000e8, "HEX returned on close");
        assertEq(sys.vaultManager.totalDebtDtsc(), 0);
    }

    /// FLOW02: Two borrowers — redemption hits lowest CR, liquidation hits underwater
    function test_FLOW02_multiUser_redeemAndLiquidate() public {
        vm.startPrank(alice);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultAlice = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.startPrank(bob);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultBob = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        (uint256 maxAlice,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        (uint256 maxBob,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 1, false);

        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultAlice, maxAlice);
        vm.prank(bob);
        sys.vaultManager.mintDtsc(vaultBob, maxBob / 4);

        // Redemption targets alice (lowest CR)
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(liquidator, 50e18);
        vm.startPrank(liquidator);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);
        prepareRedemption(sys);
        sys.redemptionHandler.redeem(25e18, 2);
        vm.stopPrank();

        assertLt(sys.vaultManager.getVault(vaultAlice).debtDtsc, maxAlice);
        assertEq(sys.vaultManager.getVault(vaultBob).debtDtsc, maxBob / 4);

        // Crash price — alice underwater, bob still healthy
        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultAlice);
        sys.vaultManager.refreshVault(vaultBob);

        assertLt(sys.vaultManager.getVaultCollateralRatio(vaultAlice), C.CCR_LONG_BPS);
        assertGe(sys.vaultManager.getVaultCollateralRatio(vaultBob), C.CCR_LONG_BPS);

        uint256 debtAlice = sys.vaultManager.getVault(vaultAlice).debtDtsc;
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(liquidator, debtAlice);
        vm.startPrank(liquidator);
        sys.dtsc.approve(address(sys.vaultManager), debtAlice);
        sys.vaultManager.liquidate(vaultAlice, debtAlice);
        vm.stopPrank();

        assertFalse(sys.vaultManager.getVault(vaultAlice).active);
        assertTrue(sys.vaultManager.getVault(vaultBob).active);
    }

    /// FLOW03: Stability Pool deposit → offset on liquidation → depositor loss
    function test_FLOW03_stabilityPool_absorbsLiquidationDebt() public {
        address spUser = address(0x5FEED2);
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(spUser, 2000e18);
        vm.startPrank(spUser);
        sys.dtsc.approve(address(sys.stabilityPool), type(uint256).max);
        sys.stabilityPool.deposit(2000e18);
        vm.stopPrank();

        vm.startPrank(alice);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        (uint256 maxBorrow,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, maxBorrow);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        uint256 spDepositBefore = sys.stabilityPool.getCompoundedDeposit(spUser);
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(liquidator, maxBorrow);
        vm.startPrank(liquidator);
        sys.dtsc.approve(address(sys.vaultManager), maxBorrow);
        sys.vaultManager.liquidate(vaultId, maxBorrow);
        vm.stopPrank();

        assertLt(sys.stabilityPool.getCompoundedDeposit(spUser), spDepositBefore, "SP depositor took loss");
        assertFalse(sys.vaultManager.getVault(vaultId).active, "vault liquidated via SP offset");
    }

    /// FLOW04: Recovery mode exit — price recovers, mint re-enabled
    function test_FLOW04_recoveryMode_exitAllowsMint() public {
        vm.startPrank(alice);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        (uint256 maxBorrow,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        uint256 initialMint = maxBorrow * 3 / 4;
        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, initialMint);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);
        assertTrue(sys.recovery.isRecoveryMode());

        vm.prank(alice);
        vm.expectRevert(VaultManager.RecoveryModeRestriction.selector);
        sys.vaultManager.mintDtsc(vaultId, 1e18);

        pair.setReserves(uint112(10_000_000e8), uint112(10_000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);
        assertFalse(sys.recovery.isRecoveryMode());

        uint256 room = maxBorrow - initialMint;
        assertGt(room, 0);
        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, room);
        assertEq(sys.vaultManager.getVault(vaultId).debtDtsc, maxBorrow);
    }

    /// FLOW05: Payment path — DTSC transfer + repay by third party
    function test_FLOW05_thirdPartyRepay_allowed() public {
        vm.startPrank(alice);
        hexToken.approve(address(sys.vaultManager), 150_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(150_000e8, 4000);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        (uint256 maxBorrow,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, maxBorrow);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(bob, maxBorrow);

        vm.startPrank(bob);
        sys.dtsc.approve(address(sys.vaultManager), maxBorrow);
        vm.expectRevert(VaultManager.Unauthorized.selector);
        sys.vaultManager.repayDtsc(vaultId, maxBorrow);
        vm.stopPrank();

        vm.startPrank(alice);
        sys.dtsc.approve(address(sys.vaultManager), maxBorrow);
        sys.vaultManager.repayDtsc(vaultId, maxBorrow);
        vm.stopPrank();

        assertEq(sys.vaultManager.getVault(vaultId).debtDtsc, 0);
    }

    /// FLOW06: Sequential operations in one session — mint, redeem, repay, close
    function test_FLOW06_sequentialOps_noStateCorruption() public {
        vm.startPrank(alice);
        hexToken.approve(address(sys.vaultManager), 300_000e8);
        uint256 v1 = sys.vaultManager.openVaultWithNewStake(150_000e8, 4500);
        uint256 v2 = sys.vaultManager.openVaultWithNewStake(150_000e8, 3000);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        uint256 debt1 = mintToTargetCr(sys, alice, v1, 0, 17_500);
        uint256 debt2 = mintToTargetCr(sys, alice, v2, 1, 19_000);

        assertEq(sys.vaultManager.totalDebtDtsc(), debt1 + debt2);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(bob, 30e18);
        vm.startPrank(bob);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);
        prepareRedemption(sys);
        sys.redemptionHandler.redeem(15e18, 3);
        vm.stopPrank();

        vm.startPrank(alice);
        sys.dtsc.approve(address(sys.vaultManager), debt2);
        sys.vaultManager.repayDtsc(v2, debt2);
        sys.vaultManager.closeVault(v2);
        vm.stopPrank();

        assertFalse(sys.vaultManager.getVault(v2).active);
        assertTrue(sys.vaultManager.getVault(v1).active);
        assertEq(sys.vaultManager.getVault(v2).debtDtsc, 0);
        assertGt(sys.vaultManager.getVault(v1).debtDtsc, 0);
    }
}