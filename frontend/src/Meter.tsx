import type { Space } from "./bindings";
import { bytesParts, share } from "./format";

/** How many segments the meter has, and from which one it is in the red:
 * the last tenth of the disk, where it clips. */
const SEGMENTS = 72;
const CLIP_FROM = Math.round(SEGMENTS * 0.9);

type Props = {
  /** The disk; null while it is not known. */
  space: Space | null;
  /** What the scan has found so far (or found), bytes; null before a scan. */
  level: number | null;
  scanning: boolean;
};

/** The disk as a level meter: what was scanned lit, the rest of what is used
 * dim, the free space (the headroom) dark, the last tenth marked as the clip
 * zone. */
export function Meter({ space, level, scanning }: Props) {
  const total = space?.total ?? 0;
  const used = space ? space.total - space.free : 0;
  const lit = total && level !== null ? Math.min(SEGMENTS, (level / total) * SEGMENTS) : 0;
  const filled = total ? (used / total) * SEGMENTS : 0;
  const [freeValue, freeUnit] = bytesParts(space?.free ?? 0);
  const [levelValue, levelUnit] = bytesParts(level ?? 0);
  const [usedValue, usedUnit] = bytesParts(used);

  return (
    <section className="meter" aria-label="Disk space">
      <div className="meter-reading">
        {level !== null ? (
          <>
            <p className="figure figure-level" aria-live={scanning ? "polite" : undefined}>
              <span className="figure-value">{levelValue}</span>
              <span className="figure-unit">{levelUnit}</span>
            </p>
            <p className="figure-caption">{scanning ? "found so far" : "in this folder"}</p>
          </>
        ) : (
          <>
            <p className="figure">
              <span className="figure-value">{usedValue}</span>
              <span className="figure-unit">{usedUnit}</span>
            </p>
            <p className="figure-caption">used on this disk</p>
          </>
        )}
      </div>

      <div
        className="segments"
        role="meter"
        aria-label="Disk used"
        aria-valuemin={0}
        aria-valuemax={total}
        aria-valuenow={used}
      >
        {Array.from({ length: SEGMENTS }, (_, i) => {
          const state = i < Math.floor(lit) ? "lit" : i < Math.ceil(lit) ? "edge" : i < filled ? "used" : "free";
          return <span key={i} className="segment" data-state={state} data-clip={i >= CLIP_FROM ? "" : undefined} />;
        })}
      </div>

      <div className="meter-reading meter-reading-end">
        {space ? (
          <>
            <p className="figure figure-headroom" data-low={space.free / space.total < 0.1 ? "" : undefined}>
              <span className="figure-value">{freeValue}</span>
              <span className="figure-unit">{freeUnit}</span>
            </p>
            <p className="figure-caption">headroom, {share(space.free / space.total)} of the disk</p>
          </>
        ) : (
          <p className="figure-caption">Disk size unknown</p>
        )}
      </div>
    </section>
  );
}
