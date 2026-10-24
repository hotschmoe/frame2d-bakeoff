//! `frame2d` CLI (SPEC 5.3): solve, gen, bench.

use frame2d::alloc_count::{self, CountingAlloc};
use frame2d::model::{Model, Results};
use frame2d::{engine, generator};
use std::process::ExitCode;

#[global_allocator]
static ALLOC: CountingAlloc = CountingAlloc;

enum Failure {
    Model(frame2d::model::ModelError),
    Other(String),
}

impl<E: std::fmt::Display> From<E> for Failure {
    fn from(e: E) -> Self {
        Failure::Other(e.to_string())
    }
}

fn solve_counted(model: &Model) -> Result<Results, Failure> {
    alloc_count::reset();
    let r = engine::solve(model);
    let a = alloc_count::snapshot();
    let mut r = r.map_err(Failure::Model)?;
    r.stats.alloc_count = Some(a.count);
    r.stats.alloc_bytes = Some(a.bytes);
    r.stats.peak_heap_bytes = Some(a.peak);
    Ok(r)
}

fn out_path(args: &[String]) -> Option<String> {
    args.iter().position(|a| a == "-o").and_then(|i| args.get(i + 1).cloned())
}

fn emit(text: String, out: Option<String>) -> Result<(), Failure> {
    match out {
        Some(p) => std::fs::write(p, text)?,
        None => println!("{text}"),
    }
    Ok(())
}

fn parse_dim(s: Option<&String>) -> Result<usize, Failure> {
    Ok(s.ok_or("missing B/S argument")?.parse::<usize>()?)
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    v[v.len() / 2]
}

fn run(args: &[String]) -> Result<(), Failure> {
    match args.first().map(String::as_str) {
        Some("solve") => {
            let path = args.get(1).ok_or("usage: frame2d solve <model.json> [-o results.json]")?;
            let model: Model = serde_json::from_slice(&std::fs::read(path)?)?;
            let res = solve_counted(&model)?;
            emit(serde_json::to_string(&res)?, out_path(args))
        }
        Some("gen") => {
            let model = generator::generate(parse_dim(args.get(1))?, parse_dim(args.get(2))?);
            emit(serde_json::to_string(&model)?, out_path(args))
        }
        Some("bench") => {
            let (b, s) = (parse_dim(args.get(1))?, parse_dim(args.get(2))?);
            let reps = match args.iter().position(|a| a == "--reps") {
                Some(i) => args.get(i + 1).ok_or("--reps needs a value")?.parse::<usize>()?.max(1),
                None => 1,
            };
            let model = generator::generate(b, s);
            let mut runs = Vec::new();
            for _ in 0..reps {
                runs.push(solve_counted(&model)?.stats);
            }
            let mut st = runs.last().cloned().unwrap();
            st.assemble_ms = median(runs.iter().map(|r| r.assemble_ms).collect());
            st.factor_ms = median(runs.iter().map(|r| r.factor_ms).collect());
            st.solve_ms = median(runs.iter().map(|r| r.solve_ms).collect());
            println!("{}", serde_json::to_string(&st)?);
            Ok(())
        }
        _ => Err(Failure::Other("usage: frame2d <solve|gen|bench> ...".into())),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(Failure::Model(e)) => {
            println!("{}", serde_json::to_string(&e).unwrap());
            ExitCode::from(2)
        }
        Err(Failure::Other(m)) => {
            eprintln!("error: {m}");
            ExitCode::from(1)
        }
    }
}
