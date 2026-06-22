// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DTSCConstants as C} from "./DTSCConstants.sol";
import {DTSCMath} from "./DTSCMath.sol";

/// @title RedemptionPolicy — Hybrid borrower protection (CR cap + grace + dynamic fee)
/// @dev Golden middle: peg defense when CR is tight; expensive/skip griefing on healthy vaults
library RedemptionPolicy {
    /// @notice True when vault may appear in redemption scan
    function isEligible(
        uint256 crBps,
        uint256 minCcrBps,
        uint64 redemptionEligibleAt,
        uint256 timestamp
    ) internal pure returns (bool) {
        if (timestamp < redemptionEligibleAt) return false;
        if (crBps > C.REDEMPTION_MAX_CR_BPS) return false;
        // Underwater vaults always eligible (peg defense) — ignore high-CR fee tier cap
        if (crBps < minCcrBps) return true;
        return crBps <= C.REDEMPTION_MAX_CR_BPS;
    }

    /// @notice Dynamic fee: cheap near minimum CCR, expensive approaching REDEMPTION_MAX_CR_BPS
    /// @dev Underwater (cr < minCcr): floor fee — keep redemption attractive for peg
    function feeBpsForCr(uint256 crBps, uint256 minCcrBps) internal pure returns (uint256 feeBps) {
        if (crBps < minCcrBps) return C.REDEMPTION_FEE_LOW_BPS;

        uint256 feeStartCr = minCcrBps + C.REDEMPTION_CR_FEE_BUFFER_BPS;
        if (crBps <= feeStartCr) return C.REDEMPTION_FEE_LOW_BPS;
        if (crBps >= C.REDEMPTION_MAX_CR_BPS) return C.REDEMPTION_FEE_HIGH_BPS;

        uint256 span = C.REDEMPTION_MAX_CR_BPS - feeStartCr;
        uint256 excess = crBps - feeStartCr;
        uint256 feeRange = C.REDEMPTION_FEE_HIGH_BPS - C.REDEMPTION_FEE_LOW_BPS;
        feeBps = C.REDEMPTION_FEE_LOW_BPS + DTSCMath.mulDiv(excess, feeRange, span);
    }

    /// @notice Gross DTSC consumed (net debt reduction + fee) from a net apply amount
    function grossFromNet(uint256 netApplied, uint256 feeBps) internal pure returns (uint256 gross) {
        if (netApplied == 0) return 0;
        gross = DTSCMath.mulDiv(netApplied, C.BPS, C.BPS - feeBps);
    }
}