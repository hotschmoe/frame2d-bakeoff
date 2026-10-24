//! Parametric sweep (SPEC 5.4): scale every `BM` section's I across N variants and solve them on all cores.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

use frame2d_engine::{analyze, Model, ModelError, Topology};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct SweepRequest {
    pub model: Option<Model>,
    pub model_id: Option<String>,
    pub variants: usize,
    #[serde(rename = "beam_I_scale")]
    pub beam_i_scale: Option<[f64; 2]>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Variant {
    pub scale: f64,
    #[serde(rename = "roof_drift_W")]
    pub roof_drift_w: f64,
    #[serde(rename = "max_abs_M")]
    pub max_abs_m: f64,
}

#[derive(Debug, Serialize)]
pub struct Envelope {
    #[serde(rename = "max_roof_drift_W")]
    pub max_roof_drift_w: f64,
    #[serde(rename = "max_abs_M")]
    pub max_abs_m: f64,
}

#[derive(Debug, Serialize)]
pub struct SweepResult {
    pub variants: Vec<Variant>,
    pub envelope: Envelope,
}

/// Variant k of n scales by `lo + (hi - lo) * k / (n - 1)`.
pub fn scale_of(k: usize, n: usize, lo: f64, hi: f64) -> f64 {
    if n <= 1 {
        lo
    } else {
        lo + (hi - lo) * k as f64 / (n - 1) as f64
    }
}

/// Index of the top-left node: highest y, then lowest x, then lowest id.
fn top_left_node(model: &Model) -> Option<usize> {
    (0..model.nodes.len()).min_by(|&a, &b| {
        let (na, nb) = (&model.nodes[a], &model.nodes[b]);
        nb.y.total_cmp(&na.y).then(na.x.total_cmp(&nb.x)).then(na.id.cmp(&nb.id))
    })
}

pub fn run(model: &Model, count: usize, range: [f64; 2]) -> Result<SweepResult, ModelError> {
    let topo = Topology::build(model)?;
    let roof = top_left_node(model).ok_or_else(|| ModelError::new("invalid_ref", "model has no nodes"))?;
    let roof_slot = topo.node_sorted.iter().position(|&n| n == roof).unwrap();
    let wind_case = model.load_cases.iter().position(|c| c.id == "W");

    let threads = std::thread::available_parallelism().map_or(1, |n| n.get()).min(count.max(1));
    let next = AtomicUsize::new(0);
    let slots: Mutex<Vec<Option<Variant>>> = Mutex::new(vec![None; count]);
    let failure: Mutex<Option<ModelError>> = Mutex::new(None);

    std::thread::scope(|scope| {
        for _ in 0..threads {
            scope.spawn(|| {
                let mut local = model.clone();
                let base: Vec<f64> = model.sections.iter().map(|s| s.i).collect();
                loop {
                    let k = next.fetch_add(1, Ordering::Relaxed);
                    if k >= count || failure.lock().unwrap().is_some() {
                        break;
                    }
                    let scale = scale_of(k, count, range[0], range[1]);
                    for (s, b) in local.sections.iter_mut().zip(&base) {
                        s.i = if s.id == "BM" { b * scale } else { *b };
                    }
                    match analyze(&local, &topo, None) {
                        Ok(r) => {
                            let drift = wind_case.map_or(0.0, |c| r.cases[c].disp[roof_slot * 3]);
                            let v = Variant { scale, roof_drift_w: drift, max_abs_m: r.max_abs_moment() };
                            slots.lock().unwrap()[k] = Some(v);
                        }
                        Err(e) => {
                            *failure.lock().unwrap() = Some(e);
                            break;
                        }
                    }
                }
            });
        }
    });

    if let Some(e) = failure.into_inner().unwrap() {
        return Err(e);
    }
    let variants: Vec<Variant> = slots.into_inner().unwrap().into_iter().flatten().collect();
    let envelope = Envelope {
        max_roof_drift_w: variants.iter().map(|v| v.roof_drift_w).fold(f64::NEG_INFINITY, f64::max),
        max_abs_m: variants.iter().map(|v| v.max_abs_m).fold(0.0, f64::max),
    };
    Ok(SweepResult { variants, envelope })
}

#[cfg(test)]
mod tests {
    use super::*;
    use frame2d_engine::generate;

    #[test]
    fn scale_follows_the_spec_formula() {
        assert_eq!(scale_of(0, 1000, 0.5, 2.0), 0.5);
        assert_eq!(scale_of(999, 1000, 0.5, 2.0), 2.0);
        assert!((scale_of(1, 3, 1.0, 3.0) - 2.0).abs() < 1e-15);
        assert_eq!(scale_of(0, 1, 0.5, 2.0), 0.5);
    }

    #[test]
    fn stiffer_beams_reduce_roof_drift() {
        let result = run(&generate(4, 4), 8, [0.5, 2.0]).unwrap();
        assert_eq!(result.variants.len(), 8);
        let drifts: Vec<f64> = result.variants.iter().map(|v| v.roof_drift_w).collect();
        assert!(drifts.windows(2).all(|w| w[1] < w[0]), "{drifts:?}");
        assert_eq!(result.envelope.max_roof_drift_w, drifts[0]);
        assert!(result.envelope.max_abs_m > 0.0);
    }

    #[test]
    fn model_errors_propagate() {
        let mut model = generate(2, 2);
        model.supports.clear();
        assert_eq!(run(&model, 3, [1.0, 1.0]).unwrap_err().code, "unstable");
    }
}
