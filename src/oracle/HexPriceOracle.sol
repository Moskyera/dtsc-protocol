// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPulseXPair} from "../interfaces/IPulseXPair.sol";
import {IHexPriceOracle} from "./IHexPriceOracle.sol";
import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {DTSCMath} from "../libraries/DTSCMath.sol";
import {TwapRingBuffer} from "../libraries/TwapRingBuffer.sol";

/// @title HexPriceOracle — Single PulseX pair conservative HEX/USD feed
/// @notice Uses min(TWAP, spot) with decimal-aware pricing, liquidity floor, and staleness guard
/// @dev TWAP uses an 8-slot observation ring spanning at least TWAP_PERIOD/2
contract HexPriceOracle is IHexPriceOracle {
    error OracleStale();
    error InvalidPair();
    error InsufficientLiquidity();
    error TwapInsufficientHistory();

    address public immutable hexToken;
    uint8 public immutable hexDecimals;
    address public immutable quoteToken;
    uint8 public immutable quoteDecimals;
    IPulseXPair public immutable pair;

    uint256 public immutable minHexReserve;
    uint256 public immutable minQuoteReserve;

    TwapRingBuffer.Store private _twapStore;

    uint32 public lastUpdateTimestamp;

    uint256 public lastTwapPrice;
    uint256 public lastSpotPrice;

    constructor(
        address hexToken_,
        uint8 hexDecimals_,
        address quoteToken_,
        uint8 quoteDecimals_,
        address pair_,
        uint256 minHexReserve_,
        uint256 minQuoteReserve_
    ) {
        if (hexToken_ == address(0) || quoteToken_ == address(0) || pair_ == address(0)) {
            revert InvalidPair();
        }
        hexToken = hexToken_;
        hexDecimals = hexDecimals_;
        quoteToken = quoteToken_;
        quoteDecimals = quoteDecimals_;
        pair = IPulseXPair(pair_);
        minHexReserve = minHexReserve_;
        minQuoteReserve = minQuoteReserve_;

        address token0 = pair.token0();
        if (token0 != hexToken_ && token0 != quoteToken_) revert InvalidPair();
    }

    function update() external {
        _recordObservation();
    }

    function getPrice() external view returns (uint256 priceUsd18) {
        _requireFresh();
        _requireLiquidity();
        (uint256 twap, uint256 spot) = _previewPrices();
        priceUsd18 = twap < spot ? twap : spot;
        if (priceUsd18 == 0) revert InsufficientLiquidity();
    }

    /// @inheritdoc IHexPriceOracle
    /// @dev H-08: Ignores spot when TWAP is available — mitigates same-block DEX pump on mint
    function getCollateralPrice() external view returns (uint256 priceUsd18) {
        _requireFresh();
        _requireLiquidity();
        priceUsd18 = _borrowTwapPrice();
        // Same-block reads: cumulative unchanged → use last full-window TWAP from update()
        if (priceUsd18 == 0 && lastTwapPrice > 0) priceUsd18 = lastTwapPrice;
        if (priceUsd18 == 0) revert TwapInsufficientHistory();
    }

    /// @notice True when borrow path has a full TWAP window (24h) of observations
    function twapReadyForBorrow() external view returns (bool) {
        _requireFresh();
        return _borrowTwapPrice() > 0 || lastTwapPrice > 0;
    }

    function getTwapAndSpot() external view returns (uint256 twapUsd18, uint256 spotUsd18) {
        _requireFresh();
        _requireLiquidity();
        return _previewPrices();
    }

    function observationCount() external view returns (uint8) {
        return _twapStore.count;
    }

    function _requireFresh() internal view {
        if (lastUpdateTimestamp == 0) revert OracleStale();
        if (block.timestamp > uint256(lastUpdateTimestamp) + C.ORACLE_MAX_STALENESS) {
            revert OracleStale();
        }
    }

    function _requireLiquidity() internal view {
        (uint256 hexReserve, uint256 quoteReserve) = _reserves();
        if (hexReserve < minHexReserve || quoteReserve < minQuoteReserve) {
            revert InsufficientLiquidity();
        }
    }

    function _reserves() internal view returns (uint256 hexReserve, uint256 quoteReserve) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool hexIsToken0 = pair.token0() == hexToken;
        hexReserve = hexIsToken0 ? uint256(r0) : uint256(r1);
        quoteReserve = hexIsToken0 ? uint256(r1) : uint256(r0);
    }

    function _previewPrices() internal view returns (uint256 twap, uint256 spot) {
        spot = _spotPrice();
        twap = _twapPrice();
        if (twap == 0) twap = spot;
    }

    function _recordObservation() internal {
        bool hexIsToken0 = pair.token0() == hexToken;
        uint256 cumulative = hexIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        uint32 nowTs = uint32(block.timestamp);

        TwapRingBuffer.record(_twapStore, nowTs, cumulative);
        lastUpdateTimestamp = nowTs;
        (lastTwapPrice, lastSpotPrice) = _previewPrices();
    }

    function _twapPrice() internal view returns (uint256) {
        (uint256 elapsed, uint256 delta) = _twapSample();
        if (elapsed == 0 || delta == 0) return 0;
        uint256 raw = DTSCMath.mulDiv(delta, 1, elapsed * 2 ** 112);
        return _toUsd18(raw);
    }

    /// @dev Full-window TWAP for borrow/mint — blocks multi-block spot pump paths
    function _borrowTwapPrice() internal view returns (uint256) {
        (uint256 elapsed, uint256 delta) = _twapSample();
        if (elapsed < C.BORROW_TWAP_MIN_ELAPSED || delta == 0) return 0;
        uint256 raw = DTSCMath.mulDiv(delta, 1, elapsed * 2 ** 112);
        return _toUsd18(raw);
    }

    function _twapSample() internal view returns (uint256 elapsed, uint256 delta) {
        bool hexIsToken0 = pair.token0() == hexToken;
        uint256 cumulativeNow = hexIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        uint32 nowTs = uint32(block.timestamp);
        return TwapRingBuffer.twap(_twapStore, nowTs, cumulativeNow, uint32(C.TWAP_PERIOD));
    }

    function _spotPrice() internal view returns (uint256) {
        (uint256 hexReserve, uint256 quoteReserve) = _reserves();
        return _quotePerHexUsd18(quoteReserve, hexReserve);
    }

    /// @dev TWAP raw ratio is quote smallest-units per hex smallest-unit
    function _toUsd18(uint256 quotePerHexRaw) internal view returns (uint256) {
        uint256 hexScale = 10 ** uint256(hexDecimals);
        uint256 quoteScale = 10 ** uint256(quoteDecimals);
        return DTSCMath.mulDiv(quotePerHexRaw, hexScale * C.PRICE_DECIMALS, quoteScale);
    }

    /// @dev Direct reserve ratio without intermediate truncation
    function _quotePerHexUsd18(uint256 quoteReserve, uint256 hexReserve) internal view returns (uint256) {
        if (hexReserve == 0) return 0;
        uint256 hexScale = 10 ** uint256(hexDecimals);
        uint256 quoteScale = 10 ** uint256(quoteDecimals);
        return DTSCMath.mulDiv(quoteReserve, hexScale * C.PRICE_DECIMALS, hexReserve * quoteScale);
    }
}