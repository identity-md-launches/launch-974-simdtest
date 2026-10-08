// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Plain fixed-supply launch token. The launch factory receives the supply
/// and performs the pool, swarm, and dead-address allocations atomically at launch.
contract SIMDTEST {
    string public constant name = "SIMDTEST";
    string public constant symbol = "SIMDTEST";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 * 10 ** 18;

    mapping(address account => uint256) public balanceOf;
    mapping(address account => mapping(address spender => uint256)) public allowance;

    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSpender(address spender);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        if (permitted != type(uint256).max) {
            if (permitted < value) revert ERC20InsufficientAllowance(msg.sender, permitted, value);
            allowance[from][msg.sender] = permitted - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 balance = balanceOf[from];
        if (balance < value) revert ERC20InsufficientBalance(from, balance, value);
        balanceOf[from] = balance - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
