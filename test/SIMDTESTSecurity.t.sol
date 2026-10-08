// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SIMDTEST} from "../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../src/SIMDTESTHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

// Code-bearing fixture is sufficient for constructor and unauthorized-caller checks.
// Actual accounting and swaps are covered separately against the real v4 manager.
contract SecurityManagerFixture {}

contract SIMDTESTSecurityTest {
    SIMDTEST private token;
    SIMDTESTHook private hook;
    IPoolManager private manager;

    uint160 private constant FLAGS = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);

    function setUp() public {
        token = new SIMDTEST();
        manager = IPoolManager(address(new SecurityManagerFixture()));
        bytes memory initCode =
            abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token), address(this)));
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 nonce; nonce < 1_000_000; ++nonce) {
            bytes32 salt = bytes32(nonce);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
            if (uint160(predicted) & ((1 << 14) - 1) == FLAGS) {
                hook = new SIMDTESTHook{salt: salt}(manager, address(token), address(this));
                require(address(hook) == predicted, "CREATE2 prediction");
                return;
            }
        }
        revert("hook salt mining exhausted");
    }

    function testHookDeploysAtExactlyDeclaredPermissionBits() public view {
        require(uint160(address(hook)) & ((1 << 14) - 1) == FLAGS, "permission address bits");
        Hooks.Permissions memory p = hook.getHookPermissions();
        require(p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap && p.afterSwap, "active callbacks");
        require(p.beforeSwapReturnDelta && p.afterSwapReturnDelta, "return deltas");
        require(
            !p.afterInitialize && !p.afterAddLiquidity && !p.beforeRemoveLiquidity && !p.afterRemoveLiquidity
                && !p.beforeDonate && !p.afterDonate && !p.afterAddLiquidityReturnDelta
                && !p.afterRemoveLiquidityReturnDelta,
            "other callbacks disabled"
        );
        require(address(hook.poolManager()) == address(manager), "immutable manager");
        require(hook.launchToken() == address(token), "immutable token");
        require(hook.launchFactory() == address(this), "initialization authority is the configured factory");
    }

    function testConstructorRejectsMissingInputs() public {
        bytes memory noFactory =
            abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token), address(0)));
        bytes memory noToken =
            abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(0xBEEF), address(this)));
        bytes memory pairAsToken = abi.encodePacked(
            type(SIMDTESTHook).creationCode, abi.encode(manager, hook.PAIRED_CURRENCY(), address(this))
        );
        require(_create(noFactory) == address(0), "zero factory accepted");
        require(_create(noToken) == address(0), "codeless token accepted");
        require(_create(pairAsToken) == address(0), "paired currency accepted as launch token");
    }

    function _create(bytes memory code) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
    }

    function testDeploymentAndRuntimeSizesWithinEthereumLimits() public view {
        require(
            type(SIMDTESTHook).creationCode.length + abi.encode(manager, address(token)).length <= 49_152,
            "hook init size"
        );
        require(type(SIMDTEST).creationCode.length <= 49_152, "token init size");
        require(address(hook).code.length <= 24_576, "hook runtime size");
        require(address(token).code.length <= 24_576, "token runtime size");
    }

    function testRuntimeContainsNoForbiddenInstructions() public view {
        _scanInstructions(address(hook).code);
        _scanInstructions(address(token).code);
    }

    function testNoOwnerPauseOrUpgradeEntryPoints() public {
        bytes[] memory forbidden = new bytes[](10);
        forbidden[0] = abi.encodeWithSignature("owner()");
        forbidden[1] = abi.encodeWithSignature("transferOwnership(address)", address(this));
        forbidden[2] = abi.encodeWithSignature("renounceOwnership()");
        forbidden[3] = abi.encodeWithSignature("pause()");
        forbidden[4] = abi.encodeWithSignature("unpause()");
        forbidden[5] = abi.encodeWithSignature("paused()");
        forbidden[6] = abi.encodeWithSignature("upgradeTo(address)", address(token));
        forbidden[7] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(token), bytes(""));
        forbidden[8] = abi.encodeWithSignature("setTreasury(address)", address(this));
        forbidden[9] = abi.encodeWithSignature("setFee(uint256)", uint256(1));
        for (uint256 i; i < forbidden.length; ++i) {
            (bool hookSuccess,) = address(hook).call(forbidden[i]);
            require(!hookSuccess, "hook admin call succeeded");
            (bool tokenSuccess,) = address(token).call(forbidden[i]);
            require(!tokenSuccess, "token admin call succeeded");
        }
    }

    function testEveryEnabledCallbackRejectsNonManager() public {
        address pair = hook.PAIRED_CURRENCY();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token) < pair ? address(token) : pair),
            currency1: Currency.wrap(address(token) < pair ? pair : address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: uint160(1 << 96)
        });
        IPoolManager.ModifyLiquidityParams memory liquidity =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: 0});
        _requiresManager(abi.encodeCall(hook.beforeInitialize, (address(this), key, uint160(1 << 96))));
        _requiresManager(abi.encodeCall(hook.beforeAddLiquidity, (address(this), key, liquidity, bytes(""))));
        _requiresManager(abi.encodeCall(hook.beforeSwap, (address(this), key, params, bytes(""))));
        _requiresManager(abi.encodeCall(hook.afterSwap, (address(this), key, params, BalanceDelta.wrap(0), bytes(""))));
        _requiresManager(abi.encodeCall(hook.unlockCallback, (bytes(""))));
        require(!hook.initialized(), "unauthorized initialization had no effect");
    }

    function _requiresManager(bytes memory payload) private {
        (bool success, bytes memory result) = address(hook).call(payload);
        require(!success, "unauthorized callback succeeded");
        require(
            keccak256(result) == keccak256(abi.encodeWithSelector(SIMDTESTHook.NotPoolManager.selector)), "wrong error"
        );
    }

    function _scanInstructions(bytes memory runtime) private pure {
        // solc 0.8.26 with bytecode_hash="none" appends a 12-byte CBOR compiler
        // version record. This is auxdata, not executable instructions.
        bytes memory auxdata = hex"a164736f6c634300081a000a";
        uint256 end = runtime.length;
        require(end >= auxdata.length, "runtime missing compiler record");
        for (uint256 i; i < auxdata.length; ++i) {
            require(runtime[end - auxdata.length + i] == auxdata[i], "unexpected compiler auxdata");
        }
        end -= auxdata.length;
        for (uint256 pc; pc < end; ++pc) {
            uint8 instruction = uint8(runtime[pc]);
            require(instruction != 0xf4, "DELEGATECALL instruction");
            require(instruction != 0xff, "SELFDESTRUCT instruction");
            if (instruction >= 0x60 && instruction <= 0x7f) pc += instruction - 0x5f;
        }
    }
}
