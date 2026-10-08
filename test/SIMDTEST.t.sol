// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTEST} from "../src/SIMDTEST.sol";

interface TokenVm {
    function prank(address caller) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
}

contract TokenTestActor {}

contract SIMDTESTTest {
    TokenVm private constant vm = TokenVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    SIMDTEST private token;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new SIMDTEST();
        alice = address(new TokenTestActor());
        bob = address(new TokenTestActor());
        spender = address(new TokenTestActor());
    }

    function testFixedSupplyAndMetadata() public view {
        require(keccak256(bytes(token.name())) == keccak256("SIMDTEST"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("SIMDTEST"), "symbol");
        require(token.decimals() == 18, "decimals");
        require(token.totalSupply() == 1e27, "supply");
        require(token.balanceOf(address(this)) == 1e27, "all supply to deploying factory");
    }

    function testTransferIsUntaxedAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 100 ether);
        require(token.transfer(alice, 100 ether), "transfer return value");
        require(token.balanceOf(alice) == 100 ether, "full amount received");
        require(token.balanceOf(address(this)) == 1e27 - 100 ether, "exact debit");
        vm.prank(alice);
        token.transfer(bob, 25 ether);
        require(token.balanceOf(bob) == 25 ether, "second transfer untaxed");
        require(token.balanceOf(alice) == 75 ether, "second debit exact");
        require(token.totalSupply() == 1e27, "no burn");
    }

    function testFactoryCanMakeSpecifiedDeadAddressAllocation() public {
        address dead = address(0xdead);
        token.transfer(dead, 100_000_000 ether);
        require(token.balanceOf(dead) == 100_000_000 ether, "ten percent sent to dead");
        require(token.balanceOf(address(this)) == 900_000_000 ether, "remaining launch allocation");
        require(token.totalSupply() == 1e27, "dead transfer preserves ERC20 total supply");
    }

    function testApprovalAndTransferFrom() public {
        token.transfer(alice, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, 60 ether);
        vm.prank(alice);
        require(token.approve(spender, 60 ether), "approval return");
        vm.prank(spender);
        require(token.transferFrom(alice, bob, 40 ether), "transferFrom return");
        require(token.allowance(alice, spender) == 20 ether, "allowance debited");
        require(token.balanceOf(alice) == 60 ether, "sender debited");
        require(token.balanceOf(bob) == 40 ether, "recipient credited");
    }

    function testApprovalReplacementAndRevocation() public {
        token.approve(spender, 5 ether);
        token.approve(spender, 2 ether);
        require(token.allowance(address(this), spender) == 2 ether, "approval replaces value");
        token.approve(spender, 0);
        vm.expectRevert(abi.encodeWithSelector(SIMDTEST.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), bob, 1);
    }

    function testInfiniteAllowanceAndSelfTransfer() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), address(this), 1e27);
        require(token.balanceOf(address(this)) == 1e27, "self transfer preserves balance");
        require(token.allowance(address(this), spender) == type(uint256).max, "infinite allowance unchanged");
    }

    function testZeroTransferAllowedWithoutTax() public {
        vm.prank(alice);
        token.transfer(bob, 0);
        require(token.balanceOf(alice) == 0 && token.balanceOf(bob) == 0, "no balance changes");
        vm.prank(spender);
        token.transferFrom(alice, bob, 0);
    }

    function testTransferExceedingBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SIMDTEST.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
        require(token.balanceOf(bob) == 0, "failed transfer has no effect");
    }

    function testTransferFromExceedingAllowanceReverts() public {
        token.approve(spender, 3);
        vm.expectRevert(abi.encodeWithSelector(SIMDTEST.ERC20InsufficientAllowance.selector, spender, 3, 4));
        vm.prank(spender);
        token.transferFrom(address(this), bob, 4);
        require(token.allowance(address(this), spender) == 3, "allowance unchanged");
        require(token.balanceOf(bob) == 0, "recipient unchanged");
    }

    function testRevertingTransferFromRestoresAllowance() public {
        vm.prank(alice);
        token.approve(spender, 9);
        vm.expectRevert(abi.encodeWithSelector(SIMDTEST.ERC20InsufficientBalance.selector, alice, 0, 9));
        vm.prank(spender);
        token.transferFrom(alice, bob, 9);
        require(token.allowance(alice, spender) == 9, "allowance rolled back");
    }

    function testZeroReceiverAndSpenderRejected() public {
        vm.expectRevert(abi.encodeWithSelector(SIMDTEST.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(SIMDTEST.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        token.approve(spender, 1);
        vm.expectRevert(abi.encodeWithSelector(SIMDTEST.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1);
        require(token.allowance(address(this), spender) == 1, "invalid recipient rolls allowance back");
        vm.expectRevert(abi.encodeWithSelector(SIMDTEST.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
    }

    function testNoAdministrativeSelectors() public {
        bytes4[5] memory forbidden = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("unpause()")),
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("upgradeTo(address)"))
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool success,) = address(token).call(abi.encodePacked(forbidden[i]));
            require(!success, "administrative selector absent");
        }
    }

    function testFuzzTransferConservesSupply(uint256 rawAmount, uint256 rawForwarded) public {
        uint256 amount = rawAmount % (1e27 + 1);
        uint256 forwarded = rawForwarded % (amount + 1);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(bob, forwarded);
        require(token.balanceOf(alice) == amount - forwarded, "alice exact balance");
        require(token.balanceOf(bob) == forwarded, "bob exact balance");
        require(
            token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob) == token.totalSupply(),
            "all supply conserved"
        );
    }
}
