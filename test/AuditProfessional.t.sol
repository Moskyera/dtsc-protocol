// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestSetup} from "./TestSetup.sol";
import {MockHEX} from "./mocks/MockHEX.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {DTSCDeployer, DTSCSystem} from "../src/deploy/DTSCDeployer.sol";
import {VaultManager} from "../src/core/VaultManager.sol";
import {RedemptionHandler} from "../src/core/RedemptionHandler.sol";
import {BuybackBurn} from "../src/core/BuybackBurn.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @title Tests aligned with professional audit firm focus areas (OZ, Trail of Bits, Liquity/Bold scope)
contract AuditProfessionalTest is TestSetup {
    DTSCSystem sys;
    MockHEX hexToken;
    MockPair pair;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    function setUp() public {
        hexToken = new MockHEX();
        address quote = address(0xDAA1);
        pair = new MockPair(address(hexToken), quote, uint112(10_000_000e8), uint112(10_000e18));

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deploy(address(hexToken), address(hexToken), quote, address(pair), address(0x1001));

        primeOracle(sys, pair);
        seedMinStabilityPool(sys);
        hexToken.mint(alice, 800_000e8);
        hexToken.mint(bob, 800_000e8);
    }

    /// AUDIT-01: CR cache updates when first vault fully redeemed in multi-vault redeem (Coinspect/Liquity ordering)
    function test_AUDIT01_crCache_updatesAfterFullVaultRedemption() public {
        uint256 vLow = _openVault(alice, 200_000e8);
        uint256 vHigh = _openVault(bob, 200_000e8);
        uint256 debtLow = mintToTargetCr(sys, alice, vLow, 0, 16_800);
        mintToTargetCr(sys, bob, vHigh, 1, 18_500);
        prepareRedemption(sys);

        (uint256 cachedBefore,) = sys.vaultManager.findLowestCrActiveVault();
        assertEq(cachedBefore, vLow);

        _fundRedeemer(attacker, debtLow + 10e18);
        vm.prank(attacker);
        sys.redemptionHandler.redeem(debtLow + 5e18, 2);

        (uint256 cachedAfter,) = sys.vaultManager.findLowestCrActiveVault();
        assertEq(cachedAfter, vHigh, "cache must point to next lowest after full redeem");
    }

    /// AUDIT-02: Zero HEX payout reverts without debt haircut (Trail of Bits CEI / economic fairness)
    function test_AUDIT02_zeroHexPayout_revertsWithDebtRestored() public {
        hexToken.setEesPenaltyBps(10_000);

        uint256 vaultId = _openVault(alice, 100_000e8);
        mintToTargetCr(sys, alice, vaultId, 0, 17_000);
        prepareRedemption(sys);

        uint256 debtBefore = sys.vaultManager.getVault(vaultId).debtDtsc;
        _fundRedeemer(attacker, 20e18);

        vm.prank(attacker);
        vm.expectRevert(VaultManager.InsufficientCollateral.selector);
        sys.redemptionHandler.redeem(5e18, 1);

        assertEq(sys.vaultManager.getVault(vaultId).debtDtsc, debtBefore, "debt restored on failed payout");
    }

    /// AUDIT-03: BuybackBurn penalty router race closed (OpenZeppelin access control)
    function test_AUDIT03_buybackPenaltyRouter_deployerOnly() public {
        address rogue = address(0xDEAD);
        vm.prank(rogue);
        vm.expectRevert(BuybackBurn.Unauthorized.selector);
        sys.buybackBurn.setPenaltyRouter(rogue);
    }

    /// AUDIT-04: RedemptionHandler refunds on no targets (Liquity-style user safety)
    function test_AUDIT04_redemptionRefund_noStateBurn() public {
        _openVault(alice, 300_000e8);
        mintToTargetCr(sys, alice, 1, 0, 25_000);
        prepareRedemption(sys);

        _fundRedeemer(attacker, 50e18);
        uint256 bal = sys.dtsc.balanceOf(attacker);
        vm.prank(attacker);
        vm.expectRevert(RedemptionHandler.NoRedeemableVaults.selector);
        sys.redemptionHandler.redeem(10e18, 3);
        assertEq(sys.dtsc.balanceOf(attacker), bal);
    }

    /// AUDIT-05: Grace + CR cap double gate (professional economic review)
    function test_AUDIT05_hybridGates_bothRequired() public {
        uint256 vaultId = _openVault(alice, 250_000e8);
        mintToTargetCr(sys, alice, vaultId, 0, 19_000);

        assertFalse(sys.vaultManager.isVaultRedeemable(vaultId), "grace blocks");

        prepareRedemption(sys);
        assertTrue(sys.vaultManager.isVaultRedeemable(vaultId), "redeemable after grace at 190%");

        uint256 vaultSafe = _openVault(bob, 300_000e8);
        mintToTargetCr(sys, bob, vaultSafe, 1, 25_000);
        prepareRedemption(sys);
        assertFalse(sys.vaultManager.isVaultRedeemable(vaultSafe), "CR cap blocks");
    }

    function _openVault(address who, uint256 hearts) internal returns (uint256 vaultId) {
        vm.startPrank(who);
        hexToken.approve(address(sys.vaultManager), hearts);
        vaultId = sys.vaultManager.openVaultWithNewStake(hearts, 4500);
        vm.stopPrank();
        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();
    }

    function _fundRedeemer(address who, uint256 amt) internal {
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(who, amt);
        vm.prank(who);
        sys.dtsc.approve(address(sys.redemptionHandler), type(uint256).max);
    }
}