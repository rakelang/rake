use soa_proof_rust::{advance_x_scalar, checksum, pressure20_scalar, sin_array_scalar};

const DEFAULT_COUNT: usize = 400;

fn input(count: usize) -> (Vec<f32>, Vec<f32>) {
    let position = (0..count)
        .map(|i| ((i as i32 % 37) - 18) as f32 * 0.125)
        .collect();
    let velocity = (0..count)
        .map(|i| ((i as i32 * 17 % 53) - 26) as f32 * 0.03125)
        .collect();
    (position, velocity)
}

fn assert_same(label: &str, expected: &[f32], actual: &[f32]) {
    assert_eq!(expected.len(), actual.len());
    expected
        .iter()
        .zip(actual)
        .enumerate()
        .find(|(_, (a, b))| a.to_bits() != b.to_bits())
        .map(|(i, (a, b))| panic!("{label}: mismatch at {i}: {a:?} != {b:?}"));
}

fn pressure_input(count: usize) -> [Vec<f32>; 20] {
    core::array::from_fn(|field| {
        (0..count)
            .map(|i| (field as f32 + 1.0) * 0.25 + (i % 29) as f32 * 0.015625)
            .collect()
    })
}

fn main() {
    let count = std::env::args()
        .nth(1)
        .map(|arg| {
            arg.parse::<usize>()
                .expect("count must be a non-negative integer")
        })
        .unwrap_or(DEFAULT_COUNT);
    let dt = 0.25_f32;
    let (position_x, velocity_x) = input(count);

    let mut expected = vec![0.0; count];
    unsafe {
        advance_x_scalar(
            position_x.as_ptr(),
            velocity_x.as_ptr(),
            expected.as_mut_ptr(),
            count,
            dt,
        );
    }
    println!(
        "advance_x_scalar count={count} checksum={:016x}",
        checksum(&expected)
    );

    let mut sine = vec![0.0; count];
    unsafe { sin_array_scalar(position_x.as_ptr(), sine.as_mut_ptr(), count) };
    println!(
        "sin_array_scalar count={count} checksum={:016x}",
        checksum(&sine)
    );

    #[cfg(target_arch = "x86_64")]
    {
        if std::is_x86_feature_detected!("sse2") {
            let mut actual = vec![0.0; count];
            unsafe {
                soa_proof_rust::advance_x_sse2(
                    position_x.as_ptr(),
                    velocity_x.as_ptr(),
                    actual.as_mut_ptr(),
                    count,
                    dt,
                );
            }
            assert_same("sse2", &expected, &actual);
            println!(
                "advance_x_sse2   count={count} checksum={:016x}",
                checksum(&actual)
            );
        }

        if std::is_x86_feature_detected!("avx2") {
            let mut actual = vec![0.0; count];
            unsafe {
                soa_proof_rust::advance_x_avx2(
                    position_x.as_ptr(),
                    velocity_x.as_ptr(),
                    actual.as_mut_ptr(),
                    count,
                    dt,
                );
            }
            assert_same("avx2", &expected, &actual);
            println!(
                "advance_x_avx2   count={count} checksum={:016x}",
                checksum(&actual)
            );

            let racks: [Vec<f32>; 8] = core::array::from_fn(|rack| {
                (0..8)
                    .map(|lane| (rack * 8 + lane + 1) as f32 * 0.03125)
                    .collect()
            });
            let mut pressure_dag = [0.0_f32; 8];
            unsafe {
                soa_proof_rust::reject_register_pressure_avx2(
                    racks[0].as_ptr(),
                    racks[1].as_ptr(),
                    racks[2].as_ptr(),
                    racks[3].as_ptr(),
                    racks[4].as_ptr(),
                    racks[5].as_ptr(),
                    racks[6].as_ptr(),
                    racks[7].as_ptr(),
                    pressure_dag.as_mut_ptr(),
                );
            }
            let pressure_dag_expected: [f32; 8] = core::array::from_fn(|lane| {
                let a = racks[0][lane];
                let b = racks[1][lane];
                let t = a + b;
                let result = t + t;
                let result = result + t;
                let result = result + t;
                let result = result + t;
                let result = result + t;
                let result = result + t;
                let result = result + t;
                let result = result + t;
                racks.iter().fold(result, |sum, rack| sum + rack[lane])
            });
            assert_same(
                "reject_register_pressure_avx2",
                &pressure_dag_expected,
                &pressure_dag,
            );
            println!(
                "reject_register_pressure_avx2 checksum={:016x}",
                checksum(&pressure_dag)
            );

            let mut pressure_expected = pressure_input(count);
            let expected_pointers: [*mut f32; 20] =
                core::array::from_fn(|j| pressure_expected[j].as_mut_ptr());
            unsafe { pressure20_scalar(expected_pointers.as_ptr(), count, 0.125) };

            let mut pressure_actual = pressure_input(count);
            let actual_pointers: [*mut f32; 20] =
                core::array::from_fn(|j| pressure_actual[j].as_mut_ptr());
            unsafe {
                soa_proof_rust::pressure20_avx2(actual_pointers.as_ptr(), count, 0.125);
            }
            pressure_expected
                .iter()
                .zip(&pressure_actual)
                .enumerate()
                .for_each(|(field, (expected, actual))| {
                    assert_same(&format!("pressure field {field}"), expected, actual)
                });
            let pressure_checksum = pressure_actual
                .iter()
                .fold(0_u64, |sum, field| sum.wrapping_add(checksum(field)));
            println!("pressure20_avx2 count={count} checksum={pressure_checksum:016x}");
        }
    }
}
