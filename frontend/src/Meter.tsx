import type { Space } from "./bindings";
import { bytes, bytesParts, share } from "./format";

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
  /** What is under the mouse on the map: its share glows on the meter. */
  focus: { name: string; size: number } | null;
};

/** The disk as a level meter: what was scanned lit, the rest of what is used
 * dim, the free space (the headroom) dark, the last tenth marked as the clip
 * zone; a scale under it, and what the mouse is on glowing at the lit end. */
export function Meter({ space, level, scanning, focus }: Props) {
  const total = space?.total ?? 0;
  const used = space ? space.total - space.free : 0;
  const lit = total && level !== null ? Math.min(SEGMENTS, (level / total) * SEGMENTS) : 0;
  const filled = total ? (used / total) * SEGMENTS : 0;
  // The focused item's segments: the last ones of the lit part, at least one.
  const focusSegments = focus && total ? Math.max(1, Math.round((focus.size / total) * SEGMENTS)) : 0;
  const focusFrom = Math.max(0, Math.ceil(lit) - focusSegments);
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

      <div className="gauge">
        <div
          className="segments"
          role="meter"
          aria-label="Disk used"
          aria-valuemin={0}
          aria-valuemax={total}
          aria-valuenow={used}
        >
          {Array.from({ length: SEGMENTS }, (_, i) => {
            const state =
              focusSegments && i >= focusFrom && i < Math.ceil(lit)
                ? "focus"
                : i < Math.floor(lit)
                  ? "lit"
                  : i < Math.ceil(lit)
                    ? "edge"
                    : i < filled
                      ? "used"
                      : "free";
            return <span key={i} className="segment" data-state={state} data-clip={i >= CLIP_FROM ? "" : undefined} />;
          })}
        </div>
        <div className="scale" aria-hidden="true">
          {total > 0 && [0, 0.25, 0.5, 0.75, 1].map((at) => (
            <span key={at} className="tick" style={{ left: `${at * 100}%` }}>
              {at === 0 ? "0" : bytes(total * at)}
            </span>
          ))}
          {focus && total > 0 && (
            <span className="scale-focus">
              <span className="scale-focus-name">{focus.name}</span> is {share(focus.size / total)} of the disk
            </span>
          )}
        </div>
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

/** The icon, small: a folder with three tiles and the headroom at the top. */
export function Mark() {
  return (
    <svg className="mark" viewBox="0 0 24 24" aria-hidden="true">
      <rect x="1" y="1" width="22" height="22" rx="5.5" fill="#152230" />
      <rect x="4" y="4" width="16" height="2.4" fill="#2f3e50" />
      <rect x="4.5" y="7" width="7" height="12.5" fill="#5b8def" />
      <rect x="12.6" y="12.6" width="3.9" height="6.9" fill="#d08a3c" />
      <rect x="17.1" y="12.6" width="2.4" height="6.9" fill="#9b6fdc" />
      <rect x="13" y="7.4" width="6.1" height="4.4" fill="none" stroke="#52c7a2" strokeWidth="0.9" />
    </svg>
  );
}
