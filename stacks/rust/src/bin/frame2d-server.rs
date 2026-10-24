//! `frame2d-server` (SPEC 5.4): axum + tokio, models stored in SQLite, concurrent sweeps.

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{header, HeaderName, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use frame2d::generator::top_left_node;
use frame2d::model::{Model, ModelError};
use frame2d::engine;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const SERVER_HEADER: &str = "x-frame2d: a"; // BENCH-EDIT:server
const BODY_LIMIT: usize = 64 * 1024 * 1024;

#[derive(Clone)]
struct AppState {
    db: Arc<Mutex<Connection>>,
}

/// Everything a handler can fail with, mapped to an HTTP status and a JSON error body.
enum ApiError {
    Model(ModelError),
    BadRequest(String),
    NotFound(String),
    Internal(String),
}

impl From<ModelError> for ApiError {
    fn from(e: ModelError) -> Self {
        ApiError::Model(e)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, body) = match self {
            ApiError::Model(e) => (StatusCode::UNPROCESSABLE_ENTITY, serde_json::to_value(e).unwrap()),
            ApiError::BadRequest(d) => (StatusCode::BAD_REQUEST, serde_json::json!({"error": "bad_request", "detail": d})),
            ApiError::NotFound(d) => (StatusCode::NOT_FOUND, serde_json::json!({"error": "not_found", "detail": d})),
            ApiError::Internal(d) => (StatusCode::INTERNAL_SERVER_ERROR, serde_json::json!({"error": "internal", "detail": d})),
        };
        (status, Json(body)).into_response()
    }
}

type ApiResult<T> = Result<T, ApiError>;

fn json_bytes(body: Vec<u8>) -> Response {
    ([(header::CONTENT_TYPE, "application/json")], body).into_response()
}

fn parse_model(body: &[u8]) -> ApiResult<Model> {
    serde_json::from_slice(body).map_err(|e| ApiError::BadRequest(format!("invalid model JSON: {e}")))
}

/// Run CPU-bound work off the async executor.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> ApiResult<T> + Send + 'static) -> ApiResult<T> {
    tokio::task::spawn_blocking(f).await.map_err(|e| ApiError::Internal(e.to_string()))?
}

fn solve_to_json(model: &Model) -> ApiResult<Vec<u8>> {
    let res = engine::solve(model)?;
    serde_json::to_vec(&res).map_err(|e| ApiError::Internal(e.to_string()))
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({"ok": true}))
}

async fn solve_handler(body: Bytes) -> ApiResult<Response> {
    let out = blocking(move || solve_to_json(&parse_model(&body)?)).await?;
    let (name, value) = SERVER_HEADER.split_once(": ").unwrap();
    let mut resp = json_bytes(out);
    resp.headers_mut()
        .insert(HeaderName::from_static(name), HeaderValue::from_str(value).unwrap());
    Ok(resp)
}

async fn create_model(State(st): State<AppState>, body: Bytes) -> ApiResult<Json<serde_json::Value>> {
    parse_model(&body)?;
    let text = String::from_utf8(body.to_vec()).map_err(|e| ApiError::BadRequest(e.to_string()))?;
    let id = blocking(move || {
        let db = st.db.lock().unwrap();
        db.execute("INSERT INTO models (body) VALUES (?1)", [&text]).map_err(|e| ApiError::Internal(e.to_string()))?;
        Ok(db.last_insert_rowid().to_string())
    })
    .await?;
    Ok(Json(serde_json::json!({ "id": id })))
}

fn load_model_text(st: &AppState, id: &str) -> ApiResult<String> {
    let db = st.db.lock().unwrap();
    let rowid: i64 = id.parse().map_err(|_| ApiError::NotFound(format!("no model {id}")))?;
    db.query_row("SELECT body FROM models WHERE id = ?1", [rowid], |r| r.get::<_, String>(0))
        .map_err(|_| ApiError::NotFound(format!("no model {id}")))
}

async fn get_model(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult<Response> {
    let text = blocking(move || load_model_text(&st, &id)).await?;
    Ok(json_bytes(text.into_bytes()))
}

async fn solve_stored(State(st): State<AppState>, Path(id): Path<String>) -> ApiResult<Response> {
    let out = blocking(move || solve_to_json(&parse_model(load_model_text(&st, &id)?.as_bytes())?)).await?;
    Ok(json_bytes(out))
}

#[derive(Deserialize)]
struct SweepRequest {
    model: Option<Model>,
    model_id: Option<String>,
    variants: usize,
    #[serde(rename = "beam_I_scale")]
    beam_i_scale: Option<[f64; 2]>,
}

#[derive(Serialize, Clone, Copy, Default)]
struct Variant {
    scale: f64,
    roof_drift_w: f64,
    max_abs_m: f64,
}

fn variant_json(v: &Variant) -> serde_json::Value {
    serde_json::json!({"scale": v.scale, "roof_drift_W": v.roof_drift_w, "max_abs_M": v.max_abs_m})
}

fn run_variant(model: &Model, roof: Option<i64>) -> Result<(f64, f64), ModelError> {
    let res = engine::solve(model)?;
    let max_m = res
        .load_cases
        .iter()
        .flat_map(|c| &c.members)
        .flat_map(|m| &m.stations)
        .fold(0.0f64, |a, s| a.max(s.m.abs()));
    let drift = match (roof, res.load_cases.iter().find(|c| c.id == "W")) {
        (Some(n), Some(c)) => c.displacements.iter().find(|d| d.node == n).map_or(0.0, |d| d.ux),
        _ => 0.0,
    };
    Ok((drift, max_m))
}

/// Variants are independent: worker threads (one per core) pull indices from an atomic counter.
fn run_sweep(model: Model, n: usize, lo: f64, hi: f64) -> ApiResult<serde_json::Value> {
    let roof = top_left_node(&model);
    let scale_of = |k: usize| if n > 1 { lo + (hi - lo) * k as f64 / (n - 1) as f64 } else { lo };
    let next = AtomicUsize::new(0);
    let slots: Vec<Mutex<Option<Result<Variant, ModelError>>>> = (0..n).map(|_| Mutex::new(None)).collect();
    let workers = std::thread::available_parallelism().map_or(4, |p| p.get()).min(n.max(1));
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                let mut m = model.clone();
                let base: Vec<f64> = m.sections.iter().map(|s| s.i).collect();
                loop {
                    let k = next.fetch_add(1, Ordering::Relaxed);
                    if k >= n {
                        break;
                    }
                    let scale = scale_of(k);
                    for (s, b) in m.sections.iter_mut().zip(&base) {
                        if s.id == "BM" {
                            s.i = b * scale;
                        }
                    }
                    let r = run_variant(&m, roof).map(|(d, mm)| Variant { scale, roof_drift_w: d, max_abs_m: mm });
                    *slots[k].lock().unwrap() = Some(r);
                }
            });
        }
    });
    let mut out = Vec::with_capacity(n);
    for s in slots {
        out.push(s.into_inner().unwrap().expect("variant computed")?);
    }
    let max_drift = out.iter().map(|v| v.roof_drift_w).fold(f64::NEG_INFINITY, f64::max);
    let max_m = out.iter().map(|v| v.max_abs_m).fold(0.0, f64::max);
    Ok(serde_json::json!({
        "variants": out.iter().map(variant_json).collect::<Vec<_>>(),
        "envelope": {"max_roof_drift_W": if out.is_empty() { 0.0 } else { max_drift }, "max_abs_M": max_m},
    }))
}

async fn sweep(State(st): State<AppState>, body: Bytes) -> ApiResult<Json<serde_json::Value>> {
    let req: SweepRequest = serde_json::from_slice(&body).map_err(|e| ApiError::BadRequest(format!("invalid sweep request: {e}")))?;
    let out = blocking(move || {
        let model = match (req.model, req.model_id) {
            (Some(m), _) => m,
            (None, Some(id)) => parse_model(load_model_text(&st, &id)?.as_bytes())?,
            (None, None) => return Err(ApiError::BadRequest("sweep needs model or model_id".into())),
        };
        let [lo, hi] = req.beam_i_scale.unwrap_or([1.0, 1.0]);
        run_sweep(model, req.variants, lo, hi)
    })
    .await?;
    Ok(Json(out))
}

fn open_db() -> Connection {
    let path = std::env::var("FRAME2D_DB").unwrap_or_else(|_| "frame2d.db".into());
    let db = Connection::open(&path).expect("open sqlite db");
    db.execute_batch("CREATE TABLE IF NOT EXISTS models (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL);")
        .expect("create table");
    db
}

#[tokio::main]
async fn main() {
    let addr = std::env::var("FRAME2D_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".into());
    let state = AppState { db: Arc::new(Mutex::new(open_db())) };
    let app = Router::new()
        .route("/health", get(health))
        .route("/solve", post(solve_handler))
        .route("/models", post(create_model))
        .route("/models/{id}", get(get_model))
        .route("/models/{id}/solve", post(solve_stored))
        .route("/sweep", post(sweep))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind FRAME2D_ADDR");
    eprintln!("frame2d-server listening on {addr}");
    axum::serve(listener, app).await.expect("serve");
}
