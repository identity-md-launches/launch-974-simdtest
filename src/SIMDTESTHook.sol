// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable, single-pool SIMD Launchpad hook. All swap fees are denominated in IMD.
/// @dev Initialization only binds the opening block. Fee mechanics run exclusively in swap callbacks.
contract SIMDTESTHook {
    address public constant PAIRED_CURRENCY = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint24 public constant BASE_FEE = 12500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant TREASURY_BPS = 50;
    uint256 public constant INITIAL_ANTI_SNIPE_BPS = 3000;
    uint256 public constant ANTI_SNIPE_BLOCKS = 10;
    uint256 private constant BPS = 10000;
    uint256 private constant MAX_AMOUNT = uint256(uint128(type(int128).max));

    IPoolManager public immutable poolManager;
    address public immutable launchToken;
    /// @notice The deploying launch factory may initialize once; it has no administrative powers.
    address public immutable launchFactory;
    bool public initialized;
    uint256 public openingBlock;

    error NotPoolManager();
    error InvalidAddress();
    error InvalidPool();
    error NotLaunchFactory();
    error AlreadyInitialized();
    error PoolNotInitialized();
    error InvalidAmount();
    error PartialFillUnsupported();

    event PoolOpened(uint256 indexed blockNumber);
    event SwapFees(uint256 grossPairedAmount, uint256 antiSnipeAmount, uint256 treasuryAmount);

    constructor(IPoolManager manager, address token) {
        if (address(manager).code.length == 0 || token.code.length == 0 || token == PAIRED_CURRENCY) {
            revert InvalidAddress();
        }
        poolManager = manager;
        launchToken = token;
        launchFactory = msg.sender;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        _checkKey(key);
        if (initialized) revert AlreadyInitialized();
        if (sender != launchFactory) revert NotLaunchFactory();
        initialized = true;
        openingBlock = block.number;
        emit PoolOpened(block.number);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Opening block pays 30%; subsequent blocks decline by 3 percentage points, reaching 0 at B+10.
    function antiSnipeBps() public view returns (uint256) {
        if (!initialized) return 0;
        uint256 elapsed = block.number - openingBlock;
        if (elapsed >= ANTI_SNIPE_BLOCKS) return 0;
        return INITIAL_ANTI_SNIPE_BPS * (ANTI_SNIPE_BLOCKS - elapsed) / ANTI_SNIPE_BLOCKS;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkSwap(key, params);
        uint256 fee = 0;
        if (_pairIsSpecified(key, params)) {
            uint256 amount = _abs(params.amountSpecified);
            uint256 rate = antiSnipeBps() + TREASURY_BPS;
            if (params.amountSpecified < 0) {
                fee = amount * rate / BPS;
            } else {
                fee = _grossUp(amount, rate) - amount;
            }
        }
        // No LP fee override: the pool always charges its own static 1.25% fee.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkSwap(key, params);
        (uint256 gross, uint256 fee, bool specified) = _swapFees(key, params, delta);
        bool pairIs0 = Currency.unwrap(key.currency0) == PAIRED_CURRENCY;
        uint256 treasuryFee = gross * TREASURY_BPS / BPS;
        // Combined fee rounds down once. Any split rounding remainder (<=1 wei) goes to LPs.
        uint256 donation = fee - treasuryFee;
        if (donation != 0) {
            poolManager.donate(key, pairIs0 ? donation : 0, pairIs0 ? 0 : donation, "");
        }
        if (treasuryFee != 0) {
            poolManager.take(Currency.wrap(PAIRED_CURRENCY), TREASURY, treasuryFee);
        }
        // donate/take debit this hook. The returned fee delta credits it during manager accounting.
        emit SwapFees(gross, donation, treasuryFee);
        return (IHooks.afterSwap.selector, specified ? int128(0) : int128(uint128(fee)));
    }

    function _swapFees(PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta)
        private
        view
        returns (uint256 gross, uint256 fee, bool specified)
    {
        bool pairIs0 = Currency.unwrap(key.currency0) == PAIRED_CURRENCY;
        int256 pairDelta = pairIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        bool pairIsInput = params.zeroForOne == pairIs0;
        if ((pairIsInput && pairDelta > 0) || (!pairIsInput && pairDelta < 0)) revert InvalidAmount();
        uint256 actual = _abs(pairDelta);
        uint256 rate = antiSnipeBps() + TREASURY_BPS;
        specified = _pairIsSpecified(key, params);
        if (specified) {
            uint256 amount = _abs(params.amountSpecified);
            gross = pairIsInput ? amount : _grossUp(amount, rate);
            fee = gross * rate / BPS;
            // A specified-currency delta cannot be refunded in afterSwap. Fail atomically
            // on partial execution instead of charging a fee on the unexecuted amount.
            if (actual != (pairIsInput ? gross - fee : gross)) revert PartialFillUnsupported();
        } else {
            gross = pairIsInput ? _grossUp(actual, rate) : actual;
            fee = gross * rate / BPS;
        }
    }

    function _checkKey(PoolKey calldata key) private view {
        address token0 = launchToken < PAIRED_CURRENCY ? launchToken : PAIRED_CURRENCY;
        address token1 = launchToken < PAIRED_CURRENCY ? PAIRED_CURRENCY : launchToken;
        if (
            Currency.unwrap(key.currency0) != token0 || Currency.unwrap(key.currency1) != token1 || key.fee != BASE_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert InvalidPool();
    }

    function _checkSwap(PoolKey calldata key, IPoolManager.SwapParams calldata params) private view {
        _checkKey(key);
        if (!initialized) revert PoolNotInitialized();
        // Avoid signed negation overflow and match v4's signed 128-bit balance domain.
        if (
            params.amountSpecified == 0 || params.amountSpecified > int256(MAX_AMOUNT)
                || params.amountSpecified < -int256(MAX_AMOUNT)
        ) revert InvalidAmount();
    }

    function _pairIsSpecified(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        private
        pure
        returns (bool)
    {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == (Currency.unwrap(key.currency0) == PAIRED_CURRENCY);
    }

    function _abs(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }

    /// @dev Smallest G with G - floor(G * rate / BPS) == net; fee splitting never changes net.
    function _grossUp(uint256 net, uint256 rate) private pure returns (uint256 gross) {
        if (net == 0) return 0;
        gross = (net - 1) * BPS / (BPS - rate) + 1;
        if (gross > MAX_AMOUNT) revert InvalidAmount();
    }
}
