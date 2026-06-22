// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DTSC} from "../src/core/DTSC.sol";
import {BuybackBurn} from "../src/core/BuybackBurn.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract MockQuote {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract BuybackBurnTest is Test {
    DTSC dtsc;
    MockQuote quote;
    BuybackBurn buyback;
    MockRouter router;

    function setUp() public {
        dtsc = new DTSC();
        quote = new MockQuote();
        router = new MockRouter(address(dtsc), address(quote));
        buyback = new BuybackBurn(address(dtsc), address(router), address(quote));
        dtsc.authorizeMinter(address(buyback), true);
        dtsc.authorizeMinter(address(this), true);
        dtsc.lockWiring();
        dtsc.mint(address(buyback), 1_000_000e18);
        dtsc.mint(address(router), 1_000_000e18);
    }

    function test_penaltyBurn() public {
        buyback.setPenaltyRouter(address(this));
        uint256 before = dtsc.totalSupply();
        dtsc.mint(address(buyback), 50e18);
        buyback.receivePenalty(50e18);
        assertEq(dtsc.totalSupply(), before);
        assertEq(buyback.totalPenaltyBurned(), 50e18);
    }

    function test_marketBuyback() public {
        quote.mint(address(this), 100e18);
        quote.approve(address(buyback), 100e18);
        buyback.receiveQuote(100e18);

        uint256 supplyBefore = dtsc.totalSupply();
        buyback.executeBuyback(100e18, 100e18);
        assertLt(dtsc.totalSupply(), supplyBefore);
        assertGt(buyback.totalDtscBurned(), 0);
    }
}