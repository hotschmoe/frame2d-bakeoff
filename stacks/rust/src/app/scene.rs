//! Render-friendly view of the model (sorted, index-based) and per-solve derived quantities.

use crate::model::{Model, Results};
use std::collections::HashMap;

pub struct Scene {
    pub node_ids: Vec<i64>,
    pub pos: Vec<[f64; 2]>,
    /// Index into `Model::nodes` for each scene node.
    pub node_slot: Vec<usize>,
    pub mem_ids: Vec<i64>,
    pub ends: Vec<(u32, u32)>,
    /// Index into `Model::members` for each scene member.
    pub mem_slot: Vec<usize>,
    pub supports: Vec<(u32, [bool; 3])>,
    pub min: [f64; 2],
    pub max: [f64; 2],
}

impl Scene {
    pub fn build(model: &Model) -> Scene {
        let mut order: Vec<usize> = (0..model.nodes.len()).collect();
        order.sort_by_key(|&k| model.nodes[k].id);
        let node_ids: Vec<i64> = order.iter().map(|&k| model.nodes[k].id).collect();
        let pos: Vec<[f64; 2]> = order.iter().map(|&k| [model.nodes[k].x, model.nodes[k].y]).collect();
        let index: HashMap<i64, u32> = node_ids.iter().enumerate().map(|(k, &id)| (id, k as u32)).collect();

        let mut morder: Vec<usize> = (0..model.members.len()).collect();
        morder.sort_by_key(|&k| model.members[k].id);
        let (mut mem_ids, mut ends, mut mem_slot) = (Vec::new(), Vec::new(), Vec::new());
        for k in morder {
            let m = &model.members[k];
            if let (Some(&a), Some(&b)) = (index.get(&m.i), index.get(&m.j)) {
                mem_ids.push(m.id);
                ends.push((a, b));
                mem_slot.push(k);
            }
        }

        let mut flags: HashMap<u32, [bool; 3]> = HashMap::new();
        for s in &model.supports {
            if let Some(&k) = index.get(&s.node) {
                let f = flags.entry(k).or_default();
                f[0] |= s.ux;
                f[1] |= s.uy;
                f[2] |= s.rz;
            }
        }
        let mut supports: Vec<_> = flags.into_iter().collect();
        supports.sort_by_key(|s| s.0);

        let mut s = Scene { node_ids, pos, node_slot: order, mem_ids, ends, mem_slot, supports, min: [0.0; 2], max: [1.0; 2] };
        s.update_bounds();
        s
    }

    pub fn update_bounds(&mut self) {
        if self.pos.is_empty() {
            return;
        }
        let (mut lo, mut hi) = ([f64::MAX; 2], [f64::MIN; 2]);
        for p in &self.pos {
            for d in 0..2 {
                lo[d] = lo[d].min(p[d]);
                hi[d] = hi[d].max(p[d]);
            }
        }
        self.min = lo;
        self.max = hi;
    }

    pub fn size(&self) -> f64 {
        (self.max[0] - self.min[0]).max(self.max[1] - self.min[1]).max(1e-9)
    }

    pub fn member_len(&self, k: usize) -> f64 {
        let (a, b) = self.ends[k];
        let (pa, pb) = (self.pos[a as usize], self.pos[b as usize]);
        ((pb[0] - pa[0]).powi(2) + (pb[1] - pa[1]).powi(2)).sqrt()
    }
}

/// Quantities of the current load case that the canvas and table need on every frame.
#[derive(Default)]
pub struct Derived {
    pub case_index: Option<usize>,
    pub max_m: Vec<f32>,
    pub global_max_m: f64,
    pub max_disp: f64,
}

impl Derived {
    pub fn compute(scene: &Scene, results: Option<&Results>, case_id: &str) -> Derived {
        let Some(res) = results else { return Derived::default() };
        let Some(ci) = res.load_cases.iter().position(|c| c.id == case_id) else { return Derived::default() };
        let case = &res.load_cases[ci];
        if case.members.len() != scene.ends.len() || case.displacements.len() != scene.pos.len() {
            return Derived::default();
        }
        let max_m: Vec<f32> =
            case.members.iter().map(|m| m.stations.iter().fold(0.0f64, |a, s| a.max(s.m.abs())) as f32).collect();
        let global_max_m = max_m.iter().fold(0.0f32, |a, &b| a.max(b)) as f64;
        let max_disp = case.displacements.iter().fold(0.0f64, |a, d| a.max(d.ux.hypot(d.uy)));
        Derived { case_index: Some(ci), max_m, global_max_m, max_disp }
    }
}
