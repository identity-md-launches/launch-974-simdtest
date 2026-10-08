// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

interface PropertyVm {
    function roll(uint256 newHeight) external;
    function prank(address sender) external;
    function expectRevert(bytes4 reason) external;
}

/// @dev Code-bearing stand-in. The callbacks under test here are view or revert before touching
///      the manager, so no manager logic is required.
contract PropertyManagerFixture {}

/// @title Property tests of the hook's fee arithmetic and callback guards, driven directly.
/// @dev The pool-level integration (settlement, donation, treasury transfer) is covered against
///      the real PoolManager elsewhere. Here the callbacks are called as the manager would call
///      them, so every edge of the arithmetic can be fuzzed without pool liquidity limits.
contract SIMDTESTHookPropertyTest {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    PropertyVm private constant vm = PropertyVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant PAIR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 private constant BPS = 10000;
    uint256 private constant MAX_AMOUNT = uint256(uint128(type(int128).max));
    uint160 private constant FLAGS = 0x28cc;
    uint160 private constant PRICE = 79228162514264337593543950336;

    SIMDTEST private token;
    IPoolManager private manager;
    SIMDTESTHook private hook;
    PoolKey private key;
    bool private pairIs0;

    function setUp() public {
        token = new SIMDTEST();
        manager = IPoolManager(address(new PropertyManagerFixture()));
        bytes memory code =
            abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token), address(this)));
        bytes32 codeHash = keccak256(code);
        for (uint256 nonce;; ++nonce) {
            bytes32 salt = bytes32(nonce);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
            if (uint160(predicted) & 0x3fff == FLAGS) {
                hook = new SIMDTESTHook{salt: salt}(manager, address(token), address(this));
                break;
            }
        }
        pairIs0 = PAIR < address(token);
        key = PoolKey({
            currency0: Currency.wrap(pairIs0 ? PAIR : address(token)),
            currency1: Currency.wrap(pairIs0 ? address(token) : PAIR),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _open() private {
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), key, PRICE);
    }

    function _swapParams(bool pairSpecified, bool exactInput, int256 amount)
        private
        view
        returns (IPoolManager.SwapParams memory)
    {
        // specified currency is currency0 when (exactInput == zeroForOne).
        bool specifiedIs0 = pairSpecified == pairIs0;
        bool zeroForOne = exactInput == specifiedIs0;
        return IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: PRICE});
    }

    function _beforeSwap(IPoolManager.SwapParams memory params) private returns (BeforeSwapDelta delta, uint24 lpFee) {
        vm.prank(address(manager));
        bytes4 selector;
        (selector, delta, lpFee) = hook.beforeSwap(address(this), key, params, "");
        require(selector == IHooks.beforeSwap.selector, "selector");
    }

    function _rateAt(uint256 age) private pure returns (uint256) {
        return (age >= 10 ? 0 : 3000 - age * 300) + 50;
    }

    // ------------------------------------------------------------------ anti-snipe schedule

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzAntiSnipeIsZeroBeforeOpeningAtAnyHeight(uint64 height) public {
        vm.roll(height);
        require(hook.antiSnipeBps() == 0, "anti-snipe before pool creation");
        require(!hook.initialized() && hook.openingBlock() == 0, "state before opening");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzAntiSnipeDecaysLinearlyThenStaysZero(uint64 openAt, uint64 age) public {
        vm.roll(openAt);
        _open();
        require(hook.openingBlock() == openAt && hook.antiSnipeBps() == 3000, "opening rate");
        vm.roll(uint256(openAt) + age);
        uint256 expected = age >= 10 ? 0 : 3000 - uint256(age) * 300;
        require(hook.antiSnipeBps() == expected, "linear decay");
        require(hook.antiSnipeBps() <= 3000, "rate above 30%");
        // Monotone: the next block never charges more than this one.
        vm.roll(uint256(openAt) + age + 1);
        require(hook.antiSnipeBps() <= expected, "decay reversed");
        // Opening block does not move with time.
        require(hook.openingBlock() == openAt, "opening block drifted");
    }

    function testAntiSnipeTableIsExact() public {
        _open();
        uint256 opening = block.number;
        uint16[11] memory table = [3000, 2700, 2400, 2100, 1800, 1500, 1200, 900, 600, 300, 0];
        for (uint256 age; age < table.length; ++age) {
            vm.roll(opening + age);
            require(hook.antiSnipeBps() == table[age], "table mismatch");
        }
        vm.roll(opening + type(uint32).max);
        require(hook.antiSnipeBps() == 0, "far future rate");
    }

    // ------------------------------------------------------------------ fee arithmetic

    /// @dev Exact input of IMD: the hook takes floor(amount * rate / BPS) from the specified side.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzExactInputPairedFeeIsFloorOfRate(uint128 rawAmount, uint8 rawAge) public {
        _open();
        uint256 age = rawAge % 12;
        vm.roll(block.number + age);
        uint256 amount = uint256(rawAmount) % MAX_AMOUNT + 1;
        (BeforeSwapDelta delta, uint24 lpFee) = _beforeSwap(_swapParams(true, true, -int256(amount)));
        uint256 expected = amount * _rateAt(age) / BPS;
        require(uint256(uint128(delta.getSpecifiedDelta())) == expected, "exact-input fee");
        require(delta.getUnspecifiedDelta() == 0, "unspecified side charged in beforeSwap");
        require(lpFee == 0, "LP fee override set");
        require(expected <= amount * 3050 / BPS && expected >= amount * 50 / BPS, "fee out of bounds");
        require(amount - expected > 0, "fee consumed whole input");
    }

    /// @dev Exact output of IMD: the hook grosses up so that gross - floor(gross * rate / BPS) == net,
    ///      with the smallest such gross. Fee splitting afterwards never alters the net.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzExactOutputPairedGrossUpIsMinimalAndExact(uint128 rawNet, uint8 rawAge) public {
        _open();
        uint256 age = rawAge % 12;
        vm.roll(block.number + age);
        uint256 rate = _rateAt(age);
        // Keep gross inside the int128 domain so the call cannot legitimately revert.
        uint256 net = uint256(rawNet) % (MAX_AMOUNT * (BPS - rate) / BPS - 1) + 1;
        (BeforeSwapDelta delta,) = _beforeSwap(_swapParams(true, false, int256(net)));
        uint256 fee = uint256(uint128(delta.getSpecifiedDelta()));
        uint256 gross = net + fee;
        require(gross - gross * rate / BPS == net, "gross-up does not return the requested net");
        require(gross == 1 || (gross - 1) - (gross - 1) * rate / BPS < net, "gross-up not minimal");
        require(fee == gross * rate / BPS, "fee is not the rate applied to gross");
        uint256 treasury = gross * 50 / BPS;
        require(treasury + (fee - treasury) == fee, "split loses wei");
        require(fee - treasury <= gross * (rate - 50) / BPS + 1, "anti-snipe share too large");
    }

    /// @dev Exact output of IMD that would need a gross above int128 max is refused, not wrapped.
    /// forge-config: default.fuzz.runs = 500
    function testFuzzExactOutputBeyondInt128GrossReverts(uint64 rawExcess, uint8 rawAge) public {
        _open();
        uint256 age = rawAge % 12;
        vm.roll(block.number + age);
        uint256 rate = _rateAt(age);
        // Smallest net whose minimal gross exceeds int128 max: ceil(MAX * (BPS - rate) / BPS) + 1.
        uint256 net = (MAX_AMOUNT * (BPS - rate) + BPS - 1) / BPS + 1 + uint256(rawExcess) % 1000;
        if (net > MAX_AMOUNT) net = MAX_AMOUNT;
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.beforeSwap(address(this), key, _swapParams(true, false, int256(net)), "");
    }

    /// @dev When the launch token is the specified currency no fee can be known in beforeSwap.
    /// forge-config: default.fuzz.runs = 500
    function testFuzzTokenSpecifiedSwapsTakeNothingInBeforeSwap(uint128 rawAmount, bool exactInput, uint8 rawAge)
        public
    {
        _open();
        vm.roll(block.number + rawAge % 12);
        int256 amount = int256(uint256(rawAmount) % MAX_AMOUNT + 1);
        (BeforeSwapDelta delta, uint24 lpFee) =
            _beforeSwap(_swapParams(false, exactInput, exactInput ? -amount : amount));
        require(BeforeSwapDelta.unwrap(delta) == 0, "token-specified swap charged in beforeSwap");
        require(lpFee == 0, "LP fee override set");
    }

    /// @dev The combined fee must be at most 30.5% at opening and exactly 0.5% from block B+10 on.
    /// forge-config: default.fuzz.runs = 500
    function testFuzzCombinedRateBoundsAcrossWindow(uint128 rawAmount, uint32 age) public {
        _open();
        vm.roll(block.number + age);
        uint256 amount = uint256(rawAmount) % MAX_AMOUNT + 1;
        (BeforeSwapDelta delta,) = _beforeSwap(_swapParams(true, true, -int256(amount)));
        uint256 fee = uint256(uint128(delta.getSpecifiedDelta()));
        if (age >= 10) {
            require(fee == amount * 50 / BPS, "post-window fee is not exactly 0.5%");
        } else {
            require(fee >= amount * 50 / BPS && fee <= amount * 3050 / BPS, "window fee outside [0.5%, 30.5%]");
        }
    }

    // ------------------------------------------------------------------ guards

    /// forge-config: default.fuzz.runs = 500
    function testFuzzAmountsOutsideInt128DomainRejected(int256 raw, bool zeroForOne) public {
        _open();
        int256 amount;
        if (raw == 0) {
            amount = 0;
        } else if (raw > 0) {
            amount = int256(MAX_AMOUNT) + 1 + raw % 1000;
        } else {
            amount = -int256(MAX_AMOUNT) - 1 + raw % 1000;
        }
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: PRICE});
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function testZeroAndBoundaryAmounts() public {
        _open();
        // Exactly the int128 boundary is accepted; one beyond is not.
        (BeforeSwapDelta delta,) = _beforeSwap(_swapParams(true, true, -int256(MAX_AMOUNT)));
        require(uint256(uint128(delta.getSpecifiedDelta())) == MAX_AMOUNT * 3050 / BPS, "boundary fee");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.beforeSwap(address(this), key, _swapParams(true, true, -int256(MAX_AMOUNT) - 1), "");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.beforeSwap(address(this), key, _swapParams(true, true, 0), "");
        // One wei of IMD in: fee rounds to zero, nothing is charged.
        (delta,) = _beforeSwap(_swapParams(true, true, -1));
        require(BeforeSwapDelta.unwrap(delta) == 0, "dust charged");
        // One wei of IMD out at 30.5%: a gross of 1 already nets 1 (1 - floor(1 * 3050 / 10000) == 1).
        (delta,) = _beforeSwap(_swapParams(true, false, 1));
        require(BeforeSwapDelta.unwrap(delta) == 0, "dust gross-up");
        // 200 wei out needs gross 287: 287 - floor(287 * 3050 / 10000) == 287 - 87 == 200, and 286 nets 199.
        (delta,) = _beforeSwap(_swapParams(true, false, 200));
        require(delta.getSpecifiedDelta() == 87, "gross-up at 200 wei");
    }

    function testSwapCallbacksRejectedBeforeOpening() public {
        IPoolManager.SwapParams memory params = _swapParams(true, true, -1e18);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.PoolNotInitialized.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.PoolNotInitialized.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    /// @dev afterSwap refuses a manager delta whose IMD sign contradicts the swap direction.
    /// forge-config: default.fuzz.runs = 500
    function testFuzzAfterSwapRejectsContradictoryDelta(uint120 rawAmount, bool pairSpecified, bool exactInput) public {
        _open();
        int128 amount = int128(uint128(uint256(rawAmount) + 1));
        IPoolManager.SwapParams memory params =
            _swapParams(pairSpecified, exactInput, exactInput ? -int256(1e18) : int256(1e18));
        bool pairIsInput = params.zeroForOne == pairIs0;
        // IMD flowing the wrong way: positive when it is the input, negative when it is the output.
        int128 wrong = pairIsInput ? amount : -amount;
        BalanceDelta delta = pairIs0 ? toBalanceDelta(wrong, 0) : toBalanceDelta(0, wrong);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidAmount.selector);
        hook.afterSwap(address(this), key, params, delta, "");
    }

    /// @dev A specified-IMD swap that executed for a different amount than the fee was computed on
    ///      fails atomically rather than mischarging.
    /// forge-config: default.fuzz.runs = 500
    function testFuzzAfterSwapRejectsPartialFillOfSpecifiedPaired(uint64 rawAmount, uint64 rawShort, bool exactInput)
        public
    {
        _open();
        uint256 amount = uint256(rawAmount) % 1e18 + 2;
        uint256 rate = 3050;
        uint256 expectedCore;
        if (exactInput) {
            expectedCore = amount - amount * rate / BPS;
        } else {
            expectedCore = (amount - 1) * BPS / (BPS - rate) + 1;
        }
        uint256 actual = uint256(rawShort) % expectedCore; // strictly less than expected
        int128 pairDelta = exactInput ? -int128(uint128(actual)) : int128(uint128(actual));
        BalanceDelta delta = pairIs0 ? toBalanceDelta(pairDelta, 0) : toBalanceDelta(0, pairDelta);
        IPoolManager.SwapParams memory params =
            _swapParams(true, exactInput, exactInput ? -int256(amount) : int256(amount));
        vm.prank(address(manager));
        if (actual == 0 && exactInput) {
            // Zero executed amount is caught as a sign/amount problem before the fill check.
            vm.expectRevert(SIMDTESTHook.PartialFillUnsupported.selector);
        } else {
            vm.expectRevert(SIMDTESTHook.PartialFillUnsupported.selector);
        }
        hook.afterSwap(address(this), key, params, delta, "");
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzzForeignPoolKeysRejected(uint8 field, uint24 fee, int24 spacing, address stranger) public {
        _open();
        PoolKey memory wrong = key;
        uint8 pick = field % 5;
        if (pick == 0) {
            if (fee == 12500) fee = 3000;
            wrong.fee = fee;
        } else if (pick == 1) {
            if (spacing == 60) spacing = 10;
            wrong.tickSpacing = spacing;
        } else if (pick == 2) {
            if (stranger == address(hook)) stranger = address(this);
            wrong.hooks = IHooks(stranger);
        } else if (pick == 3) {
            if (stranger == Currency.unwrap(wrong.currency0)) stranger = address(this);
            wrong.currency0 = Currency.wrap(stranger);
        } else {
            if (stranger == Currency.unwrap(wrong.currency1)) stranger = address(this);
            wrong.currency1 = Currency.wrap(stranger);
        }
        IPoolManager.SwapParams memory params = _swapParams(true, true, -1e18);
        IPoolManager.ModifyLiquidityParams memory liquidity =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: 0});
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        hook.beforeSwap(address(this), wrong, params, "");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        hook.afterSwap(address(this), wrong, params, BalanceDelta.wrap(0), "");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        hook.beforeAddLiquidity(address(this), wrong, liquidity, "");
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        hook.beforeInitialize(address(this), wrong, PRICE);
    }

    /// @dev The liquidity gate admits only the factory while the rate is nonzero, anyone afterwards.
    /// forge-config: default.fuzz.runs = 500
    function testFuzzLiquidityGateFollowsTheRate(address sender, uint8 age) public {
        if (sender == address(this)) sender = address(0xBEEF);
        _open();
        vm.roll(block.number + age % 14);
        IPoolManager.ModifyLiquidityParams memory liquidity =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: 0});
        // The factory is always admitted.
        vm.prank(address(manager));
        require(hook.beforeAddLiquidity(address(this), key, liquidity, "") == IHooks.beforeAddLiquidity.selector);
        bool locked = hook.antiSnipeBps() != 0;
        vm.prank(address(manager));
        if (locked) {
            vm.expectRevert(SIMDTESTHook.LiquidityLockedDuringAntiSnipe.selector);
            hook.beforeAddLiquidity(sender, key, liquidity, "");
        } else {
            require(hook.beforeAddLiquidity(sender, key, liquidity, "") == IHooks.beforeAddLiquidity.selector);
        }
    }

    function testOpeningIsFactoryOnlyAndSingleUse() public {
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.NotLaunchFactory.selector);
        hook.beforeInitialize(address(0xBEEF), key, PRICE);
        require(!hook.initialized(), "stranger opened the pool");
        _open();
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        vm.roll(block.number + 100);
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        require(hook.openingBlock() == block.number - 100, "re-opening moved the window");
    }

    function testConstantsMatchTheLaunchBrief() public view {
        require(hook.PAIRED_CURRENCY() == PAIR, "paired currency");
        require(hook.TREASURY() == 0x3dD5F73dD1A4E62630fAd3909673F130aD429985, "treasury");
        require(hook.BASE_FEE() == 12500 && hook.TICK_SPACING() == 60, "pool parameters");
        require(hook.TREASURY_BPS() == 50 && hook.INITIAL_ANTI_SNIPE_BPS() == 3000 && hook.ANTI_SNIPE_BLOCKS() == 10);
        require(address(hook.poolManager()) == address(manager) && hook.launchToken() == address(token));
        require(hook.launchFactory() == address(this), "factory");
    }
}
