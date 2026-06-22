// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHEX} from "../interfaces/IHEX.sol";
import {DTSC} from "./DTSC.sol";
import {TShareValuation} from "../valuation/TShareValuation.sol";
import {RecoveryModule} from "./RecoveryModule.sol";
import {PenaltyRouter} from "./PenaltyRouter.sol";
import {StabilityPool} from "./StabilityPool.sol";
import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {DTSCMath} from "../libraries/DTSCMath.sol";
import {RedemptionPolicy} from "../libraries/RedemptionPolicy.sol";
import {PulseChainAddresses as A} from "../config/PulseChainAddresses.sol";

/// @title VaultManager — Interest-free CDP vaults backed by HEX T-shares
contract VaultManager {
    enum CollateralMode {
        Registered,
        Custodial
    }

    struct Vault {
        address owner;
        CollateralMode mode;
        uint40 stakeId;
        uint256 stakeIndex;
        uint256 effectiveValueUsd;
        uint256 debtDtsc;
        uint256 minCollateralRatioBps;
        uint64 openedAt;
        uint64 cooldownEndsAt;
        bool active;
    }

    error Unauthorized();
    error VaultNotActive();
    error CooldownActive();
    error InsufficientCollateral();
    error RecoveryModeRestriction();
    error IneligibleStake();
    error InvalidAmount();
    error StakeAlreadyUsed();
    error SetupAlreadyFinalized();
    error RegisteredVaultsDisabled();
    error HexTransferFailed();
    error UnsupportedHexToken();
    error InsufficientSpCoverage();
    error UnbackedDebtRestriction();
    error RegisteredLiquidationDisabled();

    IHEX public immutable hexContract;
    DTSC public immutable dtsc;
    TShareValuation public immutable valuation;
    RecoveryModule public immutable recovery;
    PenaltyRouter public immutable penaltyRouter;

    address public deployer;
    StabilityPool public stabilityPool;
    address public redemptionHandler;

    bool public registeredVaultsEnabled;

    uint256 public nextVaultId = 1;
    mapping(uint256 => Vault) public vaults;
    mapping(address => uint256[]) public vaultsByOwner;
    mapping(bytes32 => uint256) public stakeKeyToVaultId;
    /// @dev Timestamp after which vault may be targeted by redemption (grace after first mint)
    mapping(uint256 => uint64) public redemptionEligibleAt;

    uint256 public totalCollateralValueUsd;
    uint256 public totalDebtDtsc;

    uint256 public cachedLowestCrVaultId;
    uint256 public cachedLowestCrBps;
    bool public crCacheValid;

    uint256 private _locked = 1;

    event VaultOpened(uint256 indexed vaultId, address indexed owner, uint40 stakeId, CollateralMode mode);
    event DebtMinted(uint256 indexed vaultId, uint256 amount, uint256 totalDebt);
    event DebtRepaid(uint256 indexed vaultId, uint256 amount, uint256 totalDebt);
    event VaultClosed(uint256 indexed vaultId);
    event EarlyUnstakeReported(uint256 indexed vaultId, address indexed reporter, uint256 debtOffset);
    event CustodialStakeCreated(uint256 indexed vaultId, uint40 stakeId, uint256 heartsStaked);
    event RedemptionApplied(uint256 indexed vaultId, uint256 dtscBurned, uint256 heartsPaid, address indexed redeemer);
    event Liquidated(
        uint256 indexed vaultId,
        uint256 dtscBurned,
        uint256 spOffset,
        uint256 heartsPaid,
        address indexed liquidator
    );
    event SetupFinalized();
    event RegisteredVaultsEnabledSet(bool enabled);
    event BadDebtSocialized(uint256 indexed vaultId, uint256 amount);

    modifier onlyDeployer() {
        if (msg.sender != deployer) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Unauthorized();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        address hexContract_,
        address dtsc_,
        address valuation_,
        address recovery_,
        address penaltyRouter_
    ) {
        if (block.chainid == A.CHAIN_ID && hexContract_ != A.PHEX) {
            revert UnsupportedHexToken();
        }
        hexContract = IHEX(hexContract_);
        dtsc = DTSC(dtsc_);
        valuation = TShareValuation(valuation_);
        recovery = RecoveryModule(recovery_);
        penaltyRouter = PenaltyRouter(penaltyRouter_);
        deployer = msg.sender;
    }

    function setRegisteredVaultsEnabled(bool enabled) external onlyDeployer {
        registeredVaultsEnabled = enabled;
        emit RegisteredVaultsEnabledSet(enabled);
    }

    function setRedemptionHandler(address handler) external onlyDeployer {
        require(redemptionHandler == address(0) && handler != address(0), "set once");
        redemptionHandler = handler;
    }

    function setStabilityPool(address pool) external onlyDeployer {
        require(address(stabilityPool) == address(0) && pool != address(0), "set once");
        stabilityPool = StabilityPool(pool);
    }

    function finalizeSetup() external onlyDeployer {
        require(redemptionHandler != address(0) && address(stabilityPool) != address(0), "incomplete");
        deployer = address(0);
        emit SetupFinalized();
    }

    function applyRedemption(uint256 vaultId, uint256 dtscAmount, address redeemer)
        external
        nonReentrant
        returns (uint256 applied, uint256 heartsPaid)
    {
        if (msg.sender != redemptionHandler) revert Unauthorized();
        Vault storage v = vaults[vaultId];
        if (!_isRedeemable(vaultId, v)) return (0, 0);

        applied = dtscAmount > v.debtDtsc ? v.debtDtsc : dtscAmount;
        if (applied == 0) return (0, 0);

        uint256 debtBefore = v.debtDtsc;
        v.debtDtsc -= applied;
        totalDebtDtsc -= applied;

        heartsPaid = _extractHeartsFromCustodialStake(vaultId, v, _heartsForUsd(applied), redeemer);
        if (heartsPaid == 0) {
            v.debtDtsc = debtBefore;
            totalDebtDtsc += applied;
            revert InsufficientCollateral();
        }

        _refreshVaultValue(vaultId, false);
        _recomputeCrCache();

        recovery.updateTotals(totalCollateralValueUsd, totalDebtDtsc);
        emit RedemptionApplied(vaultId, applied, heartsPaid, redeemer);
    }

    function _stakeKey(address owner, uint40 stakeId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, stakeId));
    }

    function _stakeOwner(Vault storage v) internal view returns (address) {
        return v.mode == CollateralMode.Custodial ? address(this) : v.owner;
    }

    function _clearStakeKey(Vault storage v) internal {
        delete stakeKeyToVaultId[_stakeKey(_stakeOwner(v), v.stakeId)];
    }

    function _requirePhexCollateral() internal view {
        if (block.chainid == A.CHAIN_ID && address(hexContract) != A.PHEX) {
            revert UnsupportedHexToken();
        }
    }

    function openVaultWithExistingStake(uint256 stakeIndex) external returns (uint256 vaultId) {
        _requirePhexCollateral();
        if (!registeredVaultsEnabled) revert RegisteredVaultsDisabled();

        (uint40 stakeId,,,,,,) = hexContract.stakeLists(msg.sender, stakeIndex);

        bytes32 key = _stakeKey(msg.sender, stakeId);
        if (stakeKeyToVaultId[key] != 0) revert StakeAlreadyUsed();

        TShareValuation.Valuation memory val = valuation.calculateEffectiveValueForBorrow(msg.sender, stakeIndex);
        if (val.tier == TShareValuation.Tier.None) revert IneligibleStake();

        vaultId = _createVault(
            msg.sender,
            CollateralMode.Registered,
            stakeId,
            stakeIndex,
            val.effectiveValueUsd,
            val.minCollateralRatioBps
        );
        stakeKeyToVaultId[key] = vaultId;
    }

    function openVaultWithNewStake(uint256 heartsAmount, uint256 stakedDays)
        external
        nonReentrant
        returns (uint256 vaultId)
    {
        _requirePhexCollateral();
        if (heartsAmount == 0 || stakedDays < C.MIN_DAYS_REMAINING) revert IneligibleStake();

        uint256 countBefore = hexContract.stakeCount(address(this));
        require(hexContract.transferFrom(msg.sender, address(this), heartsAmount), "xfer");
        hexContract.startStake(heartsAmount, stakedDays);

        require(hexContract.stakeCount(address(this)) > countBefore, "stake fail");
        uint256 stakeIndex = hexContract.stakeCount(address(this)) - 1;

        (uint40 stakeId,,,,,,) = hexContract.stakeLists(address(this), stakeIndex);
        bytes32 key = _stakeKey(address(this), stakeId);
        if (stakeKeyToVaultId[key] != 0) revert StakeAlreadyUsed();

        TShareValuation.Valuation memory val =
            valuation.calculateEffectiveValueForBorrow(address(this), stakeIndex);

        vaultId = _createVault(
            msg.sender,
            CollateralMode.Custodial,
            stakeId,
            stakeIndex,
            val.effectiveValueUsd,
            val.minCollateralRatioBps
        );
        stakeKeyToVaultId[key] = vaultId;
        emit CustodialStakeCreated(vaultId, stakeId, heartsAmount);
    }

    function _createVault(
        address owner,
        CollateralMode mode,
        uint40 stakeId,
        uint256 stakeIndex,
        uint256 effectiveValueUsd,
        uint256 minCcrBps
    ) internal returns (uint256 vaultId) {
        vaultId = nextVaultId++;
        uint64 nowTs = uint64(block.timestamp);
        vaults[vaultId] = Vault({
            owner: owner,
            mode: mode,
            stakeId: stakeId,
            stakeIndex: stakeIndex,
            effectiveValueUsd: effectiveValueUsd,
            debtDtsc: 0,
            minCollateralRatioBps: minCcrBps,
            openedAt: nowTs,
            cooldownEndsAt: nowTs + uint64(C.COOLDOWN_DAYS * 1 days),
            active: true
        });
        vaultsByOwner[owner].push(vaultId);
        totalCollateralValueUsd += effectiveValueUsd;
        recovery.updateTotals(totalCollateralValueUsd, totalDebtDtsc);
        emit VaultOpened(vaultId, owner, stakeId, mode);
    }

    function mintDtsc(uint256 vaultId, uint256 amount) external {
        Vault storage v = vaults[vaultId];
        if (!v.active || v.owner != msg.sender) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp < v.cooldownEndsAt) revert CooldownActive();
        _requireSpCoverage(amount);

        _refreshVaultValue(vaultId, true);
        v = vaults[vaultId];

        if (v.effectiveValueUsd == 0) revert InsufficientCollateral();
        _requireMintAllowed();

        uint256 maxDebt = DTSCMath.mulDiv(v.effectiveValueUsd, C.BPS, v.minCollateralRatioBps);
        if (v.debtDtsc + amount > maxDebt) revert InsufficientCollateral();

        if (v.debtDtsc == 0) {
            redemptionEligibleAt[vaultId] = uint64(block.timestamp + C.REDEMPTION_GRACE_PERIOD);
        }

        v.debtDtsc += amount;
        totalDebtDtsc += amount;
        recovery.updateTotals(totalCollateralValueUsd, totalDebtDtsc);
        _recomputeCrCache();
        dtsc.mint(msg.sender, amount);
        emit DebtMinted(vaultId, amount, v.debtDtsc);
    }

    function repayDtsc(uint256 vaultId, uint256 amount) external {
        Vault storage v = vaults[vaultId];
        if (!v.active || v.owner != msg.sender) revert Unauthorized();
        if (amount == 0 || amount > v.debtDtsc) revert InvalidAmount();

        dtsc.burnFrom(msg.sender, amount);
        v.debtDtsc -= amount;
        totalDebtDtsc -= amount;
        recovery.updateTotals(totalCollateralValueUsd, totalDebtDtsc);
        _recomputeCrCache();
        emit DebtRepaid(vaultId, amount, v.debtDtsc);
    }

    function closeVault(uint256 vaultId) external nonReentrant {
        Vault storage v = vaults[vaultId];
        if (!v.active || v.owner != msg.sender) revert Unauthorized();
        if (v.debtDtsc != 0) revert InsufficientCollateral();

        if (v.mode == CollateralMode.Custodial) {
            _returnFullCustodialStake(vaultId, v);
        }

        v.active = false;
        totalCollateralValueUsd -= v.effectiveValueUsd;
        _clearStakeKey(v);
        recovery.updateTotals(totalCollateralValueUsd, totalDebtDtsc);
        _recomputeCrCache();
        emit VaultClosed(vaultId);
    }

    function reportEarlyUnstake(uint256 vaultId) external nonReentrant {
        Vault storage v = vaults[vaultId];
        if (!v.active) revert VaultNotActive();

        address stakeOwner = _stakeOwner(v);
        if (_stakeExists(stakeOwner, v.stakeId, v.stakeIndex)) revert IneligibleStake();

        uint256 offset = 0;
        uint256 debtBefore = v.debtDtsc;
        if (debtBefore > 0 && address(stabilityPool) != address(0)) {
            offset = stabilityPool.offsetDebt(debtBefore);
            v.debtDtsc -= offset;
            totalDebtDtsc -= offset;
        }

        uint256 residual = v.debtDtsc;
        if (residual > 0) {
            recovery.recordBadDebt(residual);
            totalDebtDtsc -= residual;
            v.debtDtsc = 0;
            emit BadDebtSocialized(vaultId, residual);
        }

        v.active = false;
        totalCollateralValueUsd -= v.effectiveValueUsd;
        _clearStakeKey(v);
        recovery.updateTotals(totalCollateralValueUsd, totalDebtDtsc);
        _recomputeCrCache();
        emit EarlyUnstakeReported(vaultId, msg.sender, offset);
    }

    function liquidate(uint256 vaultId, uint256 maxDtscToCover)
        external
        nonReentrant
        returns (uint256 dtscBurned, uint256 heartsPaid)
    {
        Vault storage v = vaults[vaultId];
        if (!v.active) revert VaultNotActive();
        if (v.mode == CollateralMode.Registered) revert RegisteredLiquidationDisabled();

        _refreshVaultValue(vaultId, false);
        v = vaults[vaultId];

        if (v.debtDtsc == 0) revert InsufficientCollateral();

        uint256 cr = DTSCMath.mulDiv(v.effectiveValueUsd, C.BPS, v.debtDtsc);
        if (cr >= v.minCollateralRatioBps) revert InsufficientCollateral();

        uint256 spOffset = 0;
        if (address(stabilityPool) != address(0)) {
            spOffset = stabilityPool.offsetDebt(v.debtDtsc);
            v.debtDtsc -= spOffset;
            totalDebtDtsc -= spOffset;
        }

        uint256 debtRemaining = v.debtDtsc;
        dtscBurned = maxDtscToCover > debtRemaining ? debtRemaining : maxDtscToCover;

        if (dtscBurned > 0) {
            dtsc.burnFrom(msg.sender, dtscBurned);
            v.debtDtsc = debtRemaining - dtscBurned;
            totalDebtDtsc -= dtscBurned;

            if (v.mode == CollateralMode.Custodial) {
                uint256 bonusDtsc = DTSCMath.bpsApply(dtscBurned, C.LIQUIDATION_BONUS_BPS);
                uint256 claimUsd = dtscBurned + bonusDtsc;
                heartsPaid = _extractHeartsFromCustodialStake(vaultId, v, _heartsForUsd(claimUsd), msg.sender);
                _refreshVaultValue(vaultId, false);
            }
        }

        if (v.debtDtsc == 0) {
            v.active = false;
            totalCollateralValueUsd -= v.effectiveValueUsd;
            _clearStakeKey(v);
        }

        recovery.updateTotals(totalCollateralValueUsd, totalDebtDtsc);
        _recomputeCrCache();
        emit Liquidated(vaultId, dtscBurned, spOffset, heartsPaid, msg.sender);
    }

    function refreshVault(uint256 vaultId) external {
        _refreshVaultValue(vaultId, false);
    }

    function _requireMintAllowed() internal view {
        if (recovery.isRecoveryMode()) revert RecoveryModeRestriction();
        if (recovery.unbackedDebtBlocksMint()) revert UnbackedDebtRestriction();
    }

    function _requireSpCoverage(uint256 additionalDebt) internal view {
        if (address(stabilityPool) == address(0)) return;
        uint256 spDeposits = stabilityPool.totalDeposits();
        uint256 required = C.MIN_SP_COVERAGE_DTSC;
        uint256 debtAfter = totalDebtDtsc + additionalDebt;
        if (debtAfter > 0) {
            uint256 ratioReq = DTSCMath.mulDiv(debtAfter, C.MIN_SP_DEBT_COVERAGE_BPS, C.BPS);
            if (ratioReq > required) required = ratioReq;
        }
        if (spDeposits < required) revert InsufficientSpCoverage();
    }

    function _heartsForUsd(uint256 usdAmount) internal view returns (uint256) {
        uint256 hexPrice = valuation.hexPrice();
        return DTSCMath.mulDiv(usdAmount, C.HEARTS_PER_HEX, hexPrice);
    }

    /// @dev Uses actual HEX payout after endStake (EES penalty aware on mainnet)
    function _endStakePayout(address stakeOwner, uint256 idx, uint40 stakeId) internal returns (uint256 payout) {
        uint256 balBefore = hexContract.balanceOf(stakeOwner);
        hexContract.endStake(idx, stakeId);
        payout = hexContract.balanceOf(stakeOwner) - balBefore;
    }

    function _extractHeartsFromCustodialStake(
        uint256 vaultId,
        Vault storage v,
        uint256 heartsNeeded,
        address recipient
    ) internal returns (uint256 heartsPaid) {
        if (heartsNeeded == 0) return 0;

        address stakeOwner = address(this);
        uint256 idx = _syncStakeIndex(stakeOwner, v.stakeId, v.stakeIndex);
        (uint40 stakeId,,,, uint16 stakedDays,,) = hexContract.stakeLists(stakeOwner, idx);

        uint256 payout = _endStakePayout(stakeOwner, idx, stakeId);
        if (payout == 0) return 0;

        heartsPaid = heartsNeeded < payout ? heartsNeeded : payout;
        if (!hexContract.transfer(recipient, heartsPaid)) revert HexTransferFailed();

        uint256 remaining = payout - heartsPaid;
        if (remaining > 0) {
            hexContract.startStake(remaining, stakedDays);
            uint256 newIdx = hexContract.stakeCount(stakeOwner) - 1;
            (uint40 newId,,,,,,) = hexContract.stakeLists(stakeOwner, newIdx);
            _clearStakeKey(v);
            v.stakeId = newId;
            v.stakeIndex = newIdx;
            stakeKeyToVaultId[_stakeKey(stakeOwner, newId)] = vaultId;
        }
    }

    function _returnFullCustodialStake(uint256 vaultId, Vault storage v) internal {
        address stakeOwner = address(this);
        uint256 idx = _syncStakeIndex(stakeOwner, v.stakeId, v.stakeIndex);
        (uint40 stakeId,,,,,,) = hexContract.stakeLists(stakeOwner, idx);

        uint256 payout = _endStakePayout(stakeOwner, idx, stakeId);
        if (payout == 0) revert HexTransferFailed();
        if (!hexContract.transfer(v.owner, payout)) revert HexTransferFailed();
        _clearStakeKey(v);
        v.stakeId = 0;
        v.stakeIndex = 0;
        vaultId;
    }

    function _refreshVaultValue(uint256 vaultId, bool forBorrow) internal {
        Vault storage v = vaults[vaultId];
        if (!v.active) revert VaultNotActive();

        address stakeOwner = _stakeOwner(v);
        (uint256 newEv, uint256 newCcr, bool found) = forBorrow
            ? valuation.effectiveValueSafeForBorrow(stakeOwner, v.stakeId, v.stakeIndex)
            : valuation.effectiveValueSafe(stakeOwner, v.stakeId, v.stakeIndex);

        if (!found) {
            newEv = 0;
        } else if (newEv > 0) {
            v.stakeIndex = _syncStakeIndex(stakeOwner, v.stakeId, v.stakeIndex);
        }

        totalCollateralValueUsd = totalCollateralValueUsd + newEv - v.effectiveValueUsd;
        v.effectiveValueUsd = newEv;
        if (newCcr > 0) v.minCollateralRatioBps = newCcr;
        recovery.updateTotals(totalCollateralValueUsd, totalDebtDtsc);
        _recomputeCrCache();
    }

    function _isRedeemable(uint256 vaultId, Vault memory v) internal view returns (bool) {
        if (!v.active || v.debtDtsc == 0 || v.mode != CollateralMode.Custodial) return false;
        uint256 cr = DTSCMath.mulDiv(v.effectiveValueUsd, C.BPS, v.debtDtsc);
        return RedemptionPolicy.isEligible(cr, v.minCollateralRatioBps, redemptionEligibleAt[vaultId], block.timestamp);
    }

    function isVaultRedeemable(uint256 vaultId) external view returns (bool) {
        return _isRedeemable(vaultId, vaults[vaultId]);
    }

    function redemptionFeeBpsForVault(uint256 vaultId) external view returns (uint256 feeBps) {
        Vault memory v = vaults[vaultId];
        if (v.debtDtsc == 0) return C.REDEMPTION_FEE_HIGH_BPS;
        uint256 cr = DTSCMath.mulDiv(v.effectiveValueUsd, C.BPS, v.debtDtsc);
        return RedemptionPolicy.feeBpsForCr(cr, v.minCollateralRatioBps);
    }

    function _syncStakeIndex(address owner, uint40 stakeId, uint256 hint)
        internal
        view
        returns (uint256)
    {
        uint256 count = hexContract.stakeCount(owner);
        if (hint < count) {
            (uint40 id,,,,,,) = hexContract.stakeLists(owner, hint);
            if (id == stakeId) return hint;
        }
        for (uint256 i = 0; i < count; i++) {
            (uint40 id,,,,,,) = hexContract.stakeLists(owner, i);
            if (id == stakeId) return i;
        }
        return hint;
    }

    function _stakeExists(address owner, uint40 stakeId, uint256 stakeIndex) internal view returns (bool) {
        uint256 count = hexContract.stakeCount(owner);
        if (stakeIndex < count) {
            (uint40 id,,,,,,) = hexContract.stakeLists(owner, stakeIndex);
            if (id == stakeId) return true;
        }
        for (uint256 i = 0; i < count; i++) {
            (uint40 id,,,,,,) = hexContract.stakeLists(owner, i);
            if (id == stakeId) return true;
        }
        return false;
    }

    function getVaultCollateralRatio(uint256 vaultId) external view returns (uint256 crBps) {
        Vault memory v = vaults[vaultId];
        if (v.debtDtsc == 0) return type(uint256).max;
        return DTSCMath.mulDiv(v.effectiveValueUsd, C.BPS, v.debtDtsc);
    }

    function findLowestCrActiveVault() external view returns (uint256 vaultId, uint256 crBps) {
        if (crCacheValid && cachedLowestCrVaultId != 0) {
            Vault memory cached = vaults[cachedLowestCrVaultId];
            if (_isRedeemable(cachedLowestCrVaultId, cached)) {
                return (cachedLowestCrVaultId, cachedLowestCrBps);
            }
        }
        return _scanLowestCr();
    }

    function _scanLowestCr() internal view returns (uint256 vaultId, uint256 crBps) {
        crBps = type(uint256).max;
        uint256 cursor = nextVaultId;
        for (uint256 i = 1; i < cursor; i++) {
            Vault memory v = vaults[i];
            if (!_isRedeemable(i, v)) continue;
            uint256 cr = DTSCMath.mulDiv(v.effectiveValueUsd, C.BPS, v.debtDtsc);
            if (cr < crBps) {
                crBps = cr;
                vaultId = i;
            }
        }
    }

    function _recomputeCrCache() internal {
        (uint256 id, uint256 cr) = _scanLowestCr();
        cachedLowestCrVaultId = id;
        cachedLowestCrBps = cr == type(uint256).max ? 0 : cr;
        crCacheValid = id != 0;
    }

    function getOwnerVaults(address owner) external view returns (uint256[] memory) {
        return vaultsByOwner[owner];
    }

    function getVault(uint256 vaultId) external view returns (Vault memory) {
        return vaults[vaultId];
    }
}