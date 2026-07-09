# CryptoPiggy — Contracts

The **non-custodial trust core** of [CryptoPiggy](https://github.com/CryptoPiggy000): a simple, safe
way for beginners to invest in crypto without giving up their keys. Foundry (Solidity `0.8.28`).

> POC stage — **not audited**, no real funds. A formal audit gates mainnet.

## The set

| Contract | What |
|---|---|
| `SmartInvestmentAccount` | Per-user account (EIP-1167 clone). Holds custody; `executePlan` (**`onlyOwner`**) dispatches by `adapterType` to internal adapters; `exit`/`withdraw` are always available. |
| `ProtocolRegistry` | Admin-governed approved set (`Ownable2Step`): protocol positions, held/stable assets, swap routers. Positions are **disabled, never deleted**, so exits always resolve. |
| `AccountFactory` | Clones an account and **initializes it atomically** (no front-run window). Counterfactual addresses via CREATE2. |

Adapters live **inside** the account (smallest trust surface). Three for the POC:
- **ERC-4626** — Morpho / Sky / Spark vaults (`deposit`/`redeem`).
- **Aave** — Aave V3 `Pool` (`supply`/`withdraw`).
- **Swap** — approved router with **opaque `routeData`**, bounded by approve-exact + a post-swap
  `balance-delta ≥ minOut` (the check that makes opaque calldata safe).

## Guarantees (by construction)

- **`executePlan` is `onlyOwner`** — the platform can never move your funds; you submit your own tx.
- **No `Action` names an external destination** — funds only ever move *within* the account. The only
  door out is `withdraw` → the owner's own wallet.
- **Withdraw anytime** — `exit`/`withdraw` are status-independent (a disabled protocol never traps you).
- No leverage, no debt node. No `UserPolicy`/caps on-chain (diversification is the off-chain engine's
  job); no global `halt()` (`disableProtocol` covers it).

Design rationale: `../product-overview/10-revised-architecture.md` (in the umbrella repo).

## Live on Ethereum Sepolia (chainId 11155111)

Deployed via `script/DeploySepolia.s.sol` (this branch). **Real Circle USDC** is the stablecoin;
the Aave pool and ERC-4626 vault are **mocks, both over USDC** (no swaps, clean 6-dec). The real
registry/impl/factory are the audited/tested ones — only the yield venues are mocks. **Mocks don't
accrue**, so this proves real on-chain money movement (deposit / earn / close / withdraw), not real
yield. Full record + notes: [`DEPLOYMENTS.md`](./DEPLOYMENTS.md).

| Contract | Address |
|---|---|
| `AccountFactory` | `0xEfeeD7E0FB70316E9ceaeDcB1dBB10907370567C` |
| `ProtocolRegistry` | `0xe7F24D9963d992b2d3b838c615d41E94Ca8F8bd1` |
| `SmartInvestmentAccount` (impl) | `0xd06F148d8fe1F8eb3F145AA30BE6dAd7347627Ab` |
| Mock Aave pool (USDC) | `0x5c631226d0467ff2C15065b7173383278A639bb8` |
| Mock ERC-4626 vault (USDC) | `0xc6fA7dc154218b6d7bB81fc19530D16D16778b9E` |
| USDC (Circle, real) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

**How the frontend uses it** (matches the suggestion-only engine model): the client derives the
piggy address with `AccountFactory.predict(owner, 0x0)`, the user funds it with USDC, then the
**client builds the `Action[]` and the user signs `executePlan` / `exit` / `withdraw` themselves** —
no server touches the funds. positionId = `keccak256(abi.encode(adapterType, target, USDC))`.
Verified end-to-end on Sepolia: `createAccount` → `executePlan` (DEPOSIT) → `exit` → `withdraw`.

Redeploy (needs a funded deployer key in `.env` as `PRIVATE_KEY`):
```shell
set -a; . .env; set +a
forge script script/DeploySepolia.s.sol:DeploySepolia --rpc-url <sepolia> --broadcast
```

## Develop

```shell
forge build        # compile
forge test         # 30 tests, fully local (mock protocols — no fork/RPC needed)
forge fmt          # format
```

## Local demo

`demo/` is a single-page dApp that drives these contracts on a local anvil — deploy
`script/DeployLocal.s.sol`, serve `demo/`, and click through deposit / earn / swap / withdraw (plus a
"platform tries to drain me" button that reverts `NotOwner`). See [`demo/README.md`](demo/README.md).

Tests use mock protocols (`test/mocks/`) so the whole suite runs anywhere, including a red-team test
proving an *approved* malicious router still cannot drain an account.
