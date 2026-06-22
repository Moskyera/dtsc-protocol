// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DTSC} from "./DTSC.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IPulseXRouter} from "../interfaces/IPulseXRouter.sol";

/// @title BuybackBurn — 20% penalty burn + permissionless DEX buyback
contract BuybackBurn {
    DTSC public immutable dtsc;
    IPulseXRouter public immutable router;
    IERC20 public immutable quoteToken;

    address public penaltyRouter;
    address private deployer;

    uint256 public totalDtscBurned;
    uint256 public totalPenaltyBurned;
    uint256 public totalQuoteSpent;

    event PenaltyBurned(uint256 amount);
    event BuybackExecuted(uint256 quoteIn, uint256 dtscBurned);
    event QuoteReceived(uint256 amount);
    event PenaltyRouterSet(address router);

    error ZeroAmount();
    error SwapFailed();
    error Unauthorized();
    error AlreadySet();

    constructor(address dtsc_, address router_, address quoteToken_) {
        dtsc = DTSC(dtsc_);
        router = IPulseXRouter(router_);
        quoteToken = IERC20(quoteToken_);
        deployer = msg.sender;
    }

    function setPenaltyRouter(address router_) external {
        if (msg.sender != deployer) revert Unauthorized();
        if (penaltyRouter != address(0)) revert AlreadySet();
        if (router_ == address(0)) revert ZeroAmount();
        penaltyRouter = router_;
        deployer = address(0);
        emit PenaltyRouterSet(router_);
    }

    /// @notice Burns DTSC penalty routed by PenaltyRouter (must be transferred first)
    function receivePenalty(uint256 amount) external {
        if (msg.sender != penaltyRouter) revert Unauthorized();
        if (amount == 0) return;
        totalPenaltyBurned += amount;
        dtsc.burn(address(this), amount);
        emit PenaltyBurned(amount);
    }

    /// @notice Accept quote tokens (e.g. redemption fees) for market buyback
    function receiveQuote(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        require(quoteToken.transferFrom(msg.sender, address(this), amount), "transfer");
        emit QuoteReceived(amount);
    }

    /// @notice Permissionless: swap accumulated quote → DTSC → burn
    function executeBuyback(uint256 quoteAmount, uint256 minDtscOut) external returns (uint256 dtscBurned) {
        if (quoteAmount == 0) revert ZeroAmount();

        uint256 bal = quoteToken.balanceOf(address(this));
        if (quoteAmount > bal) quoteAmount = bal;
        if (quoteAmount == 0) revert ZeroAmount();

        quoteToken.approve(address(router), quoteAmount);

        address[] memory path = new address[](2);
        path[0] = address(quoteToken);
        path[1] = address(dtsc);

        uint256[] memory amounts = router.swapExactTokensForTokens(
            quoteAmount,
            minDtscOut,
            path,
            address(this),
            block.timestamp
        );

        dtscBurned = amounts[amounts.length - 1];
        if (dtscBurned == 0) revert SwapFailed();

        dtsc.burn(address(this), dtscBurned);
        totalDtscBurned += dtscBurned;
        totalQuoteSpent += quoteAmount;

        emit BuybackExecuted(quoteAmount, dtscBurned);
    }

    function quoteBalance() external view returns (uint256) {
        return quoteToken.balanceOf(address(this));
    }
}