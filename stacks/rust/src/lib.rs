//! Frame2D: 2D frame analysis engine plus clients (CLI, server, egui app).

pub mod alloc_count;
pub mod engine;
pub mod generator;
pub mod model;

#[cfg(feature = "ui")]
pub mod app;
