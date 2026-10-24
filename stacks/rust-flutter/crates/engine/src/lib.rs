//! Frame2D analysis engine: 2D frame direct stiffness method with RCM ordering and a skyline LDL^T solver.

pub mod analysis;
pub mod clock;
pub mod error;
pub mod generate;
pub mod model;
pub mod output;
pub mod rcm;
pub mod skyline;
pub mod topology;

pub use analysis::{analyze, solve, CaseResult, Results, Station, Stats, STATIONS};
pub use error::ModelError;
pub use generate::generate;
pub use model::Model;
pub use topology::Topology;
