// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHexPriceOracle} from "./IHexPriceOracle.sol";
import {IChainlinkFeed} from "./IChainlinkFeed.sol";
import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {DTSCMath} from "../libraries/DTSCMath.sol";

/// @title HexPriceAggregator — Multi-source conservative HEX/USD oracle
/// @notice Returns the minimum valid price across:
///         1) HEX/USDC direct PulseX pair (true USD when USDC ~= $1)
///         2) HEX/WPLS * WPLS/USDC synthetic cross-rate
/// @dev Designed for long-term peg integrity: never overvalue collateral.
///      Direct USDC path is dropped when it deviates >5% from cross-rate (depeg or thin-pool pump).
contract HexPriceAggregator is IHexPriceOracle {
    error NoValidPriceSource();

    IHexPriceOracle public immutable hexUsdcOracle;
    IHexPriceOracle public immutable hexWplsOracle;
    IHexPriceOracle public immutable wplsUsdcOracle;
    IChainlinkFeed public immutable chainlinkFeed;

    uint32 public lastUpdateTimestamp;

    event PriceAggregated(uint256 priceUsd18, bool usedUsdcDirect, bool usedWplsCross);
    event UsdcPathRejected(uint256 directUsd18, uint256 crossUsd18, string reason);

    constructor(
        address hexUsdcOracle_,
        address hexWplsOracle_,
        address wplsUsdcOracle_,
        address chainlinkFeed_
    ) {
        hexUsdcOracle = IHexPriceOracle(hexUsdcOracle_);
        hexWplsOracle = IHexPriceOracle(hexWplsOracle_);
        wplsUsdcOracle = IHexPriceOracle(wplsUsdcOracle_);
        chainlinkFeed = IChainlinkFeed(chainlinkFeed_);
        if (address(hexWplsOracle) == address(0)) revert NoValidPriceSource();
    }

    function update() external {
        if (address(hexUsdcOracle) != address(0)) {
            hexUsdcOracle.update();
        }
        hexWplsOracle.update();
        if (address(wplsUsdcOracle) != address(0)) {
            wplsUsdcOracle.update();
        }
        lastUpdateTimestamp = uint32(block.timestamp);
    }

    function getPrice() external view returns (uint256 priceUsd18) {
        (priceUsd18,,) = _aggregate(false);
    }

    function getCollateralPrice() external view returns (uint256 priceUsd18) {
        (priceUsd18,,) = _aggregate(true);
    }

    function getTwapAndSpot() external view returns (uint256 twapUsd18, uint256 spotUsd18) {
        twapUsd18 = type(uint256).max;
        spotUsd18 = type(uint256).max;
        (twapUsd18, spotUsd18) = _accumulateTwapSpot(address(hexWplsOracle), twapUsd18, spotUsd18);
        if (address(hexUsdcOracle) != address(0)) {
            (twapUsd18, spotUsd18) = _accumulateTwapSpot(address(hexUsdcOracle), twapUsd18, spotUsd18);
        }
        if (twapUsd18 == type(uint256).max) revert NoValidPriceSource();
        if (spotUsd18 == type(uint256).max) spotUsd18 = twapUsd18;
    }

    function _accumulateTwapSpot(address oracle, uint256 minTwap, uint256 minSpot)
        internal
        view
        returns (uint256 twapUsd18, uint256 spotUsd18)
    {
        twapUsd18 = minTwap;
        spotUsd18 = minSpot;
        (uint256 t, uint256 s) = IHexPriceOracle(oracle).getTwapAndSpot();
        if (t > 0 && t < twapUsd18) twapUsd18 = t;
        if (s > 0 && s < spotUsd18) spotUsd18 = s;
    }

    function _aggregate(bool collateralMode)
        internal
        view
        returns (uint256 minPrice, bool usedUsdcDirect, bool usedWplsCross)
    {
        minPrice = type(uint256).max;

        uint256 cross = _crossRate(collateralMode);

        if (address(hexUsdcOracle) != address(0)) {
            uint256 direct = _safePrice(hexUsdcOracle, collateralMode);
            if (direct > 0) {
                bool acceptDirect = _usdcPathValid(direct, cross);
                if (acceptDirect && direct < minPrice) {
                    minPrice = direct;
                    usedUsdcDirect = true;
                }
            }
        }

        if (cross > 0) {
            usedWplsCross = address(wplsUsdcOracle) != address(0);
            if (cross < minPrice) {
                minPrice = cross;
            }
        }

        uint256 chainlink = _chainlinkUsd18();
        if (chainlink > 0 && chainlink < minPrice) {
            minPrice = chainlink;
        }

        if (minPrice == type(uint256).max) revert NoValidPriceSource();
    }

    function _chainlinkUsd18() internal view returns (uint256 priceUsd18) {
        if (address(chainlinkFeed) == address(0)) return 0;
        try chainlinkFeed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (answer <= 0) return 0;
            if (block.timestamp > updatedAt + C.CHAINLINK_MAX_STALENESS) return 0;
            priceUsd18 = uint256(answer) * 1e10;
        } catch {
            return 0;
        }
    }

    function _crossRate(bool collateralMode) internal view returns (uint256 cross) {
        uint256 hexWpls = _safePrice(hexWplsOracle, collateralMode);
        if (hexWpls == 0) return 0;

        cross = hexWpls;
        if (address(wplsUsdcOracle) != address(0)) {
            uint256 wplsUsd = _safePrice(wplsUsdcOracle, collateralMode);
            if (wplsUsd > 0) {
                cross = DTSCMath.mulDiv(hexWpls, wplsUsd, 1e18);
            }
        }
    }

    function _usdcPathValid(uint256 direct, uint256 cross) internal pure returns (bool) {
        if (cross == 0) return true;

        uint256 depegFloor = DTSCMath.mulDiv(cross, C.USDC_DEPEG_TOLERANCE_BPS, C.BPS);
        if (direct < depegFloor) return false;

        uint256 premiumCeil = DTSCMath.mulDiv(cross, C.USDC_PREMIUM_TOLERANCE_BPS, C.BPS);
        if (direct > premiumCeil) return false;

        return true;
    }

    function _safePrice(IHexPriceOracle oracle, bool collateralMode) internal view returns (uint256 price) {
        if (collateralMode) {
            try oracle.getCollateralPrice() returns (uint256 p) {
                return p;
            } catch {
                return 0;
            }
        }
        try oracle.getPrice() returns (uint256 p) {
            return p;
        } catch {
            return 0;
        }
    }
}