// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChainlinkFeed} from "../../src/oracle/IChainlinkFeed.sol";

/// @dev Mock Chainlink feed — answer in 8 decimals (USD per HEX)
contract MockChainlinkFeed is IChainlinkFeed {
    int256 public answer;
    uint256 public updatedAt;

    function setPrice8(uint256 price8) external {
        answer = int256(price8);
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer_, uint256, uint256 updatedAt_, uint80)
    {
        return (1, answer, block.timestamp, updatedAt, 1);
    }
}