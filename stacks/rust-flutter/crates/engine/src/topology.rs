//! Validation, DOF numbering and skyline layout. Depends only on connectivity and restraints, not on
//! coordinates or loads, so it can be built once and reused while a node is dragged.

use std::collections::HashMap;

use crate::error::ModelError;
use crate::model::Model;
use crate::rcm::reverse_cuthill_mckee;

/// Marker for a restrained (eliminated) DOF in `Topology::dof`.
pub const FIXED: i32 = -1;

#[derive(Debug, Clone)]
pub struct Topology {
    /// Model node index of the k-th node in ascending id order.
    pub node_sorted: Vec<usize>,
    /// Model member index of the k-th member in ascending id order.
    pub member_sorted: Vec<usize>,
    /// `[node_index * 3 + comp]` -> free DOF number (RCM order) or `FIXED`.
    pub dof: Vec<i32>,
    /// Model node indices at each member end.
    pub member_nodes: Vec<(usize, usize)>,
    pub member_material: Vec<usize>,
    pub member_section: Vec<usize>,
    pub free_dofs: usize,
    /// Per node: its rotation was restrained automatically because releases left it with no stiffness.
    pub auto_rz: Vec<bool>,
    /// Rotational release flags `[i, j]` per model member.
    pub member_release: Vec<[bool; 2]>,
    /// Column heights (diagonal excluded) and start offsets into skyline storage (diagonal included).
    pub height: Vec<usize>,
    pub col_start: Vec<usize>,
    pub profile_before: u64,
    pub profile_after: u64,
    /// Free DOF -> (node index, component), for error reporting.
    pub dof_owner: Vec<(usize, u8)>,
    pub node_index: HashMap<i64, usize>,
    pub member_index: HashMap<i64, usize>,
}

impl Topology {
    pub fn build(model: &Model) -> Result<Topology, ModelError> {
        let mut node_index = HashMap::with_capacity(model.nodes.len());
        for (k, n) in model.nodes.iter().enumerate() {
            if node_index.insert(n.id, k).is_some() {
                return Err(ModelError::new("duplicate_id", format!("node {}", n.id)));
            }
        }
        let mut member_index = HashMap::with_capacity(model.members.len());
        for (k, m) in model.members.iter().enumerate() {
            if member_index.insert(m.id, k).is_some() {
                return Err(ModelError::new("duplicate_id", format!("member {}", m.id)));
            }
        }
        let material_index: HashMap<&str, usize> =
            model.materials.iter().enumerate().map(|(k, m)| (m.id.as_str(), k)).collect();
        let section_index: HashMap<&str, usize> =
            model.sections.iter().enumerate().map(|(k, s)| (s.id.as_str(), k)).collect();

        let mut member_nodes = Vec::with_capacity(model.members.len());
        let mut member_material = Vec::with_capacity(model.members.len());
        let mut member_section = Vec::with_capacity(model.members.len());
        for m in &model.members {
            let (Some(&i), Some(&j)) = (node_index.get(&m.i), node_index.get(&m.j)) else {
                return Err(ModelError::new("invalid_ref", format!("member {} references a missing node", m.id)));
            };
            let (Some(&mat), Some(&sec)) =
                (material_index.get(m.material.as_str()), section_index.get(m.section.as_str()))
            else {
                return Err(ModelError::new(
                    "invalid_ref",
                    format!("member {} references a missing material or section", m.id),
                ));
            };
            member_nodes.push((i, j));
            member_material.push(mat);
            member_section.push(sec);
        }

        let mut restrained = vec![[false; 3]; model.nodes.len()];
        for s in &model.supports {
            let Some(&k) = node_index.get(&s.node) else {
                return Err(ModelError::new("invalid_ref", format!("support at missing node {}", s.node)));
            };
            restrained[k][0] |= s.ux;
            restrained[k][1] |= s.uy;
            restrained[k][2] |= s.rz;
        }
        for lc in &model.load_cases {
            for l in &lc.nodal {
                if !node_index.contains_key(&l.node) {
                    return Err(ModelError::new("invalid_ref", format!("load on missing node {}", l.node)));
                }
            }
            for l in &lc.member_udl {
                if !member_index.contains_key(&l.member) {
                    return Err(ModelError::new("invalid_ref", format!("load on missing member {}", l.member)));
                }
            }
        }

        for sp in &model.springs {
            let Some(&k) = node_index.get(&sp.node) else {
                return Err(ModelError::new("invalid_ref", format!("spring at missing node {}", sp.node)));
            };
            for (c, name) in ["kx", "ky", "kr"].iter().enumerate() {
                if sp.stiffness()[c].is_some() && restrained[k][c] {
                    return Err(ModelError::new(
                        "support_conflict",
                        format!("node {} {} is both restrained and sprung", sp.node, name),
                    ));
                }
            }
        }

        check_lengths(model, &member_nodes)?;

        // Auto-restraint (SPEC 4.7): a free rotation that only released member ends touch has no stiffness.
        let member_release: Vec<[bool; 2]> = model.members.iter().map(|m| m.mz_released()).collect();
        let mut stiff_rz = vec![false; model.nodes.len()];
        let mut touched = vec![false; model.nodes.len()];
        for (m, &(i, j)) in member_nodes.iter().enumerate() {
            for (node, rel) in [(i, member_release[m][0]), (j, member_release[m][1])] {
                touched[node] = true;
                stiff_rz[node] |= !rel;
            }
        }
        for sp in &model.springs {
            if sp.kr.is_some_and(|k| k > 0.0) {
                stiff_rz[node_index[&sp.node]] = true;
            }
        }
        let mut auto_rz = vec![false; model.nodes.len()];
        for k in 0..model.nodes.len() {
            if !restrained[k][2] && touched[k] && !stiff_rz[k] {
                restrained[k][2] = true;
                auto_rz[k] = true;
            }
        }

        if restrained.iter().all(|r| r.iter().all(|&b| b)) {
            return Err(ModelError::new("no_free_dofs", "every DOF is restrained"));
        }

        let ids: Vec<i64> = model.nodes.iter().map(|n| n.id).collect();
        let mut node_sorted: Vec<usize> = (0..ids.len()).collect();
        node_sorted.sort_by_key(|&k| ids[k]);
        let mut member_sorted: Vec<usize> = (0..model.members.len()).collect();
        member_sorted.sort_by_key(|&k| model.members[k].id);

        // RCM numbering of the free DOFs.
        let rcm = reverse_cuthill_mckee(&ids, &member_nodes);
        let (dof, free_dofs) = number_dofs(rcm.iter().copied(), &restrained);
        let (dof_before, _) = number_dofs(node_sorted.iter().copied(), &restrained);

        let mut dof_owner = vec![(0usize, 0u8); free_dofs];
        for (k, &d) in dof.iter().enumerate() {
            if d >= 0 {
                dof_owner[d as usize] = (k / 3, (k % 3) as u8);
            }
        }

        let height = column_heights(&dof, free_dofs, &member_nodes);
        let profile_after: u64 = height.iter().map(|&h| h as u64).sum();
        let profile_before: u64 =
            column_heights(&dof_before, free_dofs, &member_nodes).iter().map(|&h| h as u64).sum();
        let mut col_start = Vec::with_capacity(free_dofs + 1);
        let mut acc = 0usize;
        for &h in &height {
            col_start.push(acc);
            acc += h + 1;
        }
        col_start.push(acc);

        Ok(Topology {
            node_sorted,
            member_sorted,
            dof,
            member_nodes,
            member_material,
            member_section,
            free_dofs,
            auto_rz,
            member_release,
            height,
            col_start,
            profile_before,
            profile_after,
            dof_owner,
            node_index,
            member_index,
        })
    }

    /// Six DOF numbers of a member (`FIXED` where restrained): i.ux, i.uy, i.rz, j.ux, j.uy, j.rz.
    pub fn member_dofs(&self, member: usize) -> [i32; 6] {
        let (i, j) = self.member_nodes[member];
        let d = &self.dof;
        [d[i * 3], d[i * 3 + 1], d[i * 3 + 2], d[j * 3], d[j * 3 + 1], d[j * 3 + 2]]
    }

    pub fn skyline_len(&self) -> usize {
        *self.col_start.last().unwrap()
    }
}

/// Fails with `zero_length` when a member's end nodes coincide.
pub fn check_lengths(model: &Model, member_nodes: &[(usize, usize)]) -> Result<(), ModelError> {
    for (k, &(i, j)) in member_nodes.iter().enumerate() {
        let (a, b) = (&model.nodes[i], &model.nodes[j]);
        if (b.x - a.x).hypot(b.y - a.y) < 1e-9 {
            return Err(ModelError::new("zero_length", format!("member {}", model.members[k].id)));
        }
    }
    Ok(())
}

fn number_dofs(order: impl Iterator<Item = usize>, restrained: &[[bool; 3]]) -> (Vec<i32>, usize) {
    let mut dof = vec![FIXED; restrained.len() * 3];
    let mut next = 0i32;
    for node in order {
        for c in 0..3 {
            if !restrained[node][c] {
                dof[node * 3 + c] = next;
                next += 1;
            }
        }
    }
    (dof, next as usize)
}

/// Height of column j = j - (lowest free DOF coupled to j by any member).
fn column_heights(dof: &[i32], free: usize, member_nodes: &[(usize, usize)]) -> Vec<usize> {
    let mut low: Vec<usize> = (0..free).collect();
    for &(i, j) in member_nodes {
        let mut dofs = [0usize; 6];
        let mut count = 0;
        for node in [i, j] {
            for c in 0..3 {
                let d = dof[node * 3 + c];
                if d >= 0 {
                    dofs[count] = d as usize;
                    count += 1;
                }
            }
        }
        if count == 0 {
            continue;
        }
        let lo = dofs[..count].iter().copied().min().unwrap();
        for &d in &dofs[..count] {
            low[d] = low[d].min(lo);
        }
    }
    low.iter().enumerate().map(|(j, &l)| j - l).collect()
}
