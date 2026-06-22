// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DTSC} from "./DTSC.sol";
import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {DTSCMath} from "../libraries/DTSCMath.sol";

interface IStabilityPoolRewards {
    function notifyReward(uint256 amount) external;
}

interface IBuybackBurn {
    function receivePenalty(uint256 amount) external;
}

contract PenaltyRouter {
    DTSC public immutable dtsc;
    IStabilityPoolRewards public immutable stabilityPool;
    IBuybackBurn public immutable buybackBurn;

    address public deployer;
    address public vaultManager;

    error Unauthorized();
    error ZeroAmount();

    event PenaltyRouted(uint256 total, uint256 toPool, uint256 toBurn);

    constructor(address dtsc_, address stabilityPool_, address buybackBurn_) {
        dtsc = DTSC(dtsc_);
        stabilityPool = IStabilityPoolRewards(stabilityPool_);
        buybackBurn = IBuybackBurn(buybackBurn_);
        deployer = msg.sender;
    }

    function setVaultManager(address vaultManager_) external {
        if (msg.sender != deployer || vaultManager != address(0)) revert Unauthorized();
        vaultManager = vaultManager_;
    }

    function renounceDeployer() external {
        if (msg.sender != deployer) revert Unauthorized();
        deployer = address(0);
    }

    function routePenalty(uint256 totalPenalty) external {
        if (msg.sender != vaultManager) revert Unauthorized();
        if (totalPenalty == 0) revert ZeroAmount();

        uint256 toPool = DTSCMath.bpsApply(totalPenalty, C.PENALTY_STABILITY_BPS);
        uint256 toBurn = totalPenalty - toPool;

        if (toPool > 0) {
            require(dtsc.transfer(address(stabilityPool), toPool), "sp");
            stabilityPool.notifyReward(toPool);
        }
        if (toBurn > 0) {
            require(dtsc.transfer(address(buybackBurn), toBurn), "bb");
            buybackBurn.receivePenalty(toBurn);
        }

        emit PenaltyRouted(totalPenalty, toPool, toBurn);
    }
}