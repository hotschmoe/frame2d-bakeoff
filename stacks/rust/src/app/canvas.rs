//! The structure canvas: pan/zoom, node dragging, and the member / support / overlay drawing.

use super::{Frame2dApp, View};
use crate::model::CaseResult;
use eframe::egui::{self, Color32, Mesh, Pos2, Rect, Sense, Shape, Stroke, Ui};

/// Moment diagrams are drawn only for members at least this long on screen (pixels).
const MOMENT_MIN_PX: f32 = 14.0;
/// Deflected curves use a smooth Hermite curve above this screen length, a straight chord below.
const CURVE_MIN_PX: f32 = 10.0;
const NODE_PICK_PX: f32 = 12.0;

struct Xf {
    center: Pos2,
    zoom: f32,
    origin: [f64; 2],
}

impl Xf {
    fn new(rect: Rect, view: &View) -> Xf {
        Xf { center: rect.center(), zoom: view.zoom, origin: view.center }
    }
    #[inline]
    fn to_screen(&self, p: [f64; 2]) -> Pos2 {
        Pos2::new(
            self.center.x + ((p[0] - self.origin[0]) * self.zoom as f64) as f32,
            self.center.y - ((p[1] - self.origin[1]) * self.zoom as f64) as f32,
        )
    }
    fn to_world(&self, s: Pos2) -> [f64; 2] {
        [
            self.origin[0] + (s.x - self.center.x) as f64 / self.zoom as f64,
            self.origin[1] - (s.y - self.center.y) as f64 / self.zoom as f64,
        ]
    }
}

/// Many same-width line segments drawn as solid quads in a few big meshes. egui's `line_segment` runs
/// the full anti-aliased path stroker per call, which dominates frame time with ~100k members;
/// a quad is a handful of vertex writes. Flushes every `CHUNK` segments to keep meshes small.
struct Segments<'a> {
    painter: &'a egui::Painter,
    mesh: Mesh,
    half_width: f32,
    count: usize,
}

impl<'a> Segments<'a> {
    const CHUNK: usize = 8192;

    fn new(painter: &'a egui::Painter, width: f32) -> Self {
        Segments { painter, mesh: Mesh::default(), half_width: width * 0.5, count: 0 }
    }

    #[inline]
    fn push(&mut self, a: Pos2, b: Pos2, color: Color32) {
        let d = b - a;
        let len = d.length();
        // Perpendicular offset of half the width; degenerate segments get a horizontal one.
        let n = if len > 1e-6 { egui::vec2(-d.y, d.x) * (self.half_width / len) } else { egui::vec2(0.0, self.half_width) };
        let base = self.mesh.vertices.len() as u32;
        let uv = egui::epaint::WHITE_UV;
        for p in [a + n, a - n, b - n, b + n] {
            self.mesh.vertices.push(egui::epaint::Vertex { pos: p, uv, color });
        }
        self.mesh.indices.extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
        self.count += 1;
        if self.count == Self::CHUNK {
            self.flush();
        }
    }

    fn flush(&mut self) {
        if self.count > 0 {
            self.painter.add(Shape::mesh(std::mem::take(&mut self.mesh)));
            self.count = 0;
        }
    }
}

/// Blue (low) through green and yellow to red (high).
fn heat(t: f32) -> Color32 {
    let t = t.clamp(0.0, 1.0);
    let (r, g, b) = if t < 0.5 {
        let u = t * 2.0;
        (0.0, 0.35 + 0.5 * u, 0.9 * (1.0 - u))
    } else {
        let u = (t - 0.5) * 2.0;
        (0.9 * u + 0.1, 0.85 * (1.0 - u) + 0.05, 0.0)
    };
    Color32::from_rgb((r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8)
}

pub fn show(app: &mut Frame2dApp, ui: &mut Ui) {
    let (resp, painter) = ui.allocate_painter(ui.available_size(), Sense::click_and_drag());
    let rect = resp.rect;

    // Fit zoom for the current rect (also used by the render bench).
    let size = app.scene.size();
    app.fit_zoom = ((rect.width().min(rect.height()) as f64 * 0.9) / size) as f32;
    if app.fit_pending && rect.width() > 10.0 {
        app.view = View {
            zoom: app.fit_zoom,
            center: [(app.scene.min[0] + app.scene.max[0]) / 2.0, (app.scene.min[1] + app.scene.max[1]) / 2.0],
        };
        app.fit_pending = false;
    }

    interact(app, ui, &resp, rect);

    painter.rect_filled(rect, 0.0, Color32::from_gray(250));
    draw_scene(app, &painter, rect);
}

fn interact(app: &mut Frame2dApp, ui: &Ui, resp: &egui::Response, rect: Rect) {
    let xf = Xf::new(rect, &app.view);

    // Zoom about the cursor (wheel, trackpad pinch, ctrl-scroll).
    if resp.hovered() {
        let (pinch, scroll) = ui.input(|i| (i.zoom_delta(), i.smooth_scroll_delta.y));
        let factor = pinch * (scroll * 0.002).exp();
        if (factor - 1.0).abs() > 1e-6 {
            if let Some(cursor) = resp.hover_pos() {
                let w = xf.to_world(cursor);
                let zoom = (app.view.zoom * factor).clamp(1e-3, 1e5);
                app.view.zoom = zoom;
                app.view.center = [
                    w[0] - (cursor.x - rect.center().x) as f64 / zoom as f64,
                    w[1] + (cursor.y - rect.center().y) as f64 / zoom as f64,
                ];
            }
        }
    }

    // Press on a node starts a node drag; otherwise the drag pans the view.
    if resp.drag_started() {
        if let Some(p) = resp.interact_pointer_pos() {
            app.drag_node = nearest_node(app, &xf, p);
            if app.drag_node.is_some() {
                app.selected_node = app.drag_node;
            }
        }
    }
    if resp.dragged() {
        match app.drag_node {
            Some(k) => {
                if let Some(p) = resp.interact_pointer_pos() {
                    let w = xf.to_world(p);
                    move_node(app, k, w);
                }
            }
            None => {
                let d = resp.drag_delta();
                app.view.center[0] -= d.x as f64 / app.view.zoom as f64;
                app.view.center[1] += d.y as f64 / app.view.zoom as f64;
            }
        }
    }
    if resp.drag_stopped() {
        app.drag_node = None;
    }
    if resp.clicked() {
        if let Some(p) = resp.interact_pointer_pos() {
            app.selected_node = nearest_node(app, &xf, p);
        }
    }
}

fn nearest_node(app: &Frame2dApp, xf: &Xf, p: Pos2) -> Option<usize> {
    let mut best = (NODE_PICK_PX * NODE_PICK_PX, None);
    for (k, &q) in app.scene.pos.iter().enumerate() {
        let s = xf.to_screen(q);
        let d = (s.x - p.x).powi(2) + (s.y - p.y).powi(2);
        if d < best.0 {
            best = (d, Some(k));
        }
    }
    best.1
}

/// Move scene node `k` to world position `w`, update the model and re-solve the current case.
pub fn move_node(app: &mut Frame2dApp, k: usize, w: [f64; 2]) {
    app.scene.pos[k] = w;
    let slot = app.scene.node_slot[k];
    app.model.nodes[slot].x = w[0];
    app.model.nodes[slot].y = w[1];
    app.solve_current();
}

fn draw_scene(app: &Frame2dApp, painter: &egui::Painter, rect: Rect) {
    let xf = Xf::new(rect, &app.view);
    let cull = rect.expand(30.0);
    let scene = &app.scene;
    let zoom = app.view.zoom;
    let case: Option<&CaseResult> = app
        .results
        .as_ref()
        .and_then(|r| app.derived.case_index.and_then(|ci| r.load_cases.get(ci)));
    let gmax = app.derived.global_max_m.max(1e-9) as f32;
    let width = if zoom < 3.0 { 1.0 } else { 2.0 };

    // Members, colored by max |M|.
    let color_by_m = app.overlays.color_by_m && case.is_some();
    let mut segs = Segments::new(painter, width);
    for (k, &(a, b)) in scene.ends.iter().enumerate() {
        let (sa, sb) = (xf.to_screen(scene.pos[a as usize]), xf.to_screen(scene.pos[b as usize]));
        if !cull.intersects(Rect::from_two_pos(sa, sb)) {
            continue;
        }
        let color = if color_by_m { heat(app.derived.max_m[k] / gmax) } else { Color32::from_gray(90) };
        segs.push(sa, sb, color);
    }
    segs.flush();

    // Supports and node markers.
    for &(n, flags) in &scene.supports {
        let s = xf.to_screen(scene.pos[n as usize]);
        if !cull.contains(s) {
            continue;
        }
        let r = 6.0;
        let col = Color32::from_rgb(40, 120, 40);
        if flags[0] || flags[1] {
            painter.add(Shape::convex_polygon(
                vec![s, Pos2::new(s.x - r, s.y + 1.6 * r), Pos2::new(s.x + r, s.y + 1.6 * r)],
                col.gamma_multiply(0.5),
                Stroke::new(1.0, col),
            ));
        }
        if flags[2] {
            painter.rect_stroke(Rect::from_center_size(s, egui::vec2(2.0 * r, 2.0 * r)), 0.0, Stroke::new(1.0, col), egui::StrokeKind::Middle);
        }
    }
    if zoom >= 4.0 {
        for &p in &scene.pos {
            let s = xf.to_screen(p);
            if cull.contains(s) {
                painter.circle_filled(s, 2.0, Color32::from_gray(40));
            }
        }
    }
    if let Some(k) = app.selected_node.filter(|&k| k < scene.pos.len()) {
        let s = xf.to_screen(scene.pos[k]);
        painter.circle_stroke(s, 7.0, Stroke::new(2.0, Color32::from_rgb(20, 90, 220)));
        painter.text(
            s + egui::vec2(10.0, -10.0),
            egui::Align2::LEFT_BOTTOM,
            format!("node {}", scene.node_ids[k]),
            egui::FontId::proportional(12.0),
            Color32::from_rgb(20, 90, 220),
        );
    }

    let Some(case) = case else { return };

    if app.overlays.moment && app.derived.global_max_m > 0.0 {
        draw_moments(app, painter, &xf, cull, case);
    }
    if app.overlays.deformed && app.derived.max_disp > 0.0 {
        draw_deflected(app, painter, &xf, cull, case);
    }
}

fn draw_moments(app: &Frame2dApp, painter: &egui::Painter, xf: &Xf, cull: Rect, case: &CaseResult) {
    let scene = &app.scene;
    // Largest moment is drawn as 1.5 m of offset, so the diagram scales with the view.
    let mscale = 1.5 / app.derived.global_max_m;
    let stroke = Stroke::new(1.2, Color32::from_rgb(170, 40, 160));
    for (k, &(a, b)) in scene.ends.iter().enumerate() {
        let (pa, pb) = (scene.pos[a as usize], scene.pos[b as usize]);
        let (sa, sb) = (xf.to_screen(pa), xf.to_screen(pb));
        if (sb - sa).length() < MOMENT_MIN_PX || !cull.intersects(Rect::from_two_pos(sa, sb)) {
            continue;
        }
        let len = scene.member_len(k);
        let (c, s) = ((pb[0] - pa[0]) / len, (pb[1] - pa[1]) / len);
        let st = &case.members[k].stations;
        let pts: Vec<Pos2> = st
            .iter()
            .map(|q| {
                // Plotted on the tension side: opposite to local +y for sagging (positive) moments.
                let off = -q.m * mscale;
                xf.to_screen([pa[0] + c * q.x - s * off, pa[1] + s * q.x + c * off])
            })
            .collect();
        painter.add(Shape::line(pts.clone(), stroke));
        painter.line_segment([sa, pts[0]], Stroke::new(0.8, stroke.color.gamma_multiply(0.5)));
        painter.line_segment([sb, pts[pts.len() - 1]], Stroke::new(0.8, stroke.color.gamma_multiply(0.5)));
    }
}

fn draw_deflected(app: &Frame2dApp, painter: &egui::Painter, xf: &Xf, cull: Rect, case: &CaseResult) {
    let scene = &app.scene;
    let auto = 0.05 * scene.size() / app.derived.max_disp;
    let scale = auto * app.overlays.def_mult as f64;
    let stroke = Stroke::new(1.6, Color32::from_rgb(230, 110, 20));
    let mut chords = Segments::new(painter, stroke.width);
    for &(a, b) in scene.ends.iter() {
        let (pa, pb) = (scene.pos[a as usize], scene.pos[b as usize]);
        let (da, db) = (&case.displacements[a as usize], &case.displacements[b as usize]);
        let qa = [pa[0] + da.ux * scale, pa[1] + da.uy * scale];
        let qb = [pb[0] + db.ux * scale, pb[1] + db.uy * scale];
        let (sa, sb) = (xf.to_screen(qa), xf.to_screen(qb));
        if !cull.intersects(Rect::from_two_pos(sa, sb)) {
            continue;
        }
        if (sb - sa).length() < CURVE_MIN_PX {
            chords.push(sa, sb, stroke.color);
            continue;
        }
        // Hermite transverse shape plus linear axial, in member axes, scaled and rotated back.
        let len = ((pb[0] - pa[0]).powi(2) + (pb[1] - pa[1]).powi(2)).sqrt();
        let (c, s) = ((pb[0] - pa[0]) / len, (pb[1] - pa[1]) / len);
        let (u1, v1, t1) = (c * da.ux + s * da.uy, -s * da.ux + c * da.uy, da.rz);
        let (u2, v2, t2) = (c * db.ux + s * db.uy, -s * db.ux + c * db.uy, db.rz);
        let n = 8;
        let pts: Vec<Pos2> = (0..=n)
            .map(|i| {
                let x = i as f64 / n as f64;
                let u = u1 * (1.0 - x) + u2 * x;
                let v = v1 * (1.0 - 3.0 * x * x + 2.0 * x.powi(3))
                    + t1 * len * (x - 2.0 * x * x + x.powi(3))
                    + v2 * (3.0 * x * x - 2.0 * x.powi(3))
                    + t2 * len * (-x * x + x.powi(3));
                let (lx, ly) = (x * len + u * scale, v * scale);
                xf.to_screen([pa[0] + c * lx - s * ly, pa[1] + s * lx + c * ly])
            })
            .collect();
        painter.add(Shape::line(pts, stroke));
    }
    chords.flush();
}
