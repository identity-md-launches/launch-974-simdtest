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

    // Ghost ledger.
    string public violation;
    uint256 public openingBlock;
    uint256 public ghostTreasury;
    uint256 public ghostDonated;
    uint256 public ghostSwaps;
    uint256 public ghostSwapReverts;
    uint256 public ghostStarvedBuys;
    uint256 public ghostWindowSwaps;
    uint256 public ghostDonatingSwaps;
    uint256 public ghostDrainedSwaps;
    uint256 public ghostThirdPartyAdds;
    uint256 public ghostThirdPartyRejections;
    uint256 public ghostTransfers;
    uint256 public ghostFactoryLiquidity;
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
        // The 10% dead-address allocation of the launch plan.
        token.transfer(DEAD, 1e26);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------- fuzzed actions

    /// @notice Random swap in one of the four modes by the handler or a third party.
    function swap(uint256 actorSeed, uint8 mode, uint96 rawAmount) external {
        // Mostly moderate trades; about one in sixty-four is large enough to push the price out of
        // the seeded range. Hash-derived so the fuzzer's edge-value bias does not make it common.
        bool large = uint256(keccak256(abi.encode(actorSeed, rawAmount, mode))) % 64 == 0;
        uint256 amount = large ? uint256(rawAmount) % 2e23 + 1e22 : uint256(rawAmount) % 5e21 + 1;
        bool buy = mode & 1 == 1;
        bool exactInput = mode & 2 == 2;
        IPoolManager.SwapParams memory params = _params(buy, exactInput, amount);
        uint256 who = actorSeed % (actors.length + 1);
        uint256 treasuryBefore = pair.balanceOf(TREASURY);
        uint256 growthBefore = _pairGrowth();
        uint256 rate = hook.antiSnipeBps() + 50;
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
        Seen memory seen = _observe(vm.getRecordedLogs());
        if (!ok) {
            ++ghostSwapReverts;
            // Reported separately: a buy that fails because the manager holds less IMD than the
            // treasury fee the hook takes in afterSwap (see .imd-findings.json). Not a ledger
            // violation, but the pool cannot be bought until someone deposits IMD.
            if (buy && pair.balanceOf(address(manager)) < amount * 50 / BPS) ++ghostStarvedBuys;
            _check(pair.balanceOf(TREASURY) == treasuryBefore, "reverted swap paid treasury");
            _check(_pairGrowth() == growthBefore, "reverted swap donated");
            return;
        }
        ++ghostSwaps;
        _check(seen.sawSwap && seen.sawFees, "swap without fee accounting");
        _check(seen.donatedToken == 0, "launch token donated");
        _check(seen.donated == seen.anti, "donation differs from reported anti-snipe amount");
        _check(pair.balanceOf(TREASURY) - treasuryBefore == seen.treasury, "treasury transfer mismatch");
        uint256 combined = seen.gross * rate / BPS;
        _check(seen.anti + seen.treasury == combined, "fee split does not equal combined fee");
        uint256 baseTreasury = seen.gross * 50 / BPS;
        if (seen.anti != 0) {
            _check(seen.treasury == baseTreasury, "treasury fee not 0.5% while donating");
            ++ghostDonatingSwaps;
            _check(_pairGrowth() > growthBefore, "donation did not raise paired fee growth");
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
            // The factory keeps at least a quarter of its seed so sequences stay tradeable; full
            // withdrawal of the launch position is a liveness scenario covered by the findings.
            uint256 floor = SEED_LIQUIDITY / 4;
            if (ghostFactoryLiquidity <= floor) return;
            uint256 amount = uint256(rawAmount) % (ghostFactoryLiquidity - floor);
            if (amount == 0) return;
            try manager.unlock(abi.encode(uint8(1), abi.encode(-int256(amount)))) {
                ghostFactoryLiquidity -= amount;
            } catch {
                _check(false, "factory removal rejected");
            }
        }
    }

    /// @notice Collecting accrued fees is a zero-delta modification; it must always be allowed.
    function collectFees() external {
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
        list = new address[](actors.length + 4);
        list[0] = address(this);
        list[1] = address(manager);
        list[2] = TREASURY;
        list[3] = DEAD;
        for (uint256 i; i < actors.length; ++i) {
            list[4 + i] = address(actors[i]);
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
    uint256 private constant PAIR_SUPPLY = 3e27;
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
        bytes4[] memory actions = new bytes4[](7);
        actions[0] = SIMDTESTHookHandler.swap.selector;
        actions[1] = SIMDTESTHookHandler.roll.selector;
        actions[2] = SIMDTESTHookHandler.thirdPartyAddLiquidity.selector;
        actions[3] = SIMDTESTHookHandler.thirdPartyRemoveLiquidity.selector;
        actions[4] = SIMDTESTHookHandler.factoryModifyLiquidity.selector;
        actions[5] = SIMDTESTHookHandler.collectFees.selector;
        actions[6] = SIMDTESTHookHandler.transfer.selector;
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
        require(pair.balanceOf(TREASURY) == handler.ghostTreasury(), "treasury balance differs from fee ledger");
        require(token.balanceOf(TREASURY) == 0, "treasury received launch token");
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
