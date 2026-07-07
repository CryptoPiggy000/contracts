# CryptoPiggy contracts — local demo dApp

A single-page app (`index.html`, ~vanilla + [viem](https://viem.sh)) that drives **these contracts**
on a local [anvil](https://book.getfoundry.sh/anvil/) node. No wallet extension, no testnet — it uses
anvil's built-in dev accounts, so every button sends a real transaction you can watch land.

It lives here (not in the `web` repo) because it's a **contracts demo**: it deploys the mock protocol
universe from `../script/DeployLocal.s.sol` and calls the real `SmartInvestmentAccount` /
`AccountFactory`. The production web app is a separate thing (the `web` repo).

## Run it (3 terminals)

**1 · a fresh anvil**
```shell
anvil
```
Restart it fresh each run so the deployed addresses stay deterministic (the app hard-codes them).

**2 · deploy the contracts + mock protocols** (from the repo root, one level up)
```shell
cd ..
forge script script/DeployLocal.s.sol:DeployLocal \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

**3 · serve this folder**
```shell
python3 -m http.server 5173      # from contracts/demo/ (any static server works)
# open http://localhost:5173
```

## What you'll see

The app creates your account once, then each button is a live tx:

- **Get 1000 test USDC** → 1000 USDC lands **idle** in the account.
- **Supply → Aave**, **Add wstETH exposure**, **Move into the Vault**, **Rebalance (1 plan)** — funds
  move between **idle · held · earning**, each an `executePlan(...)`. The account card headline shows
  the owner wallet + total value; the **Assets & allocation** accordion shows where each deposit sits
  (idle / held / earning, with the protocol named).
- **Exit** / **Withdraw** — back to idle, then out to **your wallet** (the only external door).
- **🦹 Platform: drain me** → `executePlan` from a *different* account → reverts **`NotOwner`**. That's
  the custody guarantee, live.

The swap router is intentionally kept out of the headline UI — it's transport, not a destination — and
surfaces only in the **Activity Log**.

## Addresses

The deterministic fresh-anvil addresses are baked into the `A` config in `index.html`. If you change
the deploy order (or don't restart anvil fresh), update `A` with the addresses the deploy script prints.

## Safety

Uses anvil's **well-known dev private keys** — local only, never use them anywhere real.
