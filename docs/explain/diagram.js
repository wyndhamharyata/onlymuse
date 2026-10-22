// Draws each <figure class="diagram"> from the JSON block inside it. See SKILL.md § 6.
(() => {
  const W = 160, H = 48, PAD = 20, NS = "http://www.w3.org/2000/svg";
  const root = document.body.dataset.root || "";

  const el = (name, attrs = {}, parent) => {
    const node = document.createElementNS(NS, name);
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
    if (parent) parent.appendChild(node);
    return node;
  };

  // The point where the line from a box's centre towards (tx, ty) leaves the box.
  const edgePoint = (n, tx, ty) => {
    const cx = n.x + W / 2, cy = n.y + H / 2, dx = tx - cx, dy = ty - cy;
    const scale = Math.min(Math.abs(W / 2 / dx) || Infinity, Math.abs(H / 2 / dy) || Infinity);
    return [cx + dx * scale, cy + dy * scale];
  };

  const sourceLink = (src) => {
    const a = document.createElement("a");
    a.className = "src";
    a.dataset.src = src;
    a.href = (root ? root + "/" : "") + src.split(":")[0];
    a.textContent = src;
    return a;
  };

  const draw = (figure) => {
    const data = JSON.parse(figure.querySelector("script").textContent);
    const byId = Object.fromEntries(data.nodes.map((n) => [n.id, n]));
    const width = Math.max(...data.nodes.map((n) => n.x)) + W + PAD;
    const height = Math.max(...data.nodes.map((n) => n.y)) + H + PAD;

    const svg = el("svg", { viewBox: `0 0 ${width} ${height}`, role: "img", style: `max-width: ${width}px` });
    const marker = el("marker", { id: "arrow", viewBox: "0 0 10 10", refX: 9, refY: 5,
      markerWidth: 7, markerHeight: 7, orient: "auto-start-reverse" }, el("defs", {}, svg));
    el("path", { d: "M0,0 L10,5 L0,10 z" }, marker);

    const edges = data.edges.map((e) => {
      const a = byId[e.from], b = byId[e.to];
      const [x1, y1] = edgePoint(a, b.x + W / 2, b.y + H / 2);
      const [x2, y2] = edgePoint(b, a.x + W / 2, a.y + H / 2);
      const g = el("g", { class: "edge" }, svg);
      el("line", { x1, y1, x2, y2, "marker-end": "url(#arrow)" }, g);
      if (e.label) el("text", { x: (x1 + x2) / 2, y: (y1 + y2) / 2 - 6 }, g).textContent = e.label;
      return g;
    });

    const info = document.createElement("div");
    info.className = "info";
    info.textContent = "Click a box to read what it does.";

    const show = (n) => {
      info.replaceChildren(Object.assign(document.createElement("strong"), { textContent: n.label }),
        document.createTextNode(" " + (n.info || "")));
      if (n.src) info.append(" ", sourceLink(n.src));
    };

    const nodes = Object.fromEntries(data.nodes.map((n) => {
      const g = el("g", { class: "node", tabindex: 0, role: "button" }, svg);
      el("rect", { x: n.x, y: n.y, width: W, height: H, rx: 8 }, g);
      el("text", { x: n.x + W / 2, y: n.y + H / 2 + 5 }, g).textContent = n.label;
      g.addEventListener("click", () => show(n));
      g.addEventListener("keydown", (event) => event.key === "Enter" && show(n));
      return [n.id, g];
    }));

    figure.append(svg);
    const steps = data.steps || [];
    if (steps.length === 0) return figure.append(info);

    const bar = document.createElement("div");
    bar.className = "steps";
    const button = (label) => bar.appendChild(Object.assign(document.createElement("button"), { textContent: label }));
    const back = button("Back"), play = button("Play"), next = button("Next");
    const count = bar.appendChild(document.createElement("span"));
    const caption = document.createElement("p");
    caption.className = "caption";
    figure.append(bar, caption, info);

    let current = 0, timer = null;
    const go = (index) => {
      current = (index + steps.length) % steps.length;
      const step = steps[current];
      for (const [id, g] of Object.entries(nodes)) g.classList.toggle("on", step.active.includes(id));
      edges.forEach((g, i) => g.classList.toggle("on", (step.edges || []).includes(i)));
      svg.classList.add("stepping");
      caption.textContent = step.text;
      count.textContent = `${current + 1} / ${steps.length}`;
    };
    const stop = () => { clearInterval(timer); timer = null; play.textContent = "Play"; };

    back.onclick = () => { stop(); go(current - 1); };
    next.onclick = () => { stop(); go(current + 1); };
    play.onclick = () => {
      if (timer) return stop();
      play.textContent = "Pause";
      timer = setInterval(() => go(current + 1), 2500);
    };
    figure.tabIndex = 0;
    figure.addEventListener("keydown", (event) => {
      if (event.key === "ArrowRight") next.onclick();
      if (event.key === "ArrowLeft") back.onclick();
    });
    go(0);
  };

  document.querySelectorAll("figure.diagram").forEach(draw);
})();
