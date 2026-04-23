import { useEffect, useRef, useState } from "react";
import mermaid from "mermaid";

const DIAGRAM = `classDiagram
  class User {
    +String id
    +String name
    +login()
  }
  class Order {
    +String id
    +Date created
    +submit()
  }
  class Product {
    +String sku
    +String title
    +Float price
  }
  class Payment {
    +String id
    +Float amount
    +process()
  }

  User "1" --> "*" Order : places
  Order "*" --> "*" Product : contains
  Order "1" --> "1" Payment : paidBy

  cssClass "User" highlighted
  cssClass "Payment" changed

  click User call nodeClicked()
  click Order call nodeClicked()
  click Product call nodeClicked()
  click Payment call nodeClicked()

  classDef highlighted fill:#fde68a,stroke:#d97706,stroke-width:3px,color:#7c2d12
  classDef changed fill:#bbf7d0,stroke:#15803d,stroke-width:3px,color:#14532d
  classDef selected fill:#bfdbfe,stroke:#1d4ed8,stroke-width:4px,color:#1e3a8a
`;

mermaid.initialize({
  startOnLoad: false,
  theme: "default",
  securityLevel: "loose",
  flowchart: { htmlLabels: true },
});

type NodeOffset = { x: number; y: number };

function App() {
  const containerRef = useRef<HTMLDivElement>(null);
  const offsetsRef = useRef<Record<string, NodeOffset>>({});
  const [selected, setSelected] = useState<string | null>(null);
  const [renderKey, setRenderKey] = useState(0);

  useEffect(() => {
    const w = window as unknown as {
      nodeClicked?: (e: MouseEvent, id: string) => void;
    };
    w.nodeClicked = (_e: MouseEvent, id: string) => {
      setSelected((prev) => (prev === id ? null : id));
    };
    return () => {
      w.nodeClicked = undefined;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    async function render() {
      if (!containerRef.current) return;
      const { svg, bindFunctions } = await mermaid.render(
        `mermaid-svg-${renderKey}`,
        DIAGRAM,
      );
      if (cancelled || !containerRef.current) return;
      containerRef.current.innerHTML = svg;
      const svgEl = containerRef.current.querySelector("svg");
      if (svgEl) {
        svgEl.style.maxWidth = "100%";
        svgEl.style.height = "auto";
        svgEl.removeAttribute("width");
      }
      bindFunctions?.(containerRef.current);
      attachInteractions();
      applyOffsets();
      applySelection();
    }
    render();
    return () => {
      cancelled = true;
    };
  }, [renderKey]);

  useEffect(() => {
    applySelection();
  }, [selected]);

  function applySelection() {
    if (!containerRef.current) return;
    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );
    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;
      if (selected === id) {
        node.classList.add("poc-selected");
      } else {
        node.classList.remove("poc-selected");
      }
    });
  }

  function nodeId(node: SVGGElement): string | null {
    const raw = node.id || "";
    // mermaid v11 ids look like "classId-User-12" or "flowchart-User-12"
    const m = raw.match(/^(?:classId|flowchart|node)[-_](.+?)[-_]\d+$/);
    if (m) return m[1];
    const dataId = node.getAttribute("data-id");
    return dataId;
  }

  function applyOffsets() {
    if (!containerRef.current) return;
    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );
    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;
      const off = offsetsRef.current[id];
      if (off) {
        node.setAttribute("transform-origin", "0 0");
        node.style.transform = `translate(${off.x}px, ${off.y}px)`;
      }
    });
  }

  function attachInteractions() {
    if (!containerRef.current) return;
    const svg = containerRef.current.querySelector("svg");
    if (!svg) return;

    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );

    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;

      node.style.cursor = "grab";
      let dragging = false;
      let moved = false;
      let startX = 0;
      let startY = 0;
      let baseX = 0;
      let baseY = 0;

      const onPointerDown = (ev: PointerEvent) => {
        ev.preventDefault();
        dragging = true;
        moved = false;
        startX = ev.clientX;
        startY = ev.clientY;
        const off = offsetsRef.current[id] ?? { x: 0, y: 0 };
        baseX = off.x;
        baseY = off.y;
        node.setPointerCapture(ev.pointerId);
        node.style.cursor = "grabbing";
      };

      const onPointerMove = (ev: PointerEvent) => {
        if (!dragging) return;
        const dx = ev.clientX - startX;
        const dy = ev.clientY - startY;
        if (Math.abs(dx) + Math.abs(dy) > 3) moved = true;
        const nx = baseX + dx;
        const ny = baseY + dy;
        offsetsRef.current[id] = { x: nx, y: ny };
        node.style.transform = `translate(${nx}px, ${ny}px)`;
        // re-route edges roughly: leave them where they are. Simpler: trigger
        // CSS-only translate which doesn't update edges. Acceptable for PoC.
      };

      const onPointerUp = (ev: PointerEvent) => {
        if (!dragging) return;
        dragging = false;
        node.style.cursor = "grab";
        try {
          node.releasePointerCapture(ev.pointerId);
        } catch {
          /* noop */
        }
        if (moved) {
          ev.stopPropagation();
        }
      };

      const onClick = (ev: MouseEvent) => {
        if (moved) {
          ev.stopPropagation();
          ev.preventDefault();
        }
      };

      node.addEventListener("pointerdown", onPointerDown);
      node.addEventListener("pointermove", onPointerMove);
      node.addEventListener("pointerup", onPointerUp);
      node.addEventListener("pointercancel", onPointerUp);
      node.addEventListener("click", onClick, true);
    });
  }

  function resetPositions() {
    offsetsRef.current = {};
    setRenderKey((k) => k + 1);
  }

  return (
    <div className="min-h-screen w-full bg-slate-50 text-slate-900">
      <header className="border-b border-slate-200 bg-white px-4 py-3 shadow-sm">
        <div className="mx-auto flex max-w-5xl flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h1 className="text-lg font-semibold sm:text-xl">
              Mermaid Klassendiagramm — Interaktiver PoC
            </h1>
            <p className="text-xs text-slate-500 sm:text-sm">
              Tippen zum Highlighten. Ziehen zum Verschieben.
            </p>
          </div>
          <button
            type="button"
            onClick={resetPositions}
            className="self-start rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 shadow-sm hover:bg-slate-100 active:bg-slate-200 sm:self-auto"
          >
            Positionen zurücksetzen
          </button>
        </div>
      </header>

      <main className="mx-auto max-w-5xl px-3 py-4">
        <div className="mb-3 flex flex-wrap items-center gap-3 text-xs sm:text-sm">
          <LegendDot color="#fde68a" border="#d97706" label="highlighted (Mermaid cssClass)" />
          <LegendDot color="#bbf7d0" border="#15803d" label="changed (Mermaid cssClass)" />
          <LegendDot color="#bfdbfe" border="#1d4ed8" label="selected (Tap)" />
          {selected && (
            <span className="rounded-full bg-blue-100 px-2 py-0.5 font-medium text-blue-800">
              Ausgewählt: {selected}
            </span>
          )}
        </div>

        <div className="overflow-auto rounded-lg border border-slate-200 bg-white p-2 shadow-sm">
          <div
            ref={containerRef}
            className="mermaid-host min-h-[400px] w-full touch-none select-none"
          />
        </div>

        <details className="mt-4 rounded-lg border border-slate-200 bg-white p-3 text-sm shadow-sm">
          <summary className="cursor-pointer font-medium text-slate-700">
            Mermaid-Quellcode (Marker im Code)
          </summary>
          <pre className="mt-2 overflow-x-auto rounded bg-slate-900 p-3 text-xs leading-relaxed text-slate-100">
            <code>{DIAGRAM}</code>
          </pre>
        </details>
      </main>

      <style>{`
        .mermaid-host g.node, .mermaid-host g.classGroup { transition: filter 120ms ease; }
        .mermaid-host g.poc-selected > rect,
        .mermaid-host g.poc-selected > path,
        .mermaid-host g.poc-selected > polygon {
          fill: #bfdbfe !important;
          stroke: #1d4ed8 !important;
          stroke-width: 4px !important;
        }
        .mermaid-host g.poc-selected text { fill: #1e3a8a !important; }
      `}</style>
    </div>
  );
}

function LegendDot({
  color,
  border,
  label,
}: {
  color: string;
  border: string;
  label: string;
}) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span
        className="inline-block h-3 w-3 rounded-sm"
        style={{ background: color, border: `2px solid ${border}` }}
      />
      <span className="text-slate-700">{label}</span>
    </span>
  );
}

export default App;
