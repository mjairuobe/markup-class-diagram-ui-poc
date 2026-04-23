import { useEffect, useRef, useState } from "react";
import mermaid from "mermaid";

// Marker werden direkt im Mermaid-Code als Kommentare gesetzt:
//   %% highlight: <Class>.<MemberLabel> = <markerName>
//   %% link: <Class>.<MemberLabel> = <https-URL>   (externe Links auf Klassen-Attribute/Methoden)
//   %% linkClass: <ClassName> = <https-URL>         (Link auf den Klassennamen im Kastenkopf)
//   %% classRename: <NewClassName> = <OldClassName>
//   %% classMarker: <Class> = <markerName>
//   %% relationMarker: <Label> = <markerName>
// Erlaubte Marker: changed | added | removed
const DIAGRAM = `classDiagram
  %% classMarker: User = added
  %% classMarker: Order = added
  %% classMarker: Payment = added
  %% relationMarker: gives = added
  %% relationMarker: sells = added
  %% relationMarker: pays = added
  %% highlight: Order.+submit() = added
  %% highlight: Payment.+amount = removed
  %% highlight: Product.+int objectNumber = removed
  %% highlight: Product.+String SKU = added
  %% highlight: Product.+list_products() = changed
  %% classRename: Product = StorageObject
  %% link: User.+String id = https://en.wikipedia.org/w/index.php?search=id
  %% link: User.+String name = https://en.wikipedia.org/w/index.php?search=name
  %% link: User.+login() = https://en.wikipedia.org/w/index.php?search=login
  %% link: User.+logout() = https://en.wikipedia.org/w/index.php?search=logout
  %% link: Order.+String id = https://en.wikipedia.org/w/index.php?search=id
  %% link: Order.+Date created = https://en.wikipedia.org/w/index.php?search=created
  %% link: Order.+submit() = https://en.wikipedia.org/w/index.php?search=submit
  %% link: Warehouse.+String id = https://en.wikipedia.org/w/index.php?search=id
  %% link: Warehouse.+String location = https://en.wikipedia.org/w/index.php?search=location
  %% link: Warehouse.+List~Product~ products = https://en.wikipedia.org/w/index.php?search=products
  %% link: Warehouse.+addProduct() = https://en.wikipedia.org/w/index.php?search=addProduct
  %% link: Product.+int objectNumber = https://en.wikipedia.org/w/index.php?search=objectNumber
  %% link: Product.+String SKU = https://en.wikipedia.org/w/index.php?search=SKU
  %% link: Product.+String title = https://en.wikipedia.org/w/index.php?search=title
  %% link: Product.+Float price = https://en.wikipedia.org/w/index.php?search=price
  %% link: Product.+list_products() = https://en.wikipedia.org/w/index.php?search=list_products
  %% link: Payment.+String id = https://en.wikipedia.org/w/index.php?search=id
  %% link: Payment.+Float amount = https://en.wikipedia.org/w/index.php?search=amount
  %% link: Payment.+process() = https://en.wikipedia.org/w/index.php?search=process
  %% linkClass: User = https://en.wikipedia.org/w/index.php?search=User
  %% linkClass: Order = https://en.wikipedia.org/w/index.php?search=Order
  %% linkClass: Warehouse = https://en.wikipedia.org/w/index.php?search=Warehouse
  %% linkClass: Product = https://en.wikipedia.org/w/index.php?search=Product
  %% linkClass: Payment = https://en.wikipedia.org/w/index.php?search=Payment

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
  class Warehouse {
    +String id
    +String location
    +List~Product~ products
    +addProduct()
  }
  class Product {
    +int objectNumber
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

  User "1" --> "*" Order : gives
  Order "*" --> "*" Product : sells
  Order "1" --> "1" Payment : pays
  Warehouse "1" --> "*" Product : stores

  click User call nodeClicked()
  click Order call nodeClicked()
  click Warehouse call nodeClicked()
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
type ClassRename = { className: string; oldName: string };
type RelationRename = { newLabel: string; oldLabel: string };
type ClassMarker = { className: string; marker: MemberMarker };
type RelationMarker = { label: string; marker: MemberMarker };
type MemberLink = { className: string; member: string; href: string };
type ClassNameLink = { className: string; href: string };

const CLASS_MARKER_STYLE: Record<MemberMarker, { fill: string; stroke: string }> = {
  changed: { fill: "#fef3c7", stroke: "#d97706" },
  added: { fill: "#dcfce7", stroke: "#16a34a" },
  removed: { fill: "#fee2e2", stroke: "#dc2626" },
};

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

function parseClassRenames(src: string): ClassRename[] {
  const out: ClassRename[] = [];
  const re = /%%\s*classRename:\s*([A-Za-z_][\w]*)\s*=\s*([A-Za-z_][\w]*)\s*$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    out.push({ className: m[1], oldName: m[2] });
  }
  return out;
}

function parseClassMarkers(src: string): ClassMarker[] {
  const out: ClassMarker[] = [];
  const re = /%%\s*classMarker:\s*([A-Za-z_][\w]*)\s*=\s*(changed|added|removed)\s*$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    out.push({ className: m[1], marker: m[2] as MemberMarker });
  }
  return out;
}

function parseRelationMarkers(src: string): RelationMarker[] {
  const out: RelationMarker[] = [];
  const re = /%%\s*relationMarker:\s*(.+?)\s*=\s*(changed|added|removed)\s*$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    out.push({ label: m[1].trim(), marker: m[2] as MemberMarker });
  }
  return out;
}

function parseRelationRenames(src: string): RelationRename[] {
  const out: RelationRename[] = [];
  const re = /%%\s*relationRename:\s*(.+?)\s*=\s*(.+?)\s*$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    out.push({ newLabel: m[1].trim(), oldLabel: m[2].trim() });
  }
  return out;
}

function parseMemberLinks(src: string): MemberLink[] {
  const out: MemberLink[] = [];
  const re =
    /%%\s*link:\s*([A-Za-z_][\w]*)\.(.+?)\s*=\s*(https?:\/\/\S+)\s*$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    out.push({
      className: m[1],
      member: m[2].trim(),
      href: m[3].trim(),
    });
  }
  return out;
}

function parseClassNameLinks(src: string): ClassNameLink[] {
  const out: ClassNameLink[] = [];
  const re =
    /%%\s*linkClass:\s*([A-Za-z_][\w]*)\s*=\s*(https?:\/\/\S+)\s*$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    out.push({ className: m[1], href: m[2].trim() });
  }
  return out;
}

function App() {
  const containerRef = useRef<HTMLDivElement>(null);
  const offsetsRef = useRef<Record<string, NodeOffset>>({});
  const [selected, setSelected] = useState<string | null>(null);
  const [renderKey, setRenderKey] = useState(0);
  const highlights = parseHighlights(DIAGRAM);
  const classRenames = parseClassRenames(DIAGRAM);
  const relationRenames = parseRelationRenames(DIAGRAM);
  const classMarkers = parseClassMarkers(DIAGRAM);
  const relationMarkers = parseRelationMarkers(DIAGRAM);
  const memberLinks = parseMemberLinks(DIAGRAM);
  const classNameLinks = parseClassNameLinks(DIAGRAM);

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
      applyClassMarkers();
      applyMemberHighlights();
      applyMemberLinks();
      applyClassRenames();
      applyClassTitleLinks();
      applyRelationMarkers();
      applyRelationRenames();
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

  /** Mermaid source uses ~T~, DOM often shows <T> for generics. */
  function memberSignatureKey(s: string): string {
    return normalize(s).replace(/~([^~]+)~/g, "<$1>");
  }

  function textMatchesMemberLabel(
    wantFromSource: string,
    domText: string,
  ): boolean {
    const w = normalize(wantFromSource);
    const d = normalize(domText);
    if (w === d) return true;
    return memberSignatureKey(wantFromSource) === memberSignatureKey(domText);
  }

  function highlightMemberInNode(classGroup: SVGGElement, h: Highlight) {
    const style = MARKER_STYLE[h.marker];
    const want = h.member;

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
    const target = textEls.find((t) =>
      textMatchesMemberLabel(h.member, t.textContent ?? ""),
    );
    if (!target) return;

    try {
      const textBBox = target.getBBox();
      const padX = 4;
      const padY = 2;
      const ns = "http://www.w3.org/2000/svg";
      const par = target.parentNode as SVGGElement | null;
      if (!par) return;
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
      par.insertBefore(rect, target);
      target.setAttribute("fill", style.color);
      target.style.fontWeight = "700";
    } catch {
      /* getBBox can throw on detached nodes */
    }
  }

  function applyMemberLinks() {
    if (!containerRef.current) return;
    if (memberLinks.length === 0) return;
    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );
    const byClass = new Map<string, MemberLink[]>();
    memberLinks.forEach((l) => {
      const arr = byClass.get(l.className) ?? [];
      arr.push(l);
      byClass.set(l.className, arr);
    });
    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;
      const list = byClass.get(id);
      if (!list || list.length === 0) return;
      list.forEach((l) => linkMemberInNode(node, l));
    });
  }

  function linkMemberInNode(classGroup: SVGGElement, l: MemberLink) {
    const htmlCandidates = classGroup.querySelectorAll<HTMLElement>(
      "foreignObject *",
    );
    const htmlMatch = findInnermostMatch(
      Array.from(htmlCandidates),
      l.member,
    );
    if (htmlMatch) {
      if (htmlMatch.closest("a.poc-member-link")) return;
      const a = document.createElement("a");
      a.href = l.href;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.className = "poc-member-link";
      a.title = l.href;
      a.style.cursor = "pointer";
      a.style.textDecoration = "underline";
      a.style.textUnderlineOffset = "2px";
      a.style.color = "inherit";
      const parent = htmlMatch.parentNode;
      if (!parent) return;
      parent.insertBefore(a, htmlMatch);
      a.appendChild(htmlMatch);
      a.addEventListener("click", (e) => e.stopPropagation(), true);
      a.addEventListener("pointerdown", (e) => e.stopPropagation(), true);
      return;
    }

    const textEls = Array.from(
      classGroup.querySelectorAll<SVGTextElement | SVGTSpanElement>(
        "text, tspan",
      ),
    );
    const target = textEls.find((t) =>
      textMatchesMemberLabel(l.member, t.textContent ?? ""),
    );
    if (!target) return;
    const linkParent = target.parentNode as SVGGElement | null;
    if (!linkParent) return;
    const ns = "http://www.w3.org/2000/svg";
    const a = document.createElementNS(ns, "a");
    a.setAttribute("href", l.href);
    a.setAttribute("target", "_blank");
    a.setAttribute("rel", "noopener noreferrer");
    a.setAttribute("class", "poc-member-link");
    a.style.cursor = "pointer";
    linkParent.insertBefore(a, target);
    a.appendChild(target);
    a.addEventListener("click", (e) => e.stopPropagation(), true);
    a.addEventListener("pointerdown", (e) => e.stopPropagation(), true);
  }

  function findClassTitleInner(
    node: SVGGElement,
    className: string,
  ): HTMLElement | null {
    const fos = Array.from(
      node.querySelectorAll<SVGForeignObjectElement>("foreignObject"),
    );
    let bestFo: SVGForeignObjectElement | null = null;
    let topY = Infinity;
    for (const fo of fos) {
      if ((fo.textContent ?? "").trim() !== className) continue;
      const parent = fo.parentElement;
      const tr = parent?.getAttribute("transform") || "";
      const tm = tr.match(/translate\(([-\d.]+)\s*,\s*([-\d.]+)\)/);
      const y = tm ? parseFloat(tm[2]) : 0;
      if (y < topY) {
        topY = y;
        bestFo = fo;
      }
    }
    if (!bestFo) return null;
    return bestFo.querySelector<HTMLElement>("p, span, div");
  }

  function applyClassTitleLinks() {
    if (!containerRef.current) return;
    if (classNameLinks.length === 0) return;
    const byHref = new Map(classNameLinks.map((c) => [c.className, c]));
    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );
    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;
      const cl = byHref.get(id);
      if (!cl) return;
      const titleEl = findClassTitleInner(node, id);
      if (!titleEl) return;
      if (titleEl.closest("a.poc-classname-link")) return;
      const a = document.createElement("a");
      a.href = cl.href;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.className = "poc-classname-link poc-member-link";
      a.title = cl.href;
      a.style.cursor = "pointer";
      a.style.textDecoration = "underline";
      a.style.textUnderlineOffset = "2px";
      a.style.color = "inherit";
      const parent = titleEl.parentNode;
      if (!parent) return;
      parent.insertBefore(a, titleEl);
      a.appendChild(titleEl);
      a.addEventListener("click", (e) => e.stopPropagation(), true);
      a.addEventListener("pointerdown", (e) => e.stopPropagation(), true);
    });
  }

  function applyClassRenames() {
    if (!containerRef.current) return;
    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );
    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;
      const r = classRenames.find((x) => x.className === id);
      if (!r) return;

      // Find the title foreignObject (topmost FO whose direct text equals the
      // class id). The members of the class are usually inside other FOs.
      const fos = Array.from(
        node.querySelectorAll<SVGForeignObjectElement>("foreignObject"),
      );
      let titleFo: SVGForeignObjectElement | null = null;
      let topY = Infinity;
      for (const fo of fos) {
        const txt = (fo.textContent ?? "").trim();
        if (txt !== id) continue;
        const parent = fo.parentElement;
        const tr = parent?.getAttribute("transform") || "";
        const tm = tr.match(/translate\(([-\d.]+)\s*,\s*([-\d.]+)\)/);
        const y = tm ? parseFloat(tm[2]) : 0;
        if (y < topY) {
          topY = y;
          titleFo = fo;
        }
      }
      if (!titleFo) return;

      // 1) Style the new class name as "added" (green). Keep block layout so
      // the bg fills the row and the text isn't clipped by the fixed FO width.
      const addedStyle = MARKER_STYLE.added;
      const titleText = titleFo.querySelector<HTMLElement>("p, span, div");
      if (titleText) {
        titleText.style.background = addedStyle.fill;
        titleText.style.color = addedStyle.color;
        titleText.style.borderRadius = "3px";
        titleText.style.margin = "0";
      }

      // 2) Insert a "removed" badge with the old class name above the box.
      // We position it relative to the class group's bounding box.
      let bbox: DOMRect | null = null;
      try {
        bbox = (node as unknown as SVGGraphicsElement).getBBox() as DOMRect;
      } catch {
        bbox = null;
      }
      if (!bbox) return;

      const ns = "http://www.w3.org/2000/svg";
      const xhtml = "http://www.w3.org/1999/xhtml";
      const badgeH = 22;
      const badgeFo = document.createElementNS(ns, "foreignObject");
      badgeFo.setAttribute("x", String(bbox.x));
      badgeFo.setAttribute("y", String(bbox.y - badgeH - 4));
      badgeFo.setAttribute("width", String(bbox.width));
      badgeFo.setAttribute("height", String(badgeH));
      badgeFo.setAttribute("class", "poc-class-rename-badge");
      badgeFo.setAttribute("pointer-events", "none");

      const removedStyle = MARKER_STYLE.removed;
      const wrap = document.createElementNS(xhtml, "div") as HTMLDivElement;
      wrap.setAttribute("xmlns", xhtml);
      wrap.style.width = "100%";
      wrap.style.height = "100%";
      wrap.style.display = "flex";
      wrap.style.alignItems = "center";
      wrap.style.justifyContent = "center";

      const tag = document.createElementNS(xhtml, "span") as HTMLSpanElement;
      tag.textContent = r.oldName;
      tag.style.background = removedStyle.fill;
      tag.style.color = removedStyle.color;
      tag.style.fontWeight = "700";
      tag.style.fontSize = "13px";
      tag.style.textDecoration = "line-through";
      tag.style.padding = "1px 8px";
      tag.style.borderRadius = "4px";
      tag.style.fontFamily = "inherit";

      wrap.appendChild(tag);
      badgeFo.appendChild(wrap);
      node.appendChild(badgeFo);
    });
  }

  function applyClassMarkers() {
    if (!containerRef.current) return;
    if (classMarkers.length === 0) return;
    const nodes = containerRef.current.querySelectorAll<SVGGElement>(
      "g.node, g.classGroup",
    );
    nodes.forEach((node) => {
      const id = nodeId(node);
      if (!id) return;
      const cm = classMarkers.find((x) => x.className === id);
      if (!cm) return;
      const style = CLASS_MARKER_STYLE[cm.marker];
      // Tint all section rects with the marker fill so the whole class is
      // visibly colored (green for added, red for removed, yellow for changed).
      node.querySelectorAll<SVGRectElement | SVGPathElement>(
        "rect, path",
      ).forEach((el) => {
        el.style.setProperty("fill", style.fill, "important");
      });
      // For added/removed classes: draw a separate thick dashed outer border
      // around the whole class group via getBBox. Other markers keep default.
      if (cm.marker === "added" || cm.marker === "removed") {
        try {
          const bbox = (node as unknown as SVGGraphicsElement).getBBox();
          const pad = 6;
          const ns = "http://www.w3.org/2000/svg";
          const border = document.createElementNS(ns, "rect");
          border.setAttribute("x", String(bbox.x - pad));
          border.setAttribute("y", String(bbox.y - pad));
          border.setAttribute("width", String(bbox.width + pad * 2));
          border.setAttribute("height", String(bbox.height + pad * 2));
          border.setAttribute("rx", "6");
          border.setAttribute("ry", "6");
          border.setAttribute("fill", "none");
          border.setAttribute("pointer-events", "none");
          border.style.setProperty("stroke", style.stroke, "important");
          border.style.setProperty("stroke-width", "6px", "important");
          border.style.setProperty("stroke-dasharray", "12 7", "important");
          border.setAttribute("class", "poc-class-border");
          // Insert as first child so original mermaid content renders ON TOP.
          if (node.firstChild) {
            node.insertBefore(border, node.firstChild);
          } else {
            node.appendChild(border);
          }
        } catch {
          /* getBBox can throw on detached nodes */
        }
      }
      node.classList.add("poc-class-marker", `poc-class-marker--${cm.marker}`);
    });
  }

  function applyRelationMarkers() {
    if (!containerRef.current) return;
    if (relationMarkers.length === 0) return;
    const fos = Array.from(
      containerRef.current.querySelectorAll<SVGForeignObjectElement>(
        "foreignObject",
      ),
    );
    relationMarkers.forEach((rm) => {
      const target = fos.find((fo) => {
        if (fo.closest("g.classGroup, g.node")) return false;
        return (fo.textContent ?? "").trim() === rm.label;
      });
      if (!target) return;
      const inner = target.querySelector<HTMLElement>("p, span, div");
      if (!inner) return;
      const style = MARKER_STYLE[rm.marker];
      inner.style.background = style.fill;
      inner.style.color = style.color;
      inner.style.fontWeight = "700";
      inner.style.borderRadius = "3px";
      inner.style.padding = "0 4px";
      inner.style.margin = "0";
      if (rm.marker === "removed") inner.style.textDecoration = "line-through";
    });
  }

  function applyRelationRenames() {
    if (!containerRef.current) return;
    if (relationRenames.length === 0) return;

    const fos = Array.from(
      containerRef.current.querySelectorAll<SVGForeignObjectElement>(
        "foreignObject",
      ),
    );

    relationRenames.forEach((r) => {
      // Find an edge label foreignObject whose direct text equals the new
      // label and which is NOT inside a class node.
      const target = fos.find((fo) => {
        if (fo.closest("g.classGroup, g.node")) return false;
        return (fo.textContent ?? "").trim() === r.newLabel;
      });
      if (!target) return;

      const inner = target.querySelector<HTMLElement>("p, span, div");
      if (!inner) return;

      const removed = MARKER_STYLE.removed;
      const added = MARKER_STYLE.added;

      const oldEl = document.createElement("span");
      oldEl.textContent = r.oldLabel;
      oldEl.style.background = removed.fill;
      oldEl.style.color = removed.color;
      oldEl.style.textDecoration = "line-through";
      oldEl.style.fontWeight = "700";
      oldEl.style.borderRadius = "3px";
      oldEl.style.padding = "0 4px";
      oldEl.style.display = "block";
      oldEl.style.marginBottom = "2px";

      const newEl = document.createElement("span");
      newEl.textContent = r.newLabel;
      newEl.style.background = added.fill;
      newEl.style.color = added.color;
      newEl.style.fontWeight = "700";
      newEl.style.borderRadius = "3px";
      newEl.style.padding = "0 4px";
      newEl.style.display = "block";

      inner.innerHTML = "";
      inner.style.background = "transparent";
      inner.style.padding = "0";
      inner.style.margin = "0";
      inner.style.textAlign = "center";
      inner.appendChild(oldEl);
      inner.appendChild(newEl);

      // Expand the FO to fit two stacked rows + the longer of both labels.
      const charW = 7.5;
      const longer = Math.max(r.oldLabel.length, r.newLabel.length);
      const wantW = Math.ceil(longer * charW + 16);
      const curW = parseFloat(target.getAttribute("width") || "0");
      const newW = Math.max(curW, wantW);
      const dW = newW - curW;
      target.setAttribute("width", String(newW));

      const curH = parseFloat(target.getAttribute("height") || "0");
      const newH = curH + 18;
      const dH = newH - curH;
      target.setAttribute("height", String(newH));

      // Recenter the FO on its original anchor: shift x left by dW/2 and y
      // up by dH/2 so the two-line label stays centered on the edge.
      const curX = parseFloat(target.getAttribute("x") || "0");
      const curY = parseFloat(target.getAttribute("y") || "0");
      target.setAttribute("x", String(curX - dW / 2));
      target.setAttribute("y", String(curY - dH / 2));
    });
  }

  function findInnermostMatch(
    elements: HTMLElement[],
    memberLabelFromSource: string,
  ): HTMLElement | null {
    // Find elements whose own text (excluding child element text) matches.
    const matches: HTMLElement[] = [];
    for (const el of elements) {
      // Concat only direct text node children
      let direct = "";
      el.childNodes.forEach((n) => {
        if (n.nodeType === Node.TEXT_NODE) direct += n.textContent ?? "";
      });
      if (textMatchesMemberLabel(memberLabelFromSource, direct)) {
        matches.push(el);
      }
    }
    if (matches.length > 0) return matches[matches.length - 1];

    // Fallback: any element whose full textContent matches AND has no child
    // element with the same match (i.e. is innermost).
    const allMatching = elements.filter((el) =>
      textMatchesMemberLabel(
        memberLabelFromSource,
        el.textContent ?? "",
      ),
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
            <br />
            <span className="mt-1 inline-block">
              <code className="rounded bg-slate-100 px-1 py-0.5">
                %% link: Klasse.MemberLabel = https://…
              </code>{" "}
              (öffnet in neuem Tab; Klick stoppt Drag/Selektion)
            </span>
            <br />
            <span className="mt-1 inline-block">
              <code className="rounded bg-slate-100 px-1 py-0.5">
                %% linkClass: Klassenname = https://…
              </code>{" "}
              (Link auf den Titel im Klassenrahmen; bei <code>~Typ~</code> in
              Member-Labels vergleicht der PoC generisch mit der Darstellung
              <code> &lt;Typ&gt; </code> im SVG)
            </span>
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
