//! Counting wrapper around the system allocator (SPEC 5.2). A binary opts in with
//! `#[global_allocator] static A: CountingAlloc = CountingAlloc;`.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

static COUNT: AtomicU64 = AtomicU64::new(0);
static BYTES: AtomicU64 = AtomicU64::new(0);
static CURRENT: AtomicU64 = AtomicU64::new(0);
static PEAK: AtomicU64 = AtomicU64::new(0);

pub struct CountingAlloc;

#[derive(Clone, Copy, Debug)]
pub struct AllocStats {
    pub count: u64,
    pub bytes: u64,
    pub peak: u64,
}

fn grow(n: u64) {
    COUNT.fetch_add(1, Relaxed);
    BYTES.fetch_add(n, Relaxed);
    let cur = CURRENT.fetch_add(n, Relaxed) + n;
    PEAK.fetch_max(cur, Relaxed);
}

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        grow(l.size() as u64);
        unsafe { System.alloc(l) }
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        grow(l.size() as u64);
        unsafe { System.alloc_zeroed(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        CURRENT.fetch_sub(l.size() as u64, Relaxed);
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        CURRENT.fetch_sub(l.size() as u64, Relaxed);
        grow(new as u64);
        unsafe { System.realloc(p, l, new) }
    }
}

/// Start a measurement window: zero the counters; the peak starts at the current live heap.
pub fn reset() {
    COUNT.store(0, Relaxed);
    BYTES.store(0, Relaxed);
    PEAK.store(CURRENT.load(Relaxed), Relaxed);
}

pub fn snapshot() -> AllocStats {
    AllocStats { count: COUNT.load(Relaxed), bytes: BYTES.load(Relaxed), peak: PEAK.load(Relaxed) }
}
