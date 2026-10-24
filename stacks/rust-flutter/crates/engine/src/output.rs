//! Results JSON (SPEC 5.2). Stations are derived from end forces while serializing, so large results are
//! streamed without building per-station objects.

use serde::ser::{SerializeSeq, SerializeStruct};
use serde::{Serialize, Serializer};

use crate::analysis::{CaseResult, Results, STATIONS};

impl Serialize for Results {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut s = ser.serialize_struct("Results", 3)?;
        s.serialize_field("load_cases", &Cases(self))?;
        s.serialize_field("warnings", &self.warnings)?;
        s.serialize_field("stats", &self.stats)?;
        s.end()
    }
}

struct Cases<'a>(&'a Results);

impl Serialize for Cases<'_> {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut seq = ser.serialize_seq(Some(self.0.cases.len()))?;
        for case in &self.0.cases {
            seq.serialize_element(&Case { results: self.0, case })?;
        }
        seq.end()
    }
}

struct Case<'a> {
    results: &'a Results,
    case: &'a CaseResult,
}

impl Serialize for Case<'_> {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut s = ser.serialize_struct("Case", 5)?;
        s.serialize_field("id", &self.case.id)?;
        s.serialize_field("displacements", &Displacements(self))?;
        s.serialize_field("reactions", &self.case.reactions)?;
        s.serialize_field("members", &Members(self))?;
        s.serialize_field("equilibrium_residual", &self.case.equilibrium_residual)?;
        s.end()
    }
}

struct Displacements<'a, 'b>(&'a Case<'b>);

impl Serialize for Displacements<'_, '_> {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let r = self.0.results;
        let mut seq = ser.serialize_seq(Some(r.node_ids.len()))?;
        for (k, &id) in r.node_ids.iter().enumerate() {
            let u = &self.0.case.disp[k * 3..k * 3 + 3];
            seq.serialize_element(&Displacement { node: id, ux: u[0], uy: u[1], rz: u[2] })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct Displacement {
    node: i64,
    ux: f64,
    uy: f64,
    rz: f64,
}

struct Members<'a, 'b>(&'a Case<'b>);

impl Serialize for Members<'_, '_> {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let r = self.0.results;
        let mut seq = ser.serialize_seq(Some(r.member_ids.len()))?;
        for member in 0..r.member_ids.len() {
            seq.serialize_element(&Member { case: self.0, member })?;
        }
        seq.end()
    }
}

struct Member<'a, 'b> {
    case: &'a Case<'b>,
    member: usize,
}

impl Serialize for Member<'_, '_> {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut s = ser.serialize_struct("Member", 3)?;
        s.serialize_field("id", &self.case.results.member_ids[self.member])?;
        s.serialize_field("end_forces", &self.case.case.end_forces[self.member * 6..self.member * 6 + 6])?;
        s.serialize_field("stations", &Stations { case: self.case, member: self.member })?;
        s.end()
    }
}

struct Stations<'a, 'b> {
    case: &'a Case<'b>,
    member: usize,
}

impl Serialize for Stations<'_, '_> {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let len = self.case.results.member_length[self.member];
        let mut seq = ser.serialize_seq(Some(STATIONS))?;
        for k in 0..STATIONS {
            let st = self.case.case.station(self.member, len, k);
            seq.serialize_element(&StationOut { x: st.x, n: st.n, v: st.v, m: st.m })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct StationOut {
    x: f64,
    #[serde(rename = "N")]
    n: f64,
    #[serde(rename = "V")]
    v: f64,
    #[serde(rename = "M")]
    m: f64,
}
