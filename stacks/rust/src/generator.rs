//! Deterministic B-bay x S-story moment frame generator (SPEC 4.8).

use crate::model::*;

pub fn generate(bays: usize, stories: usize) -> Model {
    let (bw, sh) = (6.0, 3.5);
    let id = |s: usize, b: usize| (s * (bays + 1) + b + 1) as i64;
    let mut nodes = Vec::with_capacity((bays + 1) * (stories + 1));
    for s in 0..=stories {
        for b in 0..=bays {
            nodes.push(Node { id: id(s, b), x: b as f64 * bw, y: s as f64 * sh, ..Default::default() });
        }
    }
    let supports = (0..=bays).map(|b| Support { node: id(0, b), ux: true, uy: true, rz: true }).collect();
    let mut members: Vec<Member> = Vec::with_capacity(bays * (stories + 1) + stories * (bays + 1));
    let mut push = |i: i64, j: i64, sec: &str| -> i64 {
        let mid = members.len() as i64 + 1;
        members.push(Member { id: mid, i, j, material: "steel".into(), section: sec.into(), release: Default::default() });
        mid
    };
    for b in 0..=bays {
        for s in 0..stories {
            push(id(s, b), id(s + 1, b), "COL");
        }
    }
    let mut beams = Vec::new();
    for s in 1..=stories {
        for b in 0..bays {
            beams.push(push(id(s, b), id(s, b + 1), "BM"));
        }
    }
    let udl = |w: f64| beams.iter().map(|&m| MemberUdl { member: m, w }).collect();
    let load_cases = vec![
        LoadCase { id: "D".into(), nodal: vec![], member_udl: udl(-20000.0) },
        LoadCase { id: "L".into(), nodal: vec![], member_udl: udl(-10000.0) },
        LoadCase {
            id: "W".into(),
            nodal: (1..=stories).map(|s| NodalLoad { node: id(s, 0), fx: 15000.0, fy: 0.0, mz: 0.0 }).collect(),
            member_udl: vec![],
        },
    ];
    Model {
        springs: Vec::new(),
        materials: vec![Material { id: "steel".into(), e: 200e9 }],
        sections: vec![Section { id: "COL".into(), a: 0.015, i: 1.2e-4 }, Section { id: "BM".into(), a: 0.010, i: 8.0e-5 }],
        nodes,
        supports,
        members,
        load_cases,
    }
}

/// Id of the top-left node (highest y, then lowest x): the roof drift probe of SPEC 5.4.
pub fn top_left_node(model: &Model) -> Option<i64> {
    model
        .nodes
        .iter()
        .max_by(|a, b| a.y.total_cmp(&b.y).then(b.x.total_cmp(&a.x)).then(b.id.cmp(&a.id)))
        .map(|n| n.id)
}
