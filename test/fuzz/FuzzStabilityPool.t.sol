// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockHEX} from "../mocks/MockHEX.sol";
import {MockPair} from "../mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../../src/deploy/DTSCDeployer.sol";

contract FuzzStabilityPoolTest is Test {
    DTSCSystem sys;
    address user = address(0xA11CE);

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

    function testFuzz_offsetProportional(uint96 depositAmt, uint96 offsetAmt) public {
        depositAmt = uint96(bound(depositAmt, 1e18, 100_000e18));
        offsetAmt = uint96(bound(offsetAmt, 1, depositAmt));

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(user, depositAmt);
        vm.prank(user);
        sys.dtsc.approve(address(sys.stabilityPool), type(uint256).max);
        vm.prank(user);
        sys.stabilityPool.deposit(depositAmt);

        uint256 compoundedBefore = sys.stabilityPool.getCompoundedDeposit(user);

        vm.prank(address(sys.vaultManager));
        uint256 actualOffset = sys.stabilityPool.offsetDebt(offsetAmt);

        assertEq(actualOffset, offsetAmt);
        assertLe(sys.stabilityPool.getCompoundedDeposit(user), compoundedBefore);
        assertEq(sys.stabilityPool.totalDeposits(), depositAmt - offsetAmt);
    }
}