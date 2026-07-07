// Reactive app state + all chain logic: connect, refresh, execute, and the off-chain "planner".
import { writable, get } from 'svelte/store';
import {
  pub, wYou, wPlat, you, platform, A, SALT, Z, ZB, PRICE, ETH_USD,
  factoryAbi, registryAbi, erc20Abi, aaveAbi, vaultAbi, routerAbi, acctAbi,
  U, num, f, money, short, encodeFunctionData,
} from './chain.js';

export const conn = writable({ up: false, down: false, text: 'connecting to anvil…' });
export const errMsg = writable('');
export const account = writable({ ready: false, ownerAddr: '', acctAddr: '', total: 0, net: 0, allocated: 0, held: 0, walletVal: 0, items: [], idleUsdc: 0, aaveVal: 0, vaultVal: 0, wstethVal: 0, walletUsdc: '0', walletWsteth: '0', walletWstethNum: 0 });
export const log = writable([]);
export const plan = writable(null);
export const busy = writable(false);

let ACCT, AAVE_ID, VAULT_ID, _raw = { idle: 0 }, _busy = false;
const R = A.router.slice(0, 6) + '…' + A.router.slice(-4); // swap router — infra, named only in the Activity Log

// ---- action builders (no field names an external destination) ----
const dep = (id, amt) => ({ kind: 0, positionId: id, assetIn: Z, assetOut: Z, router: Z, amount: amt, minOut: 0n, routeData: '0x' });
const wd = (id, amt) => ({ kind: 1, positionId: id, assetIn: Z, assetOut: Z, router: Z, amount: amt, minOut: 0n, routeData: '0x' });
const sw = (i, o, amt, minOut) => ({ kind: 2, positionId: ZB, assetIn: i, assetOut: o, router: A.router, amount: amt, minOut, routeData: encodeFunctionData({ abi: routerAbi, functionName: 'swap', args: [i, o, amt, minOut, ACCT] }) });
const planReq = (actions) => ({ address: ACCT, abi: acctAbi, functionName: 'executePlan', args: [actions] });

function addLog(ok, call, path) { log.update((l) => [...l, { ok, call, path }]); }
function errName(e) { let c = e; while (c) { if (c.data && c.data.errorName) return c.data.errorName; if (c.errorName) return c.errorName; c = c.cause; } return (e.shortMessage || e.message || 'error').split('\n')[0]; }

// simulate (catch revert) -> write -> wait -> log -> refresh
async function tx(who, label, path, req) {
  if (_busy) return; _busy = true; busy.set(true);
  const w = who === 'platform' ? wPlat : wYou, acc = who === 'platform' ? platform : you;
  try {
    await pub.simulateContract({ ...req, account: acc });
    const hash = await w.writeContract({ ...req, account: acc });
    await pub.waitForTransactionReceipt({ hash });
    addLog(true, label, path);
  } catch (e) { addLog(false, label, 'reverted: ' + errName(e)); }
  await refresh(); _busy = false; busy.set(false);
}

async function send(req) {
  await pub.simulateContract({ ...req, account: you });
  const hash = await wYou.writeContract({ ...req, account: you });
  await pub.waitForTransactionReceipt({ hash });
}

// Smart withdraw: raise the requested value out of any protocol into idle USDC, then send it to the owner.
async function withdrawTo(amount) {
  if (_busy) return; _busy = true; busy.set(true);
  try {
    const total = _raw.idle + _raw.aVal + _raw.vVal + _raw.hVal;
    const amt = Math.min(amount, total);
    if (amt >= 0.01) {
      // Phase A — if idle USDC can't cover it, unwind the shortfall from protocols (idle-sparing priority)
      if (_raw.idle < amt - 0.005) {
        let rem = (amt - _raw.idle) * 1.02 + 0.25; // buffer for rounding / slippage
        const actions = [], parts = [];
        const takeA = Math.min(rem, _raw.aVal * 0.999);
        if (takeA > 0.01) { actions.push(wd(AAVE_ID, U(takeA.toFixed(2)))); rem -= takeA; parts.push('Aave'); }
        const takeV = Math.min(rem, _raw.vVal * 0.999);
        if (takeV > 0.01) { const a = U(takeV.toFixed(2)); actions.push(wd(VAULT_ID, a), sw(A.usds, A.usdc, a, a * 99n / 100n)); rem -= takeV; parts.push('Vault'); }
        const takeH = Math.min(rem, _raw.hVal * 0.999);
        if (takeH > 0.01) { const wst = U((takeH / PRICE.wstETH).toFixed(8)); actions.push(sw(A.wsteth, A.usdc, wst, U((takeH * 0.9).toFixed(2)))); rem -= takeH; parts.push('wstETH'); }
        if (actions.length) {
          await send(planReq(actions));
          addLog(true, `<span class="k">executePlan</span>([ raise ${money(amt)} ])`, `unwind ${parts.join(' · ')} → idle USDC`);
        }
      }
      // Phase B — withdraw to the owner's own wallet (the only external door), capped to what's now idle
      const idleNow = num(await pub.readContract({ address: A.usdc, abi: erc20Abi, functionName: 'balanceOf', args: [ACCT] }));
      const out = Math.min(amt, idleNow);
      if (out >= 0.01) {
        await send({ address: ACCT, abi: acctAbi, functionName: 'withdraw', args: [A.usdc, U(out.toFixed(2))] });
        addLog(true, `<span class="k">withdraw</span>(USDC, ${out.toFixed(2)})`, '→ YOUR wallet (the only external door)');
      }
    }
  } catch (e) { addLog(false, 'smart withdraw', 'reverted: ' + errName(e)); }
  await refresh(); _busy = false; busy.set(false);
}

export async function refresh() {
  const [iu, is, hw, sa, vs, wu, ww] = await Promise.all([
    pub.readContract({ address: A.usdc, abi: erc20Abi, functionName: 'balanceOf', args: [ACCT] }),
    pub.readContract({ address: A.usds, abi: erc20Abi, functionName: 'balanceOf', args: [ACCT] }),
    pub.readContract({ address: A.wsteth, abi: erc20Abi, functionName: 'balanceOf', args: [ACCT] }),
    pub.readContract({ address: A.aave, abi: aaveAbi, functionName: 'supplied', args: [ACCT, A.usdc] }),
    pub.readContract({ address: A.vault, abi: vaultAbi, functionName: 'balanceOf', args: [ACCT] }),
    pub.readContract({ address: A.usdc, abi: erc20Abi, functionName: 'balanceOf', args: [you.address] }),
    pub.readContract({ address: A.wsteth, abi: erc20Abi, functionName: 'balanceOf', args: [you.address] }),
  ]);
  const va = vs === 0n ? 0n : await pub.readContract({ address: A.vault, abi: vaultAbi, functionName: 'convertToAssets', args: [vs] });
  const items = [
    { nm: 'Aave · USDC', bk: 'deployed', v: num(sa) },
    { nm: 'Vault · USDS', bk: 'deployed', v: num(va) },
    { nm: 'wstETH', bk: 'held', v: num(hw) * PRICE.wstETH, sub: f(hw) + ' wstETH' },
    { nm: 'USDC', bk: 'idle', v: num(iu) },
    { nm: 'USDS', bk: 'idle', v: num(is) },
  ];
  const walletItems = [
    { nm: 'USDC · in wallet', bk: 'wallet', v: num(wu) },
    { nm: 'wstETH · in wallet', bk: 'wallet', v: num(ww) * PRICE.wstETH, sub: f(ww) + ' wstETH' },
  ];
  const total = items.reduce((s, x) => s + x.v, 0); // account only
  const allocated = items.filter((x) => x.bk === 'deployed').reduce((s, x) => s + x.v, 0), held = total - allocated;
  const walletVal = walletItems.reduce((s, x) => s + x.v, 0);
  const net = total + walletVal; // whole net worth: account + wallet
  const TAG = { deployed: 'Earning', held: 'Held', idle: 'Idle', wallet: 'In wallet' };
  // allocation spans the whole net worth (account + wallet), so percentages are over total value
  const shown = [...items, ...walletItems].filter((x) => x.v > 1e-6).sort((a, b) => b.v - a.v)
    .map((x) => ({ ...x, tag: TAG[x.bk], pct: net > 0 ? x.v / net * 100 : 0 }));
  _raw = { iu, wu, aVal: num(sa), vVal: num(va), hVal: num(hw) * PRICE.wstETH, idle: num(iu), walletUsdc: num(wu) };
  account.set({
    ready: true,
    ownerAddr: short(you.address) + ' (anvil #0)',
    acctAddr: 'account ' + short(ACCT),
    total, net, allocated, held, walletVal, items: shown,
    idleUsdc: num(iu), aaveVal: num(sa), vaultVal: num(va), wstethVal: num(hw) * PRICE.wstETH,
    walletUsdc: f(wu), walletWsteth: f(ww), walletWstethNum: num(ww),
  });
  await runPlanner();
}

// ---- the "engine": idle cash -> deploy plan; no idle cash -> rebalance plan ----
async function estimateGas(actions) {
  let gas;
  try { gas = await pub.estimateContractGas({ address: ACCT, abi: acctAbi, functionName: 'executePlan', args: [actions], account: you.address }); }
  catch { gas = BigInt(actions.length) * 140000n; }
  const feeEth = num(gas * 20n * (10n ** 9n)); // @ 20 gwei
  return { gasText: `≈ ${Number(gas).toLocaleString()} gas · ${feeEth.toFixed(5)} ETH`, gasSub: `~$${(feeEth * ETH_USD).toFixed(2)} @ 20 gwei · ETH $${ETH_USD.toLocaleString()}` };
}

async function buildDeployPlan() {
  const { iu, wu, idle, walletUsdc } = _raw;
  const cashWei = iu + wu, cash = idle + walletUsdc; // deployable = account idle + wallet USDC
  const fromWallet = walletUsdc > 0.005;
  // fixed 30 / 40 / 30 split of ALL idle cash — split in wei so the actions sum to the exact balance
  const aAmt = cashWei * 30n / 100n, vAmt = cashWei * 40n / 100n, hAmt = cashWei - aAmt - vAmt;
  const aU = num(aAmt), vU = num(vAmt), hU = num(hAmt);
  const hMin = (hAmt * 4n * (10n ** 14n) / (10n ** 18n)) * 90n / 100n; // wstETH floor (rate 0.0004, 10% slack)
  const actions = [
    dep(AAVE_ID, aAmt),
    sw(A.usdc, A.usds, vAmt, vAmt * 99n / 100n), dep(VAULT_ID, vAmt),
    sw(A.usdc, A.wsteth, hAmt, hMin),
  ];
  const steps = [];
  if (fromWallet) steps.push({ k: 'FUND', t: `${money(walletUsdc)} wallet → account` });
  steps.push(
    { k: 'DEPOSIT', t: `${money(aU)} USDC → Aave (lending)` },
    { k: 'SWAP', t: `${money(vU)} USDC → USDS` },
    { k: 'DEPOSIT', t: `${money(vU)} USDS → Vault (ERC-4626)` },
    { k: 'SWAP', t: `${money(hU)} USDC → wstETH (held)` },
  );
  return {
    kind: 'deploy',
    goal: `Put your ${money(cash)} of idle cash to work at low risk.`,
    reasoning: `${money(cash)} is sitting idle${fromWallet ? ` — ${money(walletUsdc)} of it in your wallet` : ''}, earning nothing. ${fromWallet ? 'Pull it into the account and deploy' : 'Deploy'} all of it on a fixed 30 / 40 / 30 split: 30% into Aave lending and 40% into an ERC-4626 savings vault (70% withdraw-anytime stablecoin yield), plus 30% into wstETH for staking upside. Every venue is withdraw-anytime — nothing locks, you can exit whenever.`,
    targets: [{ c: 'earning', t: 'Aave 30%' }, { c: 'earning', t: 'Vault 40%' }, { c: 'held', t: 'wstETH 30%' }],
    steps,
    ...(await estimateGas(actions)), actions,
    fundFromWallet: fromWallet ? wu : 0n,
    sign: fromWallet ? 'transfer + executePlan · you sign 2 txs, non-custodial' : 'executePlan( 4 actions ) · you sign, non-custodial',
    label: `<span class="k">executePlan</span>([ 4 actions ])${fromWallet ? ' · fund + deploy' : ' · deploy'}`,
    path: `deploy ${money(cash)}${fromWallet ? ` (incl. ${money(walletUsdc)} from wallet)` : ''} → Aave ${money(aU)} · Vault ${money(vU)} · wstETH ${money(hU)}`,
  };
}

async function buildRebalancePlan() {
  const { aVal, vVal, hVal } = _raw;
  const total = aVal + vVal + hVal;
  // reached only when there's no deployable cash anywhere (account idle + wallet) AND nothing deployed
  if (total < 1) return { kind: 'none', note: 'Nothing to work with yet — click ＋ Get 1000 test USDC up top, then run the planner.' };
  // random target weights (demo). +0.15 keeps every bucket meaningfully non-zero.
  let w = [Math.random() + 0.15, Math.random() + 0.15, Math.random() + 0.15];
  const ws = w[0] + w[1] + w[2]; w = w.map((x) => x / ws);
  const pct = [Math.round(w[0] * 100), Math.round(w[1] * 100), 0]; pct[2] = 100 - pct[0] - pct[1];
  const d = { a: w[0] * total - aVal, v: w[1] * total - vVal, h: w[2] * total - hVal };
  const RED = 0.99, INC = 0.95; // raise a touch more than we redeploy so we never over-spend idle USDC
  const actions = [], steps = [];
  // Phase 1 — trim over-weight buckets into idle USDC
  if (d.a < -1) { const amt = U((-d.a * RED).toFixed(2)); actions.push(wd(AAVE_ID, amt)); steps.push({ k: 'WITHDRAW', t: `${money(-d.a)} from Aave → USDC` }); }
  if (d.v < -1) { const amt = U((-d.v * RED).toFixed(2)); actions.push(wd(VAULT_ID, amt), sw(A.usds, A.usdc, amt, amt * 99n / 100n)); steps.push({ k: 'WITHDRAW', t: `${money(-d.v)} from Vault → USDS` }, { k: 'SWAP', t: `${money(-d.v)} USDS → USDC` }); }
  if (d.h < -1) { const wst = U(((-d.h * RED) / PRICE.wstETH).toFixed(8)); actions.push(sw(A.wsteth, A.usdc, wst, U((-d.h * RED * 0.9).toFixed(2)))); steps.push({ k: 'SWAP', t: `${money(-d.h)} wstETH → USDC` }); }
  // Phase 2 — top up under-weight buckets from the idle USDC just raised
  if (d.a > 1) { const amt = U((d.a * INC).toFixed(2)); actions.push(dep(AAVE_ID, amt)); steps.push({ k: 'DEPOSIT', t: `${money(d.a)} USDC → Aave` }); }
  if (d.v > 1) { const amt = U((d.v * INC).toFixed(2)); actions.push(sw(A.usdc, A.usds, amt, amt * 99n / 100n), dep(VAULT_ID, amt)); steps.push({ k: 'SWAP', t: `${money(d.v)} USDC → USDS` }, { k: 'DEPOSIT', t: `${money(d.v)} USDS → Vault` }); }
  if (d.h > 1) { const amt = U((d.h * INC).toFixed(2)); actions.push(sw(A.usdc, A.wsteth, amt, U(((d.h * INC / PRICE.wstETH) * 0.9).toFixed(8)))); steps.push({ k: 'SWAP', t: `${money(d.h)} USDC → wstETH` }); }
  if (!actions.length) return { kind: 'none', note: 'Already on target — nothing to rebalance right now. Run again for a new random target.' };
  return {
    kind: 'rebalance',
    goal: `Rebalance ${money(total)} of positions to a fresh target mix.`,
    reasoning: `No idle cash to deploy, so the planner rebalances instead. It shifts your ${money(total)} of live positions toward a new ${pct[0]} / ${pct[1]} / ${pct[2]} target (Aave / Vault / wstETH) — trimming what's over-weight into USDC, then topping up what's under. Withdraw-anytime throughout.`,
    targets: [{ c: 'earning', t: `Aave ${pct[0]}%` }, { c: 'earning', t: `Vault ${pct[1]}%` }, { c: 'held', t: `wstETH ${pct[2]}%` }],
    steps, ...(await estimateGas(actions)), actions,
    sign: `executePlan( ${actions.length} actions ) · you sign, non-custodial`,
    label: `<span class="k">executePlan</span>([ ${actions.length} actions ]) · rebalance`,
    path: `rebalance ${money(total)} → Aave ${pct[0]}% · Vault ${pct[1]}% · wstETH ${pct[2]}%`,
  };
}

export async function runPlanner() {
  if (!ACCT) return;
  // deployable = account idle + wallet USDC (both uninvested); if there's cash anywhere, deploy it, else rebalance
  const deployable = _raw.idle + _raw.walletUsdc;
  plan.set(deployable >= 1 ? await buildDeployPlan() : await buildRebalancePlan());
}

export const ACT = {
  fund: () => tx('you', 'USDC.<span class="k">mint</span>(account, 1000)', 'test faucet', { address: A.usdc, abi: erc20Abi, functionName: 'mint', args: [ACCT, U('1000')] }),
  depAave: () => tx('you', '<span class="k">executePlan</span>([ DEPOSIT aave 400 ])', 'idle USDC → Aave.supply', planReq([dep(AAVE_ID, U('400'))])),
  swapHeld: () => tx('you', '<span class="k">executePlan</span>([ SWAP USDC→wstETH 250 ])', '250 USDC → wstETH via SwapRouter ' + R + ' · Δ ≥ minOut ✓', planReq([sw(A.usdc, A.wsteth, U('250'), U('0.09'))])),
  swapVault: () => tx('you', '<span class="k">executePlan</span>([ SWAP USDC→USDS 300, DEPOSIT vault 300 ])', '1) swap 300 USDC → USDS via SwapRouter ' + R + '  2) deposit 300 USDS → ERC-4626 Vault', planReq([sw(A.usdc, A.usds, U('300'), U('299')), dep(VAULT_ID, U('300'))])),
  rebalance: () => tx('you', '<span class="k">executePlan</span>([ WITHDRAW aave 200, SWAP USDC→USDS 200, DEPOSIT vault 200 ])', 'one atomic plan: withdraw Aave · swap 200 USDC → USDS via SwapRouter ' + R + ' · deposit Vault', planReq([wd(AAVE_ID, U('200')), sw(A.usdc, A.usds, U('200'), U('199')), dep(VAULT_ID, U('200'))])),
  exitAave: () => tx('you', '<span class="k">exit</span>(aave, MAX)', 'unwind → idle', { address: ACCT, abi: acctAbi, functionName: 'exit', args: [AAVE_ID, 2n ** 256n - 1n] }),
  withdrawTo: (amount) => withdrawTo(amount),
  rug: () => tx('platform', 'platform › <span class="k">executePlan</span>([ WITHDRAW aave MAX ])', 'the platform is NOT the owner', planReq([wd(AAVE_ID, 2n ** 256n - 1n)])),
  runPlanner: () => runPlanner(),
  dispatch: async () => {
    const p = get(plan);
    if (!p || !p.actions) return;
    if (_busy) return; _busy = true; busy.set(true);
    try {
      if (p.fundFromWallet && p.fundFromWallet > 0n) {
        await send({ address: A.usdc, abi: erc20Abi, functionName: 'transfer', args: [ACCT, p.fundFromWallet] });
        addLog(true, `wallet › <span class="k">transfer</span>(account, ${money(num(p.fundFromWallet))})`, 'move idle cash from your wallet into the account');
      }
      await send(planReq(p.actions));
      addLog(true, p.label, p.path);
    } catch (e) { addLog(false, p.label || 'dispatch', 'reverted: ' + errName(e)); }
    await refresh(); _busy = false; busy.set(false);
  },
};

export async function connectAndInit() {
  try {
    ACCT = await pub.readContract({ address: A.factory, abi: factoryAbi, functionName: 'predict', args: [you.address, SALT] });
    let owner; try { owner = await pub.readContract({ address: ACCT, abi: acctAbi, functionName: 'owner' }); } catch { owner = Z; }
    if (owner.toLowerCase() !== you.address.toLowerCase()) {
      const h = await wYou.writeContract({ address: A.factory, abi: factoryAbi, functionName: 'createAccount', args: [SALT], account: you });
      await pub.waitForTransactionReceipt({ hash: h });
      addLog(true, '<span class="k">factory.createAccount</span>(salt)', 'your account clone deployed + initialized');
    }
    [AAVE_ID, VAULT_ID] = await Promise.all([
      pub.readContract({ address: A.registry, abi: registryAbi, functionName: 'positionId', args: [2, A.aave, A.usdc] }),
      pub.readContract({ address: A.registry, abi: registryAbi, functionName: 'positionId', args: [1, A.vault, A.usds] }),
    ]);
    conn.set({ up: true, down: false, text: 'connected · anvil 31337' });
    await refresh();
  } catch (e) {
    conn.set({ up: false, down: true, text: 'anvil not reachable' });
    errMsg.set("<b>Can't reach the contracts.</b> Start a fresh anvil and run the deploy script first — see the README, then reload. If your addresses differ, update <code>A</code> in <code>src/lib/chain.js</code>.<br><br><code>" + (e.shortMessage || e.message) + '</code>');
  }
}
