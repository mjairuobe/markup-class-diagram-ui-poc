import { useEffect, useRef, useState } from "react";
import mermaid from "mermaid";

// Marker werden direkt im Mermaid-Code als Kommentare gesetzt:
//   %% highlight: <Class>.<MemberLabel> = <markerName>
// Erlaubte Marker: changed | added | removed
const DIAGRAM = `classDiagram
  %% highlight: User.+login() = changed
  %% highlight: Order.+submit() = added
  %% highlight: Payment.+amount = removed
  %% highlight: Product.+int productNumber = removed
  %% highlight: Product.+String SKU = added
  %% highlight: Product.+list_products() = changed

  class User {
    +String id
    +String name
    +login()
    +logout()
  }
  class Order {
    +String id
    +Date created
    +submit()
  }
  class Product {
    +int productNumber
    +String SKU
    +String title
    +Float price
    +list_products()
  }
  class Payment {
    +String id
    +Float amount
    +process()
  }

  User "1" --> "*" Order : places
  Order "*" --> "*" Product : contains
  Order "1" --> "1" Payment : paidBy

  click User call nodeClicked()
  click Order call nodeClicked()
  click Product call nodeClicked()
  click Payment call nodeClicked()
`;

mermaid.initialize({
  startOnLoad: false,
  theme: "default",
  securityLevel: "loose",
  flowchart: { htmlLabels: true },
});

type NodeOffset = { x: number; y: number };
type MemberMarker = "changed" | "added" | "removed";
type Highlight = { className: string; member: string; marker: MemberMarker };

const MARKER_STYLE: Record<MemberMarker, { fill: string; color: string; label: string }> = {
  changed: { fill: "#fde68a", color: "#7c2d12", label: "geändert" },
  added: { fill: "#bbf7d0", color: "#14532d", label: "hinzugefügt" },
  removed: { fill: "#fecaca", color: "#7f1d1d", label: "entfernt" },
};

function parseHighlights(src: string): Highlight[] {
  const out: Highlight[] = [];
  const re = /%%\s*highlight:\s*([A-Za-z_][\w]*)\.(.+?)\s*=\s*(changed|added|removed)\s*$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    out.push({
      className: m[1],
      member: m[2].trim(),
      marker: m[3] as MemberMarker,
    });
  }
  return out;
}

function App() {
  const containerRef = useRef<HTMLDivElement>(null);
  const offsetsRef = useRef<Record<string, NodeOffset>>({});
  const [selected, setSelected] = useState<string | null>(null);
  const [renderKey, setRenderKey] = useState(0);
  const highlights = parseHighlights(DIAGRAM);

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
      applyMemberHighlights();
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

  function nodeId(node: SVGGElement): string | null {
    const raw = node.id || "";
    // Mermaid v11 ids look like "mermaid-svg-0-classId-User-0".
    const m = raw.match(/(?:classId|flowchart|node)[-_](.+?)[-_]\d+$/);
    if (m) return m[1];
    return node.getAttribute("data-id");
  }

  function applySelection() {
    if (!containerRef.current) return;
    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );
    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;
      node.classList.toggle("poc-selected", selected === id);
    });
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

  function applyMemberHighlights() {
    if (!containerRef.current) return;
    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );

    const byClass = new Map<string, Highlight[]>();
    highlights.forEach((h) => {
      const arr = byClass.get(h.className) ?? [];
      arr.push(h);
      byClass.set(h.className, arr);
    });

    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;
      const list = byClass.get(id);
      if (!list || list.length === 0) return;
      list.forEach((h) => highlightMemberInNode(node, h));
    });
  }

  function normalize(s: string): string {
    return s.replace(/\s+/g, "").trim();
  }

  function highlightMemberInNode(classGroup: SVGGElement, h: Highlight) {
    const style = MARKER_STYLE[h.marker];
    const want = normalize(h.member);

    // 1) Try HTML labels inside foreignObject (mermaid v11 default).
    const htmlCandidates = classGroup.querySelectorAll<HTMLElement>(
      "foreignObject *",
    );
    const htmlMatch = findInnermostMatch(Array.from(htmlCandidates), want);
    if (htmlMatch) {
      // Style the innermost text element (e.g. <p>) without changing its
      // box: keep block layout so the bg fills the foreignObject row, but
      // do NOT add padding/inline-block — that would overflow the fixed
      // foreignObject width and clip the text.
      htmlMatch.style.background = style.fill;
      htmlMatch.style.color = style.color;
      htmlMatch.style.fontWeight = "700";
      htmlMatch.style.borderRadius = "3px";
      htmlMatch.style.margin = "0";
      if (h.marker === "removed") {
        htmlMatch.style.textDecoration = "line-through";
      }
      htmlMatch.classList.add("poc-member-highlight");

      // Expand the parent foreignObject width a bit so the bolder font
      // doesn't overflow on the right edge.
      const fo = htmlMatch.closest("foreignObject");
      if (fo) {
        const w = parseFloat(fo.getAttribute("width") || "0");
        if (!Number.isNaN(w) && w > 0) {
          fo.setAttribute("width", String(w + 12));
          // Shift left by 6 to keep it visually centered.
          const tr = fo.parentElement?.getAttribute("transform") || "";
          const tm = tr.match(/translate\(([-\d.]+)\s*,\s*([-\d.]+)\)/);
          if (tm && fo.parentElement) {
            const nx = parseFloat(tm[1]) - 6;
            const ny = parseFloat(tm[2]);
            fo.parentElement.setAttribute(
              "transform",
              `translate(${nx},${ny})`,
            );
          }
        }
      }
      return;
    }

    // 2) Fall back to SVG <text>/<tspan> matching.
    const textEls = Array.from(
      classGroup.querySelectorAll<SVGTextElement | SVGTSpanElement>(
        "text, tspan",
      ),
    );
    const target = textEls.find(
      (t) => normalize(t.textContent ?? "") === want,
    );
    if (!target) return;

    try {
      const textBBox = target.getBBox();
      const padX = 4;
      const padY = 2;
      const ns = "http://www.w3.org/2000/svg";
      const parent = target.parentNode as SVGGElement | null;
      if (!parent) return;
      const rect = document.createElementNS(ns, "rect");
      rect.setAttribute("x", String(textBBox.x - padX));
      rect.setAttribute("y", String(textBBox.y - padY));
      rect.setAttribute("width", String(textBBox.width + padX * 2));
      rect.setAttribute("height", String(textBBox.height + padY * 2));
      rect.setAttribute("rx", "3");
      rect.setAttribute("ry", "3");
      rect.setAttribute("fill", style.fill);
      rect.setAttribute("pointer-events", "none");
      rect.setAttribute("class", "poc-member-highlight");
      parent.insertBefore(rect, target);
      target.setAttribute("fill", style.color);
      target.style.fontWeight = "700";
    } catch {
      /* getBBox can throw on detached nodes */
    }
  }

  function findInnermostMatch(
    elements: HTMLElement[],
    want: string,
  ): HTMLElement | null {
    // Find elements whose own text (excluding child element text) matches.
    const matches: HTMLElement[] = [];
    for (const el of elements) {
      // Concat only direct text node children
      let direct = "";
      el.childNodes.forEach((n) => {
        if (n.nodeType === Node.TEXT_NODE) direct += n.textContent ?? "";
      });
      if (normalize(direct) === want) {
        matches.push(el);
      }
    }
    if (matches.length > 0) return matches[matches.length - 1];

    // Fallback: any element whose full textContent matches AND has no child
    // element with the same match (i.e. is innermost).
    const allMatching = elements.filter(
      (el) => normalize(el.textContent ?? "") === want,
    );
    if (allMatching.length === 0) return null;
    return allMatching.reduce((best, cur) =>
      cur.contains(best) ? best : cur,
    );
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
        if (moved) ev.stopPropagation();
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
              Member-Highlights aus dem Mermaid-Code · Tippen markiert Klasse · Ziehen verschiebt
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
          <LegendDot color={MARKER_STYLE.changed.fill} label="geändert" />
          <LegendDot color={MARKER_STYLE.added.fill} label="hinzugefügt" />
          <LegendDot color={MARKER_STYLE.removed.fill} label="entfernt" />
          <LegendDot color="#bfdbfe" label="ausgewählte Klasse (Tap)" border />
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
            Mermaid-Quellcode (Marker als Kommentare)
          </summary>
          <p className="mt-2 text-xs text-slate-500">
            Konvention:{" "}
            <code className="rounded bg-slate-100 px-1 py-0.5">
              %% highlight: Klasse.MemberLabel = changed|added|removed
            </code>
          </p>
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
          stroke: #1d4ed8 !important;
          stroke-width: 3px !important;
        }
      `}</style>
    </div>
  );
}

function LegendDot({
  color,
  label,
  border,
}: {
  color: string;
  label: string;
  border?: boolean;
}) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span
        className="inline-block h-3 w-3 rounded-sm"
        style={{
          background: color,
          border: border ? "2px solid #1d4ed8" : "1px solid rgba(0,0,0,0.15)",
        }}
      />
      <span className="text-slate-700">{label}</span>
    </span>
  );
}

export default App;
