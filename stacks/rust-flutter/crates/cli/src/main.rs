//! `frame2d` command line: solve / gen / bench (SPEC 5.3).

mod alloc;

use std::fs;
use std::io::{BufWriter, Write};
use std::process::ExitCode;

use frame2d_engine::{generate, solve, Model, ModelError, Results, Stats};

#[global_allocator]
static ALLOC: alloc::Counting = alloc::Counting;

const USAGE: &str = "usage:\n  frame2d solve <model.json> [-o results.json]\n  frame2d gen <B> <S> [-o model.json]\n  frame2d bench <B> <S> [--reps N]";

enum Failure {
    /// A model error: JSON on stdout, exit 2.
    Model(ModelError),
    /// Anything else: message on stderr, exit 1.
    Other(String),
}

impl From<ModelError> for Failure {
    fn from(e: ModelError) -> Self {
        Failure::Model(e)
    }
}

fn other<E: std::fmt::Display>(e: E) -> Failure {
    Failure::Other(e.to_string())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(Failure::Model(e)) => {
            println!("{}", e.to_json());
            ExitCode::from(2)
        }
        Err(Failure::Other(msg)) => {
            eprintln!("error: {msg}\n{USAGE}");
            ExitCode::from(1)
        }
    }
}

fn run(args: &[String]) -> Result<(), Failure> {
    match args.first().map(String::as_str) {
        Some("solve") => cmd_solve(&args[1..]),
        Some("gen") => cmd_gen(&args[1..]),
        Some("bench") => cmd_bench(&args[1..]),
        _ => Err(Failure::Other("unknown or missing command".into())),
    }
}

/// Splits option flags (each taking one value) from positional arguments.
fn parse<'a>(args: &'a [String], flags: &[&str]) -> Result<(Vec<&'a str>, Vec<Option<&'a str>>), Failure> {
    let mut positional = Vec::new();
    let mut values = vec![None; flags.len()];
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if let Some(slot) = flags.iter().position(|f| f == a) {
            values[slot] = Some(it.next().ok_or_else(|| other(format!("{a} needs a value")))?.as_str());
        } else if a.starts_with('-') {
            return Err(other(format!("unknown option {a}")));
        } else {
            positional.push(a.as_str());
        }
    }
    Ok((positional, values))
}

fn write_json<T: serde::Serialize>(value: &T, out: Option<&str>) -> Result<(), Failure> {
    match out {
        Some(path) => {
            let mut w = BufWriter::new(fs::File::create(path).map_err(other)?);
            serde_json::to_writer(&mut w, value).map_err(other)?;
            w.flush().map_err(other)
        }
        None => {
            let mut w = BufWriter::new(std::io::stdout().lock());
            serde_json::to_writer(&mut w, value).map_err(other)?;
            writeln!(w).map_err(other)?;
            w.flush().map_err(other)
        }
    }
}

fn cmd_solve(args: &[String]) -> Result<(), Failure> {
    let (pos, vals) = parse(args, &["-o"])?;
    let [path] = pos[..] else { return Err(other("solve takes one model file")) };
    let text = fs::read_to_string(path).map_err(other)?;
    let model: Model = serde_json::from_str(&text).map_err(other)?;
    let results = solve_counted(&model)?;
    write_json(&results, vals[0])
}

/// Solves once, recording allocator statistics for just the solve (SPEC 5.2).
fn solve_counted(model: &Model) -> Result<Results, ModelError> {
    let baseline = alloc::reset();
    let result = solve(model);
    let snap = alloc::snapshot(baseline);
    result.map(|mut r| {
        r.stats.alloc_count = Some(snap.count);
        r.stats.alloc_bytes = Some(snap.bytes);
        r.stats.peak_heap_bytes = Some(snap.peak);
        r
    })
}

fn size_arg(s: &str) -> Result<usize, Failure> {
    s.parse().map_err(|_| other(format!("not a size: {s}")))
}

fn cmd_gen(args: &[String]) -> Result<(), Failure> {
    let (pos, vals) = parse(args, &["-o"])?;
    let [b, s] = pos[..] else { return Err(other("gen takes <B> <S>")) };
    write_json(&generate(size_arg(b)?, size_arg(s)?), vals[0])
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

fn cmd_bench(args: &[String]) -> Result<(), Failure> {
    let (pos, vals) = parse(args, &["--reps"])?;
    let [b, s] = pos[..] else { return Err(other("bench takes <B> <S>")) };
    let reps: usize = vals[0].map_or(Ok(5), |v| v.parse()).map_err(other)?;
    if reps == 0 {
        return Err(other("--reps must be at least 1"));
    }
    let (b, s) = (size_arg(b)?, size_arg(s)?);

    let mut runs: Vec<Stats> = Vec::with_capacity(reps);
    for _ in 0..reps {
        let model = generate(b, s);
        runs.push(solve_counted(&model)?.stats);
    }
    let pick = |f: fn(&Stats) -> f64| median(runs.iter().map(f).collect());
    let last = runs.last().unwrap();
    let out = serde_json::json!({
        "bays": b, "stories": s, "reps": reps,
        "nodes": last.nodes, "members": last.members, "free_dofs": last.free_dofs,
        "profile_before": last.profile_before, "profile_after": last.profile_after,
        "assemble_ms": pick(|r| r.assemble_ms),
        "factor_ms": pick(|r| r.factor_ms),
        "solve_ms": pick(|r| r.solve_ms),
        "alloc_count": last.alloc_count, "alloc_bytes": last.alloc_bytes, "peak_heap_bytes": last.peak_heap_bytes,
        "runs": runs,
    });
    println!("{out}");
    Ok(())
}
