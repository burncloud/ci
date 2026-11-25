#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if data.len() < 16 {
        return;
    }
    let mut left_bytes = [0_u8; 8];
    let mut right_bytes = [0_u8; 8];
    left_bytes.copy_from_slice(&data[..8]);
    right_bytes.copy_from_slice(&data[8..16]);
    let left = i64::from_le_bytes(left_bytes);
    let right = i64::from_le_bytes(right_bytes);
    let _ = burncloud_ci_fixture::add(left, right);
});
