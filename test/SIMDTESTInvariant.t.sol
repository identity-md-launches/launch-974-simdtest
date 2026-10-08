// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTEST} from "../src/SIMDTEST.sol";

interface InvariantVm {
    function prank(address sender) external;
}

/// @dev Random transfers, approvals and delegated transfers among a fixed set of holders, plus
///      the launch allocation to the dead address. Expected failures are swallowed and counted;
///      unexpected outcomes are recorded in `violation`.
contract SIMDTESTHandler {
    InvariantVm private constant vm = InvariantVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    SIMDTEST public immutable token;
    address[] public holders;
    string public violation;
    uint256 public ghostBurned;
    uint256 public ghostTransfers;
    uint256 public ghostRejected;

    constructor(SIMDTEST token_) {
        token = token_;
        for (uint256 i; i < 6; ++i) {
            holders.push(address(uint160(uint256(keccak256(abi.encode("holder", i))))));
        }
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = rawAmount % (balance + 2); // may exceed the balance by one
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            _check(ok, "transfer returned false");
            _check(amount <= balance, "transfer above balance succeeded");
            if (from != to) {
                _check(token.balanceOf(from) == balance - amount, "sender debited wrong amount");
                _check(token.balanceOf(to) == toBefore + amount, "receiver credited wrong amount");
            } else {
                _check(token.balanceOf(from) == balance, "self transfer changed balance");
            }
            ++ghostTransfers;
        } catch {
            _check(amount > balance, "affordable transfer reverted");
            _check(token.balanceOf(from) == balance && token.balanceOf(to) == toBefore, "failed transfer moved funds");
            ++ghostRejected;
        }
    }

    function approveAndTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount)
        external
    {
        address owner = _holder(ownerSeed);
        address spender = _holder(spenderSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(owner);
        uint256 amount = rawAmount % (balance + 2);
        uint256 allowance = rawAmount % 3 == 0 ? type(uint256).max : amount - (rawAmount % 2 == 0 ? 0 : amount % 2);
        vm.prank(owner);
        token.approve(spender, allowance);
        _check(token.allowance(owner, spender) == allowance, "approval not recorded");
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            _check(ok, "transferFrom returned false");
            _check(amount <= balance && amount <= allowance, "transferFrom beyond balance or allowance");
            if (allowance == type(uint256).max) {
                _check(token.allowance(owner, spender) == type(uint256).max, "infinite allowance consumed");
            } else {
                _check(token.allowance(owner, spender) == allowance - amount, "allowance not reduced by amount");
            }
            ++ghostTransfers;
        } catch {
            _check(amount > balance || amount > allowance, "permitted transferFrom reverted");
            _check(token.allowance(owner, spender) == allowance, "failed transferFrom changed allowance");
            ++ghostRejected;
        }
    }

    function burnToDead(uint256 fromSeed, uint256 rawAmount) external {
        address from = _holder(fromSeed);
        uint256 amount = rawAmount % (token.balanceOf(from) + 1);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(from);
        token.transfer(DEAD, amount);
        _check(token.balanceOf(DEAD) == deadBefore + amount, "dead balance mismatch");
        ghostBurned += amount;
    }

    function _holder(uint256 seed) private view returns (address) {
        return holders[seed % holders.length];
    }

    function _check(bool condition, string memory reason) private {
        if (!condition && bytes(violation).length == 0) violation = reason;
    }
}

/// @title Launch token invariants: fixed supply, conservation, dead allocation never returns.
contract SIMDTESTInvariantTest {
    uint256 private constant SUPPLY = 1_000_000_000e18;

    SIMDTEST private token;
    SIMDTESTHandler private handler;
    address[] private targets;

    function setUp() public {
        token = new SIMDTEST();
        handler = new SIMDTESTHandler(token);
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            token.transfer(handler.holders(i), SUPPLY / count);
        }
        // Dust left by integer division stays with the deployer and is part of the sum below.
        targets.push(address(handler));
    }

    function targetContracts() public view returns (address[] memory) {
        return targets;
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    function invariant_HandlerSawNoViolation() public view {
        require(bytes(handler.violation()).length == 0, handler.violation());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    function invariant_SupplyIsFixedAndConserved() public view {
        require(token.totalSupply() == SUPPLY, "supply changed");
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(handler.DEAD());
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        require(sum == SUPPLY, "balances do not sum to supply");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    function invariant_DeadAllocationOnlyGrows() public view {
        require(token.balanceOf(handler.DEAD()) == handler.ghostBurned(), "dead balance differs from burns");
        require(token.balanceOf(address(handler)) == 0, "handler accumulated tokens");
    }
}
