//! The core of the agent team, ported to Rust: a skeleton until step 2 writes its domain code.
//!
//! It holds the team's rules alone. Each platform's implementation (Linux, macOS, Windows) and each
//! interface (a command line, Discord, a web app) is a crate of its own beside it, which it never
//! depends on (the workspace's `Cargo.toml` says so).

/// The crate's version, as its `Cargo.toml` gives it.
#[must_use]
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::version;

    #[test]
    fn version_is_the_package_version() {
        assert_eq!(version(), "0.1.0");
    }
}
