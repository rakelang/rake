//! Stable-Rust comparison kernels for the SoA proof demo.
//!
//! The SIMD entry points deliberately contain their own scalar tails. Their
//! `count` argument is a runtime value; no kernel assumes the demo's default
//! count of 400.

#![cfg_attr(not(target_arch = "x86_64"), allow(unused_variables))]

/// Scalar baseline: `output_x[i] = position_x[i] + velocity_x[i] * dt`.
///
/// Multiplication and addition are separate source operations. This function
/// does not request FMA or relaxed floating-point contraction.
///
/// # Safety
///
/// All pointers must be valid for `count` `f32`s. `output_x` must be writable
/// and its range must not overlap either input range.
#[unsafe(no_mangle)]
#[inline(never)]
pub unsafe extern "C" fn advance_x_scalar(
    position_x: *const f32,
    velocity_x: *const f32,
    output_x: *mut f32,
    count: usize,
    dt: f32,
) {
    for i in 0..count {
        unsafe {
            let product = *velocity_x.add(i) * dt;
            *output_x.add(i) = *position_x.add(i) + product;
        }
    }
}

/// Four lanes per explicit operation, followed by a scalar tail.
///
/// # Safety
///
/// As for [`advance_x_scalar`]. The function is only defined on x86-64.
#[cfg(target_arch = "x86_64")]
#[unsafe(no_mangle)]
#[inline(never)]
#[target_feature(enable = "sse2")]
pub unsafe extern "C" fn advance_x_sse2(
    position_x: *const f32,
    velocity_x: *const f32,
    output_x: *mut f32,
    count: usize,
    dt: f32,
) {
    use core::arch::x86_64::{_mm_add_ps, _mm_loadu_ps, _mm_mul_ps, _mm_set1_ps, _mm_storeu_ps};

    let step = 4;
    let vector_end = count / step * step;
    let dt_vector = _mm_set1_ps(dt);
    let mut i = 0;
    while i < vector_end {
        unsafe {
            let position = _mm_loadu_ps(position_x.add(i));
            let velocity = _mm_loadu_ps(velocity_x.add(i));
            let product = _mm_mul_ps(velocity, dt_vector);
            _mm_storeu_ps(output_x.add(i), _mm_add_ps(position, product));
        }
        i += step;
    }
    while i < count {
        unsafe {
            let product = *velocity_x.add(i) * dt;
            *output_x.add(i) = *position_x.add(i) + product;
        }
        i += 1;
    }
}

/// Eight lanes per explicit operation, followed by a scalar tail.
///
/// AVX2 is enabled locally, so the crate itself does not need global
/// `-C target-feature=+avx2`. This intentionally uses `_mm256_mul_ps` followed
/// by `_mm256_add_ps`, not FMA.
///
/// # Safety
///
/// As for [`advance_x_scalar`], and the caller must ensure AVX2 is available.
#[cfg(target_arch = "x86_64")]
#[unsafe(no_mangle)]
#[inline(never)]
#[target_feature(enable = "avx2")]
pub unsafe extern "C" fn advance_x_avx2(
    position_x: *const f32,
    velocity_x: *const f32,
    output_x: *mut f32,
    count: usize,
    dt: f32,
) {
    use core::arch::x86_64::{
        _mm256_add_ps, _mm256_loadu_ps, _mm256_mul_ps, _mm256_set1_ps, _mm256_storeu_ps,
    };

    let step = 8;
    let vector_end = count / step * step;
    let dt_vector = _mm256_set1_ps(dt);
    let mut i = 0;
    while i < vector_end {
        unsafe {
            let position = _mm256_loadu_ps(position_x.add(i));
            let velocity = _mm256_loadu_ps(velocity_x.add(i));
            let product = _mm256_mul_ps(velocity, dt_vector);
            _mm256_storeu_ps(output_x.add(i), _mm256_add_ps(position, product));
        }
        i += step;
    }
    while i < count {
        unsafe {
            let product = *velocity_x.add(i) * dt;
            *output_x.add(i) = *position_x.add(i) + product;
        }
        i += 1;
    }
}

/// Strict scalar sine over a runtime-length input column.
///
/// Stable x86 Rust exposes no packed `f32` sine intrinsic. This source uses
/// ordinary [`f32::sin`] and deliberately does not enable fast-math or provide
/// a custom approximation. The emitted calls/scalarization are therefore an
/// optimizer and system-libm outcome rather than a source-level SIMD promise.
///
/// # Safety
///
/// Both pointers must be valid for `count` `f32`s. `output` must be writable
/// and its range must not overlap the input range.
#[unsafe(no_mangle)]
#[inline(never)]
pub unsafe extern "C" fn sin_array_scalar(input: *const f32, output: *mut f32, count: usize) {
    for i in 0..count {
        unsafe { *output.add(i) = (*input.add(i)).sin() };
    }
}

/// The same source DAG as Rake's `reject_register_pressure` negative case.
///
/// Each pointer supplies exactly one eight-lane rack. The source names nine
/// distinct `a + b` temporaries, keeps them live until the final expression,
/// and then performs a left-associated sum of `t0..t8` followed by `a..h`.
/// This is an ordinary exported function boundary with no volatile access,
/// assembly, black-box call, or optimizer barrier. Consequently Rust/LLVM may
/// legally common-subexpression-eliminate or otherwise optimize equal values;
/// inspecting that choice is the purpose of this comparison kernel.
///
/// # Safety
///
/// Each input must point to eight readable `f32`s, `output` must point to eight
/// writable `f32`s, none of the ranges may overlap, and AVX2 must be available.
#[cfg(target_arch = "x86_64")]
#[unsafe(no_mangle)]
#[inline(never)]
#[target_feature(enable = "avx2")]
pub unsafe extern "C" fn reject_register_pressure_avx2(
    a: *const f32,
    b: *const f32,
    c: *const f32,
    d: *const f32,
    e: *const f32,
    f: *const f32,
    g: *const f32,
    h: *const f32,
    output: *mut f32,
) {
    use core::arch::x86_64::{_mm256_add_ps, _mm256_loadu_ps, _mm256_storeu_ps};

    unsafe {
        let a = _mm256_loadu_ps(a);
        let b = _mm256_loadu_ps(b);
        let c = _mm256_loadu_ps(c);
        let d = _mm256_loadu_ps(d);
        let e = _mm256_loadu_ps(e);
        let f = _mm256_loadu_ps(f);
        let g = _mm256_loadu_ps(g);
        let h = _mm256_loadu_ps(h);

        let t0 = _mm256_add_ps(a, b);
        let t1 = _mm256_add_ps(a, b);
        let t2 = _mm256_add_ps(a, b);
        let t3 = _mm256_add_ps(a, b);
        let t4 = _mm256_add_ps(a, b);
        let t5 = _mm256_add_ps(a, b);
        let t6 = _mm256_add_ps(a, b);
        let t7 = _mm256_add_ps(a, b);
        let t8 = _mm256_add_ps(a, b);

        let result = _mm256_add_ps(t0, t1);
        let result = _mm256_add_ps(result, t2);
        let result = _mm256_add_ps(result, t3);
        let result = _mm256_add_ps(result, t4);
        let result = _mm256_add_ps(result, t5);
        let result = _mm256_add_ps(result, t6);
        let result = _mm256_add_ps(result, t7);
        let result = _mm256_add_ps(result, t8);
        let result = _mm256_add_ps(result, a);
        let result = _mm256_add_ps(result, b);
        let result = _mm256_add_ps(result, c);
        let result = _mm256_add_ps(result, d);
        let result = _mm256_add_ps(result, e);
        let result = _mm256_add_ps(result, f);
        let result = _mm256_add_ps(result, g);
        let result = _mm256_add_ps(result, h);
        _mm256_storeu_ps(output, result);
    }
}

/// Scalar reference for the deliberately high-register-pressure transform.
///
/// `fields` points to 20 mutable SoA column pointers. For every particle this
/// replaces field `j` with `old[j] + old[(j + 1) % 20] * gain`.
///
/// # Safety
///
/// `fields` must contain 20 pointers valid and writable for `count` `f32`s;
/// their pointed-to ranges must be pairwise non-overlapping.
#[unsafe(no_mangle)]
#[inline(never)]
pub unsafe extern "C" fn pressure20_scalar(fields: *const *mut f32, count: usize, gain: f32) {
    let mut pointers = [core::ptr::null_mut(); 20];
    for (j, pointer) in pointers.iter_mut().enumerate() {
        *pointer = unsafe { *fields.add(j) };
    }
    for i in 0..count {
        let mut old = [0.0; 20];
        for j in 0..20 {
            old[j] = unsafe { *pointers[j].add(i) };
        }
        for j in 0..20 {
            unsafe {
                *pointers[j].add(i) = old[j] + old[(j + 1) % 20] * gain;
            }
        }
    }
}

/// AVX2 intrinsic kernel which creates more simultaneously live source racks
/// than AVX2 has architectural vector registers (20 values, 16 YMM registers).
///
/// Rust accepts this and lets the backend choose spills/reloads. This function
/// is intended for assembly inspection, not as an example of good API design.
/// It has an explicit scalar tail and separate multiply/add operations.
///
/// # Safety
///
/// As for [`pressure20_scalar`], and the caller must ensure AVX2 is available.
#[cfg(target_arch = "x86_64")]
#[unsafe(no_mangle)]
#[inline(never)]
#[target_feature(enable = "avx2")]
pub unsafe extern "C" fn pressure20_avx2(fields: *const *mut f32, count: usize, gain: f32) {
    use core::arch::x86_64::{
        __m256, _mm256_add_ps, _mm256_loadu_ps, _mm256_mul_ps, _mm256_set1_ps, _mm256_storeu_ps,
    };

    let mut pointers = [core::ptr::null_mut(); 20];
    for (j, pointer) in pointers.iter_mut().enumerate() {
        *pointer = unsafe { *fields.add(j) };
    }

    let gain_vector = _mm256_set1_ps(gain);
    let vector_end = count / 8 * 8;
    let mut i = 0;
    while i < vector_end {
        // The raw-pointer ABI does not communicate the documented disjointness
        // precondition to LLVM. Every old vector is obtained before the first
        // result is stored, so the generated code retains/reloads twenty old
        // values. The local array is not portable SIMD: its fixed eight-lane
        // width is still hand-selected by the user.
        let mut old: [__m256; 20] = [_mm256_set1_ps(0.0); 20];
        for j in 0..20 {
            old[j] = unsafe { _mm256_loadu_ps(pointers[j].add(i)) };
        }
        for j in 0..20 {
            let product = _mm256_mul_ps(old[(j + 1) % 20], gain_vector);
            let result = _mm256_add_ps(old[j], product);
            unsafe { _mm256_storeu_ps(pointers[j].add(i), result) };
        }
        i += 8;
    }

    while i < count {
        let mut old = [0.0; 20];
        for j in 0..20 {
            old[j] = unsafe { *pointers[j].add(i) };
        }
        for j in 0..20 {
            unsafe {
                *pointers[j].add(i) = old[j] + old[(j + 1) % 20] * gain;
            }
        }
        i += 1;
    }
}

/// A stable, order-defined checksum suitable for comparing implementations.
pub fn checksum(values: &[f32]) -> u64 {
    values
        .iter()
        .enumerate()
        .fold(0xcbf2_9ce4_8422_2325, |hash, (i, value)| {
            let word = u64::from(value.to_bits()) ^ (i as u64).wrapping_mul(0x9e37_79b9);
            (hash ^ word).wrapping_mul(0x0000_0100_0000_01b3)
        })
}
