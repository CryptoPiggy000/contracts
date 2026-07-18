# Guarded rollout — deposit cap + whitelist (and how to LIFT them)

Two **temporary** launch controls that bound the blast radius while real funds are new, without
touching custody. Both are admin-governed on the `ProtocolRegistry`, both **default OFF**, and both are
designed to be **lifted** once confidence is earned. This doc is the operator runbook: how they work,
how to enable them at deploy, how to run the rollout, and — the part that matters most — **exactly how
to lift each one**.

> **Why they exist:** we are launching real funds on Base without a formal external audit. The whitelist
> limits *who* is exposed; the cap limits *how much*. Together they turn "unbounded downside" into "at
> most these N users, up to $X total." See the launch decision in the memory / `launch/verdict.md`.

## The one invariant they never break

**The guards can only block money going IN — never money coming OUT.**

- `onDeploy` (deposits and base-asset *buys*) is the only hook that can revert. It enforces the cap.
- `onReturn` (withdrawals and *sell-backs*) can **never** revert the user's action — the account wraps
  it in `try/catch`, and the registry never reverts it anyway.

So even with both guards fully on and the cap maxed out, **every user can always withdraw and always
sell their crypto back to USDC.** The withdraw-anytime guarantee is preserved by construction (proven by
`test_cap_neverBlocksWithdraw` and `test_cap_sellBackNeverBlocked`).

---

## 1. Whitelist gate — WHO may open an account

State (on `ProtocolRegistry`): `whitelistEnabled` (bool), `isAllowed[address]` (mapping).

- The factory checks `registry.canOpen(msg.sender)` in `createAccount`. `canOpen` returns
  `!whitelistEnabled || isAllowed[user]`.
- **Off (default):** anyone may open an account.
- **On:** only allowlisted addresses may open. Existing account holders are **not** retroactively
  affected (the gate is at account creation only; their size is bounded by the cap).

Admin controls (owner-only):

| Call | Effect |
|---|---|
| `setWhitelistEnabled(true)` | Turn the gate ON (rollout) |
| `setAllowed(user, true/false)` | Add / remove one address |
| `setAllowedBatch(users[], true/false)` | Add / remove a cohort at once |
| **`setWhitelistEnabled(false)`** | **LIFT — reopen account creation to everyone** |

---

## 2. Deposit cap — HOW MUCH principal may be deployed

State (on `ProtocolRegistry`): `depositCapEnabled` (bool), `depositCap` (uint256),
`netDeployed` (uint256), `baseAsset` (address).

- The cap counts **net base-asset principal** deployed across **all** accounts. `netDeployed` goes **up**
  on a deposit or a base-asset buy (`onDeploy`) and **down** on a withdrawal or a sell-back to the base
  asset (`onReturn`). Net tracking means normal churn (deposit → withdraw → redeposit) does **not**
  permanently consume the cap.
- Only flows in `baseAsset` count. A held→held rebalance (e.g. WETH→cbBTC) doesn't touch the cap.
- No oracle: the cap is denominated in base-asset units the account already moves. Held-asset price
  appreciation is *not* counted as principal — this is a principal cap, not a TVL meter.
- **`baseAsset` must be set** (to USDC) for the cap to count anything. Unset ⇒ nothing is capped.

Admin controls (owner-only):

| Call | Effect |
|---|---|
| `setBaseAsset(USDC)` | Denominate the cap (required for it to work) |
| `setDepositCap(amount)` | Set / raise / lower the ceiling (base-asset units) |
| `setDepositCapEnabled(true)` | Turn the cap ON (rollout) |
| **`setDepositCapEnabled(false)`** | **LIFT — remove the ceiling (unlimited deploy)** |

`netDeployed` keeps tracking even while the cap is disabled, so the counter stays accurate if you ever
re-enable it. Lifting is intended to be permanent.

---

## 3. How accounts are trusted to report flows

The cap relies on accounts reporting their own deposits/withdrawals — so the registry must know which
callers are real accounts, or the counter could be spoofed.

- The registry has a **set-once** `factory` binding (`setFactory`, called right after deploy).
- The factory calls `registry.registerAccount(account)` for every account it creates (best-effort, so
  un-wired test setups still work). Only the bound factory can register.
- `onDeploy` / `onReturn` **no-op for any caller that isn't a registered account** — so an outside
  contract cannot move `netDeployed`, and an un-wired deployment simply doesn't track (guards inert).

---

## 4. Enable-at-deploy sequence (turning the guards ON)

Run this once, right after deploying `registry` + `impl` + `factory` (belongs in the Base deploy
script). Admin = the registry owner (a **multisig** at launch).

```solidity
registry.setFactory(address(factory));            // bind the factory (set once)
registry.setBaseAsset(USDC);                       // denominate the cap

// WHO: start with a small cohort
registry.setWhitelistEnabled(true);
registry.setAllowedBatch(betaCohort, true);

// HOW MUCH: start low
registry.setDepositCap(10_000e6);                  // $10k total, base-asset units (USDC = 6 dec)
registry.setDepositCapEnabled(true);
```

During the rollout, widen gradually: `setAllowedBatch(...)` to add users, `setDepositCap(...)` to raise
the ceiling as confidence grows.

Watch these events (all indexed for off-chain monitoring): `Deployed` / `Returned` (every capped flow,
with the running `netDeployed`), `AllowedSet`, `DepositCapSet`, `WhitelistEnabledSet`,
`DepositCapEnabledSet`, `AccountRegistered`.

---

## 5. LIFTING the guards (going fully public)

### Prerequisite — hand admin to the multisig FIRST

During the rollout a **single admin key is acceptable**: the guards bound the blast radius (small
whitelisted cohort, low cap), so a compromised key can do only bounded damage. But that key can also
**lift its own guards** — so the moment you remove the bounds, the governance key must no longer be a
single key. Therefore the order is fixed:

```solidity
// 1. Move governance to the multisig (registry is Ownable2Step — two-step, no fat-finger).
registry.transferOwnership(safe);   // then the Safe calls acceptOwnership()
//    (optionally route through a timelock so users get an exit window on future changes)
```

Only a single key is needed *during* the guarded phase; the multisig is required *before* the lift,
never after. Do not lift the guards while a single EOA still owns the registry.

### The lift — two admin calls (now made by the multisig), in any order:

```solidity
registry.setWhitelistEnabled(false);   // anyone can open an account
registry.setDepositCapEnabled(false);  // no deposit ceiling
```

That's the whole lift. After it:

- `canOpen(anyone) == true` → account creation is open to all.
- `onDeploy` never reverts → deposits/buys of any size go through.
- The flow hooks still fire (they just don't gate), so `netDeployed` stays accurate — harmless residual
  bookkeeping. If you want them fully inert you can also leave `baseAsset` set; there is no need to
  unbind the factory.
- **Custody was never affected** by either guard, so nothing about withdrawals changes.

No redeploy, no migration, no user action required. The guards were additive and are removed by flipping
two booleans — which is the whole point.
