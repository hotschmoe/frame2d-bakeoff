//! The egui/eframe client (desktop and web): application state, toolbar and glue.

mod bench;
mod canvas;
mod io;
mod scene;
mod table;

pub use bench::{boundary_bench, mark_process_start};
pub use scene::{Derived, Scene};

use crate::model::{Model, Results};
use crate::{engine, generator};
use web_time::Instant;

#[derive(Clone, Copy)]
pub struct View {
    /// Pixels per metre.
    pub zoom: f32,
    /// World point shown at the canvas centre.
    pub center: [f64; 2],
}

pub struct Overlays {
    pub deformed: bool,
    pub moment: bool,
    pub color_by_m: bool,
    /// Multiple of the automatic deflection scale.
    pub def_mult: f32,
}

pub struct Frame2dApp {
    pub model: Model,
    pub scene: Scene,
    pub results: Option<Results>,
    pub derived: Derived,
    pub case_id: String,
    pub status: Status,
    pub overlays: Overlays,
    pub view: View,
    pub fit_zoom: f32,
    pub fit_pending: bool,
    pub selected_node: Option<usize>,
    pub drag_node: Option<usize>,
    pub gen_open: bool,
    pub gen_dims: (u32, u32),
    pub table: table::TableState,
    pub io: io::Io,
    pub bench: Option<bench::Bench>,
    /// Bumped whenever results or the model change; the table re-sorts on change.
    pub generation: u64,
    pub last_solve_ms: f64,
}

#[derive(Default)]
pub struct Status {
    pub error: Option<String>,
    pub info: String,
}

impl Frame2dApp {
    pub fn new(cc: &eframe::CreationContext<'_>, bench_mode: Option<String>) -> Self {
        cc.egui_ctx.set_visuals(eframe::egui::Visuals::light());
        let model = generator::generate(10, 10);
        let mut app = Frame2dApp {
            scene: Scene::build(&model),
            model,
            results: None,
            derived: Derived::default(),
            case_id: "D".into(),
            status: Status::default(),
            overlays: Overlays { deformed: true, moment: false, color_by_m: true, def_mult: 1.0 },
            view: View { zoom: 20.0, center: [30.0, 17.5] },
            fit_zoom: 20.0,
            fit_pending: true,
            selected_node: None,
            drag_node: None,
            gen_open: false,
            gen_dims: (10, 10),
            table: table::TableState::default(),
            io: io::Io::default(),
            bench: None,
            generation: 0,
            last_solve_ms: 0.0,
        };
        bench::setup(&mut app, bench_mode);
        if app.results.is_none() {
            app.solve_all();
        }
        app
    }

    pub fn set_model(&mut self, model: Model) {
        self.scene = Scene::build(&model);
        self.model = model;
        self.selected_node = None;
        self.drag_node = None;
        if !self.model.load_cases.iter().any(|c| c.id == self.case_id) {
            self.case_id = self.model.load_cases.first().map(|c| c.id.clone()).unwrap_or_default();
        }
        self.fit_pending = true;
        self.solve_all();
    }

    pub fn generate(&mut self, bays: u32, stories: u32) {
        self.set_model(generator::generate(bays as usize, stories as usize));
    }

    /// Solve every load case.
    pub fn solve_all(&mut self) {
        self.run_solve(None);
    }

    /// Re-solve only the selected load case (the interactive drag path).
    pub fn solve_current(&mut self) {
        let id = self.case_id.clone();
        self.run_solve(Some(&id));
    }

    fn run_solve(&mut self, only: Option<&str>) {
        let t = Instant::now();
        match engine::solve_filtered(&self.model, only) {
            Ok(r) => {
                self.status.error = None;
                self.status.info = format!(
                    "{} nodes, {} members, {} free dofs, profile {} -> {}",
                    r.stats.nodes, r.stats.members, r.stats.free_dofs, r.stats.profile_before, r.stats.profile_after
                );
                self.results = Some(r);
            }
            Err(e) => {
                self.status.error = Some(e.to_string());
                self.results = None;
            }
        }
        self.last_solve_ms = t.elapsed().as_secs_f64() * 1000.0;
        self.generation += 1;
        self.derive();
    }

    pub fn derive(&mut self) {
        self.derived = Derived::compute(&self.scene, self.results.as_ref(), &self.case_id);
    }

    pub fn select_case(&mut self, id: String) {
        self.case_id = id;
        let have = self.results.as_ref().is_some_and(|r| r.load_cases.iter().any(|c| c.id == self.case_id));
        if have {
            self.generation += 1;
            self.derive();
        } else {
            self.solve_all();
        }
    }

    fn toolbar(&mut self, ui: &mut eframe::egui::Ui) {
        ui.horizontal_wrapped(|ui| {
            if ui.button("Open").clicked() {
                self.io.open();
            }
            if ui.button("Save").clicked() {
                self.io.save(&self.model);
            }
            if ui.button("Generate...").clicked() {
                self.gen_open = true;
            }
            if ui.button("Solve").clicked() { // BENCH-EDIT:ui
                self.solve_all();
            }
            if ui.button("Fit").clicked() {
                self.fit_pending = true;
            }
            ui.separator();
            let mut chosen = None;
            eframe::egui::ComboBox::from_id_salt("case").selected_text(format!("Case {}", self.case_id)).show_ui(ui, |ui| {
                for c in &self.model.load_cases {
                    if ui.selectable_label(c.id == self.case_id, &c.id).clicked() {
                        chosen = Some(c.id.clone());
                    }
                }
            });
            if let Some(id) = chosen {
                self.select_case(id);
            }
            ui.checkbox(&mut self.overlays.deformed, "Deflected");
            ui.checkbox(&mut self.overlays.moment, "Moment");
            ui.checkbox(&mut self.overlays.color_by_m, "Color |M|");
            ui.add(eframe::egui::Slider::new(&mut self.overlays.def_mult, 0.0..=10.0).text("scale"));
        });
        ui.horizontal_wrapped(|ui| match &self.status.error {
            Some(e) => {
                ui.colored_label(eframe::egui::Color32::RED, format!("Error: {e}"));
            }
            None => {
                ui.label(format!("{}  |  solve {:.2} ms", self.status.info, self.last_solve_ms));
            }
        });
    }

    fn generate_window(&mut self, ctx: &eframe::egui::Context) {
        if !self.gen_open {
            return;
        }
        let mut open = true;
        let mut go = false;
        eframe::egui::Window::new("Generate frame").open(&mut open).collapsible(false).show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Bays");
                ui.add(eframe::egui::DragValue::new(&mut self.gen_dims.0).range(1..=400));
                ui.label("Stories");
                ui.add(eframe::egui::DragValue::new(&mut self.gen_dims.1).range(1..=400));
            });
            go = ui.button("Create").clicked();
        });
        if go {
            let (b, s) = self.gen_dims;
            self.generate(b, s);
            open = false;
        }
        self.gen_open = open;
    }
}

impl eframe::App for Frame2dApp {
    fn ui(&mut self, ui: &mut eframe::egui::Ui, _frame: &mut eframe::Frame) {
        use eframe::egui::{CentralPanel, Panel};
        let ctx = ui.ctx().clone();
        bench::before_frame(self, &ctx);
        if let Some(m) = self.io.poll() {
            match m {
                Ok(model) => self.set_model(model),
                Err(e) => self.status.error = Some(e),
            }
        }
        Panel::top("toolbar").show(ui, |ui| self.toolbar(ui));
        Panel::bottom("table").resizable(true).default_size(220.0).show(ui, |ui| table::show(self, ui));
        CentralPanel::default_margins().show(ui, |ui| canvas::show(self, ui));
        self.generate_window(&ctx);
        bench::after_frame(self, &ctx);
    }

    #[cfg(target_arch = "wasm32")]
    fn as_any_mut(&mut self) -> Option<&mut dyn std::any::Any> {
        Some(&mut *self)
    }
}
