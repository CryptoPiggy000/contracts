<script>
  import { log } from '../lib/state.js';
</script>

<div class="log">
  <div class="lh">Activity Log · what got done (incl. the swap router)</div>
  <div class="b">
    {#each $log as e, i (i)}
      <div class="le {e.ok ? 'ok' : 'rv'}">
        <span class="bd">{e.ok ? '✓' : '✗'}</span><span class="c">{@html e.call}</span>
        {#if e.path}<div class="p">{e.path}</div>{/if}
      </div>
    {/each}
  </div>
</div>
