// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Vm, TestPairedToken} from "./helpers/TestSupport.sol";

/// @dev A stranger acting inside its own unlock: parks IMD as claims owned by an arbitrary
///      account, or tries to burn claims it does not own.
contract ClaimStranger is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable paired;

    constructor(IPoolManager manager_, address paired_) {
        manager = manager_;
        paired = paired_;
    }

    function gift(address to, uint256 amount) external {
        manager.unlock(abi.encode(uint8(0), to, amount));
    }

    /// @return burned Whether burning somebody else's claims succeeded.
    function tryBurn(address victim, uint256 amount) external returns (bool burned) {
        burned = abi.decode(manager.unlock(abi.encode(uint8(1), victim, amount)), (bool));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, address account, uint256 amount) = abi.decode(data, (uint8, address, uint256));
        uint256 id = Currency.wrap(paired).toId();
        if (action == 0) {
            manager.mint(account, id, amount);
            manager.sync(Currency.wrap(paired));
            require(TestPairedToken(paired).transfer(address(manager), amount));
            manager.settle();
            return "";
        }
        bool burned;
        try manager.burn(account, id, amount) {
            burned = true;
            // Would leave this stranger with a positive delta; take it so the unlock can close.
            manager.take(Currency.wrap(paired), address(this), amount);
        } catch {}
        return abi.encode(burned);
    }
}

/// @dev Syncs a currency and then calls payTreasury within the same call.
contract SyncThenPay {
    function run(IPoolManager manager, SIMDTESTHook hook, Currency currency) external returns (uint256) {
        manager.sync(currency);
        return hook.payTreasury();
    }
}

/// @title Deferred treasury claims: who can move them, when they are paid, and that a hostile or
///        re-entrant caller can neither block swaps nor divert IMD.
contract SIMDTESTHookDeferredTreasuryTest is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant PAIR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint160 private constant INITIAL_PRICE = 79228162514264337593543950336;
    uint128 private constant LIQUIDITY = 1e24;
    uint160 private constant FLAGS = 0x28cc;
    uint256 private constant BPS = 10000;

    IPoolManager private manager;
    SIMDTEST private token;
    TestPairedToken private pair;
    SIMDTESTHook private hook;
    PoolKey private key;
    ClaimStranger private stranger;

    /// @dev Set by the re-entrancy test: whether the router's in-unlock payTreasury attempt succeeded.
    bool private reentrantPayoutSucceeded;
    bytes private reentrantPayoutRevert;

    function setUp() public {
        token = new SIMDTEST();
        TestPairedToken implementation = new TestPairedToken();
        vm.etch(PAIR, address(implementation).code);
        pair = TestPairedToken(PAIR);
        pair.mint(address(this), 1e27);
        bytes memory managerCode =
            abi.encodePacked(vm.getCode("PoolManager.sol:PoolManager"), abi.encode(address(this)));
        address deployedManager;
        assembly ("memory-safe") {
            deployedManager := create(0, add(managerCode, 32), mload(managerCode))
        }
        require(deployedManager != address(0), "manager deployment failed");
        manager = IPoolManager(deployedManager);
        hook = _deployHook();
        key = PoolKey({
            currency0: Currency.wrap(address(token) < PAIR ? address(token) : PAIR),
            currency1: Currency.wrap(address(token) < PAIR ? PAIR : address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, INITIAL_PRICE);
        manager.unlock(abi.encode(uint8(1), abi.encode(int256(uint256(LIQUIDITY)))));
        stranger = new ClaimStranger(manager, PAIR);
        pair.mint(address(stranger), 1e24);
    }

    function _deployHook() private returns (SIMDTESTHook deployed) {
        bytes memory code = abi.encodePacked(
            vm.getCode("SIMDTESTHook.sol:SIMDTESTHook"), abi.encode(manager, address(token), address(this))
        );
        bytes32 codeHash = keccak256(code);
        bytes32 salt;
        for (uint256 candidate;; ++candidate) {
            salt = bytes32(candidate);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
            if (uint160(predicted) & 0x3fff == FLAGS && predicted.code.length == 0) break;
        }
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(code, 32), mload(code), salt)
        }
        require(at != address(0) && uint160(at) & 0x3fff == FLAGS, "CREATE2 deployment failed");
        deployed = SIMDTESTHook(at);
    }

    function _pairIs0() private view returns (bool) {
        return Currency.unwrap(key.currency0) == PAIR;
    }

    function _pairId() private pure returns (uint256) {
        return Currency.wrap(PAIR).toId();
    }

    function _buyParams(uint256 amountIn) private view returns (IPoolManager.SwapParams memory) {
        bool zeroForOne = _pairIs0();
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @dev action 0: plain buy. 1: factory liquidity change. 2: pre-paying router buy.
    ///      3: router that tries payTreasury inside its unlock, then buys.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        BalanceDelta delta;
        if (action == 1) {
            (delta,) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -600, tickUpper: 600, liquidityDelta: abi.decode(payload, (int256)), salt: bytes32(0)
                }),
                ""
            );
            _settle(key.currency0, delta.amount0());
            _settle(key.currency1, delta.amount1());
            return abi.encode(delta);
        }
        IPoolManager.SwapParams memory params = abi.decode(payload, (IPoolManager.SwapParams));
        if (action == 3) {
            try hook.payTreasury() returns (uint256) {
                reentrantPayoutSucceeded = true;
            } catch (bytes memory reason) {
                reentrantPayoutRevert = reason;
            }
        }
        if (action == 2) {
            uint256 input = uint256(-params.amountSpecified);
            manager.sync(Currency.wrap(PAIR));
            require(pair.transfer(address(manager), input));
            delta = manager.swap(key, params, "");
            require(manager.settle() == input, "prepaid amount");
            int128 tokenDelta = _pairIs0() ? delta.amount1() : delta.amount0();
            manager.take(Currency.wrap(address(token)), address(this), uint256(uint128(tokenDelta)));
        } else {
            delta = manager.swap(key, params, "");
            _settle(key.currency0, delta.amount0());
            _settle(key.currency1, delta.amount1());
        }
        require(manager.currencyDelta(address(hook), Currency.wrap(PAIR)) == 0, "hook paired debt");
        require(manager.currencyDelta(address(hook), Currency.wrap(address(token))) == 0, "hook token debt");
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            require(TestPairedToken(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(amount))));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    function _prepaidBuy(uint256 amountIn) private returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(2), abi.encode(_buyParams(amountIn)))), (BalanceDelta));
    }

    // ------------------------------------------------------------------ hostile claims

    function testGiftedClaimsOnlyEverReachTheTreasury() public {
        uint256 gift = 7e20;
        stranger.gift(address(hook), gift);
        require(hook.pendingTreasury() == gift, "gift not visible as pending");
        require(pair.balanceOf(address(hook)) == 0, "hook received IMD");
        // The next swap still works and, since the manager holds the IMD, flushes the gift to the
        // treasury along with its own fee.
        uint256 amountIn = 100e18;
        uint256 fee = amountIn * 50 / BPS;
        manager.unlock(abi.encode(uint8(0), abi.encode(_buyParams(amountIn))));
        require(hook.pendingTreasury() == 0, "gift not flushed");
        require(pair.balanceOf(TREASURY) == gift + fee, "treasury did not receive gift plus fee");
        require(pair.balanceOf(address(stranger)) == 1e24 - gift, "stranger got the gift back");
        // A gift after the window behaves the same through the permissionless payout.
        vm.roll(hook.openingBlock() + 10);
        stranger.gift(address(hook), 1);
        vm.prank(address(0xCAFE));
        require(hook.payTreasury() == 1, "dust gift not paid");
        require(pair.balanceOf(TREASURY) == gift + fee + 1 && hook.pendingTreasury() == 0, "dust gift lost");
    }

    function testStrangersCannotMoveOrBurnDeferredClaims() public {
        uint256 amountIn = 1000e18;
        uint256 fee = amountIn * 50 / BPS;
        _prepaidBuy(amountIn);
        require(hook.pendingTreasury() == fee, "fee not deferred");
        // ERC-6909 transfers of the hook's claims need the hook's approval, which it never gives.
        vm.prank(address(stranger));
        vm.expectRevert();
        manager.transferFrom(address(hook), address(stranger), _pairId(), fee);
        vm.prank(address(stranger));
        vm.expectRevert();
        manager.transferFrom(address(hook), address(stranger), _pairId(), 1);
        // Burning somebody else's claims inside an unlock is refused by the manager.
        require(!stranger.tryBurn(address(hook), fee), "stranger burned the hook's claims");
        require(!stranger.tryBurn(address(hook), 1), "stranger burned one wei of claims");
        require(hook.pendingTreasury() == fee, "claims changed");
        // Nothing the hook exposes lets a caller name a recipient: only the treasury is ever paid.
        uint256 strangerBefore = pair.balanceOf(address(stranger));
        vm.prank(address(stranger));
        require(hook.payTreasury() == fee, "payout");
        require(pair.balanceOf(TREASURY) == fee, "treasury short");
        require(pair.balanceOf(address(stranger)) == strangerBefore, "payer received IMD");
        require(manager.balanceOf(address(stranger), _pairId()) == 0, "payer received claims");
    }

    // ------------------------------------------------------------------ re-entrancy

    function testPayTreasuryInsideAnotherUnlockIsRefusedWithoutBreakingTheSwap() public {
        _prepaidBuy(1000e18);
        uint256 pending = hook.pendingTreasury();
        require(pending == 5e18, "backlog");
        uint256 amountIn = 100e18;
        uint256 fee = amountIn * 50 / BPS;
        // The router tries to make the hook unlock the manager while the manager is already
        // unlocked for the router. The manager refuses; the router's own swap then proceeds and
        // pays its fee plus the backlog because the manager now holds the first buyer's IMD.
        manager.unlock(abi.encode(uint8(3), abi.encode(_buyParams(amountIn))));
        require(!reentrantPayoutSucceeded, "payTreasury ran inside a foreign unlock");
        require(reentrantPayoutRevert.length >= 4, "no revert reason");
        require(bytes4(reentrantPayoutRevert) == bytes4(keccak256("AlreadyUnlocked()")), "unexpected reason");
        require(hook.pendingTreasury() == 0, "backlog not flushed by the swap");
        require(pair.balanceOf(TREASURY) == pending + fee, "treasury short after re-entrancy attempt");
        require(pair.balanceOf(address(hook)) == 0, "hook retained IMD");
    }

    // ------------------------------------------------------------------ synced currencies

    function testPayTreasuryPaysWhileTheLaunchTokenIsSynced() public {
        _prepaidBuy(1000e18);
        uint256 pending = hook.pendingTreasury();
        require(pending == 5e18, "backlog");
        // Only a synced IMD blocks payout; a synced launch token is irrelevant to the IMD ledger.
        SyncThenPay caller = new SyncThenPay();
        require(caller.run(manager, hook, Currency.wrap(address(token))) == pending, "payout blocked by token sync");
        require(hook.pendingTreasury() == 0 && pair.balanceOf(TREASURY) == pending, "payout incomplete");
        // And a synced IMD blocks it entirely, leaving the claims intact for a later call.
        _prepaidBuy(1000e18);
        require(caller.run(manager, hook, Currency.wrap(PAIR)) == 0, "paid while IMD was synced");
        require(hook.pendingTreasury() == 5e18, "claims lost during synced IMD");
        require(hook.payTreasury() == 5e18, "payout after sync cleared");
    }

    // ------------------------------------------------------------------ accumulation

    /// @dev Repeated pre-paid buys accumulate exactly floor(amount * 0.5%) each, never pay early,
    ///      and one permissionless call clears the whole backlog to the wei.
    /// forge-config: default.fuzz.runs = 300
    function testFuzzDeferredBacklogAccumulatesExactlyAndClears(uint8 rawCount, uint96 rawAmount, uint8 rawAge) public {
        uint256 count = uint256(rawCount) % 8 + 1;
        vm.roll(hook.openingBlock() + uint256(rawAge) % 14);
        uint256 expected;
        for (uint256 i; i < count; ++i) {
            // Vary amounts per buy, including sub-200-wei buys whose fee rounds to nothing.
            uint256 amountIn = uint256(keccak256(abi.encode(rawAmount, i))) % 50e18 + 1;
            if (i % 3 == 2) amountIn = uint256(rawAmount) % 400 + 1;
            BalanceDelta delta = _prepaidBuy(amountIn);
            int128 pairedDelta = _pairIs0() ? delta.amount0() : delta.amount1();
            require(pairedDelta == -int256(amountIn), "buy did not take the exact input");
            expected += amountIn * 50 / BPS;
            require(hook.pendingTreasury() == expected, "backlog off by rounding");
            require(pair.balanceOf(TREASURY) == 0, "paid out from under a synced payment");
        }
        require(hook.pendingTreasury() <= pair.balanceOf(address(manager)), "claims unbacked");
        vm.prank(address(0xBEEF));
        require(hook.payTreasury() == expected, "payout differs from backlog");
        require(pair.balanceOf(TREASURY) == expected && hook.pendingTreasury() == 0, "backlog not cleared");
        require(hook.payTreasury() == 0, "second payout paid again");
        require(pair.balanceOf(address(hook)) == 0 && token.balanceOf(address(hook)) == 0, "hook retained funds");
    }
}
