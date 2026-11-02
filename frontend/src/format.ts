/** The smallest step performance.now() takes here (engines coarsen it): the
 * shortest of a few, as a busy machine may stretch one. */
const resolution = (() => {
  let smallest = Infinity;
  let last = performance.now();
  for (let steps = 0; steps < 5; ) {
    const now = performance.now();
    if (now !== last) {
      smallest = Math.min(smallest, now - last);
      last = now;
      steps++;
    }
  }
  return smallest;
})();

/** A measured duration for people: "4 µs", "1.2 ms", "1.5 s", or "under
 * 100 µs" when it was shorter than the clock can tell. */
export function duration(ms: number): string {
  if (ms <= 0) return `under ${format(resolution)}`;
  return format(ms);
}

function format(ms: number): string {
  if (ms < 1) return `${Math.max(1, Math.round(ms * 1000))} µs`;
  if (ms < 1000) return `${ms < 10 ? ms.toFixed(1).replace(/\.0$/, "") : ms.toFixed(0)} ms`;
  return `${(ms / 1000).toFixed(1)} s`;
}

/** How many steps the worker-thread demo counts. */
export const steps = 12;
