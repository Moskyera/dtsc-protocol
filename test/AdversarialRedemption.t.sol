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
import {DTSCMath} from "../src/libraries/DTSCMath.sol";

/// @title Adversarial redemption tests — bad actors must not profit from griefing
contract AdversarialRedemptionTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    MockPair pair;
    address victim = address(0x71C71);
    address griefer = address(0xBAD);
    address pegDefender = address(0xDEEF);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(10_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));

        primeOracle(sys, pair);
        seedMinStabilityPool(sys);
        hexToken.mint(victim, 1_000_000e8);
        hexToken.mint(griefer, 600_000e8);
    }

    // ─── Griefing economics ─────────────────────────────────────────────────────

    function test_ADV01_grieferLosesMoney_at190Cr_onParPeg() public {
        uint256 vaultId = _openVault(victim, 300_000e8);
        mintToTargetCr(sys, victim, vaultId, 0, 19_000);
        prepareRedemption(sys);

        uint256 feeBps = sys.vaultManager.redemptionFeeBpsForVault(vaultId);
        assertGe(feeBps, 350, "fee >= 3.5% at 190% CR");

        uint256 hexPrice = sys.oracle.getPrice();
        uint256 dtscIn = 50e18;

        _fundRedeemer(griefer, dtscIn);
        uint256 hexBefore = hexToken.balanceOf(griefer);
        uint256 dtscBefore = sys.dtsc.balanceOf(griefer);

        vm.prank(griefer);
        sys.redemptionHandler.redeem(dtscIn, 1);

        uint256 hexReceived = hexToken.balanceOf(griefer) - hexBefore;
        uint256 dtscSpent = dtscBefore - sys.dtsc.balanceOf(griefer);

        uint256 hexValueUsd = DTSCMath.mulDiv(hexReceived, hexPrice, C.HEARTS_PER_HEX);
        assertLt(hexValueUsd, dtscSpent, "griefer net-negative at par peg");
    }

    function test_ADV02_grieferCannotTarget_immuneVault() public {
        uint256 vVictim = _openVault(victim, 300_000e8);
        mintToTargetCr(sys, victim, vVictim, 0, 25_000);

        uint256 vDecoy = _openVault(griefer, 200_000e8);
        uint256 grieferStakeIdx = sys.vaultManager.getVault(vDecoy).stakeIndex;
        mintToTargetCr(sys, griefer, vDecoy, grieferStakeIdx, 17_000);
        prepareRedemption(sys);

        assertFalse(sys.vaultManager.isVaultRedeemable(vVictim), "high CR immune");
        assertTrue(sys.vaultManager.isVaultRedeemable(vDecoy));

        uint256 debtDecoyBefore = sys.vaultManager.getVault(vDecoy).debtDtsc;
        uint256 debtVictimBefore = sys.vaultManager.getVault(vVictim).debtDtsc;

        _fundRedeemer(griefer, 30e18);
        vm.prank(griefer);
        sys.redemptionHandler.redeem(20e18, 3);

        assertLt(sys.vaultManager.getVault(vDecoy).debtDtsc, debtDecoyBefore);
        assertEq(sys.vaultManager.getVault(vVictim).debtDtsc, debtVictimBefore, "immune vault untouched");
    }

    function test_ADV03_graceBlocks_earlyGriefing() public {
        uint256 vaultId = _openVault(victim, 200_000e8);
        mintToTargetCr(sys, victim, vaultId, 0, 17_000);

        assertFalse(sys.vaultManager.isVaultRedeemable(vaultId));
        _fundRedeemer(griefer, 50e18);

        vm.prank(griefer);
        vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
        sys.redemptionHandler.redeem(10e18, 3);
    }

    function test_ADV04_microRedemptionSpam_costsGrieferFees() public {
        uint256 vaultId = _openVault(victim, 250_000e8);
        mintToTargetCr(sys, victim, vaultId, 0, 18_000);
        prepareRedemption(sys);

        _fundRedeemer(griefer, 100e18);
        uint256 totalFees;
        uint256 totalHearts;

        for (uint256 i = 0; i < 10; i++) {
            (uint256 feeBefore,) = _previewFee(vaultId, 2e18);
            totalFees += feeBefore;

            vm.prank(griefer);
            sys.redemptionHandler.redeem(2e18, 1);
            totalHearts = hexToken.balanceOf(griefer);
            if (sys.vaultManager.getVault(vaultId).debtDtsc == 0) break;
        }

        assertGt(totalFees, 0);
        assertGt(totalHearts, 0);
        assertGt(sys.redemptionHandler.totalFeesBurned(), 0, "fees burned not captured by griefer");
    }

    function test_ADV05_pegDefenderCanRestore_underwater() public {
        uint256 vaultId = _openVault(victim, 200_000e8);
        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(victim);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);
        prepareRedemption(sys);

        assertLt(sys.vaultManager.getVaultCollateralRatio(vaultId), C.CCR_LONG_BPS);
        uint256 feeBps = sys.vaultManager.redemptionFeeBpsForVault(vaultId);
        assertLe(feeBps, C.REDEMPTION_FEE_LOW_BPS, "underwater peg fee at floor");

        _fundRedeemer(pegDefender, 80e18);
        uint256 debtBefore = sys.vaultManager.getVault(vaultId).debtDtsc;
        vm.prank(pegDefender);
        sys.redemptionHandler.redeem(40e18, 2);
        assertLt(sys.vaultManager.getVault(vaultId).debtDtsc, debtBefore);
    }

    function test_ADV06_pumpMintCrash_cannotGriefAboveCap() public {
        uint256 vaultId = _openVault(victim, 200_000e8);

        pair.setReserves(uint112(10_000_000e8), uint112(20_000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        (uint256 maxPump,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(victim);
        sys.vaultManager.mintDtsc(vaultId, maxPump / 10);

        pair.setReserves(uint112(10_000_000e8), uint112(10_000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);
        prepareRedemption(sys);

        uint256 cr = sys.vaultManager.getVaultCollateralRatio(vaultId);
        if (cr > C.REDEMPTION_MAX_CR_BPS) {
            _fundRedeemer(griefer, 50e18);
            vm.prank(griefer);
            vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
            sys.redemptionHandler.redeem(10e18, 3);
        }
    }

    function test_ADV07_lowestCrTargeting_hitsWeakestVaultOnly() public {
        uint256 vLow = _openVault(victim, 250_000e8);
        uint256 vHigh = _openVault(victim, 250_000e8);
        uint256 debtLow = mintToTargetCr(sys, victim, vLow, 0, 17_000);
        uint256 debtHigh = mintToTargetCr(sys, victim, vHigh, 1, 19_500);
        prepareRedemption(sys);

        assertLt(
            sys.vaultManager.getVaultCollateralRatio(vLow),
            sys.vaultManager.getVaultCollateralRatio(vHigh)
        );

        _fundRedeemer(griefer, 40e18);
        vm.prank(griefer);
        sys.redemptionHandler.redeem(15e18, 1);

        assertLt(sys.vaultManager.getVault(vLow).debtDtsc, debtLow);
        assertEq(sys.vaultManager.getVault(vHigh).debtDtsc, debtHigh, "comfortable vault skipped");
    }

    function test_ADV08_borrowerAt190Cr_feeAbove3pct() public {
        uint256 vaultId = _openVault(victim, 300_000e8);
        mintToTargetCr(sys, victim, vaultId, 0, 19_000);
        prepareRedemption(sys);

        uint256 feeBps = sys.vaultManager.redemptionFeeBpsForVault(vaultId);
        assertGe(feeBps, 300);
        assertLt(sys.vaultManager.getVaultCollateralRatio(vaultId), C.REDEMPTION_MAX_CR_BPS);
    }

    function test_ADV09_redeemAtCapCr_maxFee() public {
        uint256 vaultId = _openVault(victim, 300_000e8);
        mintToTargetCr(sys, victim, vaultId, 0, C.REDEMPTION_MAX_CR_BPS);
        prepareRedemption(sys);

        assertEq(sys.vaultManager.redemptionFeeBpsForVault(vaultId), C.REDEMPTION_FEE_HIGH_BPS);
    }

    function test_ADV10_eesPenalty_increasesGrieferCost() public {
        hexToken.setEesPenaltyBps(1000);

        uint256 vaultId = _openVault(victim, 200_000e8);
        mintToTargetCr(sys, victim, vaultId, 0, 17_500);
        prepareRedemption(sys);

        uint256 hexPrice = sys.oracle.getPrice();
        _fundRedeemer(griefer, 40e18);

        uint256 hexBefore = hexToken.balanceOf(griefer);
        uint256 dtscBefore = sys.dtsc.balanceOf(griefer);
        vm.prank(griefer);
        sys.redemptionHandler.redeem(20e18, 1);

        uint256 hexReceived = hexToken.balanceOf(griefer) - hexBefore;
        uint256 dtscSpent = dtscBefore - sys.dtsc.balanceOf(griefer);
        uint256 hexValueUsd = DTSCMath.mulDiv(hexReceived, hexPrice, C.HEARTS_PER_HEX);

        assertLt(hexValueUsd, dtscSpent, "EES penalty worsens griefer economics");
    }

    // ─── Historical attack patterns ───────────────────────────────────────────

    function test_ADV11_liquityStyle_redemptionOrdering_hitsLowestFirst() public {
        uint256 v1 = _openVault(victim, 200_000e8);
        uint256 v2 = _openVault(victim, 200_000e8);
        uint256 debt1 = mintToTargetCr(sys, victim, v1, 0, 17_000);
        uint256 debt2 = mintToTargetCr(sys, victim, v2, 1, 18_500);
        prepareRedemption(sys);

        _fundRedeemer(griefer, 60e18);
        vm.prank(griefer);
        sys.redemptionHandler.redeem(30e18, 2);

        assertLt(sys.vaultManager.getVault(v1).debtDtsc, debt1);
        assertEq(sys.vaultManager.getVault(v2).debtDtsc, debt2, "higher-CR vault untouched");
    }

    function test_ADV12_frontRunGrace_expiry_noInstantHit() public {
        uint256 vaultId = _openVault(victim, 200_000e8);
        mintToTargetCr(sys, victim, vaultId, 0, 18_000);

        uint64 eligibleAt = sys.vaultManager.redemptionEligibleAt(vaultId);
        vm.warp(eligibleAt - 1);
        sys.oracle.update();

        assertFalse(sys.vaultManager.isVaultRedeemable(vaultId));
        _fundRedeemer(griefer, 50e18);
        vm.prank(griefer);
        vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
        sys.redemptionHandler.redeem(10e18, 1);
    }

    function test_ADV13_fuzz_feeRisesWithCr(uint256 crBps) public pure {
        crBps = bound(crBps, C.CCR_LONG_BPS + 250, C.REDEMPTION_MAX_CR_BPS);
        uint256 feeLo = RedemptionPolicy.feeBpsForCr(crBps - 100, C.CCR_LONG_BPS);
        uint256 feeHi = RedemptionPolicy.feeBpsForCr(crBps, C.CCR_LONG_BPS);
        assertGe(feeHi, feeLo);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _openVault(address who, uint256 hearts) internal returns (uint256 vaultId) {
        vm.startPrank(who);
        hexToken.approve(address(sys.vaultManager), hearts);
        vaultId = sys.vaultManager.openVaultWithNewStake(hearts, 4500);
        vm.stopPrank();
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
    }

    function _fundRedeemer(address who, uint256 amt) internal {
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(who, amt);
        vm.prank(who);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);
    }

    function _previewFee(uint256 vaultId, uint256 gross)
        internal
        view
        returns (uint256 fee, uint256 net)
    {
        uint256 feeBps = sys.vaultManager.redemptionFeeBpsForVault(vaultId);
        net = DTSCMath.mulDiv(gross, C.BPS - feeBps, C.BPS);
        fee = gross - net;
    }

}