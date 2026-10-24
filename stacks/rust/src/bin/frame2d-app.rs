//! `frame2d-app`: the egui client. Desktop: `frame2d-app [--bench=<mode>]`.
//! Web (wasm32): same code via eframe's WebRunner; bench mode comes from `?bench=<mode>`.

use frame2d::app::Frame2dApp;

#[cfg(not(target_arch = "wasm32"))]
fn main() -> eframe::Result {
    frame2d::app::mark_process_start();
    let bench = std::env::args().find_map(|a| a.strip_prefix("--bench=").map(str::to_owned));
    if bench.as_deref() == Some("boundary") {
        frame2d::app::boundary_bench();
        return Ok(());
    }
    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default().with_inner_size([1280.0, 800.0]).with_title("Frame2D"),
        ..Default::default()
    };
    eframe::run_native("Frame2D", options, Box::new(move |cc| Ok(Box::new(Frame2dApp::new(cc, bench)))))
}

#[cfg(target_arch = "wasm32")]
fn main() {
    use eframe::wasm_bindgen::JsCast as _;
    let window = web_sys::window().expect("window");
    let query = window.location().search().unwrap_or_default();
    let bench = query
        .trim_start_matches('?')
        .split('&')
        .find_map(|kv| kv.strip_prefix("bench=").map(str::to_owned));
    // Boundary mode is driven from JS (index.html) against the exported functions; no UI needed.
    if bench.as_deref() == Some("boundary") {
        return;
    }
    wasm_bindgen_futures::spawn_local(async move {
        let canvas = window
            .document()
            .and_then(|d| d.get_element_by_id("frame2d_canvas"))
            .and_then(|e| e.dyn_into::<web_sys::HtmlCanvasElement>().ok())
            .expect("canvas #frame2d_canvas");
        let res = eframe::WebRunner::new()
            .start(canvas, eframe::WebOptions::default(), Box::new(move |cc| Ok(Box::new(Frame2dApp::new(cc, bench)))))
            .await;
        if let Err(e) = res {
            web_sys::console::error_1(&e);
        }
    });
}
