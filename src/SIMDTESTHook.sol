// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable, single-pool SIMD Launchpad hook. All swap fees are denominated in IMD.
/// @dev Initialization only binds the opening block. Fee mechanics run exclusively in swap callbacks.
///      While the anti-snipe fee is nonzero, only the launch factory (or the launch transaction
///      itself) may add liquidity, so donated anti-snipe fees reach the seeded launch liquidity
///      rather than just-in-time positions. The treasury fee leaves the PoolManager as an ERC-20
///      transfer whenever the manager physically holds enough IMD at that moment; otherwise it is
///      held as an ERC-6909 claim owned by this hook and paid out by the next swap or by anyone
///      through `payTreasury`, so a swap never fails for lack of IMD in the singleton.
contract SIMDTESTHook is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address public constant PAIRED_CURRENCY = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint24 public constant BASE_FEE = 12500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant TREASURY_BPS = 50;
    uint256 public constant INITIAL_ANTI_SNIPE_BPS = 3000;
    uint256 public constant ANTI_SNIPE_BLOCKS = 10;
    uint256 private constant BPS = 10000;
    uint256 private constant MAX_AMOUNT = uint256(uint128(type(int128).max));
    /// @dev Transient flag set by beforeInitialize for the rest of the launch transaction.
    ///      Value: keccak256("SIMDTESTHook.launchTransaction").
    uint256 private constant LAUNCH_TX_SLOT = 0x76d8999e61265dc958409216863db5b960fa42776f080f4e7f3400202b5e7da3;

    IPoolManager public immutable poolManager;
    address public immutable launchToken;
    /// @notice The launch factory may initialize once and seed liquidity during the anti-snipe
    ///         window; it has no administrative powers.
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
    error LiquidityLockedDuringAntiSnipe();

    event PoolOpened(uint256 indexed blockNumber);
    event SwapFees(uint256 grossPairedAmount, uint256 antiSnipeAmount, uint256 treasuryAmount);
    /// @notice IMD transferred out of the PoolManager to the treasury (this swap's fee plus any
    ///         previously deferred claims).
    event TreasuryPaid(uint256 amount);
    /// @notice IMD owed to the treasury that stayed in the PoolManager as a claim of this hook
    ///         because the manager could not pay it out at that moment.
    event TreasuryDeferred(uint256 amount);

    constructor(IPoolManager manager, address token, address factory) {
        if (
            address(manager).code.length == 0 || token.code.length == 0 || token == PAIRED_CURRENCY
                || factory == address(0)
        ) {
            revert InvalidAddress();
        }
        poolManager = manager;
        launchToken = token;
        launchFactory = factory;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
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
        assembly ("memory-safe") {
            tstore(LAUNCH_TX_SLOT, 1)
        }
        emit PoolOpened(block.number);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice While the anti-snipe fee is nonzero only the launch factory, or any caller within
    ///         the transaction that initialized the pool, may add liquidity. Removals are never
    ///         restricted. After the window, liquidity provision is open to everyone.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        _checkKey(key);
        if (antiSnipeBps() != 0 && sender != launchFactory && !_inLaunchTransaction()) {
            revert LiquidityLockedDuringAntiSnipe();
        }
        return IHooks.beforeAddLiquidity.selector;
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
        if (donation != 0 && poolManager.getLiquidity(key.toId()) == 0) {
            // The swap emptied the active range: no position can receive a donation, so the
            // anti-snipe amount follows the treasury fee instead of failing the swap.
            treasuryFee += donation;
            donation = 0;
        }
        if (donation != 0) {
            poolManager.donate(key, pairIs0 ? donation : 0, pairIs0 ? 0 : donation, "");
        }
        if (treasuryFee != 0) {
            _payTreasury(treasuryFee);
        }
        // donate/take/mint debit this hook. The returned fee delta credits it during manager accounting.
        emit SwapFees(gross, donation, treasuryFee);
        return (IHooks.afterSwap.selector, specified ? int128(0) : int128(uint128(fee)));
    }

    /// @notice Treasury IMD held inside the PoolManager as this hook's ERC-6909 claim, waiting for
    ///         the manager to hold enough IMD to pay it out. Anyone can trigger payment with
    ///         `payTreasury`; every swap also pays it out when possible.
    function pendingTreasury() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(PAIRED_CURRENCY).toId());
    }

    /// @notice Permissionless: redeems deferred treasury claims for IMD and transfers them to the
    ///         treasury, as far as the PoolManager's IMD balance allows.
    function payTreasury() external returns (uint256 paid) {
        paid = abi.decode(poolManager.unlock(""), (uint256));
    }

    /// @dev Only reached through `payTreasury`: the manager calls back the account that unlocked it.
    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 claims = pendingTreasury();
        uint256 available = _availablePaired();
        uint256 paid = claims < available ? claims : available;
        if (paid != 0) {
            poolManager.burn(address(this), Currency.wrap(PAIRED_CURRENCY).toId(), paid);
            poolManager.take(Currency.wrap(PAIRED_CURRENCY), TREASURY, paid);
            emit TreasuryPaid(paid);
        }
        return abi.encode(paid);
    }

    /// @dev `amount` is this swap's treasury fee, credited to the hook by the returned fee delta.
    ///      Pays it, and any earlier deferred claims, with a real transfer when the manager holds the
    ///      IMD; otherwise keeps it as a claim so the swap itself never fails.
    function _payTreasury(uint256 amount) private {
        Currency pair = Currency.wrap(PAIRED_CURRENCY);
        uint256 available = _availablePaired();
        uint256 owed = amount;
        uint256 claims = pendingTreasury();
        if (claims != 0 && available >= amount + claims) {
            poolManager.burn(address(this), pair.toId(), claims);
            owed += claims;
        }
        if (available >= owed) {
            poolManager.take(pair, TREASURY, owed);
            emit TreasuryPaid(owed);
        } else {
            poolManager.mint(address(this), pair.toId(), amount);
            emit TreasuryDeferred(amount);
        }
    }

    /// @dev IMD the manager can transfer out right now. Zero while a caller has synced IMD and not
    ///      yet settled: a transfer then would be subtracted from that caller's payment.
    function _availablePaired() private view returns (uint256) {
        if (Currency.unwrap(poolManager.getSyncedCurrency()) == PAIRED_CURRENCY) return 0;
        return IERC20Minimal(PAIRED_CURRENCY).balanceOf(address(poolManager));
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

    function _inLaunchTransaction() private view returns (bool launching) {
        assembly ("memory-safe") {
            launching := tload(LAUNCH_TX_SLOT)
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
