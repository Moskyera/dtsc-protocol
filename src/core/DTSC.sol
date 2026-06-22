// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DTSC — Decentralized T-Share Coin ($1 peg target)
contract DTSC {
    string public constant name = "Decentralized T-Share Coin";
    string public constant symbol = "DTSC";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public authorizedMinters;

    address public deployer;
    bool public wiringLocked;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterAuthorized(address indexed minter, bool enabled);
    event WiringLocked();

    error Unauthorized();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();
    error WiringAlreadyLocked();

    modifier onlyDeployer() {
        if (msg.sender != deployer) revert Unauthorized();
        _;
    }

    modifier onlyMinter() {
        if (!authorizedMinters[msg.sender]) revert Unauthorized();
        _;
    }

    constructor() {
        deployer = msg.sender;
    }

    function authorizeMinter(address minter, bool enabled) external onlyDeployer {
        if (wiringLocked) revert WiringAlreadyLocked();
        if (minter == address(0)) revert ZeroAddress();
        authorizedMinters[minter] = enabled;
        emit MinterAuthorized(minter, enabled);
    }

    function lockWiring() external onlyDeployer {
        if (wiringLocked) revert WiringAlreadyLocked();
        wiringLocked = true;
        deployer = address(0);
        emit WiringLocked();
    }

    function mint(address to, uint256 amount) external onlyMinter {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function burnFrom(address from, uint256 amount) external onlyMinter {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        unchecked {
            if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        }
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        unchecked {
            if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}