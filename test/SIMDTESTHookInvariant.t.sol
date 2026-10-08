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
import {Vm, TestPairedToken, LiquidityActor} from "./helpers/TestSupport.sol";

/// @dev A stranger who parks IMD inside the PoolManager as ERC-6909 claims owned by the hook.
///      Anyone can do this; it must only ever enlarge what the treasury receives.
contract ClaimGifter is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable paired;

    constructor(IPoolManager manager_, address paired_) {
        manager = manager_;
        paired = paired_;
    }

    function gift(address to, uint256 amount) external {
        manager.unlock(abi.encode(to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        manager.mint(to, Currency.wrap(paired).toId(), amount);
        manager.sync(Currency.wrap(paired));
        require(TestPairedToken(paired).transfer(address(manager), amount));
        manager.settle();
        return "";
    }
}

/// @dev Stateful handler. It is the launch factory of its hook, the unlock callback for its own
///      swaps and liquidity changes, and the bookkeeper of every fee the hook reports. Third
///      parties are LiquidityActor contracts so the hook sees them, not this handler, as sender.
///      Any per-call expectation that fails is recorded in `violation` instead of reverting, so
///      the invariant runner reports it with the call sequence that produced it.
contract SIMDTESTHookHandler is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address public constant PAIR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant BPS = 10000;
    uint160 private constant INITIAL_PRICE = 79228162514264337593543950336;
    uint128 public constant SEED_LIQUIDITY = 1e24;
    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant DONATE_TOPIC = keccak256("Donate(bytes32,address,uint256,uint256)");
    bytes32 private constant FEES_TOPIC = keccak256("SwapFees(uint256,uint256,uint256)");

    IPoolManager public immutable manager;
    SIMDTEST public immutable token;
    TestPairedToken public immutable pair;
    SIMDTESTHook public hook;
    PoolKey public key;
    LiquidityActor[] public actors;
    ClaimGifter public gifter;

    // Ghost ledger.
    string public violation;
    uint256 public openingBlock;
    /// @dev Sum of every treasury fee the hook reported. Paid IMD plus deferred claims must equal it.
    uint256 public ghostTreasury;
    /// @dev IMD strangers parked as hook-owned claims; it may only ever reach the treasury.
    uint256 public ghostGifted;
    uint256 public ghostDonated;
    uint256 public ghostSwaps;
    uint256 public ghostSwapReverts;
    uint256 public ghostDeferredSwaps;
    uint256 public ghostBacklogFlushes;
    uint256 public ghostPrepaidBuys;
    uint256 public ghostPayouts;
    uint256 public ghostWindowSwaps;
    uint256 public ghostDonatingSwaps;
    uint256 public ghostDrainedSwaps;
    uint256 public ghostThirdPartyAdds;
    uint256 public ghostThirdPartyRejections;
    uint256 public ghostTransfers;
    uint256 public ghostFactoryLiquidity;
    uint256 public ghostFactoryWithdrawals;
    bytes public lastSwapRevert;
    mapping(uint256 => uint256) public actorLiquidity;

    struct Seen {
        bool sawSwap;
        bool sawFees;
        int128 rawPair;
        uint256 gross;
        uint256 anti;
        uint256 treasury;
        uint256 donated;
        uint256 donatedToken;
    }

    struct Snapshot {
        uint256 treasury;
        uint256 pending;
        uint256 managerPaired;
        uint256 growth;
        uint256 rate;
    }

    /// @dev Pool.PriceLimitAlreadyExceeded(uint160,uint160): the core refuses a swap whose limit
    ///      the price already sits on, which happens after a swap drained the range to the limit.
    bytes4 private constant PRICE_LIMIT_EXCEEDED = bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)"));

    constructor(IPoolManager manager_, SIMDTEST token_, TestPairedToken pair_) {
        manager = manager_;
        token = token_;
        pair = pair_;
    }

    /// @notice Binds the hook, opens the pool as its factory and seeds the launch position.
    function launch(SIMDTESTHook hook_) external {
        require(address(hook) == address(0), "already launched");
        hook = hook_;
        key = PoolKey({
            currency0: Currency.wrap(address(token) < PAIR ? address(token) : PAIR),
            currency1: Currency.wrap(address(token) < PAIR ? PAIR : address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook_))
        });
        manager.initialize(key, INITIAL_PRICE);
        openingBlock = block.number;
        _modifyAsFactory(int256(uint256(SEED_LIQUIDITY)));
        ghostFactoryLiquidity = SEED_LIQUIDITY;
        for (uint256 i; i < 2; ++i) {
            LiquidityActor actor = new LiquidityActor(manager);
            pair.mint(address(actor), 1e27);
            token.transfer(address(actor), 1e26);
            actors.push(actor);
        }
        gifter = new ClaimGifter(manager, PAIR);
        pair.mint(address(gifter), 1e27);
        // The 10% dead-address allocation of the launch plan.
        token.transfer(DEAD, 1e26);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------- fuzzed actions

    /// @notice Random swap in one of the four modes by the handler or a third party.
    function swap(uint256 actorSeed, uint8 mode, uint96 rawAmount) external {
        // Mostly moderate trades; about one in thirty-two is large enough to drain every position
        // in range and run the price to its limit, so later swaps meet an empty range, partial
        // fills and the core's price-limit refusal. Hash-derived so the fuzzer's edge-value bias
        // does not make it common.
        bool large = uint256(keccak256(abi.encode(actorSeed, rawAmount, mode))) % 32 == 0;
        uint256 amount = large ? uint256(rawAmount) % 2e24 + 1e23 : uint256(rawAmount) % 5e21 + 1;
        bool buy = mode & 1 == 1;
        bool exactInput = mode & 2 == 2;
        IPoolManager.SwapParams memory params = _params(buy, exactInput, amount);
        uint256 who = actorSeed % (actors.length + 1);
        Snapshot memory before = _snapshot();
        vm.recordLogs();
        bool ok;
        if (who == 0) {
            try manager.unlock(abi.encode(uint8(0), abi.encode(params))) {
                ok = true;
            } catch (bytes memory reason) {
                lastSwapRevert = reason;
            }
        } else {
            LiquidityActor.Step[] memory steps = new LiquidityActor.Step[](1);
            steps[0].isSwap = true;
            steps[0].swap = params;
            try actors[who - 1].run(key, steps) {
                ok = true;
            } catch (bytes memory reason) {
                lastSwapRevert = reason;
            }
        }
        _settleSwapLedger(ok, false, before, _observe(vm.getRecordedLogs()));
    }

    /// @notice A router that syncs and transfers its IMD before the swap and settles afterwards.
    ///         The hook cannot take IMD while the router's payment is synced, so this swap's
    ///         treasury fee must be deferred as a claim rather than failing the buy.
    function prepaidBuy(uint96 rawAmount) external {
        uint256 amount = uint256(rawAmount) % 5e21 + 1;
        IPoolManager.SwapParams memory params = _params(true, true, amount);
        Snapshot memory before = _snapshot();
        vm.recordLogs();
        bool ok;
        try manager.unlock(abi.encode(uint8(2), abi.encode(params))) {
            ok = true;
        } catch (bytes memory reason) {
            lastSwapRevert = reason;
        }
        if (ok) ++ghostPrepaidBuys;
        _settleSwapLedger(ok, true, before, _observe(vm.getRecordedLogs()));
    }

    /// @notice Anyone may push deferred treasury claims out to the treasury. Outside a swap the
    ///         manager always holds the IMD behind every claim, so the whole backlog must clear.
    function payTreasury(uint256 callerSeed) external {
        uint256 pendingBefore = hook.pendingTreasury();
        uint256 treasuryBefore = pair.balanceOf(TREASURY);
        address caller = address(uint160(uint256(keccak256(abi.encode("payer", callerSeed % 4)))));
        vm.prank(caller);
        uint256 paid = hook.payTreasury();
        _check(paid == pendingBefore, "payTreasury did not clear the backlog");
        _check(hook.pendingTreasury() == 0, "claims remain after payout");
        _check(pair.balanceOf(TREASURY) - treasuryBefore == paid, "payout differs from treasury credit");
        _check(pair.balanceOf(caller) == 0, "payer received IMD");
        if (paid != 0) ++ghostPayouts;
    }

    /// @notice A stranger parks IMD as hook-owned claims. It must never disturb swaps and must
    ///         only ever end up with the treasury.
    function giftClaims(uint96 rawAmount) external {
        uint256 amount = uint256(rawAmount) % 1e21 + 1;
        uint256 pendingBefore = hook.pendingTreasury();
        gifter.gift(address(hook), amount);
        _check(hook.pendingTreasury() == pendingBefore + amount, "gifted claims not counted as pending");
        ghostGifted += amount;
    }

    /// @dev Books one swap attempt against the ghost ledger. `before` was taken immediately
    ///      before the attempt; the manager's physical IMD at that moment is what the hook sees
    ///      inside afterSwap, because every router here settles after the swap returns.
    function _settleSwapLedger(bool ok, bool prepaid, Snapshot memory before, Seen memory seen) private {
        Snapshot memory current = _snapshot();
        uint256 rate = before.rate;
        if (!ok) {
            ++ghostSwapReverts;
            // The only legitimate failures: a specified-IMD swap that the pool could not fill in
            // full, or the core refusing a swap whose price limit is already reached. Both leave
            // every balance untouched. Anything else is a defect.
            _check(
                _revertContains(SIMDTESTHook.PartialFillUnsupported.selector) || _revertContains(PRICE_LIMIT_EXCEEDED),
                "unexpected swap revert"
            );
            _check(current.treasury == before.treasury, "reverted swap paid treasury");
            _check(current.pending == before.pending, "reverted swap changed claims");
            _check(current.growth == before.growth, "reverted swap donated");
            return;
        }
        ++ghostSwaps;
        _check(seen.sawSwap && seen.sawFees, "swap without fee accounting");
        _check(seen.donatedToken == 0, "launch token donated");
        _check(seen.donated == seen.anti, "donation differs from reported anti-snipe amount");
        // Treasury fee ledger: IMD that left for the treasury plus the change in deferred claims
        // equals the fee this swap reported, and the pay-or-defer choice follows exactly what the
        // manager could hand out at that moment.
        uint256 paid = current.treasury - before.treasury;
        uint256 available = prepaid ? 0 : before.managerPaired;
        uint256 expectedPaid;
        uint256 expectedPending = before.pending;
        if (seen.treasury != 0) {
            if (before.pending != 0 && available >= seen.treasury + before.pending) {
                expectedPaid = seen.treasury + before.pending;
                expectedPending = 0;
                ++ghostBacklogFlushes;
            } else if (available >= seen.treasury) {
                expectedPaid = seen.treasury;
            } else {
                expectedPending += seen.treasury;
                ++ghostDeferredSwaps;
            }
        }
        _check(paid == expectedPaid, "treasury payment differs from what the manager could pay");
        _check(current.pending == expectedPending, "deferred claims off ledger");
        _check(prepaid ? paid == 0 : true, "took IMD out from under a synced payment");
        uint256 combined = seen.gross * rate / BPS;
        _check(seen.anti + seen.treasury == combined, "fee split does not equal combined fee");
        uint256 baseTreasury = seen.gross * 50 / BPS;
        if (seen.anti != 0) {
            _check(seen.treasury == baseTreasury, "treasury fee not 0.5% while donating");
            ++ghostDonatingSwaps;
            _check(current.growth > before.growth, "donation did not raise paired fee growth");
        } else if (combined != baseTreasury) {
            // Anti-snipe amount routed to the treasury: only legal when the range is empty.
            _check(manager.getLiquidity(key.toId()) == 0, "anti-snipe went to treasury with liquidity in range");
            ++ghostDrainedSwaps;
        }
        if (rate == 50) {
            _check(seen.anti == 0 && seen.donated == 0, "donation outside anti-snipe window");
            _check(seen.treasury == baseTreasury, "post-window treasury fee not 0.5%");
        } else {
            ++ghostWindowSwaps;
        }
        _check(seen.gross == 0 || combined >= seen.gross * 50 / BPS, "fee below treasury floor");
        _check(combined <= seen.gross * 3050 / BPS, "fee above 30.5% ceiling");
        ghostTreasury += seen.treasury;
        ghostDonated += seen.donated;
    }

    /// @notice Advances the chain, mostly by a few blocks so the window is explored block by block
    ///         and a sequence usually spans both the window and the open period.
    function roll(uint8 raw) external {
        uint256 step = raw < 192 ? raw % 4 : (raw < 240 ? 5 : 12);
        vm.roll(block.number + step);
    }

    /// @notice A third party attempts to add liquidity. Must fail while the anti-snipe fee is nonzero.
    function thirdPartyAddLiquidity(uint256 actorSeed, uint96 rawAmount, uint8 rangeSeed) external {
        uint256 index = actorSeed % actors.length;
        uint256 amount = uint256(rawAmount) % 1e24 + 1;
        int24 width = int24(int256(uint256(rangeSeed) % 10 + 1)) * 60;
        bool windowOpen = hook.antiSnipeBps() != 0;
        uint256 liquidityBefore = manager.getLiquidity(key.toId());
        try actors[index].modifyLiquidity(key, _liquidityParams(-width, width, int256(amount), index + 1)) {
            _check(!windowOpen, "third party added liquidity during anti-snipe window");
            actorLiquidity[index] += amount;
            ++ghostThirdPartyAdds;
        } catch {
            if (windowOpen) ++ghostThirdPartyRejections;
            _check(manager.getLiquidity(key.toId()) == liquidityBefore, "rejected addition changed liquidity");
        }
    }

    /// @notice Removals are never restricted by the hook.
    function thirdPartyRemoveLiquidity(uint256 actorSeed, uint96 rawAmount, uint8 rangeSeed) external {
        uint256 index = actorSeed % actors.length;
        uint256 held = actorLiquidity[index];
        if (held == 0) return;
        int24 width = int24(int256(uint256(rangeSeed) % 10 + 1)) * 60;
        uint256 amount = uint256(rawAmount) % held + 1;
        // Positions were opened at random widths; removal of a width that was never opened fails
        // inside the manager, which is not a hook property. Only a successful removal is booked.
        try actors[index].modifyLiquidity(key, _liquidityParams(-width, width, -int256(amount), index + 1)) {
            actorLiquidity[index] -= amount;
        } catch {}
    }

    /// @notice The factory may add during the window and remove at any time.
    function factoryModifyLiquidity(uint96 rawAmount, bool add) external {
        if (add) {
            uint256 amount = uint256(rawAmount) % 1e24 + 1;
            try manager.unlock(abi.encode(uint8(1), abi.encode(int256(amount)))) {
                ghostFactoryLiquidity += amount;
            } catch {
                _check(false, "factory addition rejected");
            }
        } else {
            // Usually the factory keeps at least a quarter of its seed so sequences stay
            // tradeable. Now and then it withdraws the whole launch position: the pool must keep
            // working (buys defer their treasury fee instead of failing) until liquidity returns.
            if (ghostFactoryLiquidity == 0) return;
            uint256 amount;
            if (uint256(keccak256(abi.encode("withdraw", rawAmount))) % 16 == 0) {
                amount = ghostFactoryLiquidity;
                ++ghostFactoryWithdrawals;
            } else {
                uint256 floor = SEED_LIQUIDITY / 4;
                if (ghostFactoryLiquidity <= floor) return;
                amount = uint256(rawAmount) % (ghostFactoryLiquidity - floor);
                if (amount == 0) return;
            }
            try manager.unlock(abi.encode(uint8(1), abi.encode(-int256(amount)))) {
                ghostFactoryLiquidity -= amount;
            } catch {
                _check(false, "factory removal rejected");
            }
        }
    }

    /// @notice Collecting accrued fees is a zero-delta modification; it must always be allowed.
    function collectFees() external {
        // v4 itself refuses a zero-delta update of an empty position (CannotUpdateEmptyPosition).
        if (ghostFactoryLiquidity == 0) return;
        try manager.unlock(abi.encode(uint8(1), abi.encode(int256(0)))) {}
        catch {
            _check(false, "fee collection rejected");
        }
    }

    /// @notice Plain launch-token transfers between participants are never taxed.
    function transfer(uint256 fromSeed, uint256 toSeed, uint96 rawAmount) external {
        address from = _participant(fromSeed);
        address to = _participant(toSeed);
        // Bounded so that no participant is drained of the launch token it needs for swaps.
        uint256 amount = uint256(rawAmount) % 1e22;
        if (amount > token.balanceOf(from)) amount = token.balanceOf(from);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 treasuryBefore = pair.balanceOf(TREASURY);
        uint256 growthBefore = _pairGrowth();
        vm.prank(from);
        token.transfer(to, amount);
        if (from == to) {
            _check(token.balanceOf(from) == fromBefore, "self transfer changed balance");
        } else {
            _check(token.balanceOf(from) == fromBefore - amount, "sender charged more than amount");
            _check(token.balanceOf(to) == toBefore + amount, "receiver got less than amount");
        }
        _check(pair.balanceOf(TREASURY) == treasuryBefore && _pairGrowth() == growthBefore, "transfer paid swap fees");
        ++ghostTransfers;
    }

    // ---------------------------------------------------------------- views for invariants

    function participants() external view returns (address[] memory list) {
        list = new address[](actors.length + 5);
        list[0] = address(this);
        list[1] = address(manager);
        list[2] = TREASURY;
        list[3] = DEAD;
        list[4] = address(gifter);
        for (uint256 i; i < actors.length; ++i) {
            list[5 + i] = address(actors[i]);
        }
    }

    function pairGrowth() external view returns (uint256) {
        return _pairGrowth();
    }

    // ---------------------------------------------------------------- unlock plumbing

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(key, abi.decode(payload, (IPoolManager.SwapParams)), "");
        } else if (action == 2) {
            // Pre-paying router: IMD is synced and transferred before the swap, settled after it.
            IPoolManager.SwapParams memory params = abi.decode(payload, (IPoolManager.SwapParams));
            uint256 input = uint256(-params.amountSpecified);
            manager.sync(Currency.wrap(PAIR));
            require(pair.transfer(address(manager), input));
            delta = manager.swap(key, params, "");
            require(manager.settle() == input, "prepaid amount");
            int128 tokenDelta = _pairIs0() ? delta.amount1() : delta.amount0();
            if (tokenDelta > 0) {
                manager.take(Currency.wrap(address(token)), address(this), uint256(uint128(tokenDelta)));
            }
            require(manager.currencyDelta(address(hook), Currency.wrap(PAIR)) == 0, "hook paired debt");
            require(manager.currencyDelta(address(hook), Currency.wrap(address(token))) == 0, "hook token debt");
            return abi.encode(delta);
        } else {
            (delta,) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -6000, tickUpper: 6000, liquidityDelta: abi.decode(payload, (int256)), salt: bytes32(0)
                }),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        // The hook must never be left with an open balance in the manager.
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

    function _modifyAsFactory(int256 liquidityDelta) private {
        manager.unlock(abi.encode(uint8(1), abi.encode(liquidityDelta)));
    }

    function _participant(uint256 seed) private view returns (address) {
        uint256 pick = seed % (actors.length + 1);
        return pick == 0 ? address(this) : address(actors[pick - 1]);
    }

    function _pairIs0() private view returns (bool) {
        return Currency.unwrap(key.currency0) == PAIR;
    }

    function _pairGrowth() private view returns (uint256) {
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return _pairIs0() ? growth0 : growth1;
    }

    function _params(bool buy, bool exactInput, uint256 amount) private view returns (IPoolManager.SwapParams memory) {
        bool zeroForOne = buy == _pairIs0();
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _liquidityParams(int24 lower, int24 upper, int256 amount, uint256 salt)
        private
        pure
        returns (IPoolManager.ModifyLiquidityParams memory)
    {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: lower, tickUpper: upper, liquidityDelta: amount, salt: bytes32(salt)
        });
    }

    function _observe(Vm.Log[] memory logs) private view returns (Seen memory seen) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 amount0, int128 amount1,,,, uint24 fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                seen.rawPair = _pairIs0() ? amount0 : amount1;
                seen.sawSwap = fee == 12500;
            } else if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEES_TOPIC) {
                (seen.gross, seen.anti, seen.treasury) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                seen.sawFees = true;
            } else if (logs[i].emitter == address(manager) && logs[i].topics[0] == DONATE_TOPIC) {
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i].data, (uint256, uint256));
                seen.donated += _pairIs0() ? amount0 : amount1;
                seen.donatedToken += _pairIs0() ? amount1 : amount0;
            }
        }
    }

    function _snapshot() private view returns (Snapshot memory snap) {
        snap.treasury = pair.balanceOf(TREASURY);
        snap.pending = hook.pendingTreasury();
        snap.managerPaired = pair.balanceOf(address(manager));
        snap.growth = _pairGrowth();
        snap.rate = hook.antiSnipeBps() + 50;
    }

    /// @dev True when the last swap revert carries `selector` anywhere in its data. The manager
    ///      wraps hook reverts in WrappedError(target, selector, reason, details), so the hook's
    ///      own selector sits inside `reason` rather than at the front.
    function _revertContains(bytes4 selector) private view returns (bool) {
        bytes memory data = lastSwapRevert;
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    function _check(bool condition, string memory reason) private {
        if (!condition && bytes(violation).length == 0) violation = reason;
    }
}

/// @title Random call sequences against the real v4 PoolManager with the SIMDTEST hook pool.
contract SIMDTESTHookInvariantTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant PAIR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint160 private constant FLAGS = 0x28cc;
    /// @dev Handler, two actors and the claim gifter each receive 1e27 IMD.
    uint256 private constant PAIR_SUPPLY = 4e27;
    uint256 private constant TOKEN_SUPPLY = 1_000_000_000e18;

    IPoolManager private manager;
    SIMDTEST private token;
    TestPairedToken private pair;
    SIMDTESTHook private hook;
    SIMDTESTHookHandler private handler;
    address[] private targets;

    function setUp() public {
        token = new SIMDTEST();
        TestPairedToken implementation = new TestPairedToken();
        vm.etch(PAIR, address(implementation).code);
        pair = TestPairedToken(PAIR);
        manager = IPoolManager(
            _create(abi.encodePacked(vm.getCode("PoolManager.sol:PoolManager"), abi.encode(address(this))))
        );
        handler = new SIMDTESTHookHandler(manager, token, pair);
        pair.mint(address(handler), 1e27);
        token.transfer(address(handler), TOKEN_SUPPLY);
        hook = _deployHook(address(handler));
        handler.launch(hook);
        targets.push(address(handler));
    }

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    /// @dev Foundry reads this to decide which contracts receive random calls.
    function targetContracts() public view returns (address[] memory) {
        return targets;
    }

    /// @dev Only the handler's actions are fuzzed; its launch and unlock plumbing are not user entry points.
    function targetSelectors() public view returns (FuzzSelector[] memory selectors) {
        bytes4[] memory actions = new bytes4[](10);
        actions[0] = SIMDTESTHookHandler.swap.selector;
        actions[1] = SIMDTESTHookHandler.roll.selector;
        actions[2] = SIMDTESTHookHandler.thirdPartyAddLiquidity.selector;
        actions[3] = SIMDTESTHookHandler.thirdPartyRemoveLiquidity.selector;
        actions[4] = SIMDTESTHookHandler.factoryModifyLiquidity.selector;
        actions[5] = SIMDTESTHookHandler.collectFees.selector;
        actions[6] = SIMDTESTHookHandler.transfer.selector;
        actions[7] = SIMDTESTHookHandler.prepaidBuy.selector;
        actions[8] = SIMDTESTHookHandler.payTreasury.selector;
        actions[9] = SIMDTESTHookHandler.giftClaims.selector;
        selectors = new FuzzSelector[](1);
        selectors[0] = FuzzSelector({addr: address(handler), selectors: actions});
    }

    function _create(bytes memory code) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "deployment failed");
    }

    function _deployHook(address factory) private returns (SIMDTESTHook deployed) {
        bytes memory code =
            abi.encodePacked(vm.getCode("SIMDTESTHook.sol:SIMDTESTHook"), abi.encode(manager, address(token), factory));
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

    function _sumBalances(address[] memory holders, bool launchToken) private view returns (uint256 total) {
        for (uint256 i; i < holders.length; ++i) {
            total += launchToken ? token.balanceOf(holders[i]) : pair.balanceOf(holders[i]);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_HandlerSawNoViolation() public view {
        require(bytes(handler.violation()).length == 0, handler.violation());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_PairedTokenIsNeverBurnedOrLost() public view {
        require(pair.totalSupply() == PAIR_SUPPLY, "paired supply changed");
        require(pair.balanceOf(handler.DEAD()) == 0, "paired token burned");
        require(_sumBalances(handler.participants(), false) == PAIR_SUPPLY, "paired token lost or created");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_LaunchTokenSupplyIsFixed() public view {
        require(token.totalSupply() == TOKEN_SUPPLY, "launch supply changed");
        require(_sumBalances(handler.participants(), true) == TOKEN_SUPPLY, "launch token lost or created");
        require(token.balanceOf(handler.DEAD()) == 1e26, "dead allocation moved");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_HookRetainsNothing() public view {
        require(pair.balanceOf(address(hook)) == 0, "hook holds paired token");
        require(token.balanceOf(address(hook)) == 0, "hook holds launch token");
        require(address(hook).balance == 0, "hook holds ether");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_TreasuryBalanceEqualsReportedFees() public view {
        // Every reported treasury fee, and every claim strangers gifted to the hook, is either
        // already with the treasury or still a hook-owned claim inside the manager. Nothing else
        // can hold it and nothing is lost between the two.
        require(
            pair.balanceOf(TREASURY) + hook.pendingTreasury() == handler.ghostTreasury() + handler.ghostGifted(),
            "treasury balance plus deferred claims differ from fee ledger"
        );
        require(token.balanceOf(TREASURY) == 0, "treasury received launch token");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_DeferredClaimsAreAlwaysBacked() public view {
        // Between transactions nothing is synced, so the manager physically holds the IMD behind
        // every deferred claim and a permissionless payTreasury can always clear the backlog.
        require(hook.pendingTreasury() <= pair.balanceOf(address(manager)), "claims exceed the manager's IMD");
        require(manager.balanceOf(address(hook), Currency.wrap(address(token)).toId()) == 0, "hook holds token claims");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_AntiSnipeScheduleIsLinearAndImmutable() public view {
        require(hook.initialized(), "pool closed");
        uint256 opening = handler.openingBlock();
        require(hook.openingBlock() == opening, "opening block moved");
        uint256 age = block.number - opening;
        uint256 expected = age >= 10 ? 0 : 3000 - age * 300;
        require(hook.antiSnipeBps() == expected, "anti-snipe rate off schedule");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_DonationsStayInsideTheManagerForLiquidity() public view {
        // Donated IMD is held by the manager for in-range positions; it never leaves as a burn
        // and never lands in the treasury ledger. Everything the manager holds beyond what the
        // participants deposited net of withdrawals is fee growth owed to positions.
        require(handler.ghostDonated() + handler.ghostTreasury() <= pair.totalSupply(), "fees exceed supply");
        if (handler.ghostDonated() != 0) require(handler.pairGrowth() != 0, "donation without fee growth");
        require(pair.balanceOf(address(manager)) + pair.balanceOf(TREASURY) >= handler.ghostTreasury(), "fees leaked");
    }
}
