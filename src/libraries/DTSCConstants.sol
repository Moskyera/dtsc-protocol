// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DTSCConstants — Immutable protocol parameters
library DTSCConstants {
    uint256 internal constant HEARTS_PER_HEX = 1e8;
    uint256 internal constant HEX_TOKEN_DECIMALS = 8;
    uint256 internal constant USDC_DECIMALS = 6;
    uint256 internal constant WPLS_DECIMALS = 18;
    uint256 internal constant PRICE_DECIMALS = 1e18;
    uint256 internal constant DTSC_DECIMALS = 1e18;

    uint256 internal constant MIN_DAYS_REMAINING = 2000;
    uint256 internal constant MAX_STAKE_DAYS = 5555;

    uint256 internal constant TIER_LONG_MIN = 4000;
    uint256 internal constant TIER_MEDIUM_MIN = 2000;

    // Basis points (10000 = 100%)
    uint256 internal constant BPS = 10_000;

    // Long tier: 145%–150% CCR → use 150% minimum collateral ratio
    uint256 internal constant CCR_LONG_BPS = 15_000;
    // Medium-long tier: 155%–160% CCR
    uint256 internal constant CCR_MEDIUM_BPS = 16_000;
    // Recovery mode threshold
    uint256 internal constant CCR_RECOVERY_BPS = 15_000;
    // Global minimum (normal mode)
    uint256 internal constant CCR_NORMAL_BPS = 15_000;

    uint256 internal constant PENALTY_STABILITY_BPS = 8000;
    uint256 internal constant PENALTY_BUYBACK_BPS = 2000;

    uint256 internal constant EARLY_UNSTAKE_PENALTY_MIN_BPS = 2000;
    uint256 internal constant EARLY_UNSTAKE_PENALTY_MAX_BPS = 4000;

    uint256 internal constant COOLDOWN_MIN_DAYS = 30;
    uint256 internal constant COOLDOWN_MAX_DAYS = 90;
    uint256 internal constant COOLDOWN_DAYS = 60;

    uint256 internal constant EV_CAP_MULTIPLIER_BPS = 20_000; // 2x principal max
    uint256 internal constant MAX_TIME_DISCOUNT_BPS = 1500; // 15%
    uint256 internal constant MAX_LONG_BONUS_BPS = 1500; // 15%

    uint256 internal constant TWAP_PERIOD = 24 hours;
    uint256 internal constant TWAP_OBSERVATION_CAPACITY = 8;
    uint256 internal constant ORACLE_MAX_STALENESS = 2 hours;

    // USDC path excluded if direct price deviates >5% below cross-rate (depeg/manipulation)
    uint256 internal constant USDC_DEPEG_TOLERANCE_BPS = 9500;
    // USDC path excluded if direct price >5% above cross-rate (thin-pool pump)
    uint256 internal constant USDC_PREMIUM_TOLERANCE_BPS = 10_500;
    uint256 internal constant REDEMPTION_FEE_FLOOR_BPS = 0;
    uint256 internal constant REDEMPTION_FEE_CEIL_BPS = 500; // 5% max dynamic fee

    // Hybrid redemption — borrower protection (golden middle tuning)
    /// @dev Vaults above this CR are immune from redemption (griefing shield)
    uint256 internal constant REDEMPTION_MAX_CR_BPS = 19_500; // 195%
    /// @dev Days after first mint before vault is redemption-eligible
    uint256 internal constant REDEMPTION_GRACE_PERIOD = 21 days;
    /// @dev Fee at tight CR / underwater — peg defense (kept <=1.5%)
    uint256 internal constant REDEMPTION_FEE_LOW_BPS = 150; // 1.5%
    /// @dev Fee near REDEMPTION_MAX_CR_BPS — expensive griefing
    uint256 internal constant REDEMPTION_FEE_HIGH_BPS = 500; // 5.0%
    /// @dev Fee stays at LOW until CR exceeds minCcr + this buffer
    uint256 internal constant REDEMPTION_CR_FEE_BUFFER_BPS = 200; // +2% above min CCR

    // Liquidation: 7.5% bonus on debt covered (industry range 5-10%)
    uint256 internal constant LIQUIDATION_BONUS_BPS = 750;

    // Stability Pool P-factor precision (Liquity-style)
    uint256 internal constant SP_DECIMAL_PRECISION = 1e18;
    uint256 internal constant SP_SCALE_FACTOR = 1e9;

    // Minimum DEX liquidity for oracle reads
    uint256 internal constant MIN_HEX_RESERVE_HEARTS = 50_000e8;
    uint256 internal constant MIN_QUOTE_RESERVE_WPLS = 5_000e18;
    uint256 internal constant MIN_QUOTE_RESERVE_USDC = 5_000e6;

    // Minimum Stability Pool TVL before new DTSC minting (M-07 launch policy)
    uint256 internal constant MIN_SP_COVERAGE_DTSC = 10_000e18;
    /// @dev SP must hold at least this % of total protocol debt (dynamic ops floor)
    uint256 internal constant MIN_SP_DEBT_COVERAGE_BPS = 300; // 3%

    /// @dev Borrow/mint path requires TWAP window (matches TwapRingBuffer minimum; no spot fallback)
    uint256 internal constant BORROW_TWAP_MIN_ELAPSED = TWAP_PERIOD / 2;

    /// @dev Chainlink feed max staleness when optional floor is wired
    uint256 internal constant CHAINLINK_MAX_STALENESS = 1 hours;

    // Bad debt above this triggers recovery mode (unbacked DTSC)
    uint256 internal constant BAD_DEBT_RECOVERY_THRESHOLD_DTSC = 1e18;
}