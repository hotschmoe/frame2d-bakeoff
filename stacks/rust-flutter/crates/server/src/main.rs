//! Frame2D HTTP server (SPEC 5.4): axum + tokio, models stored in SQLite, sweeps run across all cores.

mod store;
mod sweep;

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{header, HeaderName, HeaderValue, StatusCode};
use axum::middleware;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use frame2d_engine::{solve, Model, ModelError};
use serde::Serialize;

use store::Store;
use sweep::SweepRequest;

const BODY_LIMIT: usize = 64 * 1024 * 1024;
const STAMP: &str = "x-frame2d: a"; // BENCH-EDIT:server

type AppState = Arc<Store>;

/// Failure of a request, mapped to an HTTP status and the spec's error JSON.
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
        let (status, code, detail) = match self {
            ApiError::Model(e) => (StatusCode::UNPROCESSABLE_ENTITY, e.code, e.detail),
            ApiError::BadRequest(d) => (StatusCode::BAD_REQUEST, "bad_request", d),
            ApiError::NotFound(d) => (StatusCode::NOT_FOUND, "not_found", d),
            ApiError::Internal(d) => (StatusCode::INTERNAL_SERVER_ERROR, "internal", d),
        };
        json_response(status, serde_json::json!({ "error": code, "detail": detail }).to_string().into_bytes())
    }
}

fn json_response(status: StatusCode, body: Vec<u8>) -> Response {
    (status, [(header::CONTENT_TYPE, HeaderValue::from_static("application/json"))], body).into_response()
}

fn parse_model(body: &[u8]) -> Result<Model, ApiError> {
    serde_json::from_slice(body).map_err(|e| ApiError::BadRequest(format!("invalid model JSON: {e}")))
}

fn to_json<T: Serialize>(value: &T) -> Result<Vec<u8>, ApiError> {
    serde_json::to_vec(value).map_err(|e| ApiError::Internal(e.to_string()))
}

/// Runs CPU-bound work off the async worker threads.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T, ApiError> + Send + 'static) -> Result<T, ApiError> {
    tokio::task::spawn_blocking(f).await.map_err(|e| ApiError::Internal(e.to_string()))?
}

fn solve_to_json(model: &Model) -> Result<Response, ApiError> {
    let results = solve(model)?;
    Ok(json_response(StatusCode::OK, to_json(&results)?))
}

async fn health() -> Response {
    json_response(StatusCode::OK, br#"{"ok":true}"#.to_vec())
}

async fn post_solve(body: Bytes) -> Result<Response, ApiError> {
    blocking(move || solve_to_json(&parse_model(&body)?)).await
}

async fn post_models(State(store): State<AppState>, body: Bytes) -> Result<Response, ApiError> {
    blocking(move || {
        parse_model(&body)?;
        let id = store.insert(&body).map_err(|e| ApiError::Internal(e.to_string()))?;
        Ok(json_response(StatusCode::OK, to_json(&serde_json::json!({ "id": id }))?))
    })
    .await
}

fn load_model(store: &Store, id: &str) -> Result<Vec<u8>, ApiError> {
    store
        .get(id)
        .map_err(|e| ApiError::Internal(e.to_string()))?
        .ok_or_else(|| ApiError::NotFound(format!("no model {id}")))
}

async fn get_model(State(store): State<AppState>, Path(id): Path<String>) -> Result<Response, ApiError> {
    blocking(move || Ok(json_response(StatusCode::OK, load_model(&store, &id)?))).await
}

async fn solve_stored(State(store): State<AppState>, Path(id): Path<String>) -> Result<Response, ApiError> {
    blocking(move || solve_to_json(&parse_model(&load_model(&store, &id)?)?)).await
}

async fn post_sweep(State(store): State<AppState>, body: Bytes) -> Result<Response, ApiError> {
    blocking(move || {
        let req: SweepRequest = serde_json::from_slice(&body)
            .map_err(|e| ApiError::BadRequest(format!("invalid sweep request: {e}")))?;
        let model = match (req.model, req.model_id) {
            (Some(m), _) => m,
            (None, Some(id)) => parse_model(&load_model(&store, &id)?)?,
            (None, None) => return Err(ApiError::BadRequest("sweep needs model or model_id".into())),
        };
        if req.variants == 0 {
            return Err(ApiError::BadRequest("variants must be at least 1".into()));
        }
        let range = req.beam_i_scale.unwrap_or([1.0, 1.0]);
        let result = sweep::run(&model, req.variants, range)?;
        Ok(json_response(StatusCode::OK, to_json(&result)?))
    })
    .await
}

/// Adds the `x-frame2d` header to every response.
async fn stamp(mut res: Response) -> Response {
    if let Some((name, value)) = STAMP.split_once(": ") {
        if let (Ok(n), Ok(v)) = (HeaderName::from_bytes(name.as_bytes()), HeaderValue::from_str(value)) {
            res.headers_mut().insert(n, v);
        }
    }
    res
}

fn app(store: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/solve", post(post_solve))
        .route("/models", post(post_models))
        .route("/models/{id}", get(get_model))
        .route("/models/{id}/solve", post(solve_stored))
        .route("/sweep", post(post_sweep))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
        .layer(middleware::map_response(stamp))
        .with_state(store)
}

fn main() {
    // Solves are CPU-bound: cap the blocking pool at the core count (tokio's default of 512 threads let a burst of
    // connections spawn hundreds of threads, each with its own solver buffers) and let extra requests queue.
    let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(cores.min(4))
        .max_blocking_threads(cores)
        .enable_all()
        .build()
        .expect("cannot start the async runtime")
        .block_on(serve());
}

async fn serve() {
    let addr = std::env::var("FRAME2D_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".into());
    let db = std::env::var("FRAME2D_DB").unwrap_or_else(|_| "frame2d.db".into());
    let store = Arc::new(Store::open(&db).unwrap_or_else(|e| {
        eprintln!("cannot open database {db}: {e}");
        std::process::exit(1)
    }));
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap_or_else(|e| {
        eprintln!("cannot listen on {addr}: {e}");
        std::process::exit(1)
    });
    eprintln!("frame2d-server listening on {addr}");
    axum::serve(listener, app(store)).await.expect("server error");
}
