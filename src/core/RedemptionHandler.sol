// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DTSC} from "./DTSC.sol";
import {VaultManager} from "./VaultManager.sol";
import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {DTSCMath} from "../libraries/DTSCMath.sol";
import {RedemptionPolicy} from "../libraries/RedemptionPolicy.sol";

/// @title RedemptionHandler — Peg defense: burn DTSC, receive HEX from custodial vaults
/// @dev Hybrid fee: per-vault CR-based dynamic fee + VaultManager eligibility gates
contract RedemptionHandler {
    DTSC public immutable dtsc;
    VaultManager public immutable vaultManager;

    uint256 public totalFeesBurned;

    event Redeemed(
        address indexed redeemer,
        uint256 dtscBurned,
        uint256 feeDtsc,
        uint256 heartsReceived,
        uint256 vaultsProcessed,
        uint256 dtscRefunded
    );

    error InvalidAmount();
    error NoRedeemableVaults();
    error TransferFailed();

    uint256 private _locked = 1;

    constructor(address dtsc_, address vaultManager_, address) {
        dtsc = DTSC(dtsc_);
        vaultManager = VaultManager(vaultManager_);
    }

    modifier nonReentrant() {
        if (_locked != 1) revert TransferFailed();
        _locked = 2;
        _;
        _locked = 1;
    }

    function redeem(uint256 dtscAmount, uint256 maxVaultsToProcess) external nonReentrant {
        if (dtscAmount == 0) revert InvalidAmount();
        if (!dtsc.transferFrom(msg.sender, address(this), dtscAmount)) revert TransferFailed();

        (uint256 processed, uint256 heartsReceived, uint256 netApplied, uint256 totalFee) =
            _processRedemptions(dtscAmount, maxVaultsToProcess);

        if (processed == 0) {
            if (!dtsc.transfer(msg.sender, dtscAmount)) revert TransferFailed();
            revert NoRedeemableVaults();
        }

        uint256 burnTotal = netApplied + totalFee;
        if (burnTotal > dtscAmount) burnTotal = dtscAmount;

        dtsc.burn(address(this), burnTotal);
        totalFeesBurned += totalFee;

        uint256 refund = dtscAmount - burnTotal;
        if (refund > 0) {
            if (!dtsc.transfer(msg.sender, refund)) revert TransferFailed();
        }

        emit Redeemed(msg.sender, burnTotal, totalFee, heartsReceived, processed, refund);
    }

    function _processRedemptions(uint256 grossBudget, uint256 maxVaults)
        internal
        returns (uint256 processed, uint256 totalHearts, uint256 netApplied, uint256 totalFee)
    {
        uint256 remainingGross = grossBudget;

        while (remainingGross > 0 && processed < maxVaults) {
            (uint256 vaultId,) = vaultManager.findLowestCrActiveVault();
            if (vaultId == 0) break;

            VaultManager.Vault memory v = vaultManager.getVault(vaultId);
            uint256 feeBps = vaultManager.redemptionFeeBpsForVault(vaultId);

            uint256 netBudget = DTSCMath.mulDiv(remainingGross, C.BPS - feeBps, C.BPS);
            if (netBudget == 0) break;

            uint256 debtCap = v.debtDtsc;
            uint256 netAttempt = netBudget > debtCap ? debtCap : netBudget;

            (uint256 applied, uint256 heartsPaid) =
                vaultManager.applyRedemption(vaultId, netAttempt, msg.sender);
            if (applied == 0) break;

            uint256 fee = DTSCMath.bpsApply(applied, feeBps);
            uint256 grossUsed = RedemptionPolicy.grossFromNet(applied, feeBps);
            if (grossUsed > remainingGross) grossUsed = remainingGross;

            remainingGross -= grossUsed;
            netApplied += applied;
            totalFee += fee;
            totalHearts += heartsPaid;
            processed++;
        }
    }

    function previewRedemptionFee(uint256 vaultId, uint256 netDtscAmount)
        external
        view
        returns (uint256 fee, uint256 gross)
    {
        uint256 feeBps = vaultManager.redemptionFeeBpsForVault(vaultId);
        fee = DTSCMath.bpsApply(netDtscAmount, feeBps);
        gross = netDtscAmount + fee;
    }

    function previewWeightedFee(uint256 dtscAmount) external view returns (uint256 feeBps) {
        (uint256 vaultId,) = vaultManager.findLowestCrActiveVault();
        if (vaultId == 0) return C.REDEMPTION_FEE_HIGH_BPS;
        return vaultManager.redemptionFeeBpsForVault(vaultId);
    }
}