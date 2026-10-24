//! wasm-bindgen front end: the same session API as `api`, with array results as typed arrays.

use wasm_bindgen::prelude::*;

use crate::api;

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = performance)]
    fn now() -> f64;
}

#[wasm_bindgen(start)]
fn start() {
    frame2d_engine::clock::set_clock(now);
}

/// Declares a JS-visible class with one getter per field of an `api` struct.
macro_rules! js_view {
    ($name:ident wraps $src:ty { $($field:ident : $ty:ty),* $(,)? }) => {
        #[wasm_bindgen]
        pub struct $name {
            inner: $src,
        }

        #[wasm_bindgen]
        impl $name {
            $(
                #[wasm_bindgen(getter)]
                pub fn $field(&self) -> $ty {
                    self.inner.$field.clone()
                }
            )*
        }
    };
}

js_view!(ModelView wraps api::ModelView {
    node_ids: Vec<i32>,
    node_xy: Vec<f64>,
    node_support: Vec<u8>,
    member_ids: Vec<i32>,
    member_nodes: Vec<u32>,
    member_length: Vec<f64>,
    member_material: Vec<u32>,
    member_section: Vec<u32>,
    material_names: Vec<String>,
    section_names: Vec<String>,
    case_ids: Vec<String>,
    nodal_load_ix: Vec<u32>,
    nodal_load_f: Vec<f64>,
    udl_ix: Vec<u32>,
    udl_w: Vec<f64>,
});

js_view!(SolveView wraps api::SolveView {
    case_index: u32,
    disp: Vec<f64>,
    end_forces: Vec<f64>,
    stations_m: Vec<f64>,
    member_max_abs_m: Vec<f64>,
    member_max_abs_v: Vec<f64>,
    member_axial: Vec<f64>,
    member_length: Vec<f64>,
    reactions: Vec<f64>,
    equilibrium_residual: f64,
    assemble_ms: f64,
    factor_ms: f64,
    solve_ms: f64,
    free_dofs: u32,
    profile_before: u32,
    profile_after: u32,
});

#[wasm_bindgen]
pub fn engine_load(json: String) -> Result<ModelView, String> {
    api::engine_load(json).map(|inner| ModelView { inner })
}

#[wasm_bindgen]
pub fn engine_generate(bays: u32, stories: u32) -> Result<ModelView, String> {
    api::engine_generate(bays, stories).map(|inner| ModelView { inner })
}

#[wasm_bindgen]
pub fn engine_export() -> Result<String, String> {
    api::engine_export()
}

#[wasm_bindgen]
pub fn engine_solve(case_index: u32) -> Result<SolveView, String> {
    api::engine_solve(case_index).map(|inner| SolveView { inner })
}

#[wasm_bindgen]
pub fn engine_move_and_solve(node_pos: u32, x: f64, y: f64, case_index: u32) -> Result<SolveView, String> {
    api::engine_move_and_solve(node_pos, x, y, case_index).map(|inner| SolveView { inner })
}

#[wasm_bindgen]
pub fn f2d_noop() {
    api::f2d_noop()
}

#[wasm_bindgen]
pub fn f2d_echo(n: u32) -> Vec<f64> {
    api::f2d_echo(n)
}
