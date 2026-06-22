// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PulseChainAddresses — Verified mainnet constants (verify before deploy)
/// @notice DTSC collateral is **pHEX T-shares only** on PulseChain
library PulseChainAddresses {
    uint256 internal constant CHAIN_ID = 369;

    /// @dev pHEX — Native PulseChain HEX contract with on-chain staking (T-shares).
    ///      This is the ONLY token accepted as DTSC collateral.
    address internal constant PHEX = 0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;

    /// @dev Legacy alias — always means pHEX on PulseChain
    address internal constant HEX = PHEX;

    address internal constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address internal constant PLSX = 0x95B303987A60C71504D99Aa1b13B4DA07b0790ab;

    address internal constant PULSEX_ROUTER_V2 = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address internal constant PULSEX_FACTORY_V2 = 0x29eA7545DEf87022BAdc76323F373EA1e707C523;

    address internal constant BURN_ADDRESS = 0x0000000000000000000000000000000000000369;

    // Bridged USDC on PulseChain (6 decimals) — verify on scan before production deploy
    address internal constant USDC = 0x15d385733de979c37f0Faee32148d6804A0CEbBD;

    // PulseX V2 pairs (pHEX denominated) — verify liquidity on scan before immutable deploy
    address internal constant PHEX_USDC_PAIR = 0xC475332e92561CD58f278E4e2eD76c17D5b50f05;

    /// @dev Legacy alias
    address internal constant HEX_USDC_PAIR = PHEX_USDC_PAIR;
}