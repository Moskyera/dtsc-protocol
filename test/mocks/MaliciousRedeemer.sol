// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RedemptionHandler} from "../../src/core/RedemptionHandler.sol";
import {VaultManager} from "../../src/core/VaultManager.sol";
import {DTSC} from "../../src/core/DTSC.sol";

/// @dev Attempts reentrancy during HEX payout in redemption / liquidation paths
contract MaliciousRedeemer {
    RedemptionHandler public handler;
    VaultManager public vaultManager;
    DTSC public dtsc;
    uint256 public targetVaultId;
    bool public attackRedeem;
    bool public attackLiquidate;
    uint256 public reentryAttempts;

    constructor(address handler_, address vaultManager_, address dtsc_) {
        handler = RedemptionHandler(handler_);
        vaultManager = VaultManager(vaultManager_);
        dtsc = DTSC(dtsc_);
    }

    function configure(uint256 vaultId_, bool redeem_, bool liquidate_) external {
        targetVaultId = vaultId_;
        attackRedeem = redeem_;
        attackLiquidate = liquidate_;
    }

    function redeem(uint256 amount, uint256 maxVaults) external {
        dtsc.approve(address(handler), type(uint256).max);
        handler.redeem(amount, maxVaults);
    }

    function liquidate(uint256 maxCover) external {
        dtsc.approve(address(vaultManager), type(uint256).max);
        vaultManager.liquidate(targetVaultId, maxCover);
    }

    /// @notice ERC20-style callback hook — MockHEX transfer does not invoke this; used if token adds hooks
    function onTokenReceived() external {
        _attemptReentry();
    }

    receive() external payable {
        _attemptReentry();
    }

    function _attemptReentry() internal {
        reentryAttempts++;
        if (attackRedeem) {
            try handler.redeem(1e18, 1) {} catch {}
        }
        if (attackLiquidate && targetVaultId != 0) {
            try vaultManager.liquidate(targetVaultId, 1e18) {} catch {}
        }
    }
}