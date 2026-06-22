// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {RedemptionHandler} from "../src/core/RedemptionHandler.sol";
import {RedemptionPolicy} from "../src/libraries/RedemptionPolicy.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @title Hybrid redemption + EES penalty tests — golden middle for borrower peace of mind
contract RedemptionHybridTest is TestSetup {
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
        hexToken.mint(alice, 800_000e8);
        hexToken.mint(bob, 800_000e8);
    }

    // ─── Hybrid redemption gates ───────────────────────────────────────────────

    function test_HYBRID01_crAbove210_immuneFromRedemption() public {
        uint256 vaultId = _openAndMint(alice, 400_000e8, 4500, 20e18);
        uint256 cr = sys.vaultManager.getVaultCollateralRatio(vaultId);
        assertGt(cr, C.REDEMPTION_MAX_CR_BPS, "vault CR above redemption cap");

        assertFalse(sys.vaultManager.isVaultRedeemable(vaultId));

        _fundRedeemer(attacker, 50e18);
        uint256 debtBefore = sys.vaultManager.getVault(vaultId).debtDtsc;
        vm.prank(attacker);
        vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
        sys.redemptionHandler.redeem(10e18, 3);
        assertEq(sys.vaultManager.getVault(vaultId).debtDtsc, debtBefore);
    }

    function test_HYBRID02_gracePeriod_blocksRedemption() public {
        uint256 vaultId = _openVaultOnly(alice, 200_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, 80e18);

        assertGt(sys.vaultManager.redemptionEligibleAt(vaultId), block.timestamp);
        assertFalse(sys.vaultManager.isVaultRedeemable(vaultId));

        _fundRedeemer(attacker, 50e18);
        vm.prank(attacker);
        vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
        sys.redemptionHandler.redeem(10e18, 3);
    }

    function test_HYBRID03_graceExpires_allowsRedemption() public {
        uint256 vaultId = _openVaultOnly(alice, 200_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        mintToTargetCr(sys, alice, vaultId, 0, 18_500);
        prepareRedemption(sys);

        assertTrue(sys.vaultManager.isVaultRedeemable(vaultId));

        _fundRedeemer(attacker, 50e18);
        uint256 debtBefore = sys.vaultManager.getVault(vaultId).debtDtsc;
        vm.prank(attacker);
        sys.redemptionHandler.redeem(10e18, 3);
        assertLt(sys.vaultManager.getVault(vaultId).debtDtsc, debtBefore);
    }

    function test_HYBRID04_dynamicFee_tightCr_cheap() public {
        uint256 vaultId = _openAndMint(alice, 200_000e8, 4500, 0);
        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc);
        vm.warp(block.timestamp + C.REDEMPTION_GRACE_PERIOD + 1);

        uint256 feeBps = sys.vaultManager.redemptionFeeBpsForVault(vaultId);
        assertEq(feeBps, C.REDEMPTION_FEE_LOW_BPS);
    }

    function test_HYBRID05_dynamicFee_comfortableCr_expensive() public {
        uint256 vaultId = _openVaultOnly(alice, 300_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        mintToTargetCr(sys, alice, vaultId, 0, 19_000);
        prepareRedemption(sys);

        uint256 cr = sys.vaultManager.getVaultCollateralRatio(vaultId);
        assertGt(cr, C.CCR_LONG_BPS + C.REDEMPTION_CR_FEE_BUFFER_BPS);
        assertLt(cr, C.REDEMPTION_MAX_CR_BPS);

        uint256 feeBps = sys.vaultManager.redemptionFeeBpsForVault(vaultId);
        assertGt(feeBps, C.REDEMPTION_FEE_LOW_BPS);
        assertLe(feeBps, C.REDEMPTION_FEE_HIGH_BPS);
    }

    function test_HYBRID06_griefing_skipsProtectedVault() public {
        uint256 vAlice = _openVaultOnly(alice, 200_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        uint256 debtAlice = mintToTargetCr(sys, alice, vAlice, 0, 16_500);

        uint256 vBob = _openVaultOnly(bob, 400_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        uint256 debtBob = mintToTargetCr(sys, bob, vBob, 1, 25_000);
        prepareRedemption(sys);

        assertLt(
            sys.vaultManager.getVaultCollateralRatio(vAlice),
            sys.vaultManager.getVaultCollateralRatio(vBob)
        );
        assertTrue(sys.vaultManager.isVaultRedeemable(vAlice));
        assertFalse(sys.vaultManager.isVaultRedeemable(vBob));

        _fundRedeemer(attacker, 50e18);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(5e18, 3);

        assertLt(sys.vaultManager.getVault(vAlice).debtDtsc, debtAlice);
        assertEq(sys.vaultManager.getVault(vBob).debtDtsc, debtBob, "protected bob untouched");
    }

    function test_HYBRID07_allVaultsProtected_revertWithRefund() public {
        _openAndMint(alice, 400_000e8, 4500, 15e18);
        _openAndMint(bob, 400_000e8, 4500, 10e18);
        vm.warp(block.timestamp + C.REDEMPTION_GRACE_PERIOD + 1);

        _fundRedeemer(attacker, 30e18);
        uint256 balBefore = sys.dtsc.balanceOf(attacker);
        vm.prank(attacker);
        vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
        sys.redemptionHandler.redeem(20e18, 5);
        assertEq(sys.dtsc.balanceOf(attacker), balBefore, "full refund when no targets");
    }

    function test_HYBRID08_underwater_alwaysRedeemable() public {
        uint256 vaultId = _openVaultOnly(alice, 200_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);
        prepareRedemption(sys);

        assertLt(sys.vaultManager.getVaultCollateralRatio(vaultId), C.CCR_LONG_BPS);
        assertTrue(sys.vaultManager.isVaultRedeemable(vaultId));
        assertEq(sys.vaultManager.redemptionFeeBpsForVault(vaultId), C.REDEMPTION_FEE_LOW_BPS);

        _fundRedeemer(attacker, 100e18);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(20e18, 2);
        assertLt(sys.vaultManager.getVault(vaultId).debtDtsc, maxDtsc);
    }

    function test_HYBRID09_borrowerAt190Cr_sleepsSoundly() public {
        uint256 vaultId = _openVaultOnly(alice, 300_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        mintToTargetCr(sys, alice, vaultId, 0, 19_000);
        prepareRedemption(sys);

        uint256 cr = sys.vaultManager.getVaultCollateralRatio(vaultId);
        assertGt(cr, 18_500);
        assertLt(cr, C.REDEMPTION_MAX_CR_BPS);

        uint256 feeBps = sys.vaultManager.redemptionFeeBpsForVault(vaultId);
        assertGe(feeBps, 300, "griefing is expensive above 180% CR");

        VaultManager.Vault memory v = sys.vaultManager.getVault(vaultId);
        (, uint72 heartsBefore,,,,,) =
            hexToken.stakeLists(address(sys.vaultManager), v.stakeIndex);

        _fundRedeemer(attacker, 100e18);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(5e18, 1);

        (, uint72 heartsAfter,,,,,) =
            hexToken.stakeLists(address(sys.vaultManager), sys.vaultManager.getVault(vaultId).stakeIndex);
        uint256 extracted = heartsBefore - heartsAfter;
        assertLt(extracted, 50_000e8, "small redeem extracts minimal HEX at high CR+fee");
    }

    function test_HYBRID10_feeScales_linearly() public pure {
        uint256 feeTight = RedemptionPolicy.feeBpsForCr(
            C.CCR_LONG_BPS + C.REDEMPTION_CR_FEE_BUFFER_BPS, C.CCR_LONG_BPS
        );
        uint256 fee180 = RedemptionPolicy.feeBpsForCr(18_000, C.CCR_LONG_BPS);
        uint256 feeMax = RedemptionPolicy.feeBpsForCr(C.REDEMPTION_MAX_CR_BPS, C.CCR_LONG_BPS);

        assertEq(feeTight, C.REDEMPTION_FEE_LOW_BPS);
        assertGt(fee180, feeTight);
        assertLt(fee180, feeMax);
        assertEq(feeMax, C.REDEMPTION_FEE_HIGH_BPS);
    }

    // ─── EES penalty / endStake payout fix ─────────────────────────────────────

    function test_HYBRID11_eesPenalty_partialRedemption_usesActualPayout() public {
        hexToken.setEesPenaltyBps(1000);

        uint256 vaultId = _openVaultOnly(alice, 200_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        mintToTargetCr(sys, alice, vaultId, 0, 17_000);
        prepareRedemption(sys);

        (, uint72 heartsBefore,,,,,) =
            hexToken.stakeLists(address(sys.vaultManager), sys.vaultManager.getVault(vaultId).stakeIndex);

        _fundRedeemer(attacker, 30e18);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(10e18, 1);

        assertGt(hexToken.balanceOf(attacker), 0, "EES-penalized payout delivered to redeemer");
        assertTrue(sys.vaultManager.getVault(vaultId).active);

        (, uint72 heartsAfter,,,,,) =
            hexToken.stakeLists(address(sys.vaultManager), sys.vaultManager.getVault(vaultId).stakeIndex);
        assertLt(heartsAfter, heartsBefore, "partial redemption extracts stake hearts");
        assertGt(heartsAfter, 0, "remainder re-staked after EES penalty");
    }

    function test_HYBRID12_eesPenalty_closeVault_transfersNetPayout() public {
        hexToken.setEesPenaltyBps(1500);

        uint256 vaultId = _openVaultOnly(alice, 100_000e8, 4500);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        uint256 balBefore = hexToken.balanceOf(alice);
        vm.prank(alice);
        sys.vaultManager.closeVault(vaultId);

        uint256 received = hexToken.balanceOf(alice) - balBefore;
        assertEq(received, 85_000e8, "15% EES penalty deducted from close payout");
    }

    function test_HYBRID13_eesPenalty_liquidation_survives() public {
        hexToken.setEesPenaltyBps(500);

        uint256 vaultId = _openAndMint(alice, 200_000e8, 4500, 0);
        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(alice);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc);

        _drainStabilityPool(sys);
        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(attacker, maxDtsc);
        vm.startPrank(attacker);
        sys.dtsc.approve(address(sys.vaultManager), maxDtsc);
        (uint256 burned, uint256 hearts) = sys.vaultManager.liquidate(vaultId, maxDtsc);
        vm.stopPrank();

        assertGt(burned, 0);
        assertGt(hearts, 0);
        assertEq(hexToken.balanceOf(attacker), hearts);
    }

    function test_HYBRID14_repayThenNoGraceOnSecondMint() public {
        uint256 vaultId = _openAndMint(alice, 200_000e8, 4500, 50e18);
        uint256 eligible1 = sys.vaultManager.redemptionEligibleAt(vaultId);

        vm.startPrank(alice);
        sys.dtsc.approve(address(sys.vaultManager), 50e18);
        sys.vaultManager.repayDtsc(vaultId, 50e18);
        sys.vaultManager.mintDtsc(vaultId, 40e18);
        vm.stopPrank();

        assertEq(sys.vaultManager.redemptionEligibleAt(vaultId), eligible1, "grace not reset on second mint");
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _openVaultOnly(address who, uint256 hearts, uint256 days_) internal returns (uint256 vaultId) {
        vm.startPrank(who);
        hexToken.approve(address(sys.vaultManager), hearts);
        vaultId = sys.vaultManager.openVaultWithNewStake(hearts, days_);
        vm.stopPrank();
    }

    function _openAndMint(address who, uint256 hearts, uint256 days_, uint256 mintAmt)
        internal
        returns (uint256 vaultId)
    {
        vaultId = _openVaultOnly(who, hearts, days_);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        if (mintAmt == 0) return vaultId;
        vm.prank(who);
        sys.vaultManager.mintDtsc(vaultId, mintAmt);
    }

    function _fundRedeemer(address who, uint256 amt) internal {
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(who, amt);
        vm.prank(who);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);
    }

    function _drainStabilityPool(DTSCSystem memory s) internal {
        uint256 total = s.stabilityPool.totalDeposits();
        if (total == 0) return;
        vm.prank(SP_LP);
        s.stabilityPool.withdraw(total);
    }
}