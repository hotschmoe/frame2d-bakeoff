//! Open / save of model JSON. Native uses blocking file dialogs; web uses rfd's async dialogs
//! (browser file picker and download) and hands results back through a shared queue.

use crate::model::Model;
use std::cell::RefCell;
use std::rc::Rc;

type Inbox = Rc<RefCell<Vec<Result<Model, String>>>>;

#[derive(Default)]
pub struct Io {
    inbox: Inbox,
}

fn parse(bytes: &[u8]) -> Result<Model, String> {
    serde_json::from_slice(bytes).map_err(|e| format!("invalid model JSON: {e}"))
}

impl Io {
    /// Next finished open operation, if any.
    pub fn poll(&mut self) -> Option<Result<Model, String>> {
        let mut q = self.inbox.borrow_mut();
        if q.is_empty() { None } else { Some(q.remove(0)) }
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub fn open(&mut self) {
        let Some(path) = rfd::FileDialog::new().add_filter("model", &["json"]).pick_file() else { return };
        let res = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display())).and_then(|b| parse(&b));
        self.inbox.borrow_mut().push(res);
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub fn save(&mut self, model: &Model) {
        let Some(path) = rfd::FileDialog::new().add_filter("model", &["json"]).set_file_name("model.json").save_file() else {
            return;
        };
        let res = serde_json::to_vec_pretty(model).map_err(|e| e.to_string()).and_then(|b| std::fs::write(&path, b).map_err(|e| e.to_string()));
        if let Err(e) = res {
            self.inbox.borrow_mut().push(Err(format!("save failed: {e}")));
        }
    }

    #[cfg(target_arch = "wasm32")]
    pub fn open(&mut self) {
        let inbox = self.inbox.clone();
        wasm_bindgen_futures::spawn_local(async move {
            let Some(file) = rfd::AsyncFileDialog::new().add_filter("model", &["json"]).pick_file().await else { return };
            let bytes = file.read().await;
            inbox.borrow_mut().push(parse(&bytes));
        });
    }

    #[cfg(target_arch = "wasm32")]
    pub fn save(&mut self, model: &Model) {
        let Ok(bytes) = serde_json::to_vec_pretty(model) else { return };
        wasm_bindgen_futures::spawn_local(async move {
            if let Some(file) = rfd::AsyncFileDialog::new().set_file_name("model.json").save_file().await {
                let _ = file.write(&bytes).await;
            }
        });
    }
}
