// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Vm, TestPairedToken, LiquidityActor, Create2Helper, AtomicLauncher} from "./helpers/TestSupport.sol";

contract SIMDTESTHookTest is IUnlockCallback {
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
    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant DONATE_TOPIC = keccak256("Donate(bytes32,address,uint256,uint256)");
    bytes32 private constant FEES_TOPIC = keccak256("SwapFees(uint256,uint256,uint256)");

    IPoolManager private manager;
    SIMDTEST private token;
    TestPairedToken private pair;
    SIMDTESTHook private hook;
    PoolKey private key;

    struct Observations {
        int128 rawPair;
        uint256 gross;
        uint256 anti;
        uint256 treasury;
        uint256 donated;
        bool sawSwap;
        bool sawFees;
    }

    struct BeforeTrade {
        uint256 treasury;
        uint256 user;
        uint256 managerBalance;
        uint256 tokenBalance;
        uint256 growth;
        uint256 supply;
    }

    function setUp() public {
        token = new SIMDTEST();
        TestPairedToken implementation = new TestPairedToken();
        vm.etch(PAIR, address(implementation).code);
        pair = TestPairedToken(PAIR);
        pair.mint(address(this), 1e27);
        manager = IPoolManager(
            _create(abi.encodePacked(vm.getCode("PoolManager.sol:PoolManager"), abi.encode(address(this))))
        );
        _deployHookAndPool();
    }

    function _create(bytes memory code) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "deployment failed");
    }

    function _hookCode(address factory) private returns (bytes memory) {
        return
            abi.encodePacked(vm.getCode("SIMDTESTHook.sol:SIMDTESTHook"), abi.encode(manager, address(token), factory));
    }

    function _mineSalt(address deployer, bytes memory code) private view returns (bytes32 salt) {
        bytes32 codeHash = keccak256(code);
        for (uint256 candidate;; ++candidate) {
            salt = bytes32(candidate);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
            if (uint160(predicted) & 0x3fff == FLAGS && predicted.code.length == 0) return salt;
        }
    }

    function _deployHook() private returns (SIMDTESTHook deployedHook) {
        bytes memory code = _hookCode(address(this));
        bytes32 salt = _mineSalt(address(this), code);
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && uint160(deployed) & 0x3fff == FLAGS, "CREATE2 deployment failed");
        return SIMDTESTHook(deployed);
    }

    function _poolKey(SIMDTESTHook target) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token) < PAIR ? address(token) : PAIR),
            currency1: Currency.wrap(address(token) < PAIR ? PAIR : address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(target))
        });
    }

    function _deployHookAndPool() private {
        hook = _deployHook();
        key = _poolKey(hook);
        manager.initialize(key, INITIAL_PRICE);
        manager.unlock(abi.encode(uint8(1), abi.encode(int256(uint256(LIQUIDITY)))));
    }

    function _newActor() private returns (LiquidityActor actor) {
        actor = new LiquidityActor(manager);
        pair.mint(address(actor), 1e27);
        token.transfer(address(actor), 1e26);
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

    function _pairIs0() private view returns (bool) {
        return Currency.unwrap(key.currency0) == PAIR;
    }

    function _params(bool buy, bool exactInput, uint256 amount) private view returns (IPoolManager.SwapParams memory) {
        bool zeroForOne = buy == _pairIs0();
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _swap(IPoolManager.SwapParams memory params) private returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), abi.encode(params))), (BalanceDelta));
    }

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
                    tickLower: -600, tickUpper: 600, liquidityDelta: abi.decode(payload, (int256)), salt: bytes32(0)
                }),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
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

    function _observations(Vm.Log[] memory logs) private view returns (Observations memory result) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 amount0, int128 amount1,,,, uint24 fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                result.rawPair = _pairIs0() ? amount0 : amount1;
                require(fee == 12500, "base fee changed");
                result.sawSwap = true;
            } else if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEES_TOPIC) {
                (result.gross, result.anti, result.treasury) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                result.sawFees = true;
            } else if (logs[i].emitter == address(manager) && logs[i].topics[0] == DONATE_TOPIC) {
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i].data, (uint256, uint256));
                require((_pairIs0() ? amount1 : amount0) == 0, "donated launch token");
                result.donated += _pairIs0() ? amount0 : amount1;
            }
        }
    }

    function _pairGrowth() private view returns (uint256) {
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return _pairIs0() ? growth0 : growth1;
    }

    function _assertTrade(bool buy, bool exactInput, uint256 amount) private {
        BeforeTrade memory beforeTrade = BeforeTrade({
            treasury: pair.balanceOf(TREASURY),
            user: pair.balanceOf(address(this)),
            managerBalance: pair.balanceOf(address(manager)),
            tokenBalance: token.balanceOf(address(this)),
            growth: _pairGrowth(),
            supply: pair.totalSupply()
        });
        vm.recordLogs();
        BalanceDelta delta = _swap(_params(buy, exactInput, amount));
        Observations memory seen = _observations(vm.getRecordedLogs());
        require(seen.sawSwap && seen.sawFees, "missing accounting events");
        int128 pairedDelta = _pairIs0() ? delta.amount0() : delta.amount1();
        int128 tokenDelta = _pairIs0() ? delta.amount1() : delta.amount0();
        uint256 gross = buy ? uint256(-int256(pairedDelta)) : uint256(uint128(seen.rawPair));
        uint256 treasuryFee = gross * 50 / 10000;
        uint256 antiFee = gross * (hook.antiSnipeBps() + 50) / 10000 - treasuryFee;
        require(seen.gross == gross && seen.treasury == treasuryFee && seen.anti == antiFee, "fee amounts");
        require(seen.donated == antiFee, "donation accounting");
        require(pair.balanceOf(TREASURY) - beforeTrade.treasury == treasuryFee, "treasury transfer");
        require(int256(pair.balanceOf(address(this))) - int256(beforeTrade.user) == pairedDelta, "paired settlement");
        require(
            int256(token.balanceOf(address(this))) - int256(beforeTrade.tokenBalance) == tokenDelta, "token settlement"
        );
        require(
            pair.balanceOf(address(manager)) + pair.balanceOf(address(this)) + pair.balanceOf(TREASURY)
                == beforeTrade.managerBalance + beforeTrade.user + beforeTrade.treasury,
            "paired conservation"
        );
        require(pair.balanceOf(address(hook)) == 0 && token.balanceOf(address(hook)) == 0, "retained hook funds");
        require(pair.totalSupply() == beforeTrade.supply && pair.balanceOf(address(0xdead)) == 0, "paired burn");
        require(manager.getLiquidity(key.toId()) == LIQUIDITY, "donation changed liquidity units");
        if (buy) {
            require(seen.rawPair == -int256(gross - treasuryFee - antiFee), "buy core amount");
            require(_pairGrowth() - beforeTrade.growth >= antiFee * (1 << 128) / LIQUIDITY, "donation fee growth");
        } else {
            require(pairedDelta == int256(gross - treasuryFee - antiFee), "sell net amount");
            require(_pairGrowth() - beforeTrade.growth == antiFee * (1 << 128) / LIQUIDITY, "exact donation fee growth");
        }
        if (exactInput) {
            require((buy ? pairedDelta : tokenDelta) == -int256(amount), "exact input");
        } else {
            require((buy ? tokenDelta : pairedDelta) == int256(amount), "exact output");
        }
    }

    function testAllFourSwapModesDuringAntiSnipe() public {
        _assertTrade(true, true, 100e18);
        _assertTrade(true, false, 100e18);
        _assertTrade(false, true, 100e18);
        _assertTrade(false, false, 100e18);
    }

    function testAllFourSwapModesAfterAntiSnipe() public {
        vm.roll(hook.openingBlock() + 10);
        _assertTrade(true, true, 100e18);
        _assertTrade(true, false, 100e18);
        _assertTrade(false, true, 100e18);
        _assertTrade(false, false, 100e18);
    }

    function testDecayEveryBlockAndDoesNotRestart() public {
        uint256 opening = hook.openingBlock();
        for (uint256 age; age <= 11; ++age) {
            vm.roll(opening + age);
            require(hook.antiSnipeBps() == (age < 10 ? 3000 - age * 300 : 0), "decay rate");
            _assertTrade(false, true, 100e18);
            require(hook.openingBlock() == opening, "opening block changed");
        }
        vm.roll(opening + 1_000_000);
        require(hook.antiSnipeBps() == 0, "anti-snipe restarted");
    }

    function testFuzzFeesConserveGrossPairedAmount(uint96 rawAmount, uint8 rawAge, bool buy, bool exactInput) public {
        uint256 amount = uint256(rawAmount) % 1000e18 + 1e6;
        vm.roll(hook.openingBlock() + uint256(rawAge) % 20);
        _assertTrade(buy, exactInput, amount);
    }

    function testTinyAmountsAndRoundingBoundaries() public {
        uint256[7] memory amounts = [uint256(1), 2, 3, 199, 200, 9999, 10000];
        for (uint256 i; i < amounts.length; ++i) {
            _assertTrade(true, true, amounts[i]);
            _assertTrade(true, false, amounts[i]);
            _assertTrade(false, true, amounts[i]);
            _assertTrade(false, false, amounts[i]);
        }
    }

    function testBothCurrencyOrderings() public {
        TestPairedToken implementation = new TestPairedToken();
        address alternate = address(_pairIs0() ? uint160(PAIR) - 1 : uint160(PAIR) + 1);
        vm.etch(alternate, address(implementation).code);
        TestPairedToken(alternate).mint(address(this), 1e27);
        token = SIMDTEST(alternate);
        _deployHookAndPool();
        testAllFourSwapModesDuringAntiSnipe();
        testAllFourSwapModesAfterAntiSnipe();
    }

    function testPairedSpecifiedPartialFillsRevertAtomically() public {
        uint256 treasuryBefore = pair.balanceOf(TREASURY);
        for (uint256 mode; mode < 2; ++mode) {
            IPoolManager.SwapParams memory params = _params(mode == 0, mode == 0, 1000e18);
            params.sqrtPriceLimitX96 = params.zeroForOne ? INITIAL_PRICE - 1e12 : INITIAL_PRICE + 1e12;
            vm.expectRevert();
            manager.unlock(abi.encode(uint8(0), abi.encode(params)));
            require(pair.balanceOf(TREASURY) == treasuryBefore, "partial fill charged fee");
            (uint160 price,,,) = manager.getSlot0(key.toId());
            require(price == INITIAL_PRICE, "partial fill changed pool");
        }
    }

    function testPairedUnspecifiedPartialFillUsesRealizedAmount() public {
        for (uint256 mode; mode < 2; ++mode) {
            bool buy = mode == 1;
            IPoolManager.SwapParams memory params = _params(buy, !buy, 1000e18);
            (uint160 price,,,) = manager.getSlot0(key.toId());
            params.sqrtPriceLimitX96 = params.zeroForOne ? price - 1e12 : price + 1e12;
            vm.recordLogs();
            BalanceDelta delta = _swap(params);
            Observations memory seen = _observations(vm.getRecordedLogs());
            int128 tokenDelta = _pairIs0() ? delta.amount1() : delta.amount0();
            int128 pairedDelta = _pairIs0() ? delta.amount0() : delta.amount1();
            uint256 actualToken = uint256(buy ? int256(tokenDelta) : -int256(tokenDelta));
            uint256 realizedGross = buy ? uint256(-int256(pairedDelta)) : uint256(uint128(seen.rawPair));
            require(actualToken > 0 && actualToken < 1000e18, "expected partial fill");
            require(seen.gross == realizedGross, "gross not realized");
            require(seen.treasury == seen.gross * 50 / 10000, "partial treasury fee");
            require(seen.anti + seen.treasury == seen.gross * 3050 / 10000, "partial anti fee");
        }
    }

    function testTreasuryTransferFailureRevertsDonationAndSwap() public {
        pair.rejectRecipient(TREASURY);
        uint256 beforeGrowth = _pairGrowth();
        uint256 beforeUser = pair.balanceOf(address(this));
        IPoolManager.SwapParams memory params = _params(false, true, 100e18);
        vm.expectRevert();
        manager.unlock(abi.encode(uint8(0), abi.encode(params)));
        require(_pairGrowth() == beforeGrowth, "donation persisted on failure");
        require(pair.balanceOf(address(this)) == beforeUser && pair.balanceOf(TREASURY) == 0, "balances changed");
        (uint160 price,,,) = manager.getSlot0(key.toId());
        require(price == INITIAL_PRICE, "price changed on failure");
    }

    function testDrainedRangeRoutesAntiSnipeToTreasury() public {
        // This sell exhausts the active range. Its unspecified IMD amount permits a partial
        // fill, but no position remains in range to receive a donation, so the anti-snipe
        // amount follows the treasury fee instead of failing the swap.
        vm.roll(hook.openingBlock() + 9);
        require(hook.antiSnipeBps() == 300, "window");
        vm.recordLogs();
        BalanceDelta delta = _swap(_params(false, true, 1e24));
        Observations memory seen = _observations(vm.getRecordedLogs());
        int128 tokenDelta = _pairIs0() ? delta.amount1() : delta.amount0();
        require(tokenDelta < 0 && tokenDelta > -1e24, "expected partial fill");
        require(manager.getLiquidity(key.toId()) == 0, "range not drained");
        uint256 gross = uint256(uint128(seen.rawPair));
        require(seen.gross == gross && seen.anti == 0 && seen.donated == 0, "donation without liquidity");
        require(seen.treasury == gross * 350 / 10000, "treasury did not absorb anti-snipe amount");
        require(pair.balanceOf(TREASURY) == seen.treasury, "treasury transfer");
        require(pair.balanceOf(address(hook)) == 0, "retained hook funds");
    }

    function testDrainedRangeAfterWindowChargesTreasuryOnly() public {
        vm.roll(hook.openingBlock() + 10);
        vm.recordLogs();
        _swap(_params(false, true, 1e24));
        Observations memory seen = _observations(vm.getRecordedLogs());
        require(manager.getLiquidity(key.toId()) == 0, "range not drained");
        require(seen.anti == 0 && seen.donated == 0 && seen.treasury == seen.gross * 50 / 10000, "post-window fees");
    }

    function testThirdPartyCannotAddLiquidityDuringAntiSnipe() public {
        LiquidityActor actor = _newActor();
        uint256 opening = hook.openingBlock();
        for (uint256 age; age < 10; ++age) {
            vm.roll(opening + age);
            vm.expectRevert();
            actor.modifyLiquidity(key, _liquidityParams(-60, 60, 1e24, 1));
        }
        require(manager.getLiquidity(key.toId()) == LIQUIDITY, "locked addition changed liquidity");
        // The factory itself may keep seeding during the window.
        vm.roll(opening + 5);
        manager.unlock(abi.encode(uint8(1), abi.encode(int256(1e23))));
        require(manager.getLiquidity(key.toId()) == LIQUIDITY + 1e23, "factory addition rejected");
        // Removals are never restricted, including the factory's own.
        manager.unlock(abi.encode(uint8(1), abi.encode(-int256(1e23))));
        require(manager.getLiquidity(key.toId()) == LIQUIDITY, "factory removal rejected");
        // Once the anti-snipe fee reaches zero, anyone may provide liquidity.
        vm.roll(opening + 10);
        actor.modifyLiquidity(key, _liquidityParams(-60, 60, 1e24, 1));
        require(manager.getLiquidity(key.toId()) == 2 * LIQUIDITY, "post-window addition rejected");
        actor.modifyLiquidity(key, _liquidityParams(-60, 60, -1e24, 1));
        require(manager.getLiquidity(key.toId()) == LIQUIDITY, "post-window removal rejected");
    }

    function testJitLiquidityCannotCaptureDonation() public {
        LiquidityActor searcher = _newActor();
        LiquidityActor.Step[] memory sandwich = new LiquidityActor.Step[](3);
        sandwich[0].liquidity = _liquidityParams(-60, 60, 100e24, 1);
        sandwich[1].isSwap = true;
        sandwich[1].swap = _params(true, true, 100e18);
        sandwich[2].liquidity = _liquidityParams(-60, 60, -100e24, 1);
        uint256 growthBefore = _pairGrowth();
        vm.expectRevert();
        searcher.run(key, sandwich);
        require(_pairGrowth() == growthBefore && pair.balanceOf(TREASURY) == 0, "sandwich executed");
        // The same buy made honestly pays its donation to the seeded launch position alone.
        LiquidityActor.Step[] memory honest = new LiquidityActor.Step[](1);
        honest[0].isSwap = true;
        honest[0].swap = _params(true, true, 100e18);
        vm.recordLogs();
        searcher.run(key, honest);
        Observations memory seen = _observations(vm.getRecordedLogs());
        require(seen.anti == 30e18 && seen.donated == 30e18, "anti-snipe donation");
        uint256 beforePair = pair.balanceOf(address(this));
        manager.unlock(abi.encode(uint8(1), abi.encode(int256(0))));
        uint256 collected = pair.balanceOf(address(this)) - beforePair;
        require(collected + 1 >= seen.anti, "seed position did not receive the whole donation");
    }

    function testLaunchTransactionMaySeedThroughPeriphery() public {
        AtomicLauncher launcher = new AtomicLauncher(manager);
        LiquidityActor periphery = _newActor();
        bytes memory code = _hookCode(address(launcher));
        SIMDTESTHook launched = SIMDTESTHook(launcher.deployHook(code, _mineSalt(address(launcher), code)));
        PoolKey memory launchKey = _poolKey(launched);
        require(launched.launchFactory() == address(launcher), "factory binding");
        // initialize and a periphery-routed seed succeed inside the launch transaction.
        launcher.launch(launchKey, INITIAL_PRICE, periphery, int256(uint256(LIQUIDITY)));
        require(launched.initialized() && manager.getLiquidity(launchKey.toId()) == LIQUIDITY, "launch seed");
        // Outside that transaction the periphery is an ordinary third party during the window.
        vm.expectRevert();
        periphery.modifyLiquidity(launchKey, _liquidityParams(-60, 60, 1e24, 1));
        vm.roll(launched.openingBlock() + 10);
        periphery.modifyLiquidity(launchKey, _liquidityParams(-60, 60, 1e24, 1));
        require(manager.getLiquidity(launchKey.toId()) == 2 * LIQUIDITY, "post-window addition rejected");
    }

    function testHookDeployedThroughCreate2HelperStillInitializes() public {
        Create2Helper helper = new Create2Helper();
        bytes memory code = _hookCode(address(this));
        SIMDTESTHook deployed = SIMDTESTHook(helper.deploy(code, _mineSalt(address(helper), code)));
        require(deployed.launchFactory() == address(this), "factory is the constructor argument, not the deployer");
        PoolKey memory helperKey = _poolKey(deployed);
        vm.prank(address(helper));
        vm.expectRevert();
        manager.initialize(helperKey, INITIAL_PRICE);
        manager.initialize(helperKey, INITIAL_PRICE);
        require(deployed.initialized(), "factory could not initialize a helper-deployed hook");
    }

    function testConstructorRejectsZeroFactory() public {
        bytes memory code = _hookCode(address(0));
        bytes32 salt = _mineSalt(address(this), code);
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed == address(0), "zero factory accepted");
    }

    function testDonationCanBeClaimedByLiquidityProvider() public {
        vm.recordLogs();
        _swap(_params(false, true, 100e18));
        Observations memory seen = _observations(vm.getRecordedLogs());
        uint256 beforePair = pair.balanceOf(address(this));
        manager.unlock(abi.encode(uint8(1), abi.encode(int256(0))));
        uint256 collected = pair.balanceOf(address(this)) - beforePair;
        require(collected <= seen.anti && seen.anti - collected <= 1, "LP did not receive donation");
    }

    function testCallbacksRequireManager() public {
        vm.expectRevert(SIMDTESTHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, INITIAL_PRICE);
        vm.expectRevert(SIMDTESTHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, _params(true, true, 100e18), "");
        vm.expectRevert(SIMDTESTHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, _params(true, true, 100e18), BalanceDelta.wrap(0), "");
        vm.expectRevert(SIMDTESTHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, _liquidityParams(-60, 60, 1, 0), "");
    }

    function testInitializationOnlyFactoryAndOnlyOnce() public {
        SIMDTESTHook fresh = _deployHook();
        PoolKey memory freshKey = key;
        freshKey.hooks = IHooks(address(fresh));
        vm.prank(TREASURY);
        vm.expectRevert();
        manager.initialize(freshKey, INITIAL_PRICE);
        require(!fresh.initialized(), "unauthorized opening");
        require(fresh.antiSnipeBps() == 0, "anti-snipe active before pool creation");
        vm.roll(block.number + 100);
        manager.initialize(freshKey, INITIAL_PRICE);
        require(fresh.initialized() && fresh.openingBlock() == block.number, "opening not recorded");
        require(fresh.antiSnipeBps() == 3000, "deployment consumed anti-snipe window");
        vm.expectRevert();
        manager.initialize(freshKey, INITIAL_PRICE);
    }

    function testWrongPoolParametersRejected() public {
        SIMDTESTHook fresh = _deployHook();
        PoolKey memory freshKey = key;
        freshKey.hooks = IHooks(address(fresh));
        freshKey.fee = 3000;
        vm.expectRevert();
        manager.initialize(freshKey, INITIAL_PRICE);
        freshKey.fee = 12500;
        freshKey.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(freshKey, INITIAL_PRICE);
        require(!fresh.initialized(), "invalid pool initialized hook");
    }

    function testPermissionFlagsAndNoAdministration() public {
        require(uint160(address(hook)) & 0x3fff == FLAGS, "wrong hook flags");
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        require(permissions.beforeInitialize && permissions.beforeSwap && permissions.afterSwap, "missing callbacks");
        require(permissions.beforeAddLiquidity, "missing liquidity gate");
        require(permissions.beforeSwapReturnDelta && permissions.afterSwapReturnDelta, "missing delta permissions");
        require(
            !permissions.afterInitialize && !permissions.afterAddLiquidity && !permissions.beforeRemoveLiquidity
                && !permissions.afterRemoveLiquidity && !permissions.beforeDonate && !permissions.afterDonate
                && !permissions.afterAddLiquidityReturnDelta && !permissions.afterRemoveLiquidityReturnDelta,
            "extra hook permissions"
        );
        bytes4[5] memory selectors = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("unpause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(hook).call(abi.encodeWithSelector(selectors[i], address(this)));
            require(!success, "administration exposed");
        }
    }

    function testStandardTransfersDoNotPaySwapFees() public {
        uint256 beforeTreasury = pair.balanceOf(TREASURY);
        uint256 beforeGrowth = _pairGrowth();
        uint256 beforeBalance = token.balanceOf(TREASURY);
        token.transfer(TREASURY, 123e18);
        require(token.balanceOf(TREASURY) - beforeBalance == 123e18, "taxed standard transfer");
        require(pair.balanceOf(TREASURY) == beforeTreasury && _pairGrowth() == beforeGrowth, "transfer triggered hook");
    }

    function testHookCreationAndRuntimeFitEvmLimits() public {
        require(vm.getCode("SIMDTESTHook.sol:SIMDTESTHook").length + 64 <= 49152, "EIP-3860");
        require(address(hook).code.length <= 24576, "EIP-170");
    }
}
