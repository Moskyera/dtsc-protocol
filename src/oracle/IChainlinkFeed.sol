// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChainlinkFeed — Future Chainlink redundancy for HEX/USD (Phase 2+)
/// @notice Not wired in v1 — documented for external audit scope and post-launch upgrade path
interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}