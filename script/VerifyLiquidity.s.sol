// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPulseXPair} from "../src/interfaces/IPulseXPair.sol";
import {IPulseXFactory} from "../src/interfaces/IPulseXFactory.sol";
import {PulseChainAddresses as A} from "../src/config/PulseChainAddresses.sol";
import {DTSCConstants as C} from "../src/libraries/DTSCConstants.sol";

/// @notice Pre-deploy liquidity verification for pHEX oracle pairs on PulseChain
/// @dev Run on PulseChain fork or mainnet: forge script script/VerifyLiquidity.s.sol --rpc-url $PULSE_RPC
contract VerifyLiquidity is Script {
    struct PairReport {
        string label;
        address pair;
        uint256 hexReserve;
        uint256 quoteReserve;
        bool hexOk;
        bool quoteOk;
    }

    function run() external view {
        require(block.chainid == A.CHAIN_ID, "run on PulseChain (chain 369)");

        console2.log("=== DTSC Oracle Liquidity Check (pHEX only) ===");
        console2.log("pHEX:", A.PHEX);
        console2.log("MIN_HEX_RESERVE:", C.MIN_HEX_RESERVE_HEARTS);
        console2.log("MIN_USDC_RESERVE:", C.MIN_QUOTE_RESERVE_USDC);
        console2.log("MIN_WPLS_RESERVE:", C.MIN_QUOTE_RESERVE_WPLS);

        IPulseXFactory factory = IPulseXFactory(A.PULSEX_FACTORY_V2);

        _checkPair(
            "HEX/WPLS",
            factory.getPair(A.PHEX, A.WPLS),
            A.PHEX,
            A.WPLS,
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_WPLS
        );

        _checkPair(
            "HEX/USDC",
            factory.getPair(A.PHEX, A.USDC),
            A.PHEX,
            A.USDC,
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_USDC
        );

        _checkPair(
            "WPLS/USDC",
            factory.getPair(A.WPLS, A.USDC),
            A.WPLS,
            A.USDC,
            C.MIN_QUOTE_RESERVE_WPLS,
            C.MIN_QUOTE_RESERVE_USDC
        );

    }

    function _checkPair(
        string memory label,
        address pairAddr,
        address tokenA,
        address tokenB,
        uint256 minA,
        uint256 minB
    ) internal view {
        if (pairAddr == address(0)) {
            console2.log(label, "pair: MISSING");
            return;
        }

        IPulseXPair pair = IPulseXPair(pairAddr);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        address t0 = pair.token0();

        uint256 reserveA = t0 == tokenA ? uint256(r0) : uint256(r1);
        uint256 reserveB = t0 == tokenA ? uint256(r1) : uint256(r0);

        bool aOk = reserveA >= minA;
        bool bOk = reserveB >= minB;

        console2.log(label, "pair:", pairAddr);
        console2.log("  reserveA:", reserveA, aOk ? "OK" : "LOW");
        console2.log("  reserveB:", reserveB, bOk ? "OK" : "LOW");

        if (!aOk || !bOk) {
            console2.log("  FAIL: below DTSC minimum liquidity");
        }
    }
}