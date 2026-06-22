// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../src/interfaces/IERC20.sol";

contract MockRouter {
    address public immutable dtsc;
    address public immutable quote;

    constructor(address dtsc_, address quote_) {
        dtsc = dtsc_;
        quote = quote_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        path;
        amountOutMin;
        require(path[0] == quote && path[1] == dtsc, "path");
        require(IERC20(quote).transferFrom(msg.sender, address(this), amountIn), "in");
        uint256 out = amountIn * 2;
        require(IERC20(dtsc).transfer(to, out), "out");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}