// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {HexPriceOracle} from "../src/oracle/HexPriceOracle.sol";
import {TShareValuation} from "../src/valuation/TShareValuation.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

contract TShareValuationTest is TestSetup {
    MockHEX hexToken;
    MockPair pair;
    HexPriceOracle oracle;
    TShareValuation valuation;

    address user = address(0xBEEF);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(1_000_000e8), uint112(10_000e18));
        oracle = new HexPriceOracle(
            address(hexToken),
            uint8(C.HEX_TOKEN_DECIMALS),
            quote,
            uint8(C.WPLS_DECIMALS),
            address(pair),
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_WPLS
        );
        valuation = new TShareValuation(address(hexToken), address(oracle));

        primeOraclePair(oracle, pair);
    }

    function test_longTierEligible() public {
        uint40 id = hexToken.seedStake(user, 100_000e8, 4500, 1001);
        TShareValuation.Valuation memory v = valuation.calculateEffectiveValue(user, 0);
        assertEq(uint256(v.tier), uint256(TShareValuation.Tier.Long));
        assertGe(v.daysRemaining, C.TIER_LONG_MIN);
        assertGt(v.effectiveValueUsd, 0);
        id;
    }

    function test_rejectsShortStake() public {
        hexToken.seedStake(user, 100_000e8, 1000, 1001);
        vm.expectRevert(TShareValuation.IneligibleStake.selector);
        valuation.calculateEffectiveValue(user, 0);
    }

    function test_maxBorrowRespectsCCR() public {
        hexToken.seedStake(user, 100_000e8, 4500, 1001);
        (uint256 maxDtsc, TShareValuation.Valuation memory v) =
            valuation.maxBorrowable(user, 0, false);
        assertEq(maxDtsc, (v.effectiveValueUsd * C.BPS) / v.minCollateralRatioBps);
    }
}