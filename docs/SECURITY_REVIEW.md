# Smart-contract security review — 2026-07-20

A deep review of the on-chain core (`SmartInvestmentAccount`, `ProtocolRegistry`,
`AccountFactory`) ahead of the real-funds Base launch. Method: a multi-lens pass (custody,
access control, reentrancy, arithmetic/accounting, swap-path, guarded-rollout), each candidate
finding adversarially verified by independent skeptics, plus a manual trace and Slither.

The custody invariant held under review: **the user can always withdraw.** `withdraw(token)` is
unconditional, `exit(positionId)` is status-independent, and every registry call on the exit path is
either not consulted or wrapped in `try/catch` — so a disabled protocol, a paused guard, or even a
misbehaving registry can never trap funds. Reentrancy is closed (`nonReentrant` on every entry point;
balance-delta accounting rather than trusting a target's self-report).

## Findings & fixes

| # | Severity | Finding | Fix | Regression test |
|---|---|---|---|---|
| 1 | **HIGH** | **Deposit-cap under-count.** `onDeploy` added principal *at cost*; `onReturn` subtracted a *market-value* balance-delta (principal + yield/gains). A yielding withdrawal by one account freed more `netDeployed` room than it occupied — room belonging to *other* accounts' live principal — so the global cap could be breached. | Per-account cost basis `deployedBy[account]`; `onReturn`'s decrement is clamped to it, so gains can never free others' room. | `test_cap_yieldingReturnCannotBreachCap` |
| 2 | Medium | **Swap with `minOut == 0`** disabled the balance-delta slippage/theft guard entirely — a malicious/approved router could return dust. | `_swap` reverts `ZeroMinOut` when `minOut == 0`. | `test_swap_zeroMinOut_reverts` |
| 3 | Medium | **Cap silently inert on mis-deploy.** If the cap was enabled but a caller wasn't a registered account, `onDeploy` no-op'd — a forgotten `setFactory` would leave the cap enabled-but-bypassed. | `onDeploy` is **fail-closed**: with factory bound *and* cap enforced, an unregistered caller reverts `NotAccount`. Un-wired setups still no-op. | `test_onDeploy_nonAccount_failsClosed`, `test_onDeploy_nonAccount_noopWhenCapOff` |
| 4 | Low | **`baseAsset` re-settable.** Changing the cap's unit after accounts deployed would strand `netDeployed`/`deployedBy` (counted in the old asset). | `setBaseAsset` is set-once and non-zero (mirrors `setFactory`). | `test_setBaseAsset_setOnce` |
| 5 | Low | **Swap spend-side unvalidated.** `_swap` checked `assetOut` was approved but not `assetIn` — a swap could relay-spend any token the account holds (e.g. vault shares) through an approved router. | `_swap` requires **both** `assetIn` and `assetOut` approved. | `test_swap_unapprovedAssetIn_reverts` |
| 6 | Info | Slither: `setBaseAsset` lacked a zero-check (footgun given set-once). | Added `ZeroAddress` guard. | covered by #4 |
| 7 | Info | Contract doc claimed "no `Action` names an external destination" — imprecise (a swap relays to an external router). | Reworded to the precise invariant: no `Action` can send funds to an *arbitrary/attacker-chosen* address; value always returns to the account. | n/a (doc) |

### Deferred (not a launch blocker)

- **ERC-4626 deposit min-shares.** `_deposit` reverts only on `shares == 0`; a `minShares` floor would
  bound share-price slippage on a vault deposit. Deferred — it needs an `Action` struct field, and the
  approved vaults (Aave V3, Moonwell/Morpho MetaMorpho) are not attacker-controlled. Tracked for a
  follow-up once the plan encodes per-action minimums.

## Non-findings (verified benign)

- **Slither reentrancy-balance on `_swap`/`_withdraw`** — false positive: reachable only through
  `nonReentrant` entry points; the balance-delta pattern is deliberate.
- **Strict equality `== 0`** — intentional "nothing received / nothing minted" guards.
- **External call in a loop (`getProtocol`)** — trusted view call; the owner controls plan length and
  pays the gas. No DoS vector.

## Result

All local tests green (58 passed, 11 fork tests skipped without an RPC). No open HIGH/Medium findings.
