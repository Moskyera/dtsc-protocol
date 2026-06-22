// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TwapRingBuffer — Uniswap V2-style cumulative price ring for TWAP
/// @dev Stores up to 8 observations; TWAP uses the oldest sample within the lookback window
library TwapRingBuffer {
    struct Observation {
        uint32 timestamp;
        uint224 priceCumulative;
    }

    struct Store {
        Observation[8] observations;
        uint8 count;
        uint8 index;
    }

    uint8 internal constant CAPACITY = 8;

    function record(Store storage self, uint32 timestamp, uint256 priceCumulative) internal {
        uint8 next = self.index;
        self.observations[next] =
            Observation({timestamp: timestamp, priceCumulative: uint224(priceCumulative)});
        self.index = (next + 1) % CAPACITY;
        if (self.count < CAPACITY) self.count++;
    }

    /// @notice TWAP from oldest in-window observation to current cumulative
    function twap(
        Store storage self,
        uint32 currentTimestamp,
        uint256 currentCumulative,
        uint32 lookbackPeriod
    ) internal view returns (uint256 elapsed, uint256 cumulativeDelta) {
        if (self.count == 0 || currentTimestamp == 0) return (0, 0);

        uint32 target = currentTimestamp > lookbackPeriod ? currentTimestamp - lookbackPeriod : 0;

        Observation memory anchor;
        bool found;
        bool foundInWindow;

        for (uint8 i = 0; i < self.count; i++) {
            Observation memory obs = self.observations[i];
            if (obs.timestamp == 0 || obs.timestamp > currentTimestamp) continue;

            if (obs.timestamp >= target) {
                if (!foundInWindow || obs.timestamp < anchor.timestamp) {
                    anchor = obs;
                    foundInWindow = true;
                    found = true;
                }
            } else if (!foundInWindow) {
                if (!found || obs.timestamp < anchor.timestamp) {
                    anchor = obs;
                    found = true;
                }
            }
        }

        if (!found || anchor.timestamp >= currentTimestamp) return (0, 0);

        elapsed = currentTimestamp - anchor.timestamp;
        if (elapsed < lookbackPeriod / 2) return (0, 0);

        if (currentCumulative < uint256(anchor.priceCumulative)) return (0, 0);
        cumulativeDelta = currentCumulative - uint256(anchor.priceCumulative);
    }

    function oldestTimestamp(Store storage self) internal view returns (uint32) {
        if (self.count == 0) return 0;
        uint32 oldestTs = type(uint32).max;
        for (uint8 i = 0; i < self.count; i++) {
            uint32 ts = self.observations[i].timestamp;
            if (ts != 0 && ts < oldestTs) oldestTs = ts;
        }
        return oldestTs == type(uint32).max ? 0 : oldestTs;
    }
}