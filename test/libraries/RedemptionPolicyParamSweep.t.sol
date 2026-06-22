// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RedemptionPolicy} from "../../src/libraries/RedemptionPolicy.sol";
import {DTSCConstants as C} from "../../src/libraries/DTSCConstants.sol";
import {DTSCMath} from "../../src/libraries/DTSCMath.sol";

/// @dev Parameterized redemption policy for tuning sweeps (mirrors production logic)
library RedemptionPolicyHarness {
    struct Params {
        uint256 feeLowBps;
        uint256 feeHighBps;
        uint256 maxCrBps;
        uint256 crFeeBufferBps;
        uint256 graceDays;
    }

    function feeBpsForCr(uint256 crBps, uint256 minCcrBps, Params memory p)
        internal
        pure
        returns (uint256 feeBps)
    {
        if (crBps < minCcrBps) return p.feeLowBps;

        uint256 feeStartCr = minCcrBps + p.crFeeBufferBps;
        if (crBps <= feeStartCr) return p.feeLowBps;
        if (crBps >= p.maxCrBps) return p.feeHighBps;

        uint256 span = p.maxCrBps - feeStartCr;
        uint256 excess = crBps - feeStartCr;
        uint256 feeRange = p.feeHighBps - p.feeLowBps;
        feeBps = p.feeLowBps + DTSCMath.mulDiv(excess, feeRange, span);
    }

    function isEligible(uint256 crBps, uint256 minCcrBps, uint64 eligibleAt, uint256 ts, Params memory p)
        internal
        pure
        returns (bool)
    {
        if (ts < eligibleAt) return false;
        if (crBps > p.maxCrBps) return false;
        if (crBps < minCcrBps) return true;
        return crBps <= p.maxCrBps;
    }

    /// @dev Higher = better borrower protection in comfortable CR band
    function griefResistanceScore(Params memory p) internal pure returns (uint256 score) {
        uint256 minCcr = C.CCR_LONG_BPS;
        uint256[] memory crs = new uint256[](5);
        crs[0] = 17_500;
        crs[1] = 18_000;
        crs[2] = 18_500;
        crs[3] = 19_000;
        crs[4] = 19_500;

        for (uint256 i = 0; i < crs.length; i++) {
            if (!isEligible(crs[i], minCcr, 0, 1, p)) continue;
            score += feeBpsForCr(crs[i], minCcr, p);
        }
    }

    /// @dev Lower = easier peg restore when underwater
    function pegDefenseScore(Params memory p) internal pure returns (uint256) {
        return feeBpsForCr(14_000, C.CCR_LONG_BPS, p);
    }

    /// @dev Comfortable CR band width where redemption is possible (bps above minCcr)
    function griefWindowBps(Params memory p) internal pure returns (uint256) {
        return p.maxCrBps > C.CCR_LONG_BPS ? p.maxCrBps - C.CCR_LONG_BPS : 0;
    }
}

/// @title Parameter sweep — find anti-grief tuning that still defends peg
contract RedemptionPolicyParamSweepTest is Test {
    RedemptionPolicyHarness.Params[] internal configs;

    function setUp() public {
        // A: legacy baseline (pre-tightening)
        configs.push(RedemptionPolicyHarness.Params(50, 450, 21_000, 500, 14));
        // B: balanced anti-grief
        configs.push(RedemptionPolicyHarness.Params(100, 500, 20_000, 300, 21));
        // C: aggressive anti-grief
        configs.push(RedemptionPolicyHarness.Params(150, 500, 19_500, 200, 21));
        // D: max borrower shield (peg still <=1.5% underwater)
        configs.push(RedemptionPolicyHarness.Params(100, 500, 19_000, 200, 28));
        // E: production candidate — tight cap + steep ramp
        configs.push(RedemptionPolicyHarness.Params(100, 500, 20_000, 250, 21));
    }

    function test_SWEEP01_productionMatchesCandidateC() public pure {
        assertEq(C.REDEMPTION_FEE_LOW_BPS, 150);
        assertEq(C.REDEMPTION_FEE_HIGH_BPS, 500);
        assertEq(C.REDEMPTION_MAX_CR_BPS, 19_500);
        assertEq(C.REDEMPTION_CR_FEE_BUFFER_BPS, 200);
        assertEq(C.REDEMPTION_GRACE_PERIOD, 21 days);
    }

    function test_SWEEP02_feeAt190Cr_beatsLegacy() public view {
        RedemptionPolicyHarness.Params memory legacy = configs[0];
        RedemptionPolicyHarness.Params memory prod = configs[2];

        uint256 legacyFee = RedemptionPolicyHarness.feeBpsForCr(19_000, C.CCR_LONG_BPS, legacy);
        uint256 prodFee = RedemptionPolicyHarness.feeBpsForCr(19_000, C.CCR_LONG_BPS, prod);

        assertGt(prodFee, legacyFee, "190% CR fee must rise vs legacy");
        assertGe(prodFee, 350, "190% CR fee >= 3.5%");
    }

    function test_SWEEP03_underwater_staysCheapForPeg() public view {
        RedemptionPolicyHarness.Params memory prod = configs[2];
        uint256 pegFee = RedemptionPolicyHarness.feeBpsForCr(14_000, C.CCR_LONG_BPS, prod);
        assertLe(pegFee, 150, "underwater peg fee <= 1.5%");
    }

    function test_SWEEP04_comfortableCr_immuneAtCap() public view {
        RedemptionPolicyHarness.Params memory prod = configs[2];
        assertFalse(RedemptionPolicyHarness.isEligible(20_500, C.CCR_LONG_BPS, 0, 1, prod));
        assertFalse(RedemptionPolicyHarness.isEligible(21_000, C.CCR_LONG_BPS, 0, 1, prod));
    }

    function test_SWEEP05_candidateE_bestPegViableGriefResistance() public view {
        uint256 bestScore;
        uint256 bestIdx = type(uint256).max;

        for (uint256 i = 0; i < configs.length; i++) {
            RedemptionPolicyHarness.Params memory p = configs[i];
            if (RedemptionPolicyHarness.pegDefenseScore(p) > 150) continue;
            uint256 score = RedemptionPolicyHarness.griefResistanceScore(p);
            if (score > bestScore) {
                bestScore = score;
                bestIdx = i;
            }
        }

        assertEq(bestIdx, 2, "candidate C wins among peg-viable configs");
    }

    function test_SWEEP06_candidateE_pegStillViable() public view {
        RedemptionPolicyHarness.Params memory prod = configs[2];
        uint256 pegFee = RedemptionPolicyHarness.pegDefenseScore(prod);
        assertLe(pegFee, 150);
        // 2% DTSC discount still profitable for peg arb: discount > fee
        assertLt(pegFee, 200);
    }

    function test_SWEEP07_feeMonotonic_inComfortBand() public view {
        RedemptionPolicyHarness.Params memory prod = configs[2];
        uint256 prev;
        for (uint256 cr = 15_300; cr <= 20_000; cr += 100) {
            uint256 fee = RedemptionPolicyHarness.feeBpsForCr(cr, C.CCR_LONG_BPS, prod);
            if (cr > 15_300) assertGe(fee, prev, "fee monotonic");
            prev = fee;
        }
    }

    function test_SWEEP08_productionPolicy_matchesHarness() public pure {
        RedemptionPolicyHarness.Params memory prod = RedemptionPolicyHarness.Params({
            feeLowBps: C.REDEMPTION_FEE_LOW_BPS,
            feeHighBps: C.REDEMPTION_FEE_HIGH_BPS,
            maxCrBps: C.REDEMPTION_MAX_CR_BPS,
            crFeeBufferBps: C.REDEMPTION_CR_FEE_BUFFER_BPS,
            graceDays: C.REDEMPTION_GRACE_PERIOD / 1 days
        });

        uint256[] memory crs = new uint256[](4);
        crs[0] = 14_000;
        crs[1] = 17_500;
        crs[2] = 19_000;
        crs[3] = 20_000;

        for (uint256 i = 0; i < crs.length; i++) {
            assertEq(
                RedemptionPolicy.feeBpsForCr(crs[i], C.CCR_LONG_BPS),
                RedemptionPolicyHarness.feeBpsForCr(crs[i], C.CCR_LONG_BPS, prod),
                "harness matches production"
            );
        }
    }

    function test_SWEEP09_logAllConfigs() public {
        string[5] memory names = ["A-legacy", "B-balanced", "C-aggressive", "D-maxShield", "E-production"];

        for (uint256 i = 0; i < configs.length; i++) {
            RedemptionPolicyHarness.Params memory p = configs[i];
            emit log_string(names[i]);
            emit log_named_uint("  griefScore", RedemptionPolicyHarness.griefResistanceScore(p));
            emit log_named_uint("  pegFee_bps", RedemptionPolicyHarness.pegDefenseScore(p));
            emit log_named_uint("  window_bps", RedemptionPolicyHarness.griefWindowBps(p));
            emit log_named_uint("  fee@175%", RedemptionPolicyHarness.feeBpsForCr(17_500, C.CCR_LONG_BPS, p));
            emit log_named_uint("  fee@190%", RedemptionPolicyHarness.feeBpsForCr(19_000, C.CCR_LONG_BPS, p));
            emit log_named_uint("  grace_days", p.graceDays);
        }
    }
}