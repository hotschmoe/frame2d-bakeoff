//! Direct stiffness analysis: element matrices, assembly, factorization, load cases, post-processing.

use serde::Serialize;

use crate::clock::now_ms;
use crate::error::ModelError;
use crate::model::Model;
use crate::skyline::Skyline;
use crate::topology::{check_lengths, Topology};

/// Number of equally spaced stations per member diagram (x = 0 .. L).
pub const STATIONS: usize = 11;

#[derive(Debug, Clone, Serialize)]
pub struct Stats {
    pub nodes: usize,
    pub members: usize,
    pub free_dofs: usize,
    pub profile_before: u64,
    pub profile_after: u64,
    pub assemble_ms: f64,
    pub factor_ms: f64,
    pub solve_ms: f64,
    pub alloc_count: Option<u64>,
    pub alloc_bytes: Option<u64>,
    pub peak_heap_bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Warning {
    pub warning: String,
    pub node: i64,
    pub dof: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Reaction {
    pub node: i64,
    pub fx: f64,
    pub fy: f64,
    pub mz: f64,
}

#[derive(Debug, Clone, Copy)]
pub struct Station {
    pub x: f64,
    pub n: f64,
    pub v: f64,
    pub m: f64,
}

/// Results of one load case. Per-node data is in ascending node id order, per-member data in ascending member id order.
#[derive(Debug, Clone)]
pub struct CaseResult {
    pub id: String,
    /// ux, uy, rz per node.
    pub disp: Vec<f64>,
    pub reactions: Vec<Reaction>,
    /// N_i, V_i, M_i, N_j, V_j, M_j per member, local, acting on the member.
    pub end_forces: Vec<f64>,
    /// Member UDL (local y) per member.
    pub udl: Vec<f64>,
    pub equilibrium_residual: f64,
}

impl CaseResult {
    pub fn station(&self, member: usize, length: f64, k: usize) -> Station {
        let ef = &self.end_forces[member * 6..member * 6 + 6];
        let w = self.udl[member];
        let x = length * k as f64 / (STATIONS - 1) as f64;
        Station { x, n: -ef[0], v: ef[1] + w * x, m: -ef[2] + ef[1] * x + w * x * x / 2.0 }
    }
}

#[derive(Debug, Clone)]
pub struct Results {
    pub node_ids: Vec<i64>,
    pub member_ids: Vec<i64>,
    pub member_length: Vec<f64>,
    pub cases: Vec<CaseResult>,
    pub warnings: Vec<Warning>,
    pub stats: Stats,
}

impl Results {
    pub fn station(&self, case: usize, member: usize, k: usize) -> Station {
        self.cases[case].station(member, self.member_length[member], k)
    }

    /// Largest |M| over all stations, members and load cases.
    pub fn max_abs_moment(&self) -> f64 {
        let mut best = 0.0f64;
        for (ci, _) in self.cases.iter().enumerate() {
            for m in 0..self.member_ids.len() {
                for k in 0..STATIONS {
                    best = best.max(self.station(ci, m, k).m.abs());
                }
            }
        }
        best
    }
}

struct Element {
    e: f64,
    a: f64,
    i: f64,
    length: f64,
    c: f64,
    s: f64,
    /// Local DOFs condensed out (mz releases at the i and j ends).
    released: [bool; 6],
}

type Mat6 = [[f64; 6]; 6];

fn local_stiffness(el: &Element) -> Mat6 {
    let l = el.length;
    let ea = el.e * el.a / l;
    let b = el.e * el.i / (l * l * l);
    let (b12, b6l, b4l2, b2l2) = (12.0 * b, 6.0 * b * l, 4.0 * b * l * l, 2.0 * b * l * l);
    [
        [ea, 0.0, 0.0, -ea, 0.0, 0.0],
        [0.0, b12, b6l, 0.0, -b12, b6l],
        [0.0, b6l, b4l2, 0.0, -b6l, b2l2],
        [-ea, 0.0, 0.0, ea, 0.0, 0.0],
        [0.0, -b12, -b6l, 0.0, b12, -b6l],
        [0.0, b6l, b2l2, 0.0, -b6l, b4l2],
    ]
}

/// Static condensation of the released local DOFs out of `k` and `f` (SPEC 4.7): released rows and columns
/// become zero, so the released end moment is exactly zero.
fn condense(k: &mut Mat6, f: &mut [f64; 6], released: &[bool; 6]) {
    for r in 0..6 {
        if !released[r] {
            continue;
        }
        let piv = k[r][r];
        for a in 0..6 {
            if a == r || released[a] && a < r {
                continue;
            }
            let fac = k[a][r] / piv;
            for b in 0..6 {
                k[a][b] -= fac * k[r][b];
            }
            f[a] -= fac * f[r];
        }
        for a in 0..6 {
            k[a][r] = 0.0;
            k[r][a] = 0.0;
        }
        f[r] = 0.0;
    }
}

/// Local stiffness and fixed-end forces for UDL `w`, with releases condensed.
fn element_local(el: &Element, w: f64) -> (Mat6, [f64; 6]) {
    let mut k = local_stiffness(el);
    let mut f = fixed_end_forces(w, el.length);
    if el.released.iter().any(|&r| r) {
        condense(&mut k, &mut f, &el.released);
    }
    (k, f)
}

/// Global-to-local rotation of the six member DOFs.
fn rotation(c: f64, s: f64) -> Mat6 {
    [
        [c, s, 0.0, 0.0, 0.0, 0.0],
        [-s, c, 0.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, c, s, 0.0],
        [0.0, 0.0, 0.0, -s, c, 0.0],
        [0.0, 0.0, 0.0, 0.0, 0.0, 1.0],
    ]
}

fn mat_mul(a: &Mat6, b: &Mat6) -> Mat6 {
    let mut out = [[0.0; 6]; 6];
    for i in 0..6 {
        for k in 0..6 {
            let aik = a[i][k];
            if aik != 0.0 {
                for j in 0..6 {
                    out[i][j] += aik * b[k][j];
                }
            }
        }
    }
    out
}

fn transpose(a: &Mat6) -> Mat6 {
    let mut out = [[0.0; 6]; 6];
    for i in 0..6 {
        for j in 0..6 {
            out[j][i] = a[i][j];
        }
    }
    out
}

fn mat_vec(a: &Mat6, v: &[f64; 6]) -> [f64; 6] {
    let mut out = [0.0; 6];
    for i in 0..6 {
        out[i] = (0..6).map(|j| a[i][j] * v[j]).sum();
    }
    out
}

/// Fixed-end forces of a UDL in member local axes, acting on the member (SPEC 4.2).
fn fixed_end_forces(w: f64, l: f64) -> [f64; 6] {
    [0.0, -w * l / 2.0, -w * l * l / 12.0, 0.0, -w * l / 2.0, w * l * l / 12.0]
}

/// Builds topology, then analyzes every load case.
pub fn solve(model: &Model) -> Result<Results, ModelError> {
    let t0 = now_ms();
    let topo = Topology::build(model)?;
    let topo_ms = now_ms() - t0;
    let mut results = analyze(model, &topo, None)?;
    results.stats.assemble_ms += topo_ms;
    Ok(results)
}

/// Assembles, factors and solves with a prebuilt topology. `select` picks load cases by index (all when `None`).
pub fn analyze(model: &Model, topo: &Topology, select: Option<&[usize]>) -> Result<Results, ModelError> {
    let t_start = now_ms();
    check_lengths(model, &topo.member_nodes)?;

    let elements: Vec<Element> = (0..model.members.len())
        .map(|k| {
            let (i, j) = topo.member_nodes[k];
            let (a, b) = (&model.nodes[i], &model.nodes[j]);
            let (dx, dy) = (b.x - a.x, b.y - a.y);
            let length = dx.hypot(dy);
            Element {
                e: model.materials[topo.member_material[k]].e,
                a: model.sections[topo.member_section[k]].a,
                i: model.sections[topo.member_section[k]].i,
                length,
                c: dx / length,
                s: dy / length,
                released: {
                    let r = topo.member_release[k];
                    [false, false, r[0], false, false, r[1]]
                },
            }
        })
        .collect();

    let mut sky = Skyline::zeros(&topo.height, &topo.col_start);
    for (k, el) in elements.iter().enumerate() {
        let dofs = topo.member_dofs(k);
        let t = rotation(el.c, el.s);
        let kg = mat_mul(&transpose(&t), &mat_mul(&element_local(el, 0.0).0, &t));
        for a in 0..6 {
            if dofs[a] < 0 {
                continue;
            }
            for b in a..6 {
                if dofs[b] < 0 {
                    continue;
                }
                let (da, db) = (dofs[a] as usize, dofs[b] as usize);
                sky.add(da.min(db), da.max(db), kg[a][b]);
            }
        }
    }
    for sp in &model.springs {
        let n = topo.node_index[&sp.node];
        for (c, k) in sp.stiffness().iter().enumerate() {
            let d = topo.dof[n * 3 + c];
            if let (Some(k), true) = (k, d >= 0) {
                sky.add(d as usize, d as usize, *k);
            }
        }
    }
    let t_assembled = now_ms();

    if let Err(bad) = sky.factor() {
        let (node, comp) = topo.dof_owner[bad.dof];
        return Err(ModelError::new(
            "unstable",
            format!("node {} {} (pivot {:e})", model.nodes[node].id, ["ux", "uy", "rz"][comp as usize], bad.value),
        ));
    }
    let t_factored = now_ms();

    let all: Vec<usize> = (0..model.load_cases.len()).collect();
    let selected = select.unwrap_or(&all);
    let mut cases = Vec::with_capacity(selected.len());
    for &ci in selected {
        cases.push(solve_case(model, topo, &elements, &sky, ci));
    }
    let t_solved = now_ms();

    Ok(Results {
        node_ids: topo.node_sorted.iter().map(|&k| model.nodes[k].id).collect(),
        member_ids: topo.member_sorted.iter().map(|&k| model.members[k].id).collect(),
        member_length: topo.member_sorted.iter().map(|&k| elements[k].length).collect(),
        cases,
        warnings: topo
            .node_sorted
            .iter()
            .filter(|&&k| topo.auto_rz[k])
            .map(|&k| Warning { warning: "auto_restrained".into(), node: model.nodes[k].id, dof: "rz".into() })
            .collect(),
        stats: Stats {
            nodes: model.nodes.len(),
            members: model.members.len(),
            free_dofs: topo.free_dofs,
            profile_before: topo.profile_before,
            profile_after: topo.profile_after,
            assemble_ms: t_assembled - t_start,
            factor_ms: t_factored - t_assembled,
            solve_ms: t_solved - t_factored,
            alloc_count: None,
            alloc_bytes: None,
            peak_heap_bytes: None,
        },
    })
}

fn solve_case(model: &Model, topo: &Topology, elements: &[Element], sky: &Skyline, ci: usize) -> CaseResult {
    let lc = &model.load_cases[ci];
    let mut rhs = vec![0.0; topo.free_dofs];

    // Member UDLs, summed per member.
    let mut w_of = vec![0.0; model.members.len()];
    for l in &lc.member_udl {
        w_of[topo.member_index[&l.member]] += l.w;
    }
    // Applied nodal loads, summed per node.
    let mut applied = vec![0.0; model.nodes.len() * 3];
    for l in &lc.nodal {
        let k = topo.node_index[&l.node];
        applied[k * 3] += l.fx;
        applied[k * 3 + 1] += l.fy;
        applied[k * 3 + 2] += l.mz;
    }
    for (k, &a) in applied.iter().enumerate() {
        let d = topo.dof[k];
        if d >= 0 {
            rhs[d as usize] += a;
        }
    }
    // Equivalent nodal loads of the fixed-end forces: minus the global fixed-end forces.
    for (k, el) in elements.iter().enumerate() {
        let w = w_of[k];
        if w == 0.0 {
            continue;
        }
        let f = element_local(el, w).1;
        let global = [
            el.c * f[0] - el.s * f[1],
            el.s * f[0] + el.c * f[1],
            f[2],
            el.c * f[3] - el.s * f[4],
            el.s * f[3] + el.c * f[4],
            f[5],
        ];
        for (g, &d) in global.iter().zip(topo.member_dofs(k).iter()) {
            if d >= 0 {
                rhs[d as usize] -= g;
            }
        }
    }

    let mut u = rhs;
    sky.solve(&mut u);

    let node_u = |node: usize, c: usize| -> f64 {
        let d = topo.dof[node * 3 + c];
        if d >= 0 {
            u[d as usize]
        } else {
            0.0
        }
    };

    let mut disp = Vec::with_capacity(model.nodes.len() * 3);
    for &n in &topo.node_sorted {
        disp.extend_from_slice(&[node_u(n, 0), node_u(n, 1), node_u(n, 2)]);
    }

    // Member end forces; accumulate global end forces at restrained DOFs for the reactions.
    let mut end_forces = vec![0.0; model.members.len() * 6];
    let mut udl = Vec::with_capacity(model.members.len());
    let mut support_force = vec![0.0; model.nodes.len() * 3];
    for (pos, &k) in topo.member_sorted.iter().enumerate() {
        let el = &elements[k];
        let (ni, nj) = topo.member_nodes[k];
        let ug = [node_u(ni, 0), node_u(ni, 1), node_u(ni, 2), node_u(nj, 0), node_u(nj, 1), node_u(nj, 2)];
        let t = rotation(el.c, el.s);
        let ul = mat_vec(&t, &ug);
        let (kl, f) = element_local(el, w_of[k]);
        let mut ef = mat_vec(&kl, &ul);
        for (e, fx) in ef.iter_mut().zip(f.iter()) {
            *e += fx;
        }
        end_forces[pos * 6..pos * 6 + 6].copy_from_slice(&ef);
        udl.push(w_of[k]);
        let gl = mat_vec(&transpose(&t), &ef);
        for (c, g) in gl.iter().enumerate() {
            let node = if c < 3 { ni } else { nj };
            let slot = node * 3 + c % 3;
            if topo.dof[slot] < 0 {
                support_force[slot] += g;
            }
        }
    }

    let mut reactions = Vec::new();
    let (mut sx, mut sy, mut mag) = (0.0f64, 0.0f64, 1.0f64);
    for &n in &topo.node_sorted {
        if (0..3).any(|c| topo.dof[n * 3 + c] < 0 && !(c == 2 && topo.auto_rz[n])) {
            let comp = |c: usize| {
                let slot = n * 3 + c;
                if topo.dof[slot] < 0 {
                    support_force[slot] - applied[slot]
                } else {
                    0.0
                }
            };
            let r = Reaction { node: model.nodes[n].id, fx: comp(0), fy: comp(1), mz: comp(2) };
            sx += r.fx;
            sy += r.fy;
            mag += r.fx.abs() + r.fy.abs();
            reactions.push(r);
        }
    }
    for sp in &model.springs {
        // The spring pulls back on the structure with -k u.
        let n = topo.node_index[&sp.node];
        for (c, k) in sp.stiffness().iter().enumerate().take(2) {
            if let Some(k) = k {
                let f = -k * node_u(n, c);
                if c == 0 { sx += f } else { sy += f }
                mag += f.abs();
            }
        }
    }
    for n in 0..model.nodes.len() {
        let (fx, fy) = (applied[n * 3], applied[n * 3 + 1]);
        sx += fx;
        sy += fy;
        mag += fx.abs() + fy.abs();
    }
    for (k, el) in elements.iter().enumerate() {
        let w = w_of[k];
        if w != 0.0 {
            let (fx, fy) = (-el.s * w * el.length, el.c * w * el.length);
            sx += fx;
            sy += fy;
            mag += fx.abs() + fy.abs();
        }
    }

    CaseResult {
        id: lc.id.clone(),
        disp,
        reactions,
        end_forces,
        udl,
        equilibrium_residual: sx.abs().max(sy.abs()) / mag,
    }
}
