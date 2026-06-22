// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHEX} from "../interfaces/IHEX.sol";
import {IHexPriceOracle} from "../oracle/IHexPriceOracle.sol";
import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {DTSCMath} from "../libraries/DTSCMath.sol";

/// @title TShareValuation — On-chain Effective Value (EV) for HEX T-shares
/// @dev EV = Principal×Price + EarnedRewards + LongBonus − TimeDiscount (conservative)
contract TShareValuation {
    enum Tier {
        None,
        MediumLong,
        Long
    }

    struct StakeSnapshot {
        uint40 stakeId;
        uint72 stakedHearts;
        uint72 stakeShares;
        uint16 lockedDay;
        uint16 stakedDays;
        uint16 unlockedDay;
        bool isAutoStake;
    }

    struct Valuation {
        uint256 effectiveValueUsd;
        uint256 principalValueUsd;
        uint256 earnedRewardsUsd;
        uint256 longBonusUsd;
        uint256 timeDiscountUsd;
        Tier tier;
        uint256 daysRemaining;
        uint256 minCollateralRatioBps;
    }

    error IneligibleStake();
    error StakeNotFound();

    IHEX public immutable hexContract;
    IHexPriceOracle public immutable priceOracle;

    constructor(address hexContract_, address priceOracle_) {
        hexContract = IHEX(hexContract_);
        priceOracle = IHexPriceOracle(priceOracle_);
    }

    function getStake(address owner, uint256 stakeIndex) public view returns (StakeSnapshot memory s) {
        (
            s.stakeId,
            s.stakedHearts,
            s.stakeShares,
            s.lockedDay,
            s.stakedDays,
            s.unlockedDay,
            s.isAutoStake
        ) = hexContract.stakeLists(owner, stakeIndex);
        if (s.stakeId == 0) revert StakeNotFound();
    }

    function getDaysRemaining(StakeSnapshot memory s) public view returns (uint256) {
        uint256 day = hexContract.currentDay();
        uint256 maturityDay = uint256(s.lockedDay) + uint256(s.stakedDays);
        if (day >= maturityDay) return 0;
        return maturityDay - day;
    }

    function getTier(uint256 daysRemaining) public pure returns (Tier tier, uint256 minCcrBps) {
        if (daysRemaining < C.MIN_DAYS_REMAINING) return (Tier.None, 0);
        if (daysRemaining >= C.TIER_LONG_MIN) return (Tier.Long, C.CCR_LONG_BPS);
        return (Tier.MediumLong, C.CCR_MEDIUM_BPS);
    }

    function earnedRewardsHearts(StakeSnapshot memory s) public view returns (uint256) {
        uint256 day = hexContract.currentDay();
        uint256 beginDay = uint256(s.lockedDay);
        if (day <= beginDay) return 0;
        return hexContract.calcPayoutRewards(uint256(s.stakeShares), beginDay, day);
    }

    function longBonusBps(uint256 daysRemaining) public pure returns (uint256) {
        if (daysRemaining >= C.TIER_LONG_MIN) {
            // 10%–15% linear between 4000 and 5555 days
            uint256 span = C.MAX_STAKE_DAYS - C.TIER_LONG_MIN;
            uint256 extra = daysRemaining - C.TIER_LONG_MIN;
            uint256 bonusRange = 500; // 10% to 15%
            return 1000 + DTSCMath.mulDiv(extra, bonusRange, span);
        }
        if (daysRemaining >= 3000) return 500; // 5%
        return 0;
    }

    function timeDiscountBps(uint256 daysRemaining) public pure returns (uint256) {
        if (daysRemaining >= C.TIER_LONG_MIN) return 0;
        // Linear 0% at 4000 days up to 15% at 2000 days
        uint256 range = C.TIER_LONG_MIN - C.TIER_MEDIUM_MIN;
        uint256 distance = C.TIER_LONG_MIN - daysRemaining;
        return DTSCMath.mulDiv(distance, C.MAX_TIME_DISCOUNT_BPS, range);
    }

    function calculateEffectiveValue(address owner, uint256 stakeIndex)
        external
        view
        returns (Valuation memory v)
    {
        StakeSnapshot memory s = getStake(owner, stakeIndex);
        return _calculate(s, false);
    }

    /// @notice Uses TWAP-only collateral price — for open vault / max borrow checks (H-08)
    function calculateEffectiveValueForBorrow(address owner, uint256 stakeIndex)
        external
        view
        returns (Valuation memory v)
    {
        StakeSnapshot memory s = getStake(owner, stakeIndex);
        return _calculate(s, true);
    }

    function calculateEffectiveValueFromStake(StakeSnapshot memory s)
        external
        view
        returns (Valuation memory v)
    {
        return _calculate(s, false);
    }

    function _calculate(StakeSnapshot memory s, bool forBorrow) internal view returns (Valuation memory v) {
        v.daysRemaining = getDaysRemaining(s);
        (v.tier, v.minCollateralRatioBps) = getTier(v.daysRemaining);
        if (v.tier == Tier.None) revert IneligibleStake();

        uint256 price = forBorrow ? priceOracle.getCollateralPrice() : priceOracle.getPrice();
        v.principalValueUsd = DTSCMath.mulDiv(uint256(s.stakedHearts), price, C.HEARTS_PER_HEX);
        uint256 earnedHearts = earnedRewardsHearts(s);
        v.earnedRewardsUsd = DTSCMath.mulDiv(earnedHearts, price, C.HEARTS_PER_HEX);

        uint256 subtotal = v.principalValueUsd + v.earnedRewardsUsd;
        v.longBonusUsd = DTSCMath.bpsApply(subtotal, longBonusBps(v.daysRemaining));
        v.timeDiscountUsd = DTSCMath.bpsApply(subtotal + v.longBonusUsd, timeDiscountBps(v.daysRemaining));

        v.effectiveValueUsd = subtotal + v.longBonusUsd;
        if (v.timeDiscountUsd > v.effectiveValueUsd) {
            v.effectiveValueUsd = 0;
        } else {
            v.effectiveValueUsd -= v.timeDiscountUsd;
        }

        uint256 cap = DTSCMath.bpsApply(v.principalValueUsd, C.EV_CAP_MULTIPLIER_BPS);
        if (v.effectiveValueUsd > cap) v.effectiveValueUsd = cap;
    }

    function hexPrice() external view returns (uint256) {
        return priceOracle.getPrice();
    }

    function maxBorrowable(address owner, uint256 stakeIndex, bool recoveryMode)
        external
        view
        returns (uint256 maxDtsc, Valuation memory v)
    {
        v = _calculate(getStake(owner, stakeIndex), true);
        uint256 ccr = recoveryMode ? C.CCR_RECOVERY_BPS : v.minCollateralRatioBps;
        maxDtsc = DTSCMath.mulDiv(v.effectiveValueUsd, C.BPS, ccr);
    }

    /// @notice Returns 0 EV if stake fell below eligibility (matured / short) without reverting
    function effectiveValueSafe(address owner, uint40 stakeId, uint256 hintIndex)
        external
        view
        returns (uint256 effectiveValueUsd, uint256 minCcrBps, bool found)
    {
        return effectiveValueSafe(owner, stakeId, hintIndex, false);
    }

    function effectiveValueSafeForBorrow(address owner, uint40 stakeId, uint256 hintIndex)
        external
        view
        returns (uint256 effectiveValueUsd, uint256 minCcrBps, bool found)
    {
        return effectiveValueSafe(owner, stakeId, hintIndex, true);
    }

    function effectiveValueSafe(address owner, uint40 stakeId, uint256 hintIndex, bool forBorrow)
        public
        view
        returns (uint256 effectiveValueUsd, uint256 minCcrBps, bool found)
    {
        uint256 idx = _findStakeIndex(owner, stakeId, hintIndex);
        if (idx == type(uint256).max) return (0, 0, false);

        StakeSnapshot memory s = getStake(owner, idx);
        uint256 daysRem = getDaysRemaining(s);
        if (daysRem < C.MIN_DAYS_REMAINING) return (0, 0, true);

        Valuation memory v = _calculate(s, forBorrow);
        return (v.effectiveValueUsd, v.minCollateralRatioBps, true);
    }

    function _findStakeIndex(address owner, uint40 stakeId, uint256 hintIndex)
        internal
        view
        returns (uint256)
    {
        uint256 count = hexContract.stakeCount(owner);
        if (hintIndex < count) {
            (uint40 id,,,,,,) = hexContract.stakeLists(owner, hintIndex);
            if (id == stakeId) return hintIndex;
        }
        for (uint256 i = 0; i < count; i++) {
            (uint40 id,,,,,,) = hexContract.stakeLists(owner, i);
            if (id == stakeId) return i;
        }
        return type(uint256).max;
    }
}