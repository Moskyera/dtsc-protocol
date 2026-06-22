// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "../TestSetup.sol";
import {MockHEX} from "../mocks/MockHEX.sol";
import {MockPair} from "../mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../../src/deploy/DTSCDeployer.sol";
import {Handler} from "./Handler.sol";

contract InvariantDTSC is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    Handler handler;

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        MockPair pair = new MockPair(address(hexToken), quote, uint112(1_000_000e8), uint112(10_000e18));
        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));
        sys.oracle.update();
        pair.bumpCumulative(1e18, 0);
        vm.warp(block.timestamp + 1 days);
        sys.oracle.update();

        seedMinStabilityPool(sys);

        handler = new Handler(sys, hexToken);
        targetContract(address(handler));
    }

    function invariant_spDepositsMatchBalance() public view {
        uint256 poolBal = sys.dtsc.balanceOf(address(sys.stabilityPool));
        assertGe(poolBal, sys.stabilityPool.totalDeposits(), "SP balance covers recorded deposits");
    }

    function invariant_totalDebtNonNegative() public view {
        assertGe(sys.vaultManager.totalDebtDtsc(), 0);
    }

    function invariant_recoveryConsistent() public view {
        uint256 col = sys.vaultManager.totalCollateralValueUsd();
        uint256 debt = sys.vaultManager.totalDebtDtsc();
        if (debt == 0) return;
        uint256 systemCr = (col * 10_000) / debt;
        bool recovery = sys.recovery.isRecoveryMode();
        if (systemCr < 15_000) {
            assertTrue(recovery, "recovery should be active below 150% CR");
        }
    }
}