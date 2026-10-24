//! Counting wrapper around the system allocator (SPEC 5.2): allocation count, bytes, and peak live heap.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

pub struct Counting;

static COUNT: AtomicU64 = AtomicU64::new(0);
static BYTES: AtomicU64 = AtomicU64::new(0);
static LIVE: AtomicU64 = AtomicU64::new(0);
static PEAK: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Default)]
pub struct Snapshot {
    pub count: u64,
    pub bytes: u64,
    /// Peak live bytes above the live level at `reset`.
    pub peak: u64,
}

/// Starts a measurement window; the peak is measured relative to the heap live right now.
pub fn reset() -> u64 {
    let live = LIVE.load(Relaxed);
    COUNT.store(0, Relaxed);
    BYTES.store(0, Relaxed);
    PEAK.store(live, Relaxed);
    live
}

pub fn snapshot(baseline: u64) -> Snapshot {
    Snapshot {
        count: COUNT.load(Relaxed),
        bytes: BYTES.load(Relaxed),
        peak: PEAK.load(Relaxed).saturating_sub(baseline),
    }
}

fn note_alloc(size: usize) {
    COUNT.fetch_add(1, Relaxed);
    BYTES.fetch_add(size as u64, Relaxed);
    let live = LIVE.fetch_add(size as u64, Relaxed) + size as u64;
    PEAK.fetch_max(live, Relaxed);
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc(layout);
        if !p.is_null() {
            note_alloc(layout.size());
        }
        p
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc_zeroed(layout);
        if !p.is_null() {
            note_alloc(layout.size());
        }
        p
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size() as u64, Relaxed);
        System.dealloc(ptr, layout);
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let p = System.realloc(ptr, layout, new_size);
        if !p.is_null() {
            LIVE.fetch_sub(layout.size() as u64, Relaxed);
            note_alloc(new_size);
        }
        p
    }
}
