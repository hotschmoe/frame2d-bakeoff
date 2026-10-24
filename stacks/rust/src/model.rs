//! Model and results types (SPEC 5.1, 5.2) plus the model error type (SPEC 4.6).

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Material {
    pub id: String,
    #[serde(rename = "E")]
    pub e: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    #[serde(rename = "A")]
    pub a: f64,
    #[serde(rename = "I")]
    pub i: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Node {
    pub id: i64,
    pub x: f64,
    pub y: f64,
    #[serde(skip)]
    pub bench_pad: u32, // BENCH-EDIT:struct
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Support {
    pub node: i64,
    #[serde(default)]
    pub ux: bool,
    #[serde(default)]
    pub uy: bool,
    #[serde(default)]
    pub rz: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Member {
    pub id: i64,
    pub i: i64,
    pub j: i64,
    pub material: String,
    pub section: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct NodalLoad {
    pub node: i64,
    #[serde(default)]
    pub fx: f64,
    #[serde(default)]
    pub fy: f64,
    #[serde(default)]
    pub mz: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MemberUdl {
    pub member: i64,
    pub w: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct LoadCase {
    pub id: String,
    #[serde(default)]
    pub nodal: Vec<NodalLoad>,
    #[serde(default)]
    pub member_udl: Vec<MemberUdl>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Model {
    #[serde(default)]
    pub materials: Vec<Material>,
    #[serde(default)]
    pub sections: Vec<Section>,
    #[serde(default)]
    pub nodes: Vec<Node>,
    #[serde(default)]
    pub supports: Vec<Support>,
    #[serde(default)]
    pub members: Vec<Member>,
    #[serde(default)]
    pub load_cases: Vec<LoadCase>,
}

/// A model error: serializes as `{"error": code, "detail": detail}`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ModelError {
    pub error: String,
    pub detail: String,
}

impl ModelError {
    pub fn new(code: &str, detail: impl Into<String>) -> Self {
        ModelError { error: code.to_string(), detail: detail.into() }
    }
}

impl std::fmt::Display for ModelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.error, self.detail)
    }
}

impl std::error::Error for ModelError {}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct NodeDisp {
    pub node: i64,
    pub ux: f64,
    pub uy: f64,
    pub rz: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Reaction {
    pub node: i64,
    pub fx: f64,
    pub fy: f64,
    pub mz: f64,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
pub struct Station {
    pub x: f64,
    #[serde(rename = "N")]
    pub n: f64,
    #[serde(rename = "V")]
    pub v: f64,
    #[serde(rename = "M")]
    pub m: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MemberResult {
    pub id: i64,
    pub end_forces: [f64; 6],
    pub stations: Vec<Station>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CaseResult {
    pub id: String,
    pub displacements: Vec<NodeDisp>,
    pub reactions: Vec<Reaction>,
    pub members: Vec<MemberResult>,
    pub equilibrium_residual: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Stats {
    pub nodes: usize,
    pub members: usize,
    pub free_dofs: usize,
    pub profile_before: usize,
    pub profile_after: usize,
    pub assemble_ms: f64,
    pub factor_ms: f64,
    pub solve_ms: f64,
    pub alloc_count: Option<u64>,
    pub alloc_bytes: Option<u64>,
    pub peak_heap_bytes: Option<u64>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Results {
    pub load_cases: Vec<CaseResult>,
    pub warnings: Vec<serde_json::Value>,
    pub stats: Stats,
}
