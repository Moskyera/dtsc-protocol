// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {IHexPriceOracle} from "../src/oracle/IHexPriceOracle.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";
import {DTSCMath} from "../src/libraries/DTSCMath.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {HexPriceOracle} from "../src/oracle/HexPriceOracle.sol";

/// @dev Shared test helpers — seeds minimum Stability Pool coverage for mintDtsc
abstract contract TestSetup is Test {
    address internal constant SP_LP = address(0x5FEED);

    function primeOracle(DTSCSystem memory sys, MockPair pair) internal {
        IHexPriceOracle(sys.oracle).update();
        pair.bumpCumulative(1e18, 0);
        vm.warp(block.timestamp + 12 hours + 1);
        pair.bumpCumulative(1e17, 0);
        IHexPriceOracle(sys.oracle).update();
    }

    function primeOraclePair(HexPriceOracle oracle, MockPair pair) internal {
        oracle.update();
        pair.bumpCumulative(1e18, 0);
        vm.warp(block.timestamp + 12 hours + 1);
        pair.bumpCumulative(1e17, 0);
        oracle.update();
    }

    function warpPastRedemptionGrace() internal {
        vm.warp(block.timestamp + C.REDEMPTION_GRACE_PERIOD + 1);
    }

    function prepareRedemption(DTSCSystem memory sys) internal {
        warpPastRedemptionGrace();
        sys.oracle.update();
    }

    /// @dev Mint debt to approach a target CR (bps). Caps at maxBorrowable.
    function mintToTargetCr(
        DTSCSystem memory sys,
        address owner,
        uint256 vaultId,
        uint256 stakeIndex,
        uint256 targetCrBps
    ) internal returns (uint256 minted) {
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);
        VaultManager.Vault memory v = sys.vaultManager.getVault(vaultId);
        require(v.effectiveValueUsd > 0, "zero EV");
        minted = DTSCMath.mulDiv(v.effectiveValueUsd, C.BPS, targetCrBps);
        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), stakeIndex, false);
        if (minted > maxDtsc) minted = maxDtsc;
        require(minted > 0, "zero mint");
        vm.prank(owner);
        sys.vaultManager.mintDtsc(vaultId, minted);
    }

    function seedMinStabilityPool(DTSCSystem memory sys) internal {
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(SP_LP, C.MIN_SP_COVERAGE_DTSC);
        vm.startPrank(SP_LP);
        sys.dtsc.approve(address(sys.stabilityPool), type(uint256).max);
        sys.stabilityPool.deposit(C.MIN_SP_COVERAGE_DTSC);
        vm.stopPrank();
    }
}