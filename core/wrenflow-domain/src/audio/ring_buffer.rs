//! Lock-free SPSC ring buffer for real-time audio.
//!
//! The producer (RT audio callback) and consumer (drain timer) each own one
//! index — `write_idx` is written only by the producer, `read_idx` only by
//! the consumer.  This is the classic single-producer / single-consumer
//! design: no mutexes, no allocation in the hot path.
//!
//! Capacity is always rounded up to the next power-of-two so that index
//! wrapping is a cheap bitwise AND.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

/// Default capacity matching the Swift implementation (~3 s at 44.1 kHz).
pub const DEFAULT_CAPACITY: usize = 131_072;

struct Inner {
    /// Ring storage — length is always a power of two.
    buffer: Vec<f32>,
    /// Capacity mask (`capacity - 1`).
    mask: usize,
    /// Written only by the producer.
    write_idx: AtomicUsize,
    /// Written only by the consumer.
    read_idx: AtomicUsize,
}

/// SPSC ring buffer.  Clone the `Arc` to share between producer and consumer.
#[derive(Clone)]
pub struct SpscRingBuffer {
    inner: Arc<Inner>,
}

impl SpscRingBuffer {
    /// Create a new buffer.  The actual capacity is rounded up to the next
    /// power of two ≥ `requested_capacity`.
    pub fn new(requested_capacity: usize) -> Self {
        let capacity = requested_capacity.next_power_of_two();
        let buffer = vec![0.0f32; capacity];
        Self {
            inner: Arc::new(Inner {
                buffer,
                mask: capacity - 1,
                write_idx: AtomicUsize::new(0),
                read_idx: AtomicUsize::new(0),
            }),
        }
    }

    /// Number of samples currently available to read.
    pub fn available_to_read(&self) -> usize {
        let wr = self.inner.write_idx.load(Ordering::Acquire);
        let rd = self.inner.read_idx.load(Ordering::Acquire);
        wr.wrapping_sub(rd)
    }

    /// Number of samples that can be written without overwriting unread data.
    pub fn available_to_write(&self) -> usize {
        let capacity = self.inner.mask + 1;
        capacity.saturating_sub(self.available_to_read())
    }

    /// **RT-safe** producer write.  Returns the number of samples actually
    /// written (may be less than `src.len()` if the buffer is nearly full).
    ///
    /// Uses only `Relaxed` loads on `read_idx` and an `Release` store on
    /// `write_idx`, which is safe under SPSC semantics.
    pub fn write(&self, src: &[f32]) -> usize {
        let inner = &*self.inner;
        let capacity = inner.mask + 1;
        let rd = inner.read_idx.load(Ordering::Acquire);
        let wr = inner.write_idx.load(Ordering::Relaxed);
        let available = capacity.wrapping_sub(wr.wrapping_sub(rd));
        let to_write = src.len().min(available);
        if to_write == 0 {
            return 0;
        }

        let start = wr & inner.mask;
        let first_chunk = to_write.min(capacity - start);

        // Safety: `buffer` is exclusive to this producer for the write region.
        // We split at the wrap point and copy each piece.
        unsafe {
            let ptr = inner.buffer.as_ptr() as *mut f32;
            std::ptr::copy_nonoverlapping(src.as_ptr(), ptr.add(start), first_chunk);
            if first_chunk < to_write {
                std::ptr::copy_nonoverlapping(
                    src.as_ptr().add(first_chunk),
                    ptr,
                    to_write - first_chunk,
                );
            }
        }

        inner
            .write_idx
            .store(wr.wrapping_add(to_write), Ordering::Release);
        to_write
    }

    /// Consumer read.  Returns the number of samples placed in `dst`.
    pub fn read(&self, dst: &mut [f32]) -> usize {
        let inner = &*self.inner;
        let capacity = inner.mask + 1;
        let wr = inner.write_idx.load(Ordering::Acquire);
        let rd = inner.read_idx.load(Ordering::Relaxed);
        let available = wr.wrapping_sub(rd);
        let to_read = dst.len().min(available);
        if to_read == 0 {
            return 0;
        }

        let start = rd & inner.mask;
        let first_chunk = to_read.min(capacity - start);

        unsafe {
            let ptr = inner.buffer.as_ptr();
            std::ptr::copy_nonoverlapping(ptr.add(start), dst.as_mut_ptr(), first_chunk);
            if first_chunk < to_read {
                std::ptr::copy_nonoverlapping(
                    ptr,
                    dst.as_mut_ptr().add(first_chunk),
                    to_read - first_chunk,
                );
            }
        }

        inner
            .read_idx
            .store(rd.wrapping_add(to_read), Ordering::Release);
        to_read
    }

    /// Reset both indices to zero.  Only safe when neither producer nor
    /// consumer is currently active.
    pub fn reset(&self) {
        self.inner.read_idx.store(0, Ordering::SeqCst);
        self.inner.write_idx.store(0, Ordering::SeqCst);
    }

    /// Actual (rounded-up) capacity.
    pub fn capacity(&self) -> usize {
        self.inner.mask + 1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capacity_rounded_to_power_of_two() {
        let rb = SpscRingBuffer::new(131_072);
        assert_eq!(rb.capacity(), 131_072);

        let rb2 = SpscRingBuffer::new(100_000);
        assert_eq!(rb2.capacity(), 131_072);

        let rb3 = SpscRingBuffer::new(1);
        assert_eq!(rb3.capacity(), 1);
    }

    #[test]
    fn simple_write_read() {
        let rb = SpscRingBuffer::new(16);
        let samples: Vec<f32> = (0..8).map(|i| i as f32 * 0.1).collect();
        let written = rb.write(&samples);
        assert_eq!(written, 8);
        assert_eq!(rb.available_to_read(), 8);

        let mut dst = vec![0.0f32; 8];
        let read = rb.read(&mut dst);
        assert_eq!(read, 8);
        assert_eq!(dst, samples);
        assert_eq!(rb.available_to_read(), 0);
    }

    #[test]
    fn wrap_around() {
        let rb = SpscRingBuffer::new(8);
        // Fill 6 of 8 slots
        let a: Vec<f32> = (0..6).map(|i| i as f32).collect();
        assert_eq!(rb.write(&a), 6);
        // Drain 4
        let mut dst = vec![0.0f32; 4];
        assert_eq!(rb.read(&mut dst), 4);
        // Write 6 more — must wrap
        let b: Vec<f32> = (10..16).map(|i| i as f32).collect();
        assert_eq!(rb.write(&b), 6);
        // Read remaining 8 (2 leftover + 6 new)
        let mut out = vec![0.0f32; 8];
        let n = rb.read(&mut out);
        assert_eq!(n, 8);
        assert_eq!(out[0], 4.0);
        assert_eq!(out[1], 5.0);
        assert_eq!(out[2], 10.0);
        assert_eq!(out[7], 15.0);
    }

    #[test]
    fn does_not_overwrite_unread_data() {
        let rb = SpscRingBuffer::new(4);
        let data = vec![1.0f32, 2.0, 3.0, 4.0];
        assert_eq!(rb.write(&data), 4); // full
        // Attempt to write more — should write 0
        let extra = vec![5.0f32];
        assert_eq!(rb.write(&extra), 0);
        // Contents unchanged
        let mut dst = vec![0.0f32; 4];
        assert_eq!(rb.read(&mut dst), 4);
        assert_eq!(dst, data);
    }

    #[test]
    fn partial_write_when_nearly_full() {
        let rb = SpscRingBuffer::new(8);
        // Write 6
        let first: Vec<f32> = (0..6).map(|i| i as f32).collect();
        assert_eq!(rb.write(&first), 6);
        // Try to write 4 — only 2 slots free
        let second: Vec<f32> = vec![10.0, 11.0, 12.0, 13.0];
        let written = rb.write(&second);
        assert_eq!(written, 2);
        assert_eq!(rb.available_to_read(), 8);
    }

    #[test]
    fn reset_clears_indices() {
        let rb = SpscRingBuffer::new(16);
        let data = vec![1.0f32; 8];
        rb.write(&data);
        assert_eq!(rb.available_to_read(), 8);
        rb.reset();
        assert_eq!(rb.available_to_read(), 0);
    }

    #[test]
    fn threaded_spsc() {
        use std::thread;

        let rb = SpscRingBuffer::new(1024);
        let rb_producer = rb.clone();

        const N: usize = 4096;

        let producer = thread::spawn(move || {
            let chunk: Vec<f32> = (0..64).map(|i| i as f32).collect();
            let mut total = 0;
            while total < N {
                let wrote = rb_producer.write(&chunk[..64.min(N - total)]);
                total += wrote;
                if wrote == 0 {
                    thread::yield_now();
                }
            }
        });

        let mut received = Vec::with_capacity(N);
        let mut buf = vec![0.0f32; 64];
        while received.len() < N {
            let n = rb.read(&mut buf);
            if n > 0 {
                received.extend_from_slice(&buf[..n]);
            } else {
                std::thread::yield_now();
            }
        }

        producer.join().unwrap();

        // Verify the pattern: values cycle through 0..64 repeatedly
        for (i, &v) in received.iter().enumerate() {
            assert_eq!(v, (i % 64) as f32, "mismatch at index {i}");
        }
    }
}
