// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "../TestSetup.sol";
import {MockHEX} from "../mocks/MockHEX.sol";
import {MockPair} from "../mocks/MockPair.sol";
import {HexPriceOracle} from "../../src/oracle/HexPriceOracle.sol";
import {TShareValuation} from "../../src/valuation/TShareValuation.sol";
import {DTSCConstants as C} from "../../src/libraries/DTSCConstants.sol";

contract FuzzValuationTest is TestSetup {
    MockHEX hexToken;
    HexPriceOracle oracle;
    TShareValuation valuation;
    address user = address(0xBEEF);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        MockPair pair = new MockPair(address(hexToken), quote, uint112(1_000_000e8), uint112(10_000e18));
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

    function testFuzz_effectiveValueBounded(uint72 hearts, uint16 stakedDays, uint16 daysRemaining) public {
        stakedDays = uint16(bound(stakedDays, C.MIN_DAYS_REMAINING, C.MAX_STAKE_DAYS));
        daysRemaining = uint16(bound(daysRemaining, C.MIN_DAYS_REMAINING, stakedDays));

        uint16 lockedDay = uint16(1000 + stakedDays - daysRemaining);
        hexToken.seedStake(user, hearts, stakedDays, lockedDay);

        TShareValuation.Valuation memory v = valuation.calculateEffectiveValue(user, 0);
        uint256 cap = (v.principalValueUsd * C.EV_CAP_MULTIPLIER_BPS) / C.BPS;

        assertLe(v.effectiveValueUsd, cap, "EV cap violated");
        assertGe(v.minCollateralRatioBps, C.CCR_LONG_BPS, "long tier CCR");
    }

    function testFuzz_maxBorrowNeverExceedsCCR(uint72 hearts) public {
        hearts = uint72(bound(hearts, 1e8, 10_000_000e8));
        hexToken.seedStake(user, hearts, 4500, 1001);

        (uint256 maxDtsc, TShareValuation.Valuation memory v) =
            valuation.maxBorrowable(user, 0, false);

        if (v.effectiveValueUsd > 0) {
            assertLe(maxDtsc, (v.effectiveValueUsd * C.BPS) / v.minCollateralRatioBps);
        }
    }
}