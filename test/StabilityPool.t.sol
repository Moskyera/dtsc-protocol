// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";

contract StabilityPoolTest is Test {
    DTSCSystem sys;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        MockHEX hexToken = new MockHEX();
        address quote = address(0xDAA1);
        MockPair pair = new MockPair(address(hexToken), quote, uint112(1_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));

        sys.oracle.update();
        pair.bumpCumulative(1e18, 0);
        vm.warp(block.timestamp + 1 days);
        sys.oracle.update();
    }

    function test_depositWithdraw() public {
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(alice, 1000e18);
        vm.prank(alice);
        sys.dtsc.approve(address(sys.stabilityPool), type(uint256).max);

        vm.prank(alice);
        sys.stabilityPool.deposit(500e18);

        vm.prank(alice);
        sys.stabilityPool.withdraw(200e18);

        assertEq(sys.stabilityPool.deposits(alice), 300e18);
    }

    function test_penaltyRewards() public {
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(alice, 1000e18);
        vm.prank(alice);
        sys.dtsc.approve(address(sys.stabilityPool), type(uint256).max);
        vm.prank(alice);
        sys.stabilityPool.deposit(1000e18);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(address(sys.penaltyRouter), 100e18);
        vm.prank(address(sys.vaultManager));
        sys.penaltyRouter.routePenalty(100e18);

        uint256 claimable = sys.stabilityPool.claimableReward(alice);
        assertEq(claimable, 80e18);

        vm.prank(alice);
        uint256 paid = sys.stabilityPool.claimRewards();
        assertEq(paid, 80e18);
        assertEq(sys.stabilityPool.claimableReward(alice), 0);
    }
}