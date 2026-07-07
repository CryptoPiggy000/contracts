# CryptoPiggy contracts — local demo dApp

A **Vite + Svelte** single-page app that drives **these contracts** on a local
[anvil](https://book.getfoundry.sh/anvil/) node using [viem](https://viem.sh). No wallet extension, no
testnet — it uses anvil's built-in dev accounts, so every button sends a real transaction you can watch land.

It lives here (not in the `web` repo) because it's a **contracts demo**: it deploys the mock protocol
universe from `../script/DeployLocal.s.sol` and calls the real `SmartInvestmentAccount` / `AccountFactory`.
The production web app is a separate thing (the `web` repo).

## Run it (3 terminals)

**1 · a fresh anvil**
```shell
anvil
```
Restart it fresh each run so the deployed addresses stay deterministic (they're baked into
`src/lib/chain.js`).

**2 · deploy the contracts + mock protocols** (from the repo root, one level up)
```shell
cd ..
forge script script/DeployLocal.s.sol:DeployLocal \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

**3 · run the app** (from this folder)
```shell
npm install     # first time only
npm run dev     # Vite dev server on http://localhost:5173
```

## What you'll see

- **Account card** — headline owner wallet + total value; a **Held / Allocated** split; an
  **Assets & allocation** accordion where each holding is tagged idle / held / earning (with the protocol named).
- **Planner** — the off-chain "engine": **Run Planner** reads your state and returns a **Plan** (goal,
  reasoning, target mix, action list, gas estimate). With idle cash it produces a **deploy** plan (fixed
  30 / 40 / 30); with none left it produces a **rebalance** plan (random target, demo). **Dispatch** submits
  it as one real `executePlan(...)` — you sign, non-custodial. It re-plans after every state change.
- **Manual actions** — direct protocol calls (supply / swap / rebalance / exit / withdraw), plus a
  **🦹 Platform: drain me** button that reverts **`NotOwner`** — the custody guarantee, live.
- **Activity Log** — every transaction, including the otherwise-hidden swap router.

## Build a static bundle

```shell
npm run build      # -> dist/  (serve with any static server, still points at localhost:8545)
```

## Architecture

- `src/lib/chain.js` — viem clients, deployed addresses, ABIs, helpers.
- `src/lib/state.js` — reactive stores + all chain logic (connect, refresh, execute, planner).
- `src/components/*.svelte` — AccountCard · PlannerCard · ManualActions · ActivityLog.

## Addresses

The deterministic fresh-anvil addresses are in the `A` map in `src/lib/chain.js`. If you change the deploy
order (or don't restart anvil fresh), update `A` with the addresses the deploy script prints.

## Safety

Uses anvil's **well-known dev private keys** — local only, never use them anywhere real.
