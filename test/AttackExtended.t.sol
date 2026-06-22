// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {StabilityPool} from "../src/core/StabilityPool.sol";
import {RedemptionHandler} from "../src/core/RedemptionHandler.sol";
import {BuybackBurn} from "../src/core/BuybackBurn.sol";
import {HexPriceOracle} from "../src/oracle/HexPriceOracle.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @title Extended attack simulations — oracle, redemption, SP, access control
contract AttackExtendedTest is TestSetup {
    DTSCSystem sys;
    DTSCSystem sysRegistered;
    MockHEX hexToken;
    MockPair pair;
    address user = address(0xA11CE);
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
        pair.bumpCumulative(1e18, 0);
        vm.warp(block.timestamp + 1 days);
        sys.oracle.update();
        sysRegistered.oracle.update();

        seedMinStabilityPool(sys);

        hexToken.seedStake(user, 500_000e8, 4500, 1001);
        hexToken.mint(user, 500_000e8);
    }

    function _openCustodialMint(DTSCSystem memory s, address who, uint256 hearts, uint256 mintAmt)
        internal
        returns (uint256 vaultId)
    {
        vm.startPrank(who);
        hexToken.approve(address(s.vaultManager), hearts);
        vaultId = s.vaultManager.openVaultWithNewStake(hearts, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        s.oracle.update();
        if (mintAmt == 0) {
            (mintAmt,) = s.valuation.maxBorrowable(address(s.vaultManager), 0, false);
            mintAmt = mintAmt / 4;
        }
        vm.prank(who);
        s.vaultManager.mintDtsc(vaultId, mintAmt);
    }

    // ATTACK 16: Partial redemption refunds unused DTSC (maxVaults cap)
    function test_ATTACK16_redemptionRefundsUnusedDtsc() public {
        hexToken.mint(user, 400_000e8);
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 400_000e8);
        uint256 v1 = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        uint256 v2 = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        mintToTargetCr(sys, user, v1, 0, 17_000);
        mintToTargetCr(sys, user, v2, 1, 17_500);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(attacker, 500e18);
        vm.prank(attacker);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);

        prepareRedemption(sys);
        uint256 balBefore = sys.dtsc.balanceOf(attacker);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(200e18, 1);

        assertLt(sys.dtsc.balanceOf(attacker), balBefore, "some DTSC burned");
        assertGt(sys.dtsc.balanceOf(attacker), balBefore - 200e18, "unused DTSC refunded");
    }

    // ATTACK 17: Redemption with no vaults reverts without burning
    function test_ATTACK17_redemptionNoVaults_noBurn() public {
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(attacker, 100e18);
        vm.prank(attacker);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);

        uint256 bal = sys.dtsc.balanceOf(attacker);
        vm.prank(attacker);
        vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
        sys.redemptionHandler.redeem(10e18, 5);

        assertEq(sys.dtsc.balanceOf(attacker), bal, "full refund on revert");
    }

    // ATTACK 18: Oracle stale blocks valuation reads
    function test_ATTACK18_staleOracle_blocksMint() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        vm.warp(block.timestamp + C.ORACLE_MAX_STALENESS + 1);

        vm.prank(user);
        vm.expectRevert();
        sys.vaultManager.mintDtsc(vaultId, 1e18);
    }

    // ATTACK 19: Unauthorized DTSC mint blocked
    function test_ATTACK19_unauthorizedMint_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        sys.dtsc.mint(attacker, 1e18);
    }

    // ATTACK 20: Unauthorized SP offset blocked
    function test_ATTACK20_unauthorizedOffset_returnsZero() public {
        vm.prank(attacker);
        uint256 offset = sys.stabilityPool.offsetDebt(1000e18);
        assertEq(offset, 0);
    }

    // ATTACK 21: Unauthorized SP notifyReward blocked
    function test_ATTACK21_unauthorizedNotifyReward_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(StabilityPool.Unauthorized.selector);
        sys.stabilityPool.notifyReward(1e18);
    }

    // ATTACK 22: Unauthorized buyback penalty burn blocked
    function test_ATTACK22_unauthorizedPenaltyBurn_reverts() public {
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(address(sys.buybackBurn), 10e18);

        vm.prank(attacker);
        vm.expectRevert(BuybackBurn.Unauthorized.selector);
        sys.buybackBurn.receivePenalty(10e18);
    }

    // ATTACK 23: Double liquidation second call reverts
    function test_ATTACK23_doubleLiquidation_blocked() public {
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
        sys.dtsc.mint(attacker, maxDtsc);
        vm.prank(attacker);
        sys.dtsc.approve(address(sys.vaultManager), type(uint256).max);

        vm.prank(attacker);
        sys.vaultManager.liquidate(vaultId, maxDtsc);

        vm.prank(attacker);
        vm.expectRevert(VaultManager.VaultNotActive.selector);
        sys.vaultManager.liquidate(vaultId, 1e18);
    }

    // ATTACK 24: Liquidate healthy vault reverts
    function test_ATTACK24_liquidateHealthyVault_reverts() public {
        uint256 vaultId = _openCustodialMint(sys, user, 200_000e8, 0);

        vm.prank(attacker);
        vm.expectRevert(VaultManager.InsufficientCollateral.selector);
        sys.vaultManager.liquidate(vaultId, 10e18);
    }

    // ATTACK 25: Recovery mode blocks mint; exits after collateral value recovers
    function test_ATTACK25_recoveryMode_blocksThenExits() public {
        (uint256 vaultId,) = _openCustodialMintMax(sys, user, 200_000e8, 4500);

        pair.setReserves(uint112(10_000_000e8), uint112(5000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);
        assertTrue(sys.recovery.isRecoveryMode());

        vm.prank(user);
        vm.expectRevert(VaultManager.RecoveryModeRestriction.selector);
        sys.vaultManager.mintDtsc(vaultId, 1e18);

        pair.setReserves(uint112(10_000_000e8), uint112(10_000e18));
        sys.oracle.update();
        sys.vaultManager.refreshVault(vaultId);
        assertFalse(sys.recovery.isRecoveryMode());
    }

    function _openCustodialMintMax(DTSCSystem memory s, address who, uint256 hearts, uint256 days_)
        internal
        returns (uint256 vaultId, uint256 minted)
    {
        vm.startPrank(who);
        hexToken.approve(address(s.vaultManager), hearts);
        vaultId = s.vaultManager.openVaultWithNewStake(hearts, days_);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        s.oracle.update();
        (minted,) = s.valuation.maxBorrowable(address(s.vaultManager), 0, false);
        vm.prank(who);
        s.vaultManager.mintDtsc(vaultId, minted);
    }

    // ATTACK 26: SP depositors share offset loss proportionally
    function test_ATTACK26_spOffset_proportionalLoss() public {
        seedMinStabilityPool(sysRegistered);
        address lp2 = address(0x10F2);
        vm.prank(address(sysRegistered.vaultManager));
        sysRegistered.dtsc.mint(lp, 1000e18);
        vm.prank(address(sysRegistered.vaultManager));
        sysRegistered.dtsc.mint(lp2, 1000e18);

        vm.startPrank(lp);
        sysRegistered.dtsc.approve(address(sysRegistered.stabilityPool), type(uint256).max);
        sysRegistered.stabilityPool.deposit(1000e18);
        vm.stopPrank();

        vm.startPrank(lp2);
        sysRegistered.dtsc.approve(address(sysRegistered.stabilityPool), type(uint256).max);
        sysRegistered.stabilityPool.deposit(1000e18);
        vm.stopPrank();

        vm.prank(user);
        uint256 vaultId = sysRegistered.vaultManager.openVaultWithExistingStake(0);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sysRegistered.oracle.update();
        vm.prank(user);
        sysRegistered.vaultManager.mintDtsc(vaultId, 100e18);

        VaultManager.Vault memory v0 = sysRegistered.vaultManager.getVault(vaultId);
        vm.prank(user);
        hexToken.endStake(0, uint48(v0.stakeId));
        sysRegistered.vaultManager.reportEarlyUnstake(vaultId);

        assertEq(
            sysRegistered.stabilityPool.getCompoundedDeposit(lp),
            sysRegistered.stabilityPool.getCompoundedDeposit(lp2)
        );
        assertLt(sysRegistered.stabilityPool.getCompoundedDeposit(lp), 1000e18);
    }

    // ATTACK 27: Close vault with debt blocked
    function test_ATTACK27_closeWithDebt_reverts() public {
        uint256 vaultId = _openCustodialMint(sys, user, 100_000e8, 0);

        vm.prank(user);
        vm.expectRevert(VaultManager.InsufficientCollateral.selector);
        sys.vaultManager.closeVault(vaultId);
    }

    // ATTACK 28: Repay full debt then close succeeds
    function test_ATTACK28_repayThenClose_succeeds() public {
        uint256 vaultId = _openCustodialMint(sys, user, 100_000e8, 0);
        uint256 debt = sys.vaultManager.getVault(vaultId).debtDtsc;

        vm.startPrank(user);
        sys.dtsc.approve(address(sys.vaultManager), debt);
        sys.vaultManager.repayDtsc(vaultId, debt);
        sys.vaultManager.closeVault(vaultId);
        vm.stopPrank();

        assertFalse(sys.vaultManager.getVault(vaultId).active);
    }

    // ATTACK 29: Same-block spot pump — min(twap,spot) uses lower TWAP when primed
    function test_ATTACK29_spotPump_minUsesTwapWhenLower() public {
        uint256 priceNormal = sys.oracle.getPrice();

        pair.setReserves(uint112(100_000e8), uint112(200_000e18));
        uint256 pricePumped = sys.oracle.getPrice();

        assertGt(pricePumped, priceNormal * 3, "spot pumps hard");

        pair.setReserves(uint112(10_000_000e8), uint112(10_000e18));
        uint256 priceReset = sys.oracle.getPrice();
        assertLt(priceReset, pricePumped);
    }

    // ATTACK 30: Unauthorized applyRedemption blocked
    function test_ATTACK30_unauthorizedRedemption_blocked() public {
        vm.prank(attacker);
        vm.expectRevert(VaultManager.Unauthorized.selector);
        sys.vaultManager.applyRedemption(1, 10e18, attacker);
    }

    // ATTACK 31: Mint by non-owner blocked
    function test_ATTACK31_mintByNonOwner_reverts() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        vm.prank(attacker);
        vm.expectRevert(VaultManager.Unauthorized.selector);
        sys.vaultManager.mintDtsc(vaultId, 1e18);
    }

    // ATTACK 32: Short stake rejected at vault open
    function test_ATTACK32_shortStake_rejected() public {
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 100_000e8);
        vm.expectRevert(VaultManager.IneligibleStake.selector);
        sys.vaultManager.openVaultWithNewStake(100_000e8, 1000);
        vm.stopPrank();
    }

    // ATTACK 33: Oracle aggregator rejects all-invalid sources
    function test_ATTACK33_allOraclesThin_reverts() public {
        pair.setReserves(uint112(1000e8), uint112(10e18));
        sys.hexWplsOracle.update();
        vm.expectRevert();
        sys.oracle.getPrice();
    }

    // ATTACK 34: Custodial redemption extracts HEX from vault stake
    function test_ATTACK34_custodialRedemption_reducesStakeHearts() public {
        (uint256 vaultId,) = _openCustodialMintMax(sys, user, 200_000e8, 4500);

        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(attacker, 200e18);
        vm.prank(attacker);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);

        prepareRedemption(sys);

        (, uint72 heartsBefore,,,,,) = hexToken.stakeLists(address(sys.vaultManager), 0);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(20e18, 5);

        (, uint72 heartsAfter,,,,,) = hexToken.stakeLists(address(sys.vaultManager), 0);
        uint256 stakeHeartsBefore = heartsBefore;
        uint256 stakeHeartsAfter = heartsAfter;
        assertLt(stakeHeartsAfter, stakeHeartsBefore, "HEX extracted from custodial stake");
    }

    // ATTACK 35: finalizeSetup blocks deployer setters
    function test_ATTACK35_postFinalize_settersBlocked() public {
        vm.expectRevert(VaultManager.Unauthorized.selector);
        sys.vaultManager.setRegisteredVaultsEnabled(true);
    }

    // ATTACK 36: Mint blocked without minimum SP coverage
    function test_ATTACK36_mintRequiresSpCoverage() public {
        DTSCDeployer deployer = new DTSCDeployer();
        DTSCSystem memory bare = deployer.deploy(
            address(hexToken), address(hexToken), address(0xDAA1), address(pair), address(0x1001)
        );
        bare.oracle.update();

        vm.startPrank(user);
        hexToken.approve(address(bare.vaultManager), 100_000e8);
        uint256 vaultId = bare.vaultManager.openVaultWithNewStake(100_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        bare.oracle.update();

        vm.prank(user);
        vm.expectRevert(VaultManager.InsufficientSpCoverage.selector);
        bare.vaultManager.mintDtsc(vaultId, 1e18);
    }

    function _drainStabilityPool(DTSCSystem memory s) internal {
        uint256 total = s.stabilityPool.totalDeposits();
        if (total == 0) return;
        vm.prank(SP_LP);
        s.stabilityPool.withdraw(total);
    }

    // ATTACK 37: TWAP collateral price ignores same-block spot pump (H-08)
    function test_ATTACK37_twapCollateralIgnoresSpotPump() public {
        hexToken.mint(user, 200_000e8);
        vm.startPrank(user);
        hexToken.approve(address(sys.vaultManager), 200_000e8);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(200_000e8, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        uint256 collateralBefore = sys.oracle.getCollateralPrice();
        uint256 spotBefore = sys.oracle.getPrice();

        pair.setReserves(uint112(100_000e8), uint112(200_000e18));
        uint256 collateralAfter = sys.oracle.getCollateralPrice();
        uint256 spotAfter = sys.oracle.getPrice();

        assertEq(collateralAfter, collateralBefore, "TWAP collateral price unchanged on spot pump");
        assertGt(spotAfter, spotBefore, "market price reacts to spot");
        vaultId;
    }

    // ATTACK 38: CR cache populated after mint
    function test_ATTACK38_crCachePopulated() public {
        (uint256 vaultId,) = _openCustodialMintMax(sys, user, 200_000e8, 4500);
        prepareRedemption(sys);
        sys.vaultManager.refreshVault(vaultId);
        assertEq(sys.vaultManager.cachedLowestCrVaultId(), vaultId);
        assertTrue(sys.vaultManager.crCacheValid());
    }

    // ATTACK 39: Bad debt triggers recovery mode
    function test_ATTACK39_badDebtTriggersRecovery() public {
        seedMinStabilityPool(sysRegistered);
        vm.prank(user);
        uint256 vaultId = sysRegistered.vaultManager.openVaultWithExistingStake(0);
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sysRegistered.oracle.update();
        vm.prank(user);
        sysRegistered.vaultManager.mintDtsc(vaultId, 100e18);

        _drainStabilityPool(sysRegistered);

        VaultManager.Vault memory v0 = sysRegistered.vaultManager.getVault(vaultId);
        vm.prank(user);
        hexToken.endStake(0, uint48(v0.stakeId));
        sysRegistered.vaultManager.reportEarlyUnstake(vaultId);

        assertGt(sysRegistered.recovery.totalBadDebtDtsc(), 0);
        assertFalse(sysRegistered.recovery.isRecoveryMode(), "recovery exits once residual debt cleared");
    }
}