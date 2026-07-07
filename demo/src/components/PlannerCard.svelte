<script>
  import { plan, busy, ACT } from '../lib/state.js';
</script>

<div class="card planner">
  <div class="h">Planner <span class="hsub">· the engine, off-chain — reads state, returns a plan</span></div>

  <button class="act plan" disabled={$busy} onclick={ACT.runPlanner}>
    <span>▶ Run Planner</span>
    <span class="s">read your positions → produce a Plan, then dispatch it</span>
  </button>

  {#if $plan}
    <div class="planbox">
      {#if $plan.kind === 'none'}
        <div class="pl-note">{$plan.note}</div>
      {:else}
        <div class="pl-sec">
          <div class="pl-k">Goal <span class="pl-badge" class:rb={$plan.kind === 'rebalance'}>{$plan.kind}</span></div>
          <div class="pl-goal">{$plan.goal}</div>
        </div>
        <div class="pl-sec"><div class="pl-k">Reasoning</div><div class="pl-txt">{$plan.reasoning}</div></div>
        <div class="pl-sec">
          <div class="pl-k">Target mix</div>
          <div class="pl-targets">{#each $plan.targets as t}<span class="pt {t.c}">{t.t}</span>{/each}</div>
        </div>
        <div class="pl-sec">
          <div class="pl-k">Actions · {$plan.steps.length} steps, 1 signature</div>
          <ol class="pl-steps">{#each $plan.steps as s}<li><span class="kk">{s.k}</span><span>{s.t}</span></li>{/each}</ol>
        </div>
        <div class="pl-sec"><div class="pl-k">Est. network fee</div><div class="pl-gas">{$plan.gasText} <span class="u">({$plan.gasSub})</span></div></div>
        <button class="act plan-go" disabled={$busy} onclick={ACT.dispatch}>
          <span>Dispatch this plan →</span>
          <span class="s">{$plan.sign}</span>
        </button>
      {/if}
    </div>
  {/if}
</div>
