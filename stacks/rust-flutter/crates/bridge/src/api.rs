//! The engine as the Flutter client sees it: a session holding one model, flat numeric arrays out.
//!
//! This module is the single source for both front ends: flutter_rust_bridge generates the desktop FFI
//! wrappers from it, and `web.rs` wraps the same functions for wasm-bindgen. All per-node data is in ascending
//! node id order and all per-member data in ascending member id order; members refer to nodes by position.

use std::sync::Mutex;

use frame2d_engine::{analyze, generate, Model, ModelError, Results, Topology, STATIONS};

/// Everything the UI needs to draw and list a model.
#[derive(Debug)]
pub struct ModelView {
    pub node_ids: Vec<i32>,
    /// x, y per node.
    pub node_xy: Vec<f64>,
    /// Bit 0 = ux, bit 1 = uy, bit 2 = rz restrained.
    pub node_support: Vec<u8>,
    pub member_ids: Vec<i32>,
    /// i, j node positions per member.
    pub member_nodes: Vec<u32>,
    pub member_length: Vec<f64>,
    pub member_material: Vec<u32>,
    pub member_section: Vec<u32>,
    pub material_names: Vec<String>,
    pub section_names: Vec<String>,
    pub case_ids: Vec<String>,
    /// Nodal loads: case index, node position per entry; fx, fy, mz per entry.
    pub nodal_load_ix: Vec<u32>,
    pub nodal_load_f: Vec<f64>,
    /// Member UDLs: case index, member position per entry; w per entry.
    pub udl_ix: Vec<u32>,
    pub udl_w: Vec<f64>,
}

/// Results of one load case as flat arrays, plus timings.
#[derive(Debug)]
pub struct SolveView {
    pub case_index: u32,
    /// ux, uy, rz per node.
    pub disp: Vec<f64>,
    /// N_i, V_i, M_i, N_j, V_j, M_j per member.
    pub end_forces: Vec<f64>,
    /// Bending moment at 11 stations per member.
    pub stations_m: Vec<f64>,
    pub member_max_abs_m: Vec<f64>,
    pub member_max_abs_v: Vec<f64>,
    /// Axial force (tension positive) at the member start.
    pub member_axial: Vec<f64>,
    /// Current member lengths (they change while a node is dragged).
    pub member_length: Vec<f64>,
    /// node position, fx, fy, mz per reaction entry.
    pub reactions: Vec<f64>,
    pub equilibrium_residual: f64,
    pub assemble_ms: f64,
    pub factor_ms: f64,
    pub solve_ms: f64,
    pub free_dofs: u32,
    pub profile_before: u32,
    pub profile_after: u32,
}

struct Session {
    model: Model,
    topo: Topology,
    /// Model node index -> position in ascending id order.
    node_pos: Vec<usize>,
}

static SESSION: Mutex<Option<Session>> = Mutex::new(None);

fn err(e: ModelError) -> String {
    format!("{}|{}", e.code, e.detail)
}

fn with_session<T>(f: impl FnOnce(&mut Session) -> Result<T, String>) -> Result<T, String> {
    let mut guard = SESSION.lock().map_err(|_| "internal|session lock poisoned".to_string())?;
    match guard.as_mut() {
        Some(s) => f(s),
        None => Err("no_model|load or generate a model first".to_string()),
    }
}

fn install(model: Model) -> Result<ModelView, String> {
    let topo = Topology::build(&model).map_err(err)?;
    let mut node_pos = vec![0; model.nodes.len()];
    for (pos, &k) in topo.node_sorted.iter().enumerate() {
        node_pos[k] = pos;
    }
    let view = model_view(&model, &topo, &node_pos);
    *SESSION.lock().map_err(|_| "internal|session lock poisoned".to_string())? =
        Some(Session { model, topo, node_pos });
    Ok(view)
}

fn model_view(model: &Model, topo: &Topology, node_pos: &[usize]) -> ModelView {
    let mut node_xy = Vec::with_capacity(model.nodes.len() * 2);
    let mut node_support = Vec::with_capacity(model.nodes.len());
    for &k in &topo.node_sorted {
        node_xy.extend_from_slice(&[model.nodes[k].x, model.nodes[k].y]);
        node_support.push((0..3).fold(0u8, |acc, c| if topo.dof[k * 3 + c] < 0 { acc | (1 << c) } else { acc }));
    }
    let mut member_nodes = Vec::with_capacity(model.members.len() * 2);
    let mut member_length = Vec::with_capacity(model.members.len());
    for &k in &topo.member_sorted {
        let (i, j) = topo.member_nodes[k];
        member_nodes.extend_from_slice(&[node_pos[i] as u32, node_pos[j] as u32]);
        let (a, b) = (&model.nodes[i], &model.nodes[j]);
        member_length.push((b.x - a.x).hypot(b.y - a.y));
    }
    let mut member_slot = vec![0usize; model.members.len()];
    for (pos, &k) in topo.member_sorted.iter().enumerate() {
        member_slot[k] = pos;
    }

    let mut nodal_load_ix = Vec::new();
    let mut nodal_load_f = Vec::new();
    let mut udl_ix = Vec::new();
    let mut udl_w = Vec::new();
    for (ci, lc) in model.load_cases.iter().enumerate() {
        for l in &lc.nodal {
            nodal_load_ix.extend_from_slice(&[ci as u32, node_pos[topo.node_index[&l.node]] as u32]);
            nodal_load_f.extend_from_slice(&[l.fx, l.fy, l.mz]);
        }
        for l in &lc.member_udl {
            udl_ix.extend_from_slice(&[ci as u32, member_slot[topo.member_index[&l.member]] as u32]);
            udl_w.push(l.w);
        }
    }

    ModelView {
        node_ids: topo.node_sorted.iter().map(|&k| model.nodes[k].id as i32).collect(),
        node_xy,
        node_support,
        member_ids: topo.member_sorted.iter().map(|&k| model.members[k].id as i32).collect(),
        member_nodes,
        member_length,
        member_material: topo.member_sorted.iter().map(|&k| topo.member_material[k] as u32).collect(),
        member_section: topo.member_sorted.iter().map(|&k| topo.member_section[k] as u32).collect(),
        material_names: model.materials.iter().map(|m| m.id.clone()).collect(),
        section_names: model.sections.iter().map(|s| s.id.clone()).collect(),
        case_ids: model.load_cases.iter().map(|c| c.id.clone()).collect(),
        nodal_load_ix,
        nodal_load_f,
        udl_ix,
        udl_w,
    }
}

fn solve_view(session: &Session, case_index: u32) -> Result<SolveView, String> {
    if case_index as usize >= session.model.load_cases.len() {
        return Err(format!("invalid_ref|no load case {case_index}"));
    }
    let results = analyze(&session.model, &session.topo, Some(&[case_index as usize])).map_err(err)?;
    Ok(flatten(&session.topo, &session.node_pos, case_index, &results))
}

fn flatten(topo: &Topology, node_pos: &[usize], case_index: u32, results: &Results) -> SolveView {
    let case = &results.cases[0];
    let members = results.member_ids.len();
    let mut stations_m = Vec::with_capacity(members * STATIONS);
    let mut max_m = Vec::with_capacity(members);
    let mut max_v = Vec::with_capacity(members);
    let mut axial = Vec::with_capacity(members);
    for m in 0..members {
        let (mut mm, mut vv) = (0.0f64, 0.0f64);
        for k in 0..STATIONS {
            let st = results.station(0, m, k);
            stations_m.push(st.m);
            mm = mm.max(st.m.abs());
            vv = vv.max(st.v.abs());
            if k == 0 {
                axial.push(st.n);
            }
        }
        max_m.push(mm);
        max_v.push(vv);
    }
    let mut reactions = Vec::with_capacity(case.reactions.len() * 4);
    for r in &case.reactions {
        let pos = node_pos[topo.node_index[&r.node]];
        reactions.extend_from_slice(&[pos as f64, r.fx, r.fy, r.mz]);
    }
    let s = &results.stats;
    SolveView {
        case_index,
        disp: case.disp.clone(),
        end_forces: case.end_forces.clone(),
        stations_m,
        member_max_abs_m: max_m,
        member_max_abs_v: max_v,
        member_axial: axial,
        member_length: results.member_length.clone(),
        reactions,
        equilibrium_residual: case.equilibrium_residual,
        assemble_ms: s.assemble_ms,
        factor_ms: s.factor_ms,
        solve_ms: s.solve_ms,
        free_dofs: s.free_dofs as u32,
        profile_before: s.profile_before as u32,
        profile_after: s.profile_after as u32,
    }
}

/// Parses and validates a model (SPEC 5.1 JSON) and makes it the current session.
pub fn engine_load(json: String) -> Result<ModelView, String> {
    let model: Model = serde_json::from_str(&json).map_err(|e| format!("bad_json|{e}"))?;
    install(model)
}

/// Generates the B x S moment frame (SPEC 4.8) and makes it the current session.
pub fn engine_generate(bays: u32, stories: u32) -> Result<ModelView, String> {
    install(generate(bays as usize, stories as usize))
}

/// The current model, including dragged node positions, as model JSON.
pub fn engine_export() -> Result<String, String> {
    with_session(|s| serde_json::to_string_pretty(&s.model).map_err(|e| format!("internal|{e}")))
}

/// Solves one load case of the current model.
pub fn engine_solve(case_index: u32) -> Result<SolveView, String> {
    with_session(|s| solve_view(s, case_index))
}

/// Moves one node (by position) and solves one load case: a single boundary crossing per drag step.
pub fn engine_move_and_solve(node_pos: u32, x: f64, y: f64, case_index: u32) -> Result<SolveView, String> {
    with_session(|s| {
        let k = *s.topo.node_sorted.get(node_pos as usize).ok_or("invalid_ref|no such node position")?;
        s.model.nodes[k].x = x;
        s.model.nodes[k].y = y;
        solve_view(s, case_index)
    })
}

/// Boundary benchmark: a call that does nothing.
#[cfg_attr(not(target_arch = "wasm32"), flutter_rust_bridge::frb(sync))]
pub fn f2d_noop() {}

/// Boundary benchmark: returns `n` f64 values.
#[cfg_attr(not(target_arch = "wasm32"), flutter_rust_bridge::frb(sync))]
pub fn f2d_echo(n: u32) -> Vec<f64> {
    (0..n).map(|i| i as f64).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // The session is process-global, so the cases run in one test to avoid interleaving.
    #[test]
    fn session_lifecycle() {
        assert!(engine_solve(0).unwrap_err().starts_with("no_model|"));

        let view = engine_generate(3, 2).unwrap();
        assert_eq!(view.node_ids.len(), 12);
        assert_eq!(view.member_ids.len(), 4 * 2 + 3 * 2);
        assert_eq!(view.case_ids, vec!["D", "L", "W"]);
        assert_eq!(view.node_support.iter().filter(|&&s| s == 7).count(), 4);

        let solved = engine_solve(2).unwrap();
        assert_eq!(solved.disp.len(), 12 * 3);
        assert_eq!(solved.stations_m.len(), view.member_ids.len() * STATIONS);
        assert!(solved.equilibrium_residual < 1e-8);
        assert!(solved.disp[(11 - 0) * 3 - 3] != 0.0, "wind load must move the top-left node");
        assert!(engine_solve(9).unwrap_err().starts_with("invalid_ref|"));

        // Dragging a node changes lengths and results in one call.
        let top = 11u32;
        let before = solved.disp[top as usize * 3];
        let moved = engine_move_and_solve(top, 6.5, 7.0, 2).unwrap();
        assert!(moved.disp[top as usize * 3] != before);
        assert!(moved.member_length.iter().any(|&l| (l - 3.5).abs() > 1e-6));
        let json = engine_export().unwrap();
        assert!(json.contains("6.5"));

        // The exported model loads back into an equivalent session.
        let again = engine_load(json).unwrap();
        assert_eq!(again.node_ids, view.node_ids);
        assert_eq!(again.node_xy[top as usize * 2], 6.5);

        assert!(engine_load("{ not json".into()).unwrap_err().starts_with("bad_json|"));
        // A failed load keeps the previous session usable.
        assert!(engine_solve(0).is_ok());
    }

    #[test]
    fn boundary_benchmark_functions() {
        f2d_noop();
        let v = f2d_echo(38_103);
        assert_eq!(v.len(), 38_103);
        assert_eq!(v[38_102], 38_102.0);
    }
}
