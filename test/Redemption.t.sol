// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

contract RedemptionTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    MockPair pair;
    address user = address(0xA11CE);
    address redeemer = address(0xDEED);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(1_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));

        sys.oracle.update();
        pair.bumpCumulative(1e18, 0);
        vm.warp(block.timestamp + 1 days);
        sys.oracle.update();

        seedMinStabilityPool(sys);

        hexToken.mint(user, 100_000e8);
    }

    function test_redeemCustodialVaultReceivesHex() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        (uint256 maxDtsc,) =
            sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(user);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc);

        pair.setReserves(uint112(1_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(redeemer, 1000e18);
        vm.prank(redeemer);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);

        prepareRedemption(sys);

        uint256 hexBefore = hexToken.balanceOf(redeemer);
        vm.prank(redeemer);
        sys.redemptionHandler.redeem(10e18, 10);

        assertLt(sys.vaultManager.getVault(vaultId).debtDtsc, maxDtsc);
        assertGt(hexToken.balanceOf(redeemer), hexBefore);
    }
}