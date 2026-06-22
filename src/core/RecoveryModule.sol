// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {DTSCMath} from "../libraries/DTSCMath.sol";

/// @title RecoveryModule — System-wide collateral ratio + bad debt monitoring
contract RecoveryModule {
    uint256 public totalCollateralValueUsd;
    uint256 public totalDebtDtsc;
    uint256 public totalBadDebtDtsc;

    bool public recoveryMode;

    event RecoveryModeUpdated(bool enabled, uint256 systemCrBps);
    event TotalsUpdated(uint256 collateralUsd, uint256 debtDtsc);
    event BadDebtRecorded(uint256 amount, uint256 totalBadDebt);

    error OnlyVaultManager();

    address public vaultManager;
    address public deployer;

    constructor() {
        deployer = msg.sender;
    }

    function setVaultManager(address vaultManager_) external {
        if (msg.sender != deployer || vaultManager != address(0)) revert OnlyVaultManager();
        vaultManager = vaultManager_;
    }

    function renounceDeployer() external {
        if (msg.sender != deployer) revert OnlyVaultManager();
        deployer = address(0);
    }

    modifier onlyVaultManager() {
        if (msg.sender != vaultManager) revert OnlyVaultManager();
        _;
    }

    function updateTotals(uint256 collateralUsd, uint256 debtDtsc) external onlyVaultManager {
        totalCollateralValueUsd = collateralUsd;
        totalDebtDtsc = debtDtsc;
        emit TotalsUpdated(collateralUsd, debtDtsc);
        _syncRecoveryMode();
    }

    /// @notice Records unbacked DTSC after early unstake when SP cannot fully offset (M-07)
    function recordBadDebt(uint256 amount) external onlyVaultManager {
        if (amount == 0) return;
        totalBadDebtDtsc += amount;
        emit BadDebtRecorded(amount, totalBadDebtDtsc);
        _syncRecoveryMode();
    }

    function systemCollateralRatioBps() public view returns (uint256) {
        if (totalDebtDtsc == 0) return type(uint256).max;
        return DTSCMath.mulDiv(totalCollateralValueUsd, C.BPS, totalDebtDtsc);
    }

    /// @notice Blocks new mint while unbacked DTSC from socialized bad debt remains on record
    function unbackedDebtBlocksMint() external view returns (bool) {
        return totalBadDebtDtsc >= C.BAD_DEBT_RECOVERY_THRESHOLD_DTSC;
    }

    function _syncRecoveryMode() internal {
        bool shouldRecover = totalDebtDtsc > 0 && systemCollateralRatioBps() < C.CCR_RECOVERY_BPS;

        if (shouldRecover != recoveryMode) {
            recoveryMode = shouldRecover;
            emit RecoveryModeUpdated(shouldRecover, systemCollateralRatioBps());
        }
    }

    function isRecoveryMode() external view returns (bool) {
        return recoveryMode;
    }
}