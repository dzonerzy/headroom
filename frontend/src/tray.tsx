import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";
import Popover from "./Popover";

// The tray's popover (tray.html): its own window by the tray icon.
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Popover />
  </StrictMode>,
);
