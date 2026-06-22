// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {DTSC} from "../src/core/DTSC.sol";
import {TShareValuation} from "../src/valuation/TShareValuation.sol";
import {RecoveryModule} from "../src/core/RecoveryModule.sol";
import {PenaltyRouter} from "../src/core/PenaltyRouter.sol";
import {StabilityPool} from "../src/core/StabilityPool.sol";
import {PulseChainAddresses as A} from "../src/config/PulseChainAddresses.sol";

contract PhexGuardTest is Test {
    address internal constant FAKE_HEX = 0x57f7061E2B759feB9788C6944a6534B2aF36bEdA;

    function test_mainnetConstructorRejectsNonPhex() public {
        vm.chainId(A.CHAIN_ID);

        DTSC dtsc = new DTSC();
        address oracle = address(0xBEEF);
        TShareValuation valuation = new TShareValuation(A.PHEX, oracle);
        RecoveryModule recovery = new RecoveryModule();
        StabilityPool pool = new StabilityPool(address(dtsc));
        PenaltyRouter router = new PenaltyRouter(address(dtsc), address(pool), address(0x1001));

        vm.expectRevert(VaultManager.UnsupportedHexToken.selector);
        new VaultManager(
            FAKE_HEX,
            address(dtsc),
            address(valuation),
            address(recovery),
            address(router)
        );
    }

    function test_testnetAllowsMockHex() public {
        vm.chainId(31337);

        DTSC dtsc = new DTSC();
        address mockHex = address(0xABCD);
        address oracle = address(0xBEEF);
        TShareValuation valuation = new TShareValuation(mockHex, oracle);
        RecoveryModule recovery = new RecoveryModule();
        StabilityPool pool = new StabilityPool(address(dtsc));
        PenaltyRouter router = new PenaltyRouter(address(dtsc), address(pool), address(0x1001));

        VaultManager vmgr = new VaultManager(
            mockHex,
            address(dtsc),
            address(valuation),
            address(recovery),
            address(router)
        );

        assertEq(address(vmgr.hexContract()), mockHex);
    }
}