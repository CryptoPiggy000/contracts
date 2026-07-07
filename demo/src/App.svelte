<script>
  import { onMount } from 'svelte';
  import { conn, errMsg, busy, ACT, connectAndInit, refresh } from './lib/state.js';
  import AccountCard from './components/AccountCard.svelte';
  import PlannerCard from './components/PlannerCard.svelte';
  import WithdrawCard from './components/WithdrawCard.svelte';
  import ManualActions from './components/ManualActions.svelte';
  import ActivityLog from './components/ActivityLog.svelte';

  onMount(connectAndInit);
</script>

<div class="wrap">
  <div class="top">
    <div class="eyebrow">
      <span class="dot" class:up={$conn.up} class:down={$conn.down}></span>
      <span>{$conn.text}</span>
    </div>
    <button class="mini" onclick={refresh}>↻ Refresh</button>
  </div>

  <div class="title-row">
    <h1>CryptoPiggy — <em>local dApp</em></h1>
    <button class="mini faucet" disabled={$busy} onclick={ACT.fund}>＋ Get 1000 test USDC</button>
  </div>

  <p class="lede">A real single-page app talking to your local <code>anvil</code> node. Every button sends an actual transaction to the deployed contracts (as anvil account&nbsp;#0, the owner). Watch funds move; then try to make the <b>platform</b> steal.</p>

  {#if $errMsg}
    <div class="banner">{@html $errMsg}</div>
  {/if}

  <div class="stage">
    <AccountCard />
    <div class="rcol">
      <PlannerCard />
      <WithdrawCard />
      <ManualActions />
    </div>
  </div>

  <ActivityLog />
</div>
