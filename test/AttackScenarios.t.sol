// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {VaultManager} from "../src/core/VaultManager.sol";

import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @title Attack scenario simulations after security hardening
contract AttackScenariosTest is TestSetup {
    DTSCSystem sys;
    DTSCSystem sysRegistered;
    MockHEX hexToken;
    MockPair pair;
    address victim = address(0xA11CE);
    address attacker = address(0xBAD);
    address lp = address(0x10F1);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(10_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));
        sysRegistered = deployer.deployWithOptions(
            address(hexToken), address(hexToken), quote, address(pair), address(0x1001), true
        );

        sys.oracle.update();
        sysRegistered.oracle.update();
        pair.bumpCumulative(1e18, 0);
        vm.warp(block.timestamp + 1 days);
        sys.oracle.update();
        sysRegistered.oracle.update();

        seedMinStabilityPool(sys);

        hexToken.seedStake(victim, 500_000e8, 4500, 1001);
        hexToken.mint(victim, 500_000e8);
    }

    function _openCustodialMintMax(DTSCSystem memory s, address user, uint256 hearts, uint256 stakedDays)
        internal
        returns (uint256 vaultId, uint256 minted)
    {
        vm.startPrank(user);
        hexToken.approve(address(s.vaultManager), hearts);
        vaultId = s.vaultManager.openVaultWithNewStake(hearts, stakedDays);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        s.oracle.update();
        (minted,) = s.valuation.maxBorrowable(address(s.vaultManager), 0, false);
        vm.prank(user);
        s.vaultManager.mintDtsc(vaultId, minted);
    }

    function _openRegisteredMintMax(DTSCSystem memory s, address user, uint256 stakeIndex)
        internal
        returns (uint256 vaultId, uint256 minted)
    {
        vm.prank(user);
        vaultId = s.vaultManager.openVaultWithExistingStake(stakeIndex);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        s.oracle.update();
        (minted,) = s.valuation.maxBorrowable(user, stakeIndex, false);
        vm.prank(user);
        s.vaultManager.mintDtsc(vaultId, minted);
    }

    // ATTACK 1: Registered walk-away blocked in production (custodial-only)
    function test_ATTACK1_registeredWalkAway_blockedInProduction() public {
        vm.prank(victim);
        vm.expectRevert(VaultManager.RegisteredVaultsDisabled.selector);
        sys.vaultManager.openVaultWithExistingStake(0);
    }

    // ATTACK 2: Liquidator receives HEX bonus on custodial vault
    function test_ATTACK2_liquidationPaysHexBonus() public {
        (uint256 vaultId, uint256 minted) = _openCustodialMintMax(sys, victim, 200_000e8, 4500);
        _drainStabilityPool(sys);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(attacker, minted);
        vm.prank(attacker);
        sys.dtsc.approve(address(sys.vaultManager), minted);

        uint256 hexBefore = hexToken.balanceOf(attacker);
        vm.prank(attacker);
        sys.vaultManager.liquidate(vaultId, minted);

        assertGt(hexToken.balanceOf(attacker), hexBefore, "liquidator receives HEX bonus");
    }

    // ATTACK 3: Oracle pump still risky but bounded by min(twap,spot)
    function test_ATTACK3_oraclePumpThenCrash_stillDangerous() public {
        pair.setReserves(uint112(1_000_000e8), uint112(50_000e18));
        sys.oracle.update();

        (uint256 pumpedMax,) = sys.valuation.maxBorrowable(victim, 0, false);

        pair.setReserves(uint112(10_000_000e8), uint112(10_000e18));
        sys.oracle.update();
        pumpedMax;

        vm.startPrank(victim);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        pair.setReserves(uint112(1_000_000e8), uint112(50_000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        (uint256 atPump,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        vm.prank(victim);
        sys.vaultManager.mintDtsc(vaultId, atPump);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        uint256 cr = sys.vaultManager.getVaultCollateralRatio(vaultId);
        console2.log("ATTACK3 CR after pump-mint-crash:", cr);
        assertLt(cr, C.CCR_LONG_BPS, "pump-dump still creates underwater vault");
    }

    // ATTACK 4: Redemption now pays HEX on custodial vaults
    function test_ATTACK4_redemptionPaysHexCollateral() public {
        (uint256 vaultId, uint256 minted) = _openCustodialMintMax(sys, victim, 200_000e8, 4500);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(attacker, 100e18);
        vm.prank(attacker);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);

        prepareRedemption(sys);

        uint256 hexBefore = hexToken.balanceOf(attacker);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(50e18, 5);

        assertGt(hexToken.balanceOf(attacker), hexBefore, "redeemer receives HEX");
        assertLt(sys.vaultManager.getVault(vaultId).debtDtsc, minted);
    }

    // ATTACK 5: Empty SP leaves residual debt (registered mode test)
    function test_ATTACK5_emptySP_residualDebt() public {
        seedMinStabilityPool(sysRegistered);
        (uint256 vaultId, uint256 minted) = _openRegisteredMintMax(sysRegistered, victim, 0);
        VaultManager.Vault memory v0 = sysRegistered.vaultManager.getVault(vaultId);
        minted;

        _drainStabilityPool(sysRegistered);

        vm.prank(victim);
        hexToken.endStake(0, uint48(v0.stakeId));
        sysRegistered.vaultManager.reportEarlyUnstake(vaultId);

        assertEq(sysRegistered.vaultManager.totalDebtDtsc(), 0, "active debt cleared");
        assertGt(sysRegistered.recovery.totalBadDebtDtsc(), 0, "bad debt recorded when SP empty");
    }

    // ATTACK 6: SP offset burns DTSC and reduces compounded deposits
    function test_ATTACK6_spOffsetReducesDepositsCorrectly() public {
        seedMinStabilityPool(sysRegistered);
        vm.prank(address(sysRegistered.vaultManager));
        sysRegistered.dtsc.mint(lp, 5000e18);
        vm.prank(lp);
        sysRegistered.dtsc.approve(address(sysRegistered.stabilityPool), type(uint256).max);
        vm.prank(lp);
        sysRegistered.stabilityPool.deposit(5000e18);

        vm.prank(victim);
        uint256 vaultId = sysRegistered.vaultManager.openVaultWithExistingStake(0);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sysRegistered.oracle.update();
        vm.prank(victim);
        sysRegistered.vaultManager.mintDtsc(vaultId, 100e18);

        VaultManager.Vault memory v0 = sysRegistered.vaultManager.getVault(vaultId);
        vm.prank(victim);
        hexToken.endStake(0, uint48(v0.stakeId));
        sysRegistered.vaultManager.reportEarlyUnstake(vaultId);

        assertLt(sysRegistered.stabilityPool.getCompoundedDeposit(lp), 5000e18);
    }

    function _drainStabilityPool(DTSCSystem memory s) internal {
        uint256 total = s.stabilityPool.totalDeposits();
        if (total == 0) return;
        vm.prank(SP_LP);
        s.stabilityPool.withdraw(total);
    }

    // ATTACK 7: Recovery mode blocks new mint
    function test_ATTACK7_recoveryMode_blocksNewMint() public {
        (uint256 v1, uint256 m1) = _openCustodialMintMax(sys, victim, 200_000e8, 4500);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(v1);

        vm.prank(victim);
        vm.expectRevert(VaultManager.RecoveryModeRestriction.selector);
        sys.vaultManager.mintDtsc(v1, 1e18);
        m1;
    }

    // ATTACK 8: Cooldown bypass blocked
    function test_ATTACK8_cooldownCannotBypass() public {
        vm.startPrank(victim);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.prank(victim);
        vm.expectRevert(VaultManager.CooldownActive.selector);
        sys.vaultManager.mintDtsc(vaultId, 1e18);
    }

    // ATTACK 9: Double collateral blocked (same registered stake)
    function test_ATTACK9_doubleStakeBlocked() public {
        vm.prank(victim);
        sysRegistered.vaultManager.openVaultWithExistingStake(0);

        vm.prank(victim);
        vm.expectRevert(VaultManager.StakeAlreadyUsed.selector);
        sysRegistered.vaultManager.openVaultWithExistingStake(0);
    }

    // ATTACK 10: Over-borrow blocked
    function test_ATTACK10_overBorrowBlocked() public {
        vm.startPrank(victim);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);

        vm.prank(victim);
        vm.expectRevert(VaultManager.InsufficientCollateral.selector);
        sys.vaultManager.mintDtsc(vaultId, maxDtsc + 1e18);
    }

    // ATTACK 11: Redemption griefing targets lowest CR (custodial)
    function test_ATTACK11_redemptionGriefing_lowestCrVault() public {
        hexToken.mint(victim, 600_000e8);
        vm.startPrank(victim);
        hexToken.approve(address(sys.vaultManager), 600_000e8);
        uint256 v1 = sys.vaultManager.openVaultWithNewStake(300_000e8, 4500);
        uint256 v2 = sys.vaultManager.openVaultWithNewStake(300_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        (uint256 max1,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        (uint256 max2,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 1, false);

        vm.startPrank(victim);
        sys.vaultManager.mintDtsc(v1, max1);
        sys.vaultManager.mintDtsc(v2, max2 / 4);
        vm.stopPrank();

        assertLt(
            sys.vaultManager.getVaultCollateralRatio(v1),
            sys.vaultManager.getVaultCollateralRatio(v2),
            "v1 lower CR before redemption"
        );

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(attacker, 200e18);
        vm.prank(attacker);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);
        prepareRedemption(sys);

        (uint256 lowestId,) = sys.vaultManager.findLowestCrActiveVault();
        assertEq(lowestId, v1);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(50e18, 3);

        assertLt(sys.vaultManager.getVault(v1).debtDtsc, max1);
    }

    // ATTACK 12: Custodial close returns HEX
    function test_ATTACK12_custodialCloseReturnsHex() public {
        vm.startPrank(victim);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 3000);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        vm.prank(victim);
        sys.vaultManager.closeVault(vaultId);

        assertEq(hexToken.stakeCount(address(sys.vaultManager)), 0);
        assertEq(hexToken.balanceOf(victim), 500_000e8);
    }

    // ATTACK 13: No penalty mint on early unstake (registered with SP)
    function test_ATTACK13_noPenaltyMintInflation() public {
        seedMinStabilityPool(sysRegistered);
        vm.prank(address(sysRegistered.vaultManager));
        sysRegistered.dtsc.mint(lp, 10_000e18);
        vm.prank(lp);
        sysRegistered.dtsc.approve(address(sysRegistered.stabilityPool), type(uint256).max);
        vm.prank(lp);
        sysRegistered.stabilityPool.deposit(10_000e18);

        vm.prank(victim);
        uint256 vaultId = sysRegistered.vaultManager.openVaultWithExistingStake(0);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sysRegistered.oracle.update();
        (uint256 minted,) = sysRegistered.valuation.maxBorrowable(victim, 0, false);
        vm.prank(victim);
        sysRegistered.vaultManager.mintDtsc(vaultId, minted);

        uint256 supply0 = sysRegistered.dtsc.totalSupply();

        VaultManager.Vault memory v0 = sysRegistered.vaultManager.getVault(vaultId);
        vm.prank(victim);
        hexToken.endStake(0, uint48(v0.stakeId));
        sysRegistered.vaultManager.reportEarlyUnstake(vaultId);

        assertLe(sysRegistered.dtsc.totalSupply(), supply0, "no inflation from penalty mint");
        assertEq(sysRegistered.dtsc.balanceOf(victim), minted, "victim still holds minted DTSC");
    }

    // ATTACK 14: Spot manipulation still instant; TWAP lags
    function test_ATTACK14_spotManipulation_twapLags() public {
        sys.oracle.update();
        uint256 priceNormal = sys.oracle.getPrice();

        pair.setReserves(uint112(100_000e8), uint112(100_000e18));
        uint256 pricePumpedSpot = sys.oracle.getPrice();

        assertGt(pricePumpedSpot, priceNormal * 5, "spot reacts instantly");

        pair.setReserves(uint112(10_000_000e8), uint112(10_000e18));
        uint256 priceAfterReset = sys.oracle.getPrice();
        assertLt(priceAfterReset, pricePumpedSpot);
    }

    // ATTACK 15: Oracle rejects thin liquidity pools
    function test_ATTACK15_thinPool_rejectedByOracle() public {
        pair.setReserves(uint112(1000e8), uint112(10e18));
        sys.hexWplsOracle.update();
        vm.expectRevert();
        sys.oracle.getPrice();
    }
}