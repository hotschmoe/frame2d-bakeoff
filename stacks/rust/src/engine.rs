//! The analysis engine (SPEC 4): validation, RCM ordering, skyline LDL^T, post-processing.
//! Written by hand; no numeric libraries.

use crate::model::*;
use std::collections::HashMap;
use web_time::Instant;

const MIN_LENGTH: f64 = 1e-9;
const STATIONS: usize = 11;

// ---------------------------------------------------------------------------------------------
// Resolved (validated, index-based) model
// ---------------------------------------------------------------------------------------------

struct Elem {
    id: i64,
    ni: usize,
    nj: usize,
    len: f64,
    c: f64,
    s: f64,
    ea: f64,
    ei: f64,
    rel: [bool; 6], // released local DOFs (SPEC 4.7)
}

struct Prepared<'a> {
    nodes: Vec<&'a Node>,  // sorted by id
    elems: Vec<Elem>,      // sorted by id
    restrained: Vec<bool>,  // 3 per node, as given (reactions are reported here)
    solve_restr: Vec<bool>, // restrained plus auto-restrained DOFs
    springs: Vec<[f64; 3]>, // 3 per node
    warnings: Vec<serde_json::Value>,
    cases: Vec<CaseData<'a>>,
}

struct CaseData<'a> {
    id: &'a str,
    nodal: Vec<[f64; 3]>, // per node, summed
    udl: Vec<f64>,        // per member, summed
}

fn prepare<'a>(model: &'a Model, only: Option<&str>) -> Result<Prepared<'a>, ModelError> {
    let mut nodes: Vec<&Node> = model.nodes.iter().collect();
    nodes.sort_by_key(|n| n.id);
    if let Some(w) = nodes.windows(2).find(|w| w[0].id == w[1].id) {
        return Err(ModelError::new("duplicate_id", format!("duplicate node id {}", w[0].id)));
    }
    let nidx: HashMap<i64, usize> = nodes.iter().enumerate().map(|(k, n)| (n.id, k)).collect();

    let mut members: Vec<&Member> = model.members.iter().collect();
    members.sort_by_key(|m| m.id);
    if let Some(w) = members.windows(2).find(|w| w[0].id == w[1].id) {
        return Err(ModelError::new("duplicate_id", format!("duplicate member id {}", w[0].id)));
    }
    let midx: HashMap<i64, usize> = members.iter().enumerate().map(|(k, m)| (m.id, k)).collect();
    let mats: HashMap<&str, &Material> = model.materials.iter().map(|m| (m.id.as_str(), m)).collect();
    let secs: HashMap<&str, &Section> = model.sections.iter().map(|s| (s.id.as_str(), s)).collect();

    let mut elems = Vec::with_capacity(members.len());
    for m in &members {
        let find = |id: i64| {
            nidx.get(&id).copied().ok_or_else(|| {
                ModelError::new("invalid_ref", format!("member {} references missing node {}", m.id, id))
            })
        };
        let (ni, nj) = (find(m.i)?, find(m.j)?);
        let mat = mats.get(m.material.as_str()).ok_or_else(|| {
            ModelError::new("invalid_ref", format!("member {} references missing material {}", m.id, m.material))
        })?;
        let sec = secs.get(m.section.as_str()).ok_or_else(|| {
            ModelError::new("invalid_ref", format!("member {} references missing section {}", m.id, m.section))
        })?;
        let mut rel = [false; 6];
        for (list, off) in [(&m.release.i, 0), (&m.release.j, 3)] {
            for d in list {
                if d != "mz" {
                    return Err(ModelError::new("invalid_ref", format!("member {} has unsupported release {}", m.id, d)));
                }
                rel[off + 2] = true;
            }
        }
        elems.push(Elem { id: m.id, ni, nj, len: 0.0, c: 1.0, s: 0.0, ea: mat.e * sec.a, ei: mat.e * sec.i, rel });
    }

    let mut restrained = vec![false; 3 * nodes.len()];
    for s in &model.supports {
        let k = *nidx
            .get(&s.node)
            .ok_or_else(|| ModelError::new("invalid_ref", format!("support references missing node {}", s.node)))?;
        restrained[3 * k] |= s.ux;
        restrained[3 * k + 1] |= s.uy;
        restrained[3 * k + 2] |= s.rz;
    }

    let mut springs = vec![[0.0; 3]; nodes.len()];
    for sp in &model.springs {
        let k = *nidx
            .get(&sp.node)
            .ok_or_else(|| ModelError::new("invalid_ref", format!("spring references missing node {}", sp.node)))?;
        for (c, v) in [sp.kx, sp.ky, sp.kr].into_iter().enumerate() {
            if let Some(v) = v {
                if restrained[3 * k + c] {
                    return Err(ModelError::new(
                        "support_conflict",
                        format!("node {} {} is both restrained and sprung", sp.node, ["ux", "uy", "rz"][c]),
                    ));
                }
                springs[k][c] += v;
            }
        }
    }

    let mut cases = Vec::with_capacity(model.load_cases.len());
    for lc in &model.load_cases {
        if only.is_some_and(|o| o != lc.id) {
            continue;
        }
        let mut nodal = vec![[0.0; 3]; nodes.len()];
        for l in &lc.nodal {
            let k = *nidx.get(&l.node).ok_or_else(|| {
                ModelError::new("invalid_ref", format!("load case {} references missing node {}", lc.id, l.node))
            })?;
            nodal[k][0] += l.fx;
            nodal[k][1] += l.fy;
            nodal[k][2] += l.mz;
        }
        let mut udl = vec![0.0; elems.len()];
        for l in &lc.member_udl {
            let k = *midx.get(&l.member).ok_or_else(|| {
                ModelError::new("invalid_ref", format!("load case {} references missing member {}", lc.id, l.member))
            })?;
            udl[k] += l.w;
        }
        cases.push(CaseData { id: &lc.id, nodal, udl });
    }

    for e in &mut elems {
        let (a, b) = (nodes[e.ni], nodes[e.nj]);
        let (dx, dy) = (b.x - a.x, b.y - a.y);
        let len = (dx * dx + dy * dy).sqrt();
        if len < MIN_LENGTH {
            return Err(ModelError::new("zero_length", format!("member {} has length {:e}", e.id, len)));
        }
        e.len = len;
        e.c = dx / len;
        e.s = dy / len;
    }
    let (solve_restr, warnings) = auto_restrain(&nodes, &elems, &restrained, &springs);
    Ok(Prepared { nodes, elems, restrained, solve_restr, springs, warnings, cases })
}

/// Auto-restraint (SPEC 4.7): a free rz with (numerically) zero stiffness is restrained, with a warning.
fn auto_restrain(
    nodes: &[&Node],
    elems: &[Elem],
    restrained: &[bool],
    springs: &[[f64; 3]],
) -> (Vec<bool>, Vec<serde_json::Value>) {
    let mut rot = vec![0.0f64; nodes.len()];
    for e in elems {
        let k = local_k(e);
        rot[e.ni] += k[2][2];
        rot[e.nj] += k[5][5];
    }
    let mut out = restrained.to_vec();
    let mut warnings = Vec::new();
    let scale = (0..nodes.len()).filter(|&n| !restrained[3 * n + 2]).map(|n| rot[n] + springs[n][2]).fold(0.0, f64::max);
    for n in 0..nodes.len() {
        if !restrained[3 * n + 2] && rot[n] + springs[n][2] <= 1e-12 * scale {
            out[3 * n + 2] = true;
            warnings.push(serde_json::json!({"warning": "auto_restrained", "node": nodes[n].id, "dof": "rz"}));
        }
    }
    (out, warnings)
}

// ---------------------------------------------------------------------------------------------
// Reverse Cuthill-McKee (SPEC 4.4)
// ---------------------------------------------------------------------------------------------

fn adjacency(n: usize, elems: &[Elem]) -> Vec<Vec<usize>> {
    let mut adj: Vec<Vec<usize>> = vec![Vec::new(); n];
    for e in elems {
        if e.ni != e.nj {
            adj[e.ni].push(e.nj);
            adj[e.nj].push(e.ni);
        }
    }
    for a in &mut adj {
        a.sort_unstable();
        a.dedup();
    }
    adj
}

/// BFS level structure rooted at `root`. Neighbours are visited in the order stored in `adj`
/// (ascending degree, id), so the visit order doubles as the Cuthill-McKee order.
/// Returns (visit order, level start offsets with a final sentinel = order.len()).
fn bfs_levels(root: usize, adj: &[Vec<usize>], mark: &mut [u32], stamp: u32) -> (Vec<usize>, Vec<usize>) {
    let mut order = vec![root];
    let mut starts = vec![0usize];
    mark[root] = stamp;
    let mut head = 0;
    let mut level_end = 1;
    while head < order.len() {
        if head == level_end {
            starts.push(head);
            level_end = order.len();
        }
        let u = order[head];
        head += 1;
        for &v in &adj[u] {
            if mark[v] != stamp {
                mark[v] = stamp;
                order.push(v);
            }
        }
    }
    starts.push(order.len());
    (order, starts)
}

fn rcm(n: usize, elems: &[Elem]) -> Vec<usize> {
    let mut adj = adjacency(n, elems);
    let deg: Vec<usize> = adj.iter().map(|a| a.len()).collect();
    for a in &mut adj {
        a.sort_unstable_by_key(|&v| (deg[v], v));
    }
    let mut mark = vec![0u32; n];
    let mut stamp = 0u32;
    let mut done = vec![false; n];
    let mut result = Vec::with_capacity(n);
    for first in 0..n {
        if done[first] {
            continue;
        }
        // Component discovery (marks it done).
        stamp += 1;
        let (comp, _) = bfs_levels(first, &adj, &mut mark, stamp);
        for &v in &comp {
            done[v] = true;
        }
        // Minimum-degree node of the component, lowest id on ties.
        let root = comp.iter().copied().min_by_key(|&v| (deg[v], v)).unwrap();
        // George-Liu pseudo-peripheral search.
        stamp += 1;
        let (mut ord, mut starts) = bfs_levels(root, &adj, &mut mark, stamp);
        loop {
            let levels = starts.len() - 1;
            let last = &ord[starts[levels - 1]..starts[levels]];
            let cand = last.iter().copied().min_by_key(|&v| (deg[v], v)).unwrap();
            stamp += 1;
            let (ord2, starts2) = bfs_levels(cand, &adj, &mut mark, stamp);
            if starts2.len() > starts.len() {
                ord = ord2;
                starts = starts2;
            } else {
                break;
            }
        }
        result.extend_from_slice(&ord);
    }
    result.reverse();
    result
}

// ---------------------------------------------------------------------------------------------
// DOF numbering and skyline profile
// ---------------------------------------------------------------------------------------------

struct Numbering {
    free: Vec<i32>,  // 3 per node: free index or -1
    owner: Vec<u32>, // per free dof: node*3 + component
}

fn number_dofs(order: &[usize], restrained: &[bool]) -> Numbering {
    let mut free = vec![-1i32; restrained.len()];
    let mut owner = Vec::new();
    for &nd in order {
        for c in 0..3 {
            if !restrained[3 * nd + c] {
                free[3 * nd + c] = owner.len() as i32;
                owner.push((3 * nd + c) as u32);
            }
        }
    }
    Numbering { free, owner }
}

fn member_dofs(num: &Numbering, e: &Elem) -> [i32; 6] {
    let f = &num.free;
    [f[3 * e.ni], f[3 * e.ni + 1], f[3 * e.ni + 2], f[3 * e.nj], f[3 * e.nj + 1], f[3 * e.nj + 2]]
}

/// Lowest coupled free-DOF index per column (SPEC 4.4 profile definition).
fn column_tops(num: &Numbering, elems: &[Elem]) -> Vec<usize> {
    let mut top: Vec<usize> = (0..num.owner.len()).collect();
    for e in elems {
        let d = member_dofs(num, e);
        if let Some(m) = d.iter().filter(|&&x| x >= 0).min().copied() {
            for &x in &d {
                if x >= 0 {
                    let x = x as usize;
                    top[x] = top[x].min(m as usize);
                }
            }
        }
    }
    top
}

fn profile_of(top: &[usize]) -> usize {
    top.iter().enumerate().map(|(j, &r)| j - r).sum()
}

// ---------------------------------------------------------------------------------------------
// Skyline storage and LDL^T
// ---------------------------------------------------------------------------------------------

struct Skyline {
    top: Vec<usize>,
    diag: Vec<usize>, // index of each diagonal entry in `a`
    a: Vec<f64>,
}

impl Skyline {
    fn new(top: Vec<usize>) -> Self {
        let mut diag = Vec::with_capacity(top.len());
        let mut pos = 0usize;
        for (j, &r) in top.iter().enumerate() {
            pos += j - r;
            diag.push(pos);
            pos += 1;
        }
        Skyline { a: vec![0.0; pos], top, diag }
    }

    #[inline]
    fn n(&self) -> usize {
        self.top.len()
    }

    #[inline]
    fn col_start(&self, j: usize) -> usize {
        self.diag[j] - (j - self.top[j])
    }

    #[inline]
    fn add(&mut self, row: usize, col: usize, v: f64) {
        let idx = self.diag[col] - (col - row);
        self.a[idx] += v;
    }

    /// In-place LDL^T. Returns Err(free dof) at the first failed pivot.
    fn factor(&mut self) -> Result<(), usize> {
        let n = self.n();
        let maxd = self.diag.iter().map(|&d| self.a[d]).fold(0.0f64, f64::max);
        let tol = 1e-12 * maxd; // BENCH-EDIT:leaf
        for j in 0..n {
            let rj = self.top[j];
            let cj = self.col_start(j);
            let dj = self.diag[j];
            let (left, right) = self.a.split_at_mut(cj);
            let colj = &mut right[..=(j - rj)];
            for i in rj..j {
                let ri = self.top[i];
                let lo = ri.max(rj);
                if lo < i {
                    let ci = self.diag[i] - (i - ri);
                    let s = dot(&left[ci + (lo - ri)..ci + (i - ri)], &colj[lo - rj..i - rj]);
                    colj[i - rj] -= s;
                }
            }
            let mut d = colj[j - rj];
            for i in rj..j {
                let g = colj[i - rj];
                let u = g / left[self.diag[i]];
                d -= u * g;
                colj[i - rj] = u;
            }
            if !(d > tol) {
                return Err(j);
            }
            self.a[dj] = d;
        }
        Ok(())
    }

    fn solve(&self, b: &mut [f64]) {
        let n = self.n();
        for j in 0..n {
            let rj = self.top[j];
            let cj = self.col_start(j);
            b[j] -= dot(&self.a[cj..cj + (j - rj)], &b[rj..j]);
        }
        for j in 0..n {
            b[j] /= self.a[self.diag[j]];
        }
        for j in (0..n).rev() {
            let bj = b[j];
            if bj != 0.0 {
                let rj = self.top[j];
                let cj = self.col_start(j);
                for (u, x) in self.a[cj..cj + (j - rj)].iter().zip(&mut b[rj..j]) {
                    *x -= u * bj;
                }
            }
        }
    }
}

#[inline]
fn dot(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len().min(b.len());
    let (a, b) = (&a[..n], &b[..n]);
    let mut s = [0.0f64; 4];
    let ca = a.chunks_exact(4);
    let cb = b.chunks_exact(4);
    let (ra, rb) = (ca.remainder(), cb.remainder());
    for (x, y) in ca.zip(cb) {
        s[0] += x[0] * y[0];
        s[1] += x[1] * y[1];
        s[2] += x[2] * y[2];
        s[3] += x[3] * y[3];
    }
    let mut t = (s[0] + s[1]) + (s[2] + s[3]);
    for (x, y) in ra.iter().zip(rb) {
        t += x * y;
    }
    t
}

// ---------------------------------------------------------------------------------------------
// Element formulation
// ---------------------------------------------------------------------------------------------

type M6 = [[f64; 6]; 6];

fn local_k(e: &Elem) -> M6 {
    let k = full_k(e);
    if e.rel.iter().any(|&r| r) { condense(&k, &[0.0; 6], &e.rel).0 } else { k }
}

/// Static condensation of released local DOFs out of k and the fixed-end vector f (SPEC 4.7).
fn condense(k: &M6, f: &[f64; 6], rel: &[bool; 6]) -> (M6, [f64; 6]) {
    let r: Vec<usize> = (0..6).filter(|&i| rel[i]).collect();
    if r.is_empty() {
        return (*k, *f);
    }
    let inv: [[f64; 2]; 2] = if r.len() == 1 {
        [[1.0 / k[r[0]][r[0]], 0.0], [0.0, 0.0]]
    } else {
        let (a, b, c, d) = (k[r[0]][r[0]], k[r[0]][r[1]], k[r[1]][r[0]], k[r[1]][r[1]]);
        let det = a * d - b * c;
        [[d / det, -b / det], [-c / det, a / det]]
    };
    let mut kc = [[0.0; 6]; 6];
    let mut fc = [0.0; 6];
    for a in (0..6).filter(|&i| !rel[i]) {
        let mut w = [0.0; 2];
        for q in 0..r.len() {
            w[q] = (0..r.len()).map(|p| k[a][r[p]] * inv[p][q]).sum();
        }
        for b in (0..6).filter(|&i| !rel[i]) {
            kc[a][b] = k[a][b] - (0..r.len()).map(|q| w[q] * k[r[q]][b]).sum::<f64>();
        }
        fc[a] = f[a] - (0..r.len()).map(|q| w[q] * f[r[q]]).sum::<f64>();
    }
    (kc, fc)
}

fn full_k(e: &Elem) -> M6 {
    let (l, ea, ei) = (e.len, e.ea, e.ei);
    let a = ea / l;
    let b1 = 12.0 * ei / (l * l * l);
    let b2 = 6.0 * ei / (l * l);
    let b3 = 4.0 * ei / l;
    let b4 = 2.0 * ei / l;
    [
        [a, 0.0, 0.0, -a, 0.0, 0.0],
        [0.0, b1, b2, 0.0, -b1, b2],
        [0.0, b2, b3, 0.0, -b2, b4],
        [-a, 0.0, 0.0, a, 0.0, 0.0],
        [0.0, -b1, -b2, 0.0, b1, -b2],
        [0.0, b2, b4, 0.0, -b2, b3],
    ]
}

/// Rotate a 6-vector from global to local axes.
#[inline]
fn to_local(e: &Elem, g: &[f64; 6]) -> [f64; 6] {
    let (c, s) = (e.c, e.s);
    [c * g[0] + s * g[1], -s * g[0] + c * g[1], g[2], c * g[3] + s * g[4], -s * g[3] + c * g[4], g[5]]
}

/// Rotate a 6-vector from local to global axes.
#[inline]
fn to_global(e: &Elem, l: &[f64; 6]) -> [f64; 6] {
    let (c, s) = (e.c, e.s);
    [c * l[0] - s * l[1], s * l[0] + c * l[1], l[2], c * l[3] - s * l[4], s * l[3] + c * l[4], l[5]]
}

/// K_global = T^T k T, built one column at a time from the rotation helpers.
fn global_k(e: &Elem) -> M6 {
    let k = local_k(e);
    let mut out = [[0.0; 6]; 6];
    for col in 0..6 {
        let mut unit = [0.0; 6];
        unit[col] = 1.0;
        let tcol = to_local(e, &unit);
        let mut kt = [0.0; 6];
        for r in 0..6 {
            kt[r] = (0..6).map(|m| k[r][m] * tcol[m]).sum();
        }
        let g = to_global(e, &kt);
        for r in 0..6 {
            out[r][col] = g[r];
        }
    }
    out
}

fn fixed_end(e: &Elem, w: f64) -> [f64; 6] {
    let l = e.len;
    let f = [0.0, -w * l / 2.0, -w * l * l / 12.0, 0.0, -w * l / 2.0, w * l * l / 12.0];
    if e.rel.iter().any(|&r| r) { condense(&full_k(e), &f, &e.rel).1 } else { f }
}

// ---------------------------------------------------------------------------------------------
// Solve
// ---------------------------------------------------------------------------------------------

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

/// Solve every load case of the model.
pub fn solve(model: &Model) -> Result<Results, ModelError> {
    solve_filtered(model, None)
}

/// Solve only the load case named `only` (all of them when `None`); used for interactive re-solves.
pub fn solve_filtered(model: &Model, only: Option<&str>) -> Result<Results, ModelError> {
    let t0 = Instant::now();
    let p = prepare(model, only)?;
    let nn = p.nodes.len();

    // Orderings: original id order (profile_before) and RCM (used for the solve).
    let identity: Vec<usize> = (0..nn).collect();
    let num_before = number_dofs(&identity, &p.solve_restr);
    let n = num_before.owner.len();
    if p.restrained.iter().all(|&r| r) || n == 0 {
        return Err(ModelError::new("no_free_dofs", "every DOF is restrained"));
    }
    let profile_before = profile_of(&column_tops(&num_before, &p.elems));
    drop(num_before);

    let order = rcm(nn, &p.elems);
    let num = number_dofs(&order, &p.solve_restr);
    let top = column_tops(&num, &p.elems);
    let profile_after = profile_of(&top);

    // Assembly.
    let mut sky = Skyline::new(top);
    for e in &p.elems {
        let d = member_dofs(&num, e);
        let k = global_k(e);
        for a in 0..6 {
            if d[a] < 0 {
                continue;
            }
            for b in 0..6 {
                if d[b] >= 0 && d[a] <= d[b] {
                    sky.add(d[a] as usize, d[b] as usize, k[a][b]);
                }
            }
        }
    }
    for nd in 0..nn {
        for c in 0..3 {
            let d = num.free[3 * nd + c];
            if d >= 0 && p.springs[nd][c] != 0.0 {
                sky.add(d as usize, d as usize, p.springs[nd][c]);
            }
        }
    }
    let assemble_ms = ms(t0);

    // Factorization (once for all load cases).
    let t1 = Instant::now();
    if let Err(j) = sky.factor() {
        let o = num.owner[j] as usize;
        let comp = ["ux", "uy", "rz"][o % 3];
        return Err(ModelError::new(
            "unstable",
            format!("zero pivot at node {} {} (free dof {})", p.nodes[o / 3].id, comp, j),
        ));
    }
    let factor_ms = ms(t1);

    // Load cases.
    let t2 = Instant::now();
    let case_results = p.cases.iter().map(|cd| solve_case(&p, &num, &sky, cd)).collect();
    let solve_ms = ms(t2);

    Ok(Results {
        load_cases: case_results,
        warnings: p.warnings.clone(),
        stats: Stats {
            nodes: nn,
            members: p.elems.len(),
            free_dofs: n,
            profile_before,
            profile_after,
            assemble_ms,
            factor_ms,
            solve_ms,
            alloc_count: None,
            alloc_bytes: None,
            peak_heap_bytes: None,
        },
    })
}

fn solve_case(p: &Prepared, num: &Numbering, sky: &Skyline, cd: &CaseData) -> CaseResult {
    let nn = p.nodes.len();
    let n = sky.n();

    // Load vector: nodal loads plus UDL equivalent loads (minus the fixed-end forces).
    let mut f = vec![0.0; n];
    for nd in 0..nn {
        for c in 0..3 {
            let d = num.free[3 * nd + c];
            if d >= 0 {
                f[d as usize] += cd.nodal[nd][c];
            }
        }
    }
    for (e, &w) in p.elems.iter().zip(&cd.udl) {
        if w == 0.0 {
            continue;
        }
        let eq = to_global(e, &fixed_end(e, w));
        let d = member_dofs(num, e);
        for a in 0..6 {
            if d[a] >= 0 {
                f[d[a] as usize] -= eq[a];
            }
        }
    }
    sky.solve(&mut f);

    // Displacements (global, 0 at restrained DOFs).
    let mut u = vec![0.0; 3 * nn];
    for (k, uk) in u.iter_mut().enumerate() {
        let d = num.free[k];
        if d >= 0 {
            *uk = f[d as usize];
        }
    }

    // Member end forces, stations, nodal force accumulation.
    let mut acc = vec![[0.0f64; 3]; nn];
    let mut members = Vec::with_capacity(p.elems.len());
    let (mut sx, mut sy) = (0.0f64, 0.0f64);
    let mut mag = 1.0f64;
    // Spring support forces act on the structure as -k*u (reactions for the equilibrium check).
    for nd in 0..nn {
        let (fx, fy) = (-p.springs[nd][0] * u[3 * nd], -p.springs[nd][1] * u[3 * nd + 1]);
        sx += fx;
        sy += fy;
        mag += fx.abs() + fy.abs();
    }
    for (e, &w) in p.elems.iter().zip(&cd.udl) {
        let ug = [u[3 * e.ni], u[3 * e.ni + 1], u[3 * e.ni + 2], u[3 * e.nj], u[3 * e.nj + 1], u[3 * e.nj + 2]];
        let ul = to_local(e, &ug);
        let k = local_k(e);
        let ff = fixed_end(e, w);
        let mut ef = [0.0; 6];
        for r in 0..6 {
            ef[r] = (0..6).map(|m| k[r][m] * ul[m]).sum::<f64>() + ff[r];
        }
        let g = to_global(e, &ef);
        for c in 0..3 {
            acc[e.ni][c] += g[c];
            acc[e.nj][c] += g[3 + c];
        }
        let mut stations = Vec::with_capacity(STATIONS);
        for kx in 0..STATIONS {
            let x = e.len * kx as f64 / (STATIONS - 1) as f64;
            stations.push(Station { x, n: -ef[0], v: ef[1] + w * x, m: -ef[2] + ef[1] * x + w * x * x / 2.0 });
        }
        members.push(MemberResult { id: e.id, end_forces: ef, stations });
        if w != 0.0 {
            let (fxg, fyg) = (-e.s * w * e.len, e.c * w * e.len);
            sx += fxg;
            sy += fyg;
            mag += fxg.abs() + fyg.abs();
        }
    }

    let mut reactions = Vec::new();
    for nd in 0..nn {
        let r = &p.restrained[3 * nd..3 * nd + 3];
        let l = &cd.nodal[nd];
        if r.iter().any(|&x| x) {
            let a = &acc[nd];
            let v = |c: usize| if r[c] { a[c] - l[c] } else { 0.0 };
            let rx = Reaction { node: p.nodes[nd].id, fx: v(0), fy: v(1), mz: v(2) };
            sx += rx.fx;
            sy += rx.fy;
            mag += rx.fx.abs() + rx.fy.abs();
            reactions.push(rx);
        }
        sx += l[0];
        sy += l[1];
        mag += l[0].abs() + l[1].abs();
    }

    let displacements = (0..nn)
        .map(|nd| NodeDisp { node: p.nodes[nd].id, ux: u[3 * nd], uy: u[3 * nd + 1], rz: u[3 * nd + 2] })
        .collect();
    CaseResult {
        id: cd.id.to_string(),
        displacements,
        reactions,
        members,
        equilibrium_residual: sx.abs().max(sy.abs()) / mag,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::generator::generate;

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() <= 1e-9 * b.abs().max(1e-3)
    }

    fn beam(supports: Vec<Support>, load: LoadCase, nmem: usize) -> Model {
        let nodes = (0..=nmem)
            .map(|k| Node { id: k as i64 + 1, x: 5.0 * k as f64 / nmem as f64, ..Default::default() })
            .collect();
        let members = (0..nmem)
            .map(|k| Member { id: k as i64 + 1, i: k as i64 + 1, j: k as i64 + 2, material: "s".into(), section: "b".into(), release: Default::default() })
            .collect();
        Model {
            springs: vec![],
            materials: vec![Material { id: "s".into(), e: 200e9 }],
            sections: vec![Section { id: "b".into(), a: 0.01, i: 8e-5 }],
            nodes,
            supports,
            members,
            load_cases: vec![load],
        }
    }

    fn fixed(node: i64) -> Support {
        Support { node, ux: true, uy: true, rz: true }
    }

    #[test]
    fn cantilever_tip_load() {
        let lc = LoadCase {
            id: "P".into(),
            nodal: vec![NodalLoad { node: 2, fy: -10000.0, ..Default::default() }],
            member_udl: vec![],
        };
        let r = solve(&beam(vec![fixed(1)], lc, 1)).unwrap();
        let c = &r.load_cases[0];
        assert!(close(c.displacements[1].uy, -0.026041666666666668));
        assert!(close(c.reactions[0].mz, 50000.0));
        assert!(close(c.reactions[0].fy, 10000.0));
    }

    #[test]
    fn fixed_fixed_udl() {
        let lc = LoadCase {
            id: "D".into(),
            nodal: vec![],
            member_udl: vec![MemberUdl { member: 1, w: -5000.0 }, MemberUdl { member: 2, w: -5000.0 }],
        };
        let r = solve(&beam(vec![fixed(1), fixed(3)], lc, 2)).unwrap();
        let c = &r.load_cases[0];
        assert!(close(c.displacements[1].uy, -0.0005086263020833333));
        assert!(close(c.members[0].stations[0].m, -10416.666666666666));
        assert!(close(c.members[0].stations[10].m, 5208.333333333333));
    }

    #[test]
    fn no_supports_is_unstable() {
        let lc = LoadCase { id: "P".into(), ..Default::default() };
        let e = solve(&beam(vec![], lc, 1)).unwrap_err();
        assert_eq!(e.error, "unstable");
    }

    #[test]
    fn missing_node_is_invalid_ref() {
        let lc = LoadCase { id: "P".into(), ..Default::default() };
        let mut m = beam(vec![fixed(1)], lc, 1);
        m.members[0].j = 99;
        assert_eq!(solve(&m).unwrap_err().error, "invalid_ref");
    }

    #[test]
    fn profiles_match_reference() {
        let r = solve(&generate(10, 10)).unwrap();
        assert_eq!(r.stats.free_dofs, 330);
        assert_eq!(r.stats.profile_before, 10221);
        assert_eq!(r.stats.profile_after, 7575);
        assert!(r.load_cases.iter().all(|c| c.equilibrium_residual < 1e-8));
    }
}
