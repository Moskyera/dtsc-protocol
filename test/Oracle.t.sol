// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {HexPriceOracle} from "../src/oracle/HexPriceOracle.sol";
import {HexPriceAggregator} from "../src/oracle/HexPriceAggregator.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

contract OracleTest is Test {
    MockHEX hexToken;
    MockPair hexUsdcPair;
    MockPair hexWplsPair;
    MockPair wplsUsdcPair;
    address usdc = address(0xDAA1);
    address wpls = address(0xDAA2);

    HexPriceOracle hexUsdcOracle;
    HexPriceOracle hexWplsOracle;
    HexPriceOracle wplsUsdcOracle;
    HexPriceAggregator aggregator;

    function setUp() public {
        hexToken = new MockHEX();

        // 1M HEX + 10,000 USDC => $0.01/HEX
        hexUsdcPair = new MockPair(address(hexToken), usdc, uint112(1_000_000e8), uint112(10_000e6));

        // 1M HEX + 1M WPLS => $0.02/HEX via cross (1 WPLS/HEX * $0.02/WPLS)
        hexWplsPair = new MockPair(address(hexToken), wpls, uint112(1_000_000e8), uint112(1_000_000e18));

        // 1 WPLS = 0.0104 USDC => cross ~$0.0104/HEX (within 5% of direct $0.01)
        wplsUsdcPair = new MockPair(wpls, usdc, uint112(1_000_000e18), uint112(10_400e6));

        hexUsdcOracle = new HexPriceOracle(
            address(hexToken),
            uint8(C.HEX_TOKEN_DECIMALS),
            usdc,
            uint8(C.USDC_DECIMALS),
            address(hexUsdcPair),
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_USDC
        );

        hexWplsOracle = new HexPriceOracle(
            address(hexToken),
            uint8(C.HEX_TOKEN_DECIMALS),
            wpls,
            uint8(C.WPLS_DECIMALS),
            address(hexWplsPair),
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_WPLS
        );

        wplsUsdcOracle = new HexPriceOracle(
            wpls,
            uint8(C.WPLS_DECIMALS),
            usdc,
            uint8(C.USDC_DECIMALS),
            address(wplsUsdcPair),
            C.MIN_QUOTE_RESERVE_WPLS,
            C.MIN_QUOTE_RESERVE_USDC
        );

        aggregator = new HexPriceAggregator(
            address(hexUsdcOracle), address(hexWplsOracle), address(wplsUsdcOracle), address(0)
        );

        _primeOracle(hexUsdcOracle, hexUsdcPair);
        _primeOracle(hexWplsOracle, hexWplsPair);
        _primeOracle(wplsUsdcOracle, wplsUsdcPair);
        aggregator.update();
    }

    function _primeOracle(HexPriceOracle oracle, MockPair pair) internal {
        oracle.update();
        pair.bumpCumulative(1e18, 1e18);
        vm.warp(block.timestamp + 12 hours + 1);
        pair.bumpCumulative(1e17, 1e17);
        oracle.update();
    }

    function test_hexUsdcOracle_decimalCorrectness() public view {
        uint256 price = hexUsdcOracle.getPrice();
        assertEq(price, 0.01e18, "1M HEX / 10k USDC = $0.01");
    }

    function test_collateralPrice_usesTwapWhenAvailable() public view {
        uint256 collateral = hexUsdcOracle.getCollateralPrice();
        uint256 market = hexUsdcOracle.getPrice();
        assertGt(collateral, 0);
        assertLe(collateral, market + 1);
    }

    function test_aggregator_collateralPrice() public view {
        uint256 collateral = aggregator.getCollateralPrice();
        assertGt(collateral, 0);
    }

    function test_aggregator_usesMinimumSource() public view {
        uint256 price = aggregator.getPrice();
        // Direct USDC ($0.01) < cross (hexWpls * wplsUsd)
        assertEq(price, 0.01e18);
    }

    function test_aggregator_crossRateMath() public view {
        uint256 hexWpls = hexWplsOracle.getPrice();
        uint256 wplsUsd = wplsUsdcOracle.getPrice();
        uint256 cross = hexWpls * wplsUsd / 1e18;
        assertApproxEqRel(cross, 0.0104e18, 0.01e18);
        assertGt(cross, 0.01e18);
    }

    function test_thinUsdcPool_reverts() public {
        hexUsdcPair.setReserves(uint112(1000e8), uint112(10e6));
        hexUsdcOracle.update();
        vm.expectRevert(HexPriceOracle.InsufficientLiquidity.selector);
        hexUsdcOracle.getPrice();
    }

    function test_twapRingBuffer_accumulatesObservations() public {
        MockPair freshPair = new MockPair(address(hexToken), usdc, uint112(1_000_000e8), uint112(10_000e6));
        HexPriceOracle freshOracle = new HexPriceOracle(
            address(hexToken),
            uint8(C.HEX_TOKEN_DECIMALS),
            usdc,
            uint8(C.USDC_DECIMALS),
            address(freshPair),
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_USDC
        );

        freshOracle.update();
        assertEq(freshOracle.observationCount(), 1);

        vm.warp(block.timestamp + 6 hours);
        freshPair.bumpCumulative(1e18, 1e18);
        freshOracle.update();
        assertEq(freshOracle.observationCount(), 2);

        vm.warp(block.timestamp + 6 hours);
        freshPair.bumpCumulative(1e18, 1e18);
        freshOracle.update();
        assertEq(freshOracle.observationCount(), 3);
    }

    function test_aggregator_rejectsDepeggedUsdcPath() public {
        // Cross ~ $0.0104; direct USDC at $0.005 is >5% below cross => reject direct
        hexUsdcPair.setReserves(uint112(1_000_000e8), uint112(5_000e6));
        hexUsdcOracle.update();
        aggregator.update();

        uint256 price = aggregator.getPrice();
        assertApproxEqRel(price, 0.0104e18, 0.01e18, "should fall back to cross-rate");
    }

    function test_aggregator_rejectsPumpedUsdcPath() public {
        // Direct $0.05 vs cross ~$0.0104 => reject inflated thin-pool direct path
        hexUsdcPair.setReserves(uint112(1_000_000e8), uint112(50_000e6));
        hexUsdcOracle.update();
        aggregator.update();

        uint256 price = aggregator.getPrice();
        assertLt(price, 0.05e18, "should ignore pumped USDC pool");
        assertApproxEqRel(price, 0.0104e18, 0.01e18);
    }
}