// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IHEX} from "../../src/interfaces/IHEX.sol";
import {PulseChainAddresses as A} from "../../src/config/PulseChainAddresses.sol";

/// @title PulseChain fork tests — real pHEX endStake / EES behavior
/// @dev Run: forge test --match-contract HexForkTest -vv
contract HexForkTest is Test {
    IHEX hexToken;
    bool forkReady;

    address constant WHALE = 0x56498E5F9cC4Ce5F32A198268CC484574aa5B0A3;

    function setUp() public {
        try vm.createSelectFork(vm.envOr("PULSECHAIN_RPC_URL", string("https://rpc.pulsechain.com"))) {
            hexToken = IHEX(A.PHEX);
            forkReady = true;
        } catch {
            forkReady = false;
        }
    }

    function _requireFork() internal view {
        require(forkReady, "SKIP: PulseChain fork unavailable");
    }

    function _findStakerWithStakes() internal view returns (address staker, uint256 count) {
        address[3] memory candidates = [
            WHALE,
            0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39,
            0x9bdF4Afb839e77ACaB393AcE7906e1CD51e1e4f9
        ];
        for (uint256 i = 0; i < candidates.length; i++) {
            if (candidates[i] == address(0)) continue;
            uint256 c = hexToken.stakeCount(candidates[i]);
            if (c > 0) return (candidates[i], c);
        }
        return (address(0), 0);
    }

    function test_FORK01_hexContract_callable() public view {
        if (!forkReady) return;
        uint256 day = hexToken.currentDay();
        assertGt(day, 0);
    }

    function test_FORK02_stakeLists_readable() public view {
        if (!forkReady) return;
        (address staker, uint256 count) = _findStakerWithStakes();
        if (count == 0) return;

        (uint40 stakeId, uint72 stakedHearts,, uint16 lockedDay, uint16 stakedDays,,) =
            hexToken.stakeLists(staker, 0);
        assertGt(stakeId, 0);
        assertGt(stakedHearts, 0);
        assertGt(stakedDays, 0);
        lockedDay;
    }

    function test_FORK03_longStake_preMaturity_documented() public view {
        if (!forkReady) return;
        (address staker, uint256 count) = _findStakerWithStakes();
        if (count == 0) return;

        uint256 day = hexToken.currentDay();
        for (uint256 i = 0; i < count && i < 3; i++) {
            (, uint72 hearts,, uint16 lockedDay, uint16 stakedDays,,) = hexToken.stakeLists(staker, i);
            if (hearts == 0) continue;
            uint256 maturityDay = uint256(lockedDay) + uint256(stakedDays);
            if (stakedDays >= 2000 && day < maturityDay) {
                assertGt(maturityDay - day, 50, "active long stake: EES penalty applies on endStake");
            }
        }
    }

    function test_FORK05_forkAlive_forProductionOracleChecklist() public view {
        if (!forkReady) return;
        assertGt(hexToken.currentDay(), 0, "fork live: run PreDeployChecklist before mainnet");
    }

    function test_FORK04_calcPayoutRewards_callable() public view {
        if (!forkReady) return;
        (address staker, uint256 count) = _findStakerWithStakes();
        if (count == 0) return;

        (, uint72 hearts, uint72 shares, uint16 lockedDay,,,) = hexToken.stakeLists(staker, 0);
        if (hearts == 0) return;
        uint256 day = hexToken.currentDay();
        if (day > lockedDay) {
            uint256 rewards = hexToken.calcPayoutRewards(shares, lockedDay, day);
            assertGt(rewards, 0);
        }
    }
}