use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

pub const MAX_HEAP: usize = 512 * 1024 * 1024;
static LIVE_BYTES: AtomicUsize = AtomicUsize::new(0);

pub struct BoundedAllocator;

fn reserve(size: usize) {
    let mut previous = LIVE_BYTES.load(Ordering::Relaxed);
    loop {
        let next = previous.checked_add(size).filter(|next| *next <= MAX_HEAP);
        let Some(next) = next else {
            terminate();
        };
        match LIVE_BYTES.compare_exchange_weak(previous, next, Ordering::Relaxed, Ordering::Relaxed)
        {
            Ok(_) => return,
            Err(current) => previous = current,
        }
    }
}

fn terminate() -> ! {
    // Allocation failure must not allocate diagnostics or unwind a partially built diagram.
    unsafe { libc::_exit(4) }
}

unsafe impl GlobalAlloc for BoundedAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        reserve(layout.size());
        let pointer = unsafe { System.alloc(layout) };
        if pointer.is_null() {
            terminate();
        }
        pointer
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        reserve(layout.size());
        let pointer = unsafe { System.alloc_zeroed(layout) };
        if pointer.is_null() {
            terminate();
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe {
            System.dealloc(pointer, layout);
        }
        LIVE_BYTES.fetch_sub(layout.size(), Ordering::Relaxed);
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        // Count both buffers during a moving realloc, including its temporary peak.
        let replacement = unsafe { Layout::from_size_align_unchecked(size, layout.align()) };
        let destination = unsafe { self.alloc(replacement) };
        unsafe {
            std::ptr::copy_nonoverlapping(pointer, destination, layout.size().min(size));
            self.dealloc(pointer, layout);
        }
        destination
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_oversize_allocation_in_isolated_process() {
        const PROBE: &str = "TELAR_TEST_DIAGRAM_ALLOCATION";
        if std::env::var_os(PROBE).is_some() {
            let mut allocation = Vec::<u8>::new();
            allocation.try_reserve_exact(MAX_HEAP + 1).unwrap();
            std::hint::black_box(allocation);
            panic!("global allocation quota was not applied");
        }
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "bounded_allocator::tests::rejects_oversize_allocation_in_isolated_process",
            ])
            .env(PROBE, "1")
            .output()
            .unwrap();
        assert_eq!(result.status.code(), Some(4));
    }
}
