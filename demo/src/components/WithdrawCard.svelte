<script>
  import { account, busy, ACT } from '../lib/state.js';
  const money = (n) => '$' + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  let amount = 100;
  $: avail = ($account.idleUsdc || 0) + ($account.aaveVal || 0) + ($account.vaultVal || 0) + ($account.wstethVal || 0);
  $: capped = Math.min(Math.max(Number(amount) || 0, 0), avail);
  $: sources = buildSources($account, capped);
  $: fromProtocols = sources.some((s) => s.label !== 'Idle USDC');
  $: over = Number(amount) > avail + 0.005;

  function buildSources(a, amt) {
    const out = []; let need = amt;
    const take = (label, val) => { const v = Math.min(need, val || 0); if (v > 0.005) { out.push({ label, v }); need -= v; } };
    take('Idle USDC', a.idleUsdc); take('Aave', a.aaveVal); take('Vault', a.vaultVal); take('wstETH', a.wstethVal);
    return out;
  }
</script>

<div class="card">
  <div class="h">Withdraw <span class="hsub">· to your own wallet — the only door out</span></div>

  <div class="wd-row">
    <span class="wd-cur">$</span>
    <input class="wd-in" type="number" min="0" step="50" bind:value={amount} disabled={$busy} />
    <button class="mini" disabled={$busy} onclick={() => (amount = Math.floor(avail * 100) / 100)}>Max</button>
  </div>

  {#if capped > 0.005}
    <div class="wd-src">
      <div class="pl-k">Sourced from {#if over}<span class="hsub">(capped to available {money(avail)})</span>{/if}</div>
      <ul class="pl-steps">
        {#each sources as s}
          <li><span class="kk">{s.label}</span><span>{money(s.v)}</span></li>
        {/each}
      </ul>
      {#if fromProtocols}<div class="wd-note">Unwinds those positions to idle USDC, then sends {money(capped)} to your wallet — two owner-signed txs.</div>{/if}
    </div>
    <button class="act plan-go wd-go" disabled={$busy} onclick={() => ACT.withdrawTo(capped)}>
      <span>Withdraw {money(capped)} → wallet</span>
      <span class="s">{fromProtocols ? 'unwind → withdraw' : 'withdraw(USDC)'} · non-custodial, owner-only</span>
    </button>
  {:else}
    <div class="pl-note wd-empty">Nothing to withdraw yet — fund or deploy first.</div>
  {/if}
</div>
