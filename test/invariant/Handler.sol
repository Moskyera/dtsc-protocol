// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DTSCSystem} from "../../src/deploy/DTSCDeployer.sol";
import {MockHEX} from "../mocks/MockHEX.sol";
import {DTSCConstants as C} from "../../src/libraries/DTSCConstants.sol";

contract Handler is Test {
    DTSCSystem public sys;
    MockHEX public hexToken;

    address public actor;
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;

    constructor(DTSCSystem memory sys_, MockHEX hexToken_) {
        sys = sys_;
        hexToken = hexToken_;
        actor = address(0xA11CE);
    }

    function depositSP(uint256 amount) public {
        amount = bound(amount, 1e18, 100_000e18);
        vm.prank(address(sys.vaultManager));
        sys.dtsc.mint(actor, amount);
        vm.startPrank(actor);
        sys.dtsc.approve(address(sys.stabilityPool), type(uint256).max);
        sys.stabilityPool.deposit(amount);
        vm.stopPrank();
        ghost_totalDeposited += amount;
    }

    function withdrawSP(uint256 amount) public {
        uint256 bal = sys.stabilityPool.getCompoundedDeposit(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(actor);
        sys.stabilityPool.withdraw(amount);
        ghost_totalWithdrawn += amount;
    }

    function openVaultAndMint(uint256 hearts) public {
        hearts = bound(hearts, 50_000e8, 200_000e8);
        hexToken.mint(actor, hearts);
        vm.startPrank(actor);
        hexToken.approve(address(sys.vaultManager), hearts);
        uint256 vaultId = sys.vaultManager.openVaultWithNewStake(hearts, 4500);
        vm.stopPrank();

        vm.warp(block.timestamp + C.COOLDOWN_DAYS * 1 days + 1);
        sys.oracle.update();

        (uint256 maxDtsc,) = sys.valuation.maxBorrowable(address(sys.vaultManager), 0, false);
        if (maxDtsc == 0) return;
        uint256 mintAmt = maxDtsc / 4;
        vm.prank(actor);
        try sys.vaultManager.mintDtsc(vaultId, mintAmt) {} catch {}
    }
}