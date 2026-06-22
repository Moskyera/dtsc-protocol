// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHexPriceOracle — Conservative HEX/USD price feed interface
/// @notice Returns 18-decimal USD price per 1 whole HEX token (not per heart)
interface IHexPriceOracle {
    function update() external;
    /// @notice Conservative price: min(TWAP, spot) across sources
    function getPrice() external view returns (uint256 priceUsd18);
    /// @notice Borrow/collateral price: TWAP when available, spot only during bootstrap
    function getCollateralPrice() external view returns (uint256 priceUsd18);
    function getTwapAndSpot() external view returns (uint256 twapUsd18, uint256 spotUsd18);
    function lastUpdateTimestamp() external view returns (uint32);
}