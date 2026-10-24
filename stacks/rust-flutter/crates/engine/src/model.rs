//! Input model (SPEC 5.1). Unknown fields are ignored so later-phase additions stay readable.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Material {
    pub id: String,
    #[serde(rename = "E")]
    pub e: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    #[serde(rename = "A")]
    pub a: f64,
    #[serde(rename = "I")]
    pub i: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Node {
    pub id: i64,
    pub x: f64,
    pub y: f64,
    #[serde(skip)]
    pub bench_pad: u32, // BENCH-EDIT:struct
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Support {
    pub node: i64,
    #[serde(default)]
    pub ux: bool,
    #[serde(default)]
    pub uy: bool,
    #[serde(default)]
    pub rz: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Member {
    pub id: i64,
    pub i: i64,
    pub j: i64,
    pub material: String,
    pub section: String,
    #[serde(default)]
    pub release: Option<Release>,
}

/// End releases (SPEC 4.7): lists of released components per end; only `mz` is supported.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Release {
    #[serde(default)]
    pub i: Vec<String>,
    #[serde(default)]
    pub j: Vec<String>,
}

impl Member {
    /// `[i end, j end]` rotational release flags.
    pub fn mz_released(&self) -> [bool; 2] {
        let has = |v: &Vec<String>| v.iter().any(|s| s == "mz");
        self.release.as_ref().map_or([false; 2], |r| [has(&r.i), has(&r.j)])
    }
}

/// Spring support (SPEC 4.7): stiffness added to the free DOF's diagonal.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Spring {
    pub node: i64,
    #[serde(default)]
    pub kx: Option<f64>,
    #[serde(default)]
    pub ky: Option<f64>,
    #[serde(default)]
    pub kr: Option<f64>,
}

impl Spring {
    pub fn stiffness(&self) -> [Option<f64>; 3] {
        [self.kx, self.ky, self.kr]
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NodalLoad {
    pub node: i64,
    #[serde(default)]
    pub fx: f64,
    #[serde(default)]
    pub fy: f64,
    #[serde(default)]
    pub mz: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UdlLoad {
    pub member: i64,
    pub w: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LoadCase {
    pub id: String,
    #[serde(default)]
    pub nodal: Vec<NodalLoad>,
    #[serde(default)]
    pub member_udl: Vec<UdlLoad>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
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
    pub springs: Vec<Spring>,
    #[serde(default)]
    pub load_cases: Vec<LoadCase>,
}
