// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DTSC} from "./DTSC.sol";
import {VaultManager} from "./VaultManager.sol";
import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {DTSCMath} from "../libraries/DTSCMath.sol";

/// @title StabilityPool — Peg defense via DTSC deposits (Liquity-style P factor)
contract StabilityPool {
    DTSC public immutable dtsc;
    VaultManager public vaultManager;
    address public penaltyRouter;
    address public deployer;

    uint256 public totalDeposits;
    uint256 public pendingRewardsPerShare;
    uint256 internal constant REWARD_PRECISION = 1e18;

    /// @dev Running product P tracks deposit depletion from debt offsets
    uint256 public P = C.SP_DECIMAL_PRECISION;
    uint256 public currentScale;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public depositSnapshotP;
    mapping(address => uint256) public depositSnapshotScale;

    event Deposited(address indexed user, uint256 amount, uint256 compoundedBalance);
    event Withdrawn(address indexed user, uint256 amount, uint256 compoundedBalance);
    event RewardPaid(address indexed user, uint256 amount);
    event DebtOffset(uint256 dtscBurned, uint256 newP, uint256 newTotalDeposits);

    error ZeroAmount();
    error InsufficientDeposit();
    error Unauthorized();

    constructor(address dtsc_) {
        dtsc = DTSC(dtsc_);
        deployer = msg.sender;
    }

    function setVaultManager(address vaultManager_) external {
        if (msg.sender != deployer || address(vaultManager) != address(0)) revert Unauthorized();
        vaultManager = VaultManager(vaultManager_);
    }

    function setPenaltyRouter(address penaltyRouter_) external {
        if (msg.sender != deployer || penaltyRouter != address(0)) revert Unauthorized();
        penaltyRouter = penaltyRouter_;
    }

    function renounceDeployer() external {
        if (msg.sender != deployer) revert Unauthorized();
        deployer = address(0);
    }

    function getCompoundedDeposit(address user) public view returns (uint256) {
        uint256 initial = deposits[user];
        if (initial == 0) return 0;

        uint256 snapshotP = depositSnapshotP[user];
        uint256 snapshotScale = depositSnapshotScale[user];
        if (snapshotP == 0) return initial;

        if (snapshotScale == currentScale) {
            return DTSCMath.mulDiv(initial, P, snapshotP);
        }

        uint256 scaleDiff = currentScale - snapshotScale;
        if (scaleDiff > 1) return 0;

        uint256 adjustedP = DTSCMath.mulDiv(snapshotP, C.SP_SCALE_FACTOR, C.SP_DECIMAL_PRECISION);
        return DTSCMath.mulDiv(initial, P, adjustedP);
    }

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _checkpointRewards(msg.sender, true);
        require(dtsc.transferFrom(msg.sender, address(this), amount), "xfer");

        deposits[msg.sender] = deposits[msg.sender] + amount;
        depositSnapshotP[msg.sender] = P;
        depositSnapshotScale[msg.sender] = currentScale;
        totalDeposits += amount;

        emit Deposited(msg.sender, amount, deposits[msg.sender]);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _checkpointRewards(msg.sender, true);
        if (deposits[msg.sender] < amount) revert InsufficientDeposit();

        deposits[msg.sender] = deposits[msg.sender] - amount;
        depositSnapshotP[msg.sender] = P;
        depositSnapshotScale[msg.sender] = currentScale;
        totalDeposits -= amount;

        require(dtsc.transfer(msg.sender, amount), "xfer");
        emit Withdrawn(msg.sender, amount, deposits[msg.sender]);
    }

    /// @notice Only PenaltyRouter after it transfers DTSC to this contract
    function notifyReward(uint256 amount) external {
        if (msg.sender != penaltyRouter) revert Unauthorized();
        if (amount == 0 || totalDeposits == 0) return;
        pendingRewardsPerShare += DTSCMath.mulDiv(amount, REWARD_PRECISION, totalDeposits);
    }

    function claimableReward(address user) public view returns (uint256) {
        uint256 accrued = DTSCMath.mulDiv(getCompoundedDeposit(user), pendingRewardsPerShare, REWARD_PRECISION);
        if (accrued <= rewardDebt[user]) return 0;
        return accrued - rewardDebt[user];
    }

    function claimRewards() external returns (uint256 reward) {
        _syncDeposit(msg.sender);
        reward = claimableReward(msg.sender);
        if (reward > 0) {
            rewardDebt[msg.sender] += reward;
            require(dtsc.transfer(msg.sender, reward), "xfer");
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Burns DTSC and depletes all deposits proportionally via P
    function offsetDebt(uint256 dtscAmount) external returns (uint256 offset) {
        if (msg.sender != address(vaultManager)) return 0;
        if (dtscAmount == 0 || totalDeposits == 0) return 0;

        offset = dtscAmount > totalDeposits ? totalDeposits : dtscAmount;

        uint256 newTotal = totalDeposits - offset;
        uint256 newP = DTSCMath.mulDiv(P, newTotal, totalDeposits);

        if (newP == 0) {
            currentScale++;
            newP = C.SP_DECIMAL_PRECISION;
        }

        P = newP;
        totalDeposits = newTotal;

        dtsc.burn(address(this), offset);
        emit DebtOffset(offset, P, newTotal);
    }

    /// @dev Syncs P-factor state; optionally resets rewardDebt baseline (deposit/withdraw only).
    ///      Claim must pass resetBaseline=false — resetting before claim zeroes claimable rewards.
    function _checkpointRewards(address user, bool resetBaseline) internal {
        _syncDeposit(user);
        if (resetBaseline) {
            rewardDebt[user] = DTSCMath.mulDiv(deposits[user], pendingRewardsPerShare, REWARD_PRECISION);
        }
    }

    /// @dev Syncs P-factor compounding; scales rewardDebt proportionally on depletion
    function _syncDeposit(address user) internal {
        uint256 compounded = getCompoundedDeposit(user);
        uint256 stored = deposits[user];
        if (compounded == stored) return;

        if (stored > 0 && rewardDebt[user] > 0) {
            rewardDebt[user] = DTSCMath.mulDiv(rewardDebt[user], compounded, stored);
        }

        deposits[user] = compounded;
        depositSnapshotP[user] = P;
        depositSnapshotScale[user] = currentScale;
    }
}