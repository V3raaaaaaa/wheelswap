# Wheelswap

**The SQK/ETH pool paced by Squeektoshi's wheel.** A constant-product AMM for Squeekchain's SQK token against native ETH on Sepolia — the first place SQK can be swapped at all — where the swap fee is not a constant: the real hamster sets it.

- Live site: [v3raaaaaaa.github.io/wheelswap](https://v3raaaaaaa.github.io/wheelswap/) (GitHub Pages, `gh-pages` = `web/`)
- Pool contract (Sepolia): [`0xF33F5D8f98e5412149C9F8FFEa8fAb6Cd28a5466`](https://sepolia.etherscan.io/address/0xF33F5D8f98e5412149C9F8FFEa8fAb6Cd28a5466) — deployed block 12083308, [Sourcify-verified](https://repo.sourcify.dev/11155111/0xF33F5D8f98e5412149C9F8FFEa8fAb6Cd28a5466), **no owner, no admin, no fee switch, no pause, no upgrade**
- Built on [Squeekchain](https://squeekchain.com) · Sepolia testnet · unaudited · tokens have no value

## The fee is the wheel

Before every swap the pool reads `SqueekCore.state()` and classifies the stretch of **Squeek blocks** settled since it last looked, against the live difficulty `workPerThousandBlocks`:

| wheel | condition (since last observation) | fee |
|---|---|---|
| **NAP** | new Squeek blocks, **no new work** | **0.50 %** |
| **JOG** | work settled **below** the difficulty pace | **0.30 %** |
| **ZOOMIES** | work settled **at or above** the difficulty pace | **0.10 %** |

`pace = Δwork × 1000 / ΔblockHeight`, in the same units as the difficulty. Between settlements the last classification sticks, so the on-chain tier lags the live cam by roughly one round. Each observation is emitted as `WheelObserved(work, height, difficulty, wheel)` and every `Swap` event carries the `feeBps` and `wheel` it was charged under, so the whole fee history is auditable from logs.

**Every fee stays in the pool and accrues to LP holders.** There is no protocol cut and nobody who could add one.

## What's in the contract

`src/WheelSwap.sol` (one contract, ~8 KB runtime):

- **Pool** — Uniswap-V2-style `x·y = k` with `MINIMUM_LIQUIDITY` locked on the first mint, UQ112x112 **TWAP accumulators** (`priceSQKCumulativeLast`, `priceETHCumulativeLast`), `skim` / `sync` for forced balances, reentrancy lock, deadline + slippage checks on every state-changing call. Native ETH on one side — no WETH, no factory, no router: the user-facing functions live on the pool itself.
- **LP token** — the pool *is* the ERC-20 (`wSQK-ETH`, 18 decimals).
- **Permit flows** — `addLiquidityWithPermit` and `swapExactSQKForETHWithPermit` take an EIP-2612 signature for SQK, so SQK-side actions are one signature + one transaction with no separate approve. SqueekToken's real permit is exercised in the fork tests.
- **Wheel tracker** — `lastWork`, `lastHeight`, `lastWheel`; `currentWheel()` is the view the UI quotes from and `_observeWheel()` is what a swap commits.
- **Views** — `getReserves`, `currentWheel`, `quoteSwap(amountIn, sqkIn)`, `quoteLiquidity(amountSQK)`.

Live Squeekchain dependencies on Sepolia (`core-sepolia-20261103`):

| | address |
|---|---|
| SqueekCore (`state()`) | `0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4` |
| SQK — SqueekToken, ERC-20 + EIP-2612 | `0xd78a3956cF63164d1Fa1C622ad3c66623162Fa1e` |

## Tests

```
forge test --no-match-contract Fork                                  # 27 unit tests incl. fuzz (256 runs)
SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-contract Fork   # 5 fork tests on the live deployment
```

Unit tests cover: first mint (`√(x·y) − 1000`), pro-rata deposits with ETH refund and SQK scaling, pro-rata withdrawals, swap output equal to the closed-form formula in both directions, the three fee tiers driven by a mocked core (below pace → JOG, at pace → ZOOMIES, blocks without work → NAP), stickiness between settlements, per-stretch (not lifetime) classification, deadline / min-out / slippage / empty-pool reverts, `quoteSwap == swap`, TWAP accumulation, EIP-2612 permit for both add-liquidity and swap, `skim`/`sync`, a re-entrancy attempt from the ETH receive hook (blocked), LP-token transfer/allowance, and two fuzz invariants — **k never decreases on a swap** and **add→remove never extracts more than deposited**.

Fork tests run against the real SqueekCore and the real SqueekToken: the constructor snapshots live core state, `currentWheel()` returns a valid tier, add → swap both ways → remove works with real SQK transfers, and a real EIP-2612 permit on SqueekToken is accepted.

## Frontend

`web/` is a static site (GitHub Pages): ethers v6, wallet connect on Sepolia, read-only without a wallet. Header shows the **on-chain** wheel class and fee (from `currentWheel()`) next to the **live cam** RPM from `api.squeekchain.com/v1/status`, so you can see the one-round lag. Swap quotes come from `quoteSwap` on-chain; SQK → ETH signs a permit (falls back to approve if the wallet can't sign typed data). Pool panel: reserves, price, LP supply, your share and underlying, add (ratio auto-filled, first deposit sets the price) and remove (slider). Price chart from `Sync` events, recent swaps with their wheel/fee, and the `WheelObserved` log with the pace computed per stretch.

## Deploy

```
KEYFILE=path/to/deployer.key SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com ./script/deploy_sepolia.sh
```

The script asks the **node** for a gas estimate and sends the creation with an explicit limit, then verifies on Sourcify. That matters on today's Sepolia: it already runs **Glamsterdam**, whose state-creation repricing makes code deposit cost ~1.5k gas per byte, so this 8 KB contract needs ~12.7M gas while Foundry's local EVM still estimates ~2.5M — a plain `forge script --broadcast` runs out of gas. The limit must stay under the 16.7M per-transaction cap, which is also why the contract is kept to a single ~8 KB unit.

## Design notes

- **Why native ETH, not WETH?** One fewer approval, one fewer contract, and the Sepolia WETH has no bearing on Squeekchain. Reserves are tracked arithmetically and reconciled by `sync`/`skim`, Uniswap-V2 style.
- **Why read `blockHeight` instead of Ethereum blocks?** `workPerThousandBlocks` is defined per thousand *Squeek* blocks, so the pace is compared in its own units. Ethereum blocks would make the tier depend on how often someone swaps.
- **Why does the tier stick between settlements?** The core only moves when a round settles; until then there is no new information, and reading "NAP" just because nobody settled yet would punish traders for the oracle's cadence.
- **Randomness, oracles, admin keys:** none. The only external dependency is the Squeekchain core itself.

## Disclaimer

Testnet only. Unaudited. SQK and ETH on Sepolia have no value. Unofficial fan project; not affiliated with the Squeekchain team.
