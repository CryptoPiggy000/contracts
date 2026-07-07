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
