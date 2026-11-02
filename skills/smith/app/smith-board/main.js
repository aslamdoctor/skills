// Smith board: one row per task of a smith run, from <run>/run.json plus live agent status.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, props, theme, run, readTextFile, watchFolder } from "herdr";

// Lower sorts first.
const ORDER = { needs: 0, blocked: 1, working: 2, waiting: 3, done: 4 };
const WORD = { needs: "NEEDS YOU", blocked: "blocked", working: "working", waiting: "waiting", done: "done" };

function duration(ms) {
  const m = Math.floor(ms / 60000);
  if (!(m >= 1)) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// `live` is the matching agents() entry, if any. A task with no entry has ended or never reported.
function rowState(task, live) {
  if (task.needs_you === true || live?.status === "blocked") return "needs";
  if (!live) return "done";
  if (live.status === "working") return "working";
  return "waiting";
}

// Repo and date from a run dir named <repo>-<YYYY-MM-DD>-app.
function heading(path) {
  const base = path.replace(/\/+$/, "").split("/").pop();
  const m = base.match(/^(.*)-(\d{4}-\d{2}-\d{2})(?:-app)?$/);
  return m ? `Smith · ${m[1]} · ${m[2]}` : `Smith · ${base}`;
}

export default class Board extends View {
  init(_props, cx) {
    this.path = props()?.run ?? "";
    this.data = null;
    this.error = this.path ? null : "No run given";
    if (!this.path) return;
    this.load(cx);
    cx.spawn(async (cx) => {
      for (;;) {
        try { await watchFolder(this.path); } catch { return; }
        await this.load(cx);
      }
    });
    cx.timer.every(30000, (cx) => cx.notify());
  }

  async load(cx) {
    try {
      const text = await readTextFile(`${this.path}/run.json`);
      this.data = text == null ? null : JSON.parse(text);
      this.error = this.data?.tasks && typeof this.data.tasks === "object" ? null : `No run at ${this.path}`;
    } catch {
      this.data = null;
      this.error = `No run at ${this.path}`;
    }
    cx.notify();
  }

  render(_cx) {
    const t = theme();
    const shell = () => v_flex().size_full().min_h(0).bg(t.surface).text_color(t.foreground).text_size(13).p(16).gap(12);
    if (this.error) return shell().child(div().text_color(t.muted).child(this.error.startsWith("No run at") ? this.error : `No run at ${this.path}`));

    // Workers are hc children without a pane, so agents() may not list them: fall back to terminals().
    const live = new Map();
    for (const k of terminals()) if (k.state === "live") live.set(k.address, { status: k.status === "error" ? "blocked" : k.status ?? "idle" });
    for (const a of agents()) live.set(a.address, a);
    const now = Date.now();
    const rows = Object.values(this.data.tasks).map((task) => {
      const l = live.get(task.hc);
      return { task, l, s: rowState(task, l), at: Date.parse(String(task.updated ?? "").replace(/([+-]\d\d)(\d\d)$/, "$1:$2")) };
    });
    rows.sort((x, y) => ORDER[x.s] - ORDER[y.s] || (y.at || 0) - (x.at || 0));
    const needs = rows.filter((r) => r.s === "needs").length;
    const color = { needs: t.blocked, blocked: t.blocked, working: t.working, waiting: t.idle ?? t.dim, done: t.dim };
    const name = (r) => `Smith-${r.task.id}`;

    const top = h_flex()
      .flex_none()
      .items_center()
      .justify_between()
      .child(div().font_semibold().text_size(14).child(heading(this.path)))
      .child(div().text_color(t.muted).child(`${rows.length} worker${rows.length === 1 ? "" : "s"} · ${needs} needs you`));

    const row = (r) => h_flex()
      .id(`row-${r.task.id}`)
      .flex_none()
      .h(30)
      .px(8)
      .gap(12)
      .items_center()
      .rounded(8)
      .hover((el) => el.bg(t.hover))
      .child(div().size(8).flex_none().rounded(4).bg(color[r.s]))
      .child(div().w(90).flex_none().truncate().child(name(r)))
      .child(div().w(60).flex_none().truncate().text_color(t.muted).child(r.task.kind ?? ""))
      .child(div().w(86).flex_none().text_size(12).font_semibold().text_color(color[r.s]).child(WORD[r.s]))
      .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(r.task.gate_text ?? ""))
      .child(div().w(40).flex_none().text_right().text_size(12).text_color(t.dim).child(r.at ? duration(now - r.at) : ""))
      .child(div()
        .id(`open-${r.task.id}`)
        .flex_none()
        .px(6)
        .h(20)
        .rounded(5)
        .flex()
        .items_center()
        .text_size(12)
        .text_color(t.muted)
        .cursor_pointer()
        .hover((el) => el.bg(t.raised).text_color(t.foreground))
        .on_click(() => r.task.hc && run("agent.focus", { terminal: r.task.hc }))
        .child("[open]"));

    const info = (r) => h_flex()
      .flex_none()
      .px(8)
      .gap(12)
      .text_size(12)
      .text_color(t.muted)
      .child(div().w(40).flex_none().child(r.task.id))
      .child(div().w(240).flex_none().truncate().child(r.task.branch ?? ""))
      .child(div().w(50).flex_none().child(r.task.gate ?? ""))
      .child(div().flex_1().min_w(0).truncate().child(r.task.pr || r.task.ref || ""));

    return shell()
      .child(top)
      .child(div().h(1).flex_none().bg(t.border))
      .child(v_flex().id("rows").flex_none().gap(2).children(rows.map(row)))
      .child(div().h(1).flex_none().bg(t.border))
      .child(v_flex().id("info").flex_1().min_h(0).gap(4).overflow_y_scrollbar().children(rows.map(info)));
  }
}
