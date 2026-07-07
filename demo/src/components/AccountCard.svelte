<script>
  import { account } from '../lib/state.js';
  const money = (n) => '$' + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
</script>

<div class="card acct">
  <div class="head">
    <div class="head-l">
      <div class="hl-lbl">Owner wallet</div>
      <div class="hl-addr">{$account.ownerAddr || '—'}</div>
      <div class="hl-acct">{$account.acctAddr || 'account —'}</div>
    </div>
    <div class="head-r">
      <div class="hl-lbl">Total asset value</div>
      <div class="hl-num">{money($account.net)}</div>
      <div class="hl-acct">account {money($account.total)} + wallet {money($account.walletVal)}</div>
    </div>
  </div>

  <div class="split">
    <div class="sp earning"><div class="sp-l">Allocated · earning</div><div class="sp-v">{money($account.allocated)}</div></div>
    <div class="sp held"><div class="sp-l">Held · in account</div><div class="sp-v">{money($account.held)}</div></div>
    <div class="sp wallet"><div class="sp-l">In wallet · withdrawn</div><div class="sp-v">{money($account.walletVal)}</div></div>
  </div>

  <details class="acc">
    <summary>Assets &amp; allocation<span class="caret">▾</span></summary>
    <div class="alloc">
      {#if $account.items.length}
        {#each $account.items as it (it.nm)}
          <div class="al {it.bk}">
            <div class="al-top">
              <span class="al-nm">{it.nm}{#if it.sub} <span class="al-sub">{it.sub}</span>{/if} <span class="al-tag">{it.tag}</span></span>
              <span class="al-v">{money(it.v)} · {it.pct.toFixed(0)}%</span>
            </div>
            <div class="al-bar"><div style="width:{it.pct.toFixed(1)}%"></div></div>
          </div>
        {/each}
      {:else}
        <div class="al-empty">No assets yet — click “＋ Get 1000 test USDC” to begin.</div>
      {/if}
    </div>
  </details>
</div>
