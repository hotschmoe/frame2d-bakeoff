//! Deterministic B-bay x S-story moment frame generator (SPEC 4.8).

use crate::model::*;

pub fn generate(bays: usize, stories: usize) -> Model {
    let node_id = |b: usize, s: usize| (s * (bays + 1) + b + 1) as i64;

    let mut nodes = Vec::with_capacity((bays + 1) * (stories + 1));
    for s in 0..=stories {
        for b in 0..=bays {
            nodes.push(Node { id: node_id(b, s), x: 6.0 * b as f64, y: 3.5 * s as f64, ..Default::default() });
        }
    }

    let member = |id: i64, i: i64, j: i64, section: &str| Member {
        id,
        i,
        j,
        material: "steel".into(),
        section: section.into(),
    };
    let mut members = Vec::with_capacity(bays * stories + (bays + 1) * stories);
    let mut next_id = 1i64;
    for b in 0..=bays {
        for s in 0..stories {
            members.push(member(next_id, node_id(b, s), node_id(b, s + 1), "COL"));
            next_id += 1;
        }
    }
    let mut beam_ids = Vec::with_capacity(bays * stories);
    for s in 1..=stories {
        for b in 0..bays {
            members.push(member(next_id, node_id(b, s), node_id(b + 1, s), "BM"));
            beam_ids.push(next_id);
            next_id += 1;
        }
    }

    let udl = |w: f64| beam_ids.iter().map(|&m| UdlLoad { member: m, w }).collect::<Vec<_>>();
    let wind = (1..=stories)
        .map(|s| NodalLoad { node: node_id(0, s), fx: 15000.0, fy: 0.0, mz: 0.0 })
        .collect();

    Model {
        materials: vec![Material { id: "steel".into(), e: 200e9 }],
        sections: vec![
            Section { id: "COL".into(), a: 0.015, i: 1.2e-4 },
            Section { id: "BM".into(), a: 0.010, i: 8.0e-5 },
        ],
        nodes,
        supports: (0..=bays)
            .map(|b| Support { node: node_id(b, 0), ux: true, uy: true, rz: true })
            .collect(),
        members,
        load_cases: vec![
            LoadCase { id: "D".into(), nodal: vec![], member_udl: udl(-20000.0) },
            LoadCase { id: "L".into(), nodal: vec![], member_udl: udl(-10000.0) },
            LoadCase { id: "W".into(), nodal: wind, member_udl: vec![] },
        ],
    }
}
