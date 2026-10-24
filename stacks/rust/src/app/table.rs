//! Virtualized, sortable member table.

use super::Frame2dApp;
use eframe::egui::{self, Ui};
use egui_extras::{Column, TableBuilder};

const COLUMNS: [&str; 9] = ["id", "i", "j", "section", "L (m)", "N_i (N)", "V_i (N)", "M_i (N.m)", "max |M|"];
const ROW_HEIGHT: f32 = 18.0;

#[derive(Default)]
pub struct TableState {
    sort_col: usize,
    descending: bool,
    order: Vec<u32>,
    /// (sort_col, descending, app generation) the current `order` was built for.
    built_for: Option<(usize, bool, u64)>,
}

enum Cell<'a> {
    Int(i64),
    Num(f64),
    Text(&'a str),
}

fn cell<'a>(app: &'a Frame2dApp, col: usize, k: usize) -> Cell<'a> {
    let m = &app.model.members[app.scene.mem_slot[k]];
    let end = |idx: usize| {
        app.results
            .as_ref()
            .and_then(|r| app.derived.case_index.map(|ci| &r.load_cases[ci]))
            .and_then(|c| c.members.get(k))
            .map_or(f64::NAN, |mr| mr.end_forces[idx])
    };
    match col {
        0 => Cell::Int(m.id),
        1 => Cell::Int(m.i),
        2 => Cell::Int(m.j),
        3 => Cell::Text(&m.section),
        4 => Cell::Num(app.scene.member_len(k)),
        5 => Cell::Num(end(0)),
        6 => Cell::Num(end(1)),
        7 => Cell::Num(end(2)),
        _ => Cell::Num(app.derived.max_m.get(k).map_or(f64::NAN, |&v| v as f64)),
    }
}

fn compare(a: &Cell, b: &Cell) -> std::cmp::Ordering {
    match (a, b) {
        (Cell::Int(x), Cell::Int(y)) => x.cmp(y),
        (Cell::Num(x), Cell::Num(y)) => x.total_cmp(y),
        (Cell::Text(x), Cell::Text(y)) => x.cmp(y),
        _ => std::cmp::Ordering::Equal,
    }
}

fn resort(app: &mut Frame2dApp) {
    let key = (app.table.sort_col, app.table.descending, app.generation);
    let n = app.scene.ends.len();
    if app.table.built_for == Some(key) && app.table.order.len() == n {
        return;
    }
    let mut order: Vec<u32> = (0..n as u32).collect();
    let (col, desc) = (key.0, key.1);
    order.sort_by(|&a, &b| {
        let o = compare(&cell(app, col, a as usize), &cell(app, col, b as usize));
        if desc { o.reverse() } else { o }
    });
    app.table.order = order;
    app.table.built_for = Some(key);
}

pub fn show(app: &mut Frame2dApp, ui: &mut Ui) {
    resort(app);
    let n = app.table.order.len();
    let mut new_sort = None;
    let (sort_col, desc) = (app.table.sort_col, app.table.descending);
    ui.label(format!("Members: {n}"));
    let mut table = TableBuilder::new(ui).striped(true).resizable(true).max_scroll_height(f32::INFINITY);
    for _ in 0..COLUMNS.len() {
        table = table.column(Column::initial(90.0).at_least(40.0));
    }
    table
        .header(20.0, |mut header| {
            for (c, name) in COLUMNS.iter().enumerate() {
                header.col(|ui| {
                    let arrow = if c == sort_col { if desc { " v" } else { " ^" } } else { "" };
                    if ui.button(format!("{name}{arrow}")).clicked() {
                        new_sort = Some(c);
                    }
                });
            }
        })
        .body(|body| {
            body.rows(ROW_HEIGHT, n, |mut row| {
                let k = app.table.order[row.index()] as usize;
                for c in 0..COLUMNS.len() {
                    row.col(|ui| {
                        let text = match cell(app, c, k) {
                            Cell::Int(v) => v.to_string(),
                            Cell::Num(v) => format!("{v:.4e}"),
                            Cell::Text(t) => t.to_string(),
                        };
                        ui.add(egui::Label::new(text).truncate());
                    });
                }
            });
        });
    if let Some(c) = new_sort {
        if c == app.table.sort_col {
            app.table.descending = !app.table.descending;
        } else {
            app.table.sort_col = c;
            app.table.descending = false;
        }
    }
}
