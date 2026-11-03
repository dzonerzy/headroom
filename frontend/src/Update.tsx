import { useEffect, useState } from "react";
import { App, Plume, PlumeError, type PlumeRelease } from "./bindings";
import { bytes } from "./format";

const RELEASES = "https://github.com/dzonerzy/headroom/releases";

/** How long after the start the check waits: the first scan comes first. */
const CHECK_AFTER_MS = 8000;

type State =
  | { name: "offer"; release: PlumeRelease }
  | { name: "installing"; release: PlumeRelease; received: number; total: number }
  | { name: "ready"; release: PlumeRelease }
  | { name: "failed"; release: PlumeRelease; message: string };

/** A newer Headroom, offered: GitHub asked once a little after the start;
 * nothing is downloaded before "Update". The update is signed and tried
 * before it replaces this one (Plume's updater); the restart is the user's. */
export default function Update() {
  const [state, setState] = useState<State | null>(null);

  useEffect(() => {
    if (!App.checksUpdates()) return;
    let stopped = false;
    const timer = window.setTimeout(async () => {
      try {
        const release = await Plume.updates.check();
        if (release && !stopped) setState({ name: "offer", release });
      } catch {
        // Offline, or GitHub's limit: asked again at the next start.
      }
    }, CHECK_AFTER_MS);
    return () => {
      stopped = true;
      window.clearTimeout(timer);
    };
  }, []);

  if (!state) return null;
  const { release } = state;

  async function install() {
    setState({ name: "installing", release, received: 0, total: release.size });
    const off = Plume.updates.on("progress", ({ received, total }) =>
      setState({ name: "installing", release, received, total: total || release.size }),
    );
    try {
      await Plume.updates.install(release);
      setState({ name: "ready", release });
    } catch (error) {
      const code = error instanceof PlumeError ? String(error.code) : "Failed";
      const reasons: Record<string, string> = {
        BadSignature: "The download is not signed by Headroom's key, so it was not installed.",
        VerifyFailed: "The new version did not start, so this one stays.",
        AccessDenied: "Headroom cannot replace itself where it is installed.",
      };
      setState({ name: "failed", release, message: reasons[code] ?? `It could not be installed (${code}).` });
    } finally {
      off();
    }
  }

  const page = `${RELEASES}/tag/v${release.version}`;
  return (
    <aside className="update" role="status" aria-label="Update">
      {state.name === "offer" && (
        <>
          <p className="update-text">
            Headroom {release.version} is out.{" "}
            <button className="update-link" onClick={() => Plume.app.openURL(page)}>
              What is new
            </button>
          </p>
          <span className="update-actions">
            <button className="control control-main" onClick={install}>
              Update
            </button>
            <button className="control control-quiet" onClick={() => setState(null)}>
              Not now
            </button>
          </span>
        </>
      )}
      {state.name === "installing" && (
        <>
          <p className="update-text">
            Downloading Headroom {release.version}
            {state.total > 0 && `: ${bytes(state.received)} of ${bytes(state.total)}`}
          </p>
          <span className="update-track">
            <span className="update-bar" style={{ width: `${state.total > 0 ? (state.received / state.total) * 100 : 0}%` }} />
          </span>
        </>
      )}
      {state.name === "ready" && (
        <>
          <p className="update-text">Headroom {release.version} is installed. It starts with the next launch, or now:</p>
          <span className="update-actions">
            <button className="control control-main" onClick={() => Plume.updates.restart()}>
              Restart Headroom
            </button>
            <button className="control control-quiet" onClick={() => setState(null)}>
              Later
            </button>
          </span>
        </>
      )}
      {state.name === "failed" && (
        <>
          <p className="update-text">{state.message}</p>
          <span className="update-actions">
            <button className="control control-main" onClick={() => Plume.app.openURL(page)}>
              Download it
            </button>
            <button className="control control-quiet" onClick={() => setState(null)}>
              Close
            </button>
          </span>
        </>
      )}
    </aside>
  );
}
