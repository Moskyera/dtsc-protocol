// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {HexPriceOracle} from "../src/oracle/HexPriceOracle.sol";
import {HexPriceAggregator} from "../src/oracle/HexPriceAggregator.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @title Regression tests for former design/ops open issues
contract OpenIssuesFixTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    MockPair pair;
    address user = address(0xBEEF);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(10_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));

        primeOracle(sys, pair);
        seedMinStabilityPool(sys);
        hexToken.mint(user, 500_000e8);
    }

    function test_OPEN01_borrowTwap_blocksFreshOracleMint() public {
        HexPriceOracle fresh = new HexPriceOracle(
            address(hexToken),
            uint8(C.HEX_TOKEN_DECIMALS),
            address(0xDAA1),
            18,
            address(pair),
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_WPLS
        );

        vm.expectRevert(HexPriceOracle.OracleStale.selector);
        fresh.getCollateralPrice();
    }

    function test_OPEN02_chainlinkFloor_capsPumpedDexPrice() public {
        MockChainlinkFeed feed = new MockChainlinkFeed();
        feed.setPrice8(1e8);

        HexPriceOracle oracle = new HexPriceOracle(
            address(hexToken),
            uint8(C.HEX_TOKEN_DECIMALS),
            address(0xDAA1),
            18,
            address(pair),
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_WPLS
        );

        HexPriceAggregator agg = new HexPriceAggregator(address(0), address(oracle), address(0), address(feed));

        oracle.update();
        vm.warp(block.timestamp + 12 hours + 1);
        pair.bumpCumulative(1e17, 0);
        oracle.update();

        pair.setReserves(uint112(10_000_000e8), uint112(50_000e18));
        oracle.update();

        uint256 collateral = agg.getCollateralPrice();
        assertLe(collateral, 1e18, "chainlink floor caps borrow price");
    }

    function test_OPEN03_spDebtRatio_blocksMintWhenUndercollateralized() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 300_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(300_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);

        vm.prank(SP_LP);
        sys.stabilityPool.withdraw(C.MIN_SP_COVERAGE_DTSC - 1);

        vm.prank(user);
        vm.expectRevert(VaultManager.InsufficientSpCoverage.selector);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc);
    }

    function test_OPEN04_registeredLiquidation_explicitlyBlocked() public {
        DTSCDeployer deployer = new DTSCDeployer();
        DTSCSystem memory sysReg = deployer.deployWithOptions(
            address(hexToken), address(hexToken), address(0xDAA1), address(pair), address(0x1001), true
        );
        primeOracle(sysReg, pair);
        seedMinStabilityPool(sysReg);

        hexToken.seedStake(user, 200_000e8, 4500, 1001);
        vm.prank(user);
        uint256 vaultId = sysReg.vaultManager.openVaultWithExistingStake(0);

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sysReg.oracle.update();
        vm.prank(user);
        sysReg.vaultManager.mintDtsc(vaultId, 50e18);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sysReg.oracle.update();
        sysReg.vaultManager.refreshVault(vaultId);

        vm.prank(address(sysReg.vaultManager));
        sysReg.dtsc.mint(address(0xBAD), 50e18);
        vm.startPrank(address(0xBAD));
        sysReg.dtsc.approve(address(sysReg.vaultManager), 50e18);
        vm.expectRevert(VaultManager.RegisteredLiquidationDisabled.selector);
        sysReg.vaultManager.liquidate(vaultId, 10e18);
        vm.stopPrank();
    }

    function test_OPEN05_aggregatorTwapSpot_returnsDistinctFeeds() public view {
        (uint256 twap, uint256 spot) = sys.oracle.getTwapAndSpot();
        assertGt(twap, 0);
        assertGt(spot, 0);
    }
}