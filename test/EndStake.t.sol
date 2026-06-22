// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @title endStake path verification — close, redemption, liquidation, index resync
contract EndStakeTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    MockPair pair;
    address user = address(0xA11CE);
    address redeemer = address(0xDEED);
    address liquidator = address(0x1E4A);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(10_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));

        primeOracle(sys, pair);
        seedMinStabilityPool(sys);
        hexToken.mint(user, 400_000e8);
    }

    function test_endStake_closeVault_returnsFullStake() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 150_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(150_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        uint256 balBefore = hexToken.balanceOf(user);
        vm.prank(user);
        sys.vaultManager.closeVault(vaultId);

        assertEq(hexToken.balanceOf(user), balBefore + 150_000e8);
        assertEq(hexToken.stakeCount(address(sys.vaultManager)), 0);
        assertFalse(sys.vaultManager.getVault(vaultId).active);
    }

    function test_endStake_redemption_partialExtractsAndRestakes() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        uint256 minted = mintToTargetCr(sys, user, vaultId, 0, 17_500);

        (, uint72 heartsBefore,,,,,) = hexToken.stakeLists(address(sys.vaultManager), 0);
        uint40 stakeIdBefore = sys.vaultManager.getVault(vaultId).stakeId;

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(redeemer, 50e18);
        vm.startPrank(redeemer);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);
        prepareRedemption(sys);
        sys.redemptionHandler.redeem(10e18, 1);
        vm.stopPrank();

        assertGt(hexToken.balanceOf(redeemer), 0, "redeemer received HEX");
        assertLt(sys.vaultManager.getVault(vaultId).debtDtsc, minted);
        assertEq(hexToken.stakeCount(address(sys.vaultManager)), 1, "remainder re-staked");

        VaultManager.Vault memory v = sys.vaultManager.getVault(vaultId);
        assertTrue(v.active);
        assertGt(v.stakeId, 0);
        assertGe(v.stakeId, stakeIdBefore, "new stakeId after partial endStake");

        (, uint72 heartsAfter,,,,,) = hexToken.stakeLists(address(sys.vaultManager), v.stakeIndex);
        assertLt(heartsAfter, heartsBefore, "stake hearts reduced");
        assertGt(heartsAfter, 0, "stake not fully drained");
    }

    function test_endStake_multipleRedemptions_depletesStakeGradually() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(user);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(redeemer, maxDtsc);
        vm.prank(redeemer);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);
        prepareRedemption(sys);

        uint256 totalHex;
        for (uint256 i = 0; i < 5; i++) {
            uint256 debt = sys.vaultManager.getVault(vaultId).debtDtsc;
            if (debt == 0) break;
            uint256 chunk = debt / 5;
            if (chunk == 0) chunk = debt;
            uint256 hexBefore = hexToken.balanceOf(redeemer);
            vm.prank(redeemer);
            sys.redemptionHandler.redeem(chunk, 1);
            totalHex += hexToken.balanceOf(redeemer) - hexBefore;
        }

        assertGt(totalHex, 0);
        assertTrue(
            sys.vaultManager.getVault(vaultId).debtDtsc < maxDtsc || !sys.vaultManager.getVault(vaultId).active
        );
    }

    function test_endStake_liquidation_extractsHexBonus() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(user);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc);

        _drainStabilityPool(sys);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        uint256 stakeBefore = hexToken.stakeCount(address(sys.vaultManager));
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(liquidator, maxDtsc);
        vm.startPrank(liquidator);
        sys.dtsc.approve(address(sys.vaultManager), maxDtsc);
        (uint256 burned, uint256 heartsPaid) = sys.vaultManager.liquidate(vaultId, maxDtsc);
        vm.stopPrank();

        assertGt(burned, 0);
        assertGt(heartsPaid, 0);
        assertEq(hexToken.balanceOf(liquidator), heartsPaid);
        assertLe(hexToken.stakeCount(address(sys.vaultManager)), stakeBefore);
        assertFalse(sys.vaultManager.getVault(vaultId).active);
    }

    function test_endStake_stakeIndexResync_afterSiblingStakeRemoved() public {
        uint40 siblingId = hexToken.seedStake(address(sys.vaultManager), 50_000e8, 3000, 1001);

        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        uint40 vaultStakeId = sys.vaultManager.getVault(vaultId).stakeId;
        uint256 siblingIdx = hexToken.stakeCount(address(sys.vaultManager)) - 1;
        for (uint256 i = 0; i < hexToken.stakeCount(address(sys.vaultManager)); i++) {
            (uint40 id,,,,,,) = hexToken.stakeLists(address(sys.vaultManager), i);
            if (id == siblingId) siblingIdx = i;
        }

        vm.prank(address(sys.vaultManager));
        hexToken.endStake(siblingIdx, uint48(siblingId));

        sys.vaultManager.refreshVault(vaultId);
        VaultManager.Vault memory v = sys.vaultManager.getVault(vaultId);
        assertEq(v.stakeId, vaultStakeId);
        assertTrue(v.active);
        assertGt(v.effectiveValueUsd, 0);
    }

    function test_endStake_custodialUserCannotEndStakeDirectly() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.expectRevert();
        hexToken.endStake(0, 1);
    }

    function _drainStabilityPool(DTSCSystem memory s) internal {
        uint256 total = s.stabilityPool.totalDeposits();
        if (total == 0) return;
        vm.prank(SP_LP);
        s.stabilityPool.withdraw(total);
    }
}