import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";
import Root from "./Root";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
);
