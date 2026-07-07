<script>
  import { busy, ACT } from '../lib/state.js';
</script>

<div class="card">
  <div class="h">Manual actions <span class="hsub">· direct protocol calls, no planner</span></div>
  <div class="agrid">
    <div class="agt">Deploy &amp; rebalance (executePlan)</div>
    <button class="act" disabled={$busy} onclick={ACT.depAave}><span>Supply 400 → Aave</span><span class="s">DEPOSIT</span></button>
    <button class="act" disabled={$busy} onclick={ACT.swapHeld}><span>Add wstETH exposure</span><span class="s">250 USDC → held</span></button>
    <button class="act" disabled={$busy} onclick={ACT.swapVault}><span>Move 300 into the Vault</span><span class="s">stable savings (ERC-4626)</span></button>
    <button class="act" disabled={$busy} onclick={ACT.rebalance}><span>Rebalance (1 plan)</span><span class="s">WITHDRAW+SWAP+DEPOSIT</span></button>
    <div class="agt">Exit</div>
    <button class="act" disabled={$busy} onclick={ACT.exitAave}><span>Exit Aave → idle</span><span class="s">exit(aave, MAX)</span></button>
    <div class="agt">Custody</div>
    <button class="act danger" disabled={$busy} onclick={ACT.rug}><span>🦹 Platform: drain me</span><span class="s">executePlan as acct #1</span></button>
  </div>
</div>
