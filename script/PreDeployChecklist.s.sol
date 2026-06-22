// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPulseXPair} from "../src/interfaces/IPulseXPair.sol";
import {IPulseXFactory} from "../src/interfaces/IPulseXFactory.sol";
import {IHexPriceOracle} from "../src/oracle/IHexPriceOracle.sol";
import {PulseChainAddresses as A} from "../src/config/PulseChainAddresses.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @notice Pre-launch checklist — run on PulseChain before enabling public mint
/// forge script script/PreDeployChecklist.s.sol --rpc-url $PULSECHAIN_RPC_URL
contract PreDeployChecklist is Script {
    function run() external view {
        require(block.chainid == A.CHAIN_ID, "run on PulseChain (369)");

        console2.log("=== DTSC Pre-Deploy Checklist ===");
        console2.log("DTSC token: NOT YET DEPLOYED (expected)");
        console2.log("Collateral: pHEX only at", A.PHEX);

        _checkPairs();
        _checkOracleFreshness();
        _printLaunchRequirements();
    }

    function _checkPairs() internal view {
        IPulseXFactory factory = IPulseXFactory(A.PULSEX_FACTORY_V2);
        address hexWpls = factory.getPair(A.PHEX, A.WPLS);
        address hexUsdc = factory.getPair(A.PHEX, A.USDC);
        address wplsUsdc = factory.getPair(A.WPLS, A.USDC);

        require(hexWpls != address(0), "CRITICAL: HEX/WPLS pair missing");
        _logPair("HEX/WPLS", hexWpls, A.PHEX, A.WPLS, C.MIN_HEX_RESERVE_HEARTS, C.MIN_QUOTE_RESERVE_WPLS);
        _logPair("HEX/USDC", hexUsdc, A.PHEX, A.USDC, C.MIN_HEX_RESERVE_HEARTS, C.MIN_QUOTE_RESERVE_USDC);
        _logPair("WPLS/USDC", wplsUsdc, A.WPLS, A.USDC, C.MIN_QUOTE_RESERVE_WPLS, C.MIN_QUOTE_RESERVE_USDC);
    }

    function _logPair(
        string memory label,
        address pairAddr,
        address tokenA,
        address tokenB,
        uint256 minA,
        uint256 minB
    ) internal view {
        if (pairAddr == address(0)) {
            console2.log(label, ": MISSING (optional for cross-rate)");
            return;
        }
        IPulseXPair pair = IPulseXPair(pairAddr);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        address t0 = pair.token0();
        uint256 a = t0 == tokenA ? uint256(r0) : uint256(r1);
        uint256 b = t0 == tokenA ? uint256(r1) : uint256(r0);
        console2.log(label, "pair:", pairAddr);
        console2.log("  reserveA:", a, a >= minA ? "OK" : "LOW");
        console2.log("  reserveB:", b, b >= minB ? "OK" : "LOW");
    }

    function _checkOracleFreshness() internal view {
        console2.log("Oracle freshness: verify keeper updates every", C.ORACLE_MAX_STALENESS, "seconds");
        console2.log("TWAP period:", C.TWAP_PERIOD, "seconds");
        console2.log("Mint uses getCollateralPrice() = TWAP when available (H-08)");
    }

    function _printLaunchRequirements() internal pure {
        console2.log("--- Launch requirements ---");
        console2.log("1. Seed Stability Pool >=", C.MIN_SP_COVERAGE_DTSC, "DTSC before public mint");
        console2.log("2. Prime oracles (update every <2h via keeper)");
        console2.log("3. External audits complete (see docs/AUDIT_PACKAGE.md)");
        console2.log("4. Bug bounty live (see docs/BUG_BOUNTY.md)");
        console2.log("5. User approval before immutable deploy");
    }
}