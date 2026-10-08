# SIMDTEST launch

SIMD Launchpad `univ4_hook` preset for Ethereum mainnet. `SIMDTEST` is a plain,
fixed-supply ERC-20; `SIMDTESTHook` charges fees only on swaps in its single bound
SIMDTEST/IMD Uniswap v4 pool. Neither contract has an owner, pause, minting
authority, proxy, upgrade mechanism, arbitrary call, or withdrawal function.

## Reproducible build

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer enabled (200 runs), and
`bytecode_hash = "none"`. The verifier must provide that compiler and Foundry.
All Solidity dependencies and license texts are vendored as ordinary files;
see [dependency provenance](lib/DEPENDENCIES.md). No FFI, filesystem permissions,
environment variables, fork, RPC, external service, or package installation is
needed by the tests. Integration tests use a real local v4 PoolManager and a
local mock at the task's fixed IMD address, not a live mainnet fork.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| Hook constructor | `SIMDTESTHook(IPoolManager manager, address token)` |
| `manager` / `$poolManager` | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| `token` / `$token` | The actual SIMDTEST deployed by the launch factory immediately before the hook |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| Treasury | `0x3dd5f73dd1a4e62630fad3909673f130ad429985` |
| Static pool LP fee | 12500 millionths = 1.25% |
| Tick spacing | 60 |
| Hook address permission bits | `address(hook) & 0x3fff == 0x20cc` |
| Manifest initial price | `79228162514264337593543950336` (Q64.96); provenance only |

The manager is a constructor argument, not hardcoded in hook code. IMD and
treasury are constants from the task. The launch token and deploying factory
are immutable. No address is filled with a stand-in or configured after launch.
The constructor checks manager/token code and validates the address permission
bits. The same bytecode can be tested against a local manager; mainnet targeting
is the launch factory's deployment responsibility.

The factory must deploy the hook with CREATE2 and mine a salt for the actual
factory address, hook creation code and ABI-encoded constructor arguments.
Enabled permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`,
`beforeSwapReturnDelta`, and `afterSwapReturnDelta`. Initialize with sorted
currencies, the specified fee and spacing, and this hook. Other keys are rejected.
The factory that directly creates the hook must also be the direct caller of
`PoolManager.initialize`; an intermediate deployer or initialization router will
not work. The factory address is only a one-time initialization gate and grants
no control over fees, swaps or liquidity after initialization.

Deploy the token, deploy and initialize the hook pool, and seed liquidity
atomically. `beforeInitialize` rejects non-manager calls and initialization by
anyone except the deploying factory; it records the opening block once. Having
this permission also prevents initialization at an empty predicted hook address.
The factory determines the actual opening price from launch economics and must
supply the paired IMD funding. The manifest price is not an onchain price check.

## Supply and launchpad responsibilities

The no-argument token constructor mints exactly 1,000,000,000 tokens with 18
decimals (`10^27` minor units) to the deploying factory, as required by the
launchpad. The factory distributes them during launch:

| Allocation | Tokens | Responsibility |
| --- | ---: | --- |
| Dead-address allocation | 100,000,000 (10%) | Factory transfers to `0x000000000000000000000000000000000000dEaD` |
| Pool seed | 800,000,000 (80%) | Factory seeds the hook pool alongside funded IMD |
| Swarm | 100,000,000 (10%) | Factory uses its launchpad swarm allocation mechanism |

Sending to the dead address does not reduce ERC-20 `totalSupply`; it removes
tokens from circulation. The token itself performs no distribution, tax, or
automatic burn. The swarm is an external launchpad allocation, so neither token
nor hook accepts or invents a swarm recipient. No standalone launch distributor
is deployed by this project. The factory must verify these three allocations
and liquidity ownership when launching.

The launchpad fee splitter separately handles its 1% creator fee. This hook
does not duplicate that fee, interact with the splitter, or control LP positions.
There are no after-launch setters, keeper tasks, or privileged transactions.

## Swap fees and exact rounding

Let `B` be the block of pool initialization. Anti-snipe basis points are:

| Block | B | B+1 | B+2 | B+3 | B+4 | B+5 | B+6 | B+7 | B+8 | B+9 | B+10 onward |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Anti-snipe % | 30 | 27 | 24 | 21 | 18 | 15 | 12 | 9 | 6 | 3 | 0 |

The clock starts on initialization, not the first swap or liquidity deposit.
Empty intervening blocks still count. Treasury fees continue indefinitely.

Both hook fees use **gross IMD**: the trader's IMD input on a buy, or the pool's
IMD output before hook deductions on a sell. With gross amount `G`, anti-snipe
basis points `a`, and `D = 10000`, in minor units:

```
totalHookFee = floor(G * (a + 50) / D)
treasuryFee  = floor(G * 50 / D)
donation     = totalHookFee - treasuryFee
netAmount    = G - totalHookFee
```

The treasury receives exactly the floor-rounded 0.5% amount. Splitting a combined
fee assigns at most one extra minor unit to the donation compared with separately
floor-rounding the two fees. At `a = 0`, donation is exactly zero. Tiny swaps
can have zero fees due to integer rounding. There is no minimum fee.

For a required net IMD amount `N > 0`, gross-up uses
`G = floor((N - 1) * D / (D - a - 50)) + 1`, the smallest gross amount whose
fee deduction leaves exactly `N`. Zero net maps to zero gross.

| Swap | Fee accounting |
| --- | --- |
| Buy SIMDTEST, exact IMD input | Reserve the fee with a positive specified delta in `beforeSwap`; swap the remaining IMD |
| Buy SIMDTEST, exact token output | Gross up actual IMD input in `afterSwap`; charge an unspecified IMD delta |
| Sell SIMDTEST, exact token input | Deduct fees from actual gross IMD output in `afterSwap` |
| Sell SIMDTEST, exact IMD output | Gross up the requested net output in `beforeSwap`; the trader receives the exact requested IMD |

The pool separately applies its static 1.25% LP fee. No dynamic-fee flag or LP
fee override is used. Because hook and pool fees can have different bases and
the LP fee is charged on the swap input, percentages are not a simple additive
effective price quote. Slippage and price impact also apply.

Every completed swap immediately calls `PoolManager.donate` with its anti-snipe
IMD amount (when nonzero) and `PoolManager.take` to send its treasury IMD fee
directly to the fixed treasury. Donation and take create hook debts that the
positive returned fee delta settles within the same unlock. No fee remains in
the hook, is converted to ETH, is deferred as a claim, or is sent to a burn
address. SIMDTEST transfers and approvals never call the hook.

Donation distributes IMD fee growth to liquidity in range **after the swap**.
It increases claimable LP fees, not liquidity units `L`; LPs decide whether to
compound. There is no automatic purchase, burn, or reinvestment.

## Routing limits and review assumptions

For IMD-specified swaps (exact-input buys and exact-output sells), `afterSwap`
cannot change the previously reserved specified-currency delta. These swaps
therefore require a full fill: a price-limit or liquidity-induced partial fill
reverts the entire transaction with `PartialFillUnsupported`. For token-specified
swaps fees use actual executed IMD and partial fills are supported. Routers must
check realized amounts and use appropriate user slippage limits/deadlines.

If a nonzero donation is due but the swap ends with no active liquidity,
Uniswap's donation operation reverts atomically. No fee is charged and no swap
persists. Launch liquidity ranges must support intended early trading. Once the
anti-snipe period ends, no donation is attempted.

The fixed IMD token is assumed to support ordinary ERC-20 transfer accounting
(no transfer tax or rebasing). Treasury transfer failure reverts the swap.
No live-chain bytecode verification or transaction broadcasting is performed by
the test suite. The deployer must confirm the named mainnet contracts and token
behavior before funding. Donations can be captured by eligible in-range LPs,
including just-in-time liquidity; the anti-snipe schedule is a fee policy, not
a guarantee against MEV or trading through other pools.

The included deterministic and fuzz tests cover successful fees and settlement,
failure rollback, access restrictions, and plain token behavior. Bytecode size
and forbidden runtime opcodes are also checked. Local testing and code review
do not replace the launch network's independent security review before release.
