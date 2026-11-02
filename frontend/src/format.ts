/** Bytes for people: "495.1 GB", "640 KB", "12 bytes" (powers of 1024, the
 * way file managers count). */
export function bytes(n: number): string {
  if (n < 1024) return n === 1 ? "1 byte" : `${n} bytes`;
  const units = ["KB", "MB", "GB", "TB", "PB"];
  let value = n / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value < 10 ? value.toFixed(1) : value < 100 ? value.toFixed(1) : value.toFixed(0)} ${units[unit]}`;
}

/** The number and the unit apart, for type set at two sizes. */
export function bytesParts(n: number): [string, string] {
  const [value, unit] = bytes(n).split(" ");
  return [value, unit];
}

const counts = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const whole = new Intl.NumberFormat("en");

/** "6.5M", "840K", "212". */
export function compact(n: number): string {
  return counts.format(n);
}

/** "6,522,293". */
export function exact(n: number): string {
  return whole.format(n);
}

/** "8.1 s", "640 ms". */
export function seconds(ms: number): string {
  return ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(1)} s`;
}

/** "4.2%", "under 0.1%". */
export function share(fraction: number): string {
  const percent = fraction * 100;
  if (percent < 0.1) return "under 0.1%";
  return `${percent < 10 ? percent.toFixed(1) : percent.toFixed(0)}%`;
}

/** "files" or "file". */
export function plural(n: number, one: string, many: string): string {
  return n === 1 ? one : many;
}
