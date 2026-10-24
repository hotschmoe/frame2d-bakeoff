//! Engine unit tests: closed-form beams, error codes, generator statistics, factorization against a dense solve.

use frame2d_engine::*;

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() <= 1e-12f64.max(1e-9 * b.abs())
}

/// Builds a model along +X with `n` equal members of length `len / n`.
fn beam(n: usize, len: f64, supports: &[(i64, bool, bool, bool)]) -> Model {
    let mut m = Model::default();
    m.materials.push(model::Material { id: "steel".into(), e: 200e9 });
    m.sections.push(model::Section { id: "BM".into(), a: 0.01, i: 8e-5 });
    for k in 0..=n {
        m.nodes.push(model::Node { id: k as i64 + 1, x: len * k as f64 / n as f64, y: 0.0, ..Default::default() });
    }
    for k in 0..n {
        m.members.push(model::Member {
            id: k as i64 + 1,
            i: k as i64 + 1,
            j: k as i64 + 2,
            material: "steel".into(),
            section: "BM".into(),
            release: None,
        });
    }
    for &(node, ux, uy, rz) in supports {
        m.supports.push(model::Support { node, ux, uy, rz });
    }
    m
}

fn case(id: &str, nodal: Vec<model::NodalLoad>, udl: Vec<model::UdlLoad>) -> model::LoadCase {
    model::LoadCase { id: id.into(), nodal, member_udl: udl }
}

#[test]
fn cantilever_tip_load() {
    let mut m = beam(1, 5.0, &[(1, true, true, true)]);
    m.load_cases.push(case("P", vec![model::NodalLoad { node: 2, fy: -10000.0, ..Default::default() }], vec![]));
    let r = solve(&m).unwrap();
    let c = &r.cases[0];
    assert!(close(c.disp[4], -0.026041666666666668), "tip uy {}", c.disp[4]);
    assert!(close(c.disp[5], -0.0078125));
    assert!(close(c.reactions[0].fy, 10000.0));
    assert!(close(c.reactions[0].mz, 50000.0));
    assert!(c.equilibrium_residual < 1e-12);
}

#[test]
fn simply_supported_udl_midspan_moment() {
    let mut m = beam(2, 5.0, &[(1, true, true, false), (3, false, true, false)]);
    m.load_cases.push(case("D", vec![], vec![model::UdlLoad { member: 1, w: -5000.0 }, model::UdlLoad { member: 2, w: -5000.0 }]));
    let r = solve(&m).unwrap();
    assert!(close(r.cases[0].disp[3 + 1], -0.002543131510416667));
    assert!(close(r.station(0, 0, 10).m, 15625.0));
    assert!(close(r.cases[0].reactions[0].fy, 12500.0));
}

#[test]
fn factorization_runs_once_for_many_load_cases() {
    let mut m = beam(2, 5.0, &[(1, true, true, true), (3, true, true, true)]);
    m.load_cases.push(case("P", vec![model::NodalLoad { node: 2, fy: -10000.0, ..Default::default() }], vec![]));
    m.load_cases.push(case("Z", vec![], vec![]));
    let r = solve(&m).unwrap();
    assert_eq!(r.cases.len(), 2);
    assert!(close(r.cases[0].disp[4], -0.0004069010416666667));
    assert!(r.cases[1].disp.iter().all(|&v| v == 0.0));
}

#[test]
fn error_codes() {
    let free = beam(1, 5.0, &[]);
    assert_eq!(solve(&free).unwrap_err().code, "unstable");

    let mut missing = beam(1, 5.0, &[(1, true, true, true)]);
    missing.members[0].j = 99;
    assert_eq!(solve(&missing).unwrap_err().code, "invalid_ref");

    let mut zero = beam(1, 5.0, &[(1, true, true, true)]);
    zero.nodes[1].x = 0.0;
    assert_eq!(solve(&zero).unwrap_err().code, "zero_length");

    let mut dup = beam(1, 5.0, &[(1, true, true, true)]);
    dup.nodes[1].id = 1;
    assert_eq!(solve(&dup).unwrap_err().code, "duplicate_id");

    let all = beam(1, 5.0, &[(1, true, true, true), (2, true, true, true)]);
    assert_eq!(solve(&all).unwrap_err().code, "no_free_dofs");
}

#[test]
fn generator_profile_statistics() {
    let m = generate(10, 10);
    assert_eq!((m.nodes.len(), m.members.len()), (121, 210));
    let r = solve(&m).unwrap();
    assert_eq!(r.stats.free_dofs, 330);
    assert_eq!(r.stats.profile_before, 10221);
    assert_eq!(r.stats.profile_after, 7575);
    for c in &r.cases {
        assert!(c.equilibrium_residual < 1e-8, "{}", c.equilibrium_residual);
    }
}

#[test]
fn generator_ids_follow_spec() {
    let m = generate(2, 3);
    assert_eq!(m.nodes[0].id, 1);
    assert_eq!(m.nodes[3].id, 4); // level 1, first column line
    // columns first (by column line, bottom to top), then beams (by level, left to right)
    assert_eq!((m.members[0].i, m.members[0].j), (1, 4));
    assert_eq!((m.members[3].i, m.members[3].j), (2, 5));
    assert_eq!((m.members[9].i, m.members[9].j), (4, 5));
    assert_eq!(m.load_cases[2].nodal.len(), 3);
}

#[test]
fn rcm_orders_every_component_deterministically() {
    // Two disjoint chains: 10-20-30 and 5-6.
    let ids = [10, 20, 30, 5, 6];
    let edges = [(0, 1), (1, 2), (3, 4), (1, 0)];
    let a = rcm::reverse_cuthill_mckee(&ids, &edges);
    let b = rcm::reverse_cuthill_mckee(&ids, &edges);
    assert_eq!(a, b);
    let mut sorted = a.clone();
    sorted.sort();
    assert_eq!(sorted, vec![0, 1, 2, 3, 4]);
    // Component of node id 5 comes first before reversal, so it is last after.
    assert_eq!(&a[3..], &[4, 3]);
}

#[test]
fn skyline_matches_dense_solve() {
    // Small SPD matrix with a non-trivial profile.
    let dense = [
        [4.0, 1.0, 0.0, 0.0],
        [1.0, 5.0, 2.0, 0.0],
        [0.0, 2.0, 6.0, 1.0],
        [0.0, 0.0, 1.0, 3.0],
    ];
    let height = [0usize, 1, 1, 1];
    let mut col_start = vec![0usize];
    for h in &height {
        col_start.push(col_start.last().unwrap() + h + 1);
    }
    let mut sky = skyline::Skyline::zeros(&height, &col_start);
    for j in 0..4 {
        for i in (j - height[j])..=j {
            sky.add(i, j, dense[i][j]);
        }
    }
    sky.factor().unwrap();
    let b = [1.0, 2.0, 3.0, 4.0];
    let mut x = b;
    sky.solve(&mut x);
    for i in 0..4 {
        let row: f64 = (0..4).map(|j| dense[i][j] * x[j]).sum();
        assert!((row - b[i]).abs() < 1e-12, "row {i}: {row}");
    }
}

#[test]
fn results_json_has_expected_shape() {
    let mut m = beam(1, 5.0, &[(1, true, true, true)]);
    m.load_cases.push(case("P", vec![model::NodalLoad { node: 2, fy: -10000.0, ..Default::default() }], vec![]));
    let r = solve(&m).unwrap();
    let v: serde_json::Value = serde_json::to_value(&r).unwrap();
    let lc = &v["load_cases"][0];
    assert_eq!(lc["id"], "P");
    assert_eq!(lc["members"][0]["stations"].as_array().unwrap().len(), 11);
    assert_eq!(lc["members"][0]["end_forces"].as_array().unwrap().len(), 6);
    assert!(v["stats"]["alloc_count"].is_null());
    assert_eq!(v["warnings"].as_array().unwrap().len(), 0);
}
