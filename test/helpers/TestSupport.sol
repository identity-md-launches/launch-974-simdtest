// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function getCode(string calldata artifact) external returns (bytes memory);
    function etch(address target, bytes calldata code) external;
    function roll(uint256 newHeight) external;
    function prank(address sender) external;
    function expectRevert() external;
    function expectRevert(bytes4 reason) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// @dev Test-only paired-token implementation, installed locally at the specified IMD address.
contract TestPairedToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    address public rejectedRecipient;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
        totalSupply += amount;
    }

    function rejectRecipient(address recipient) external {
        rejectedRecipient = recipient;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(recipient != rejectedRecipient, "recipient rejects transfer");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

interface IMinimalToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

/// @dev An independent liquidity provider or searcher. It is the direct caller of the
///      PoolManager, so hooks see it, not the test contract, as `sender`.
contract LiquidityActor is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;

    struct Step {
        bool isSwap;
        IPoolManager.ModifyLiquidityParams liquidity;
        IPoolManager.SwapParams swap;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        Step[] memory steps = new Step[](1);
        steps[0].liquidity = params;
        (delta, feesAccrued) = run(key, steps);
    }

    /// @notice Executes every step inside one unlock, e.g. a just-in-time liquidity sandwich.
    function run(PoolKey memory key, Step[] memory steps) public returns (BalanceDelta, BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, steps)), (BalanceDelta, BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, Step[] memory steps) = abi.decode(data, (PoolKey, Step[]));
        BalanceDelta total;
        BalanceDelta fees;
        for (uint256 i; i < steps.length; ++i) {
            if (steps[i].isSwap) {
                total = total + manager.swap(key, steps[i].swap, "");
            } else {
                (BalanceDelta delta, BalanceDelta accrued) = manager.modifyLiquidity(key, steps[i].liquidity, "");
                total = total + delta;
                fees = fees + accrued;
            }
        }
        _settle(key.currency0, total.amount0());
        _settle(key.currency1, total.amount1());
        return abi.encode(total, fees);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            require(IMinimalToken(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(amount))));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @dev Deterministic-deployment helper: the hook's constructor sees this helper as msg.sender.
contract Create2Helper {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }
}

/// @dev A launch factory that opens the pool and seeds it through a periphery contract
///      within one transaction.
contract AtomicLauncher {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deployHook(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }

    function launch(PoolKey memory key, uint160 price, LiquidityActor periphery, int256 liquidity) external {
        manager.initialize(key, price);
        periphery.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: liquidity, salt: 0})
        );
    }
}
