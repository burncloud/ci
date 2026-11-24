#![forbid(unsafe_code)]

//! Fixture crate for the burncloud/ci self-test.

/// Returns the sum of two integers, saturating at the bounds of `i64`.
///
/// # Examples
///
/// ```
/// use burncloud_ci_fixture::add;
/// assert_eq!(add(2, 2), 4);
/// ```
#[must_use]
pub const fn add(left: i64, right: i64) -> i64 {
    left.saturating_add(right)
}

#[cfg(test)]
mod tests {
    use super::add;

    #[test]
    fn two_plus_two_is_four() {
        assert_eq!(add(2, 2), 4);
    }

    #[test]
    fn saturates_at_the_top() {
        assert_eq!(add(i64::MAX, 1), i64::MAX);
    }
}
