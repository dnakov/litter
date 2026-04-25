//! Remote server capability detection.
//!
//! The app-server's `initialize` handshake returns a `user_agent` string in
//! the format:
//!
//! ```text
//! {originator}/{CARGO_PKG_VERSION} ({os_type} {os_version}; {arch}) {terminal_type}
//! ```
//!
//! for first-party codex originators (`codex_cli_rs`, `codex-tui`,
//! `codex_vscode`, `Codex ...`).  See
//! `codex-rs/login/src/auth/default_client.rs::get_codex_user_agent`.
//!
//! Mobile clients use the parsed semver to decide whether the remote supports
//! features like paginated turn fetching (`thread/turns/list` +
//! `exclude_turns`), added in rust-v0.125.0.

use semver::Version;

/// Minimum remote codex version that supports paginated turn fetching.
pub const MIN_TURN_PAGINATION_VERSION: Version = Version::new(0, 125, 0);

/// Parse the codex semver version from an `initialize.user_agent` string.
///
/// Returns `None` when the string is empty, malformed, or uses an originator
/// format we do not recognise. Callers should treat parse failure as
/// "capability unknown" and rely on the runtime probe to flip the capability
/// flag if the RPC fails.
pub fn parse_codex_version(user_agent: &str) -> Option<Version> {
    let after_slash = user_agent.split_once('/')?.1;
    let version_token = after_slash.split_whitespace().next()?;
    Version::parse(version_token).ok()
}

/// Whether a parsed codex version indicates the remote supports paginated
/// turn fetching. `None` (parse failure) returns `true` so we fall back to
/// the runtime probe instead of denying pagination to forked/unknown builds.
pub fn supports_turn_pagination(codex_version: Option<&Version>) -> bool {
    match codex_version {
        Some(version) => *version >= MIN_TURN_PAGINATION_VERSION,
        None => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_codex_cli_rs_user_agent() {
        let ua = "codex_cli_rs/0.125.0 (Darwin 25.4.0; arm64) zsh";
        let version = parse_codex_version(ua).expect("parse");
        assert_eq!(version, Version::new(0, 125, 0));
    }

    #[test]
    fn parses_codex_tui_user_agent() {
        let ua = "codex-tui/0.124.3 (Linux 6.1.0; x86_64) bash";
        let version = parse_codex_version(ua).expect("parse");
        assert_eq!(version, Version::new(0, 124, 3));
    }

    #[test]
    fn parses_codex_vscode_prerelease_user_agent() {
        let ua = "codex_vscode/0.125.0-alpha.3 (Darwin 25.4.0; arm64) vscode";
        let version = parse_codex_version(ua).expect("parse");
        assert_eq!(version.major, 0);
        assert_eq!(version.minor, 125);
        assert_eq!(version.patch, 0);
        assert!(!version.pre.is_empty());
    }

    #[test]
    fn returns_none_on_empty_user_agent() {
        assert!(parse_codex_version("").is_none());
    }

    #[test]
    fn returns_none_on_garbage() {
        assert!(parse_codex_version("not a user agent").is_none());
    }

    #[test]
    fn returns_none_when_originator_has_no_version_slash() {
        assert!(parse_codex_version("codex_cli_rs").is_none());
    }

    #[test]
    fn returns_none_when_version_token_is_invalid() {
        assert!(parse_codex_version("codex_cli_rs/notaversion (os 1; x86) shell").is_none());
    }

    #[test]
    fn supports_turn_pagination_on_v0_125() {
        let v = Version::parse("0.125.0").unwrap();
        assert!(supports_turn_pagination(Some(&v)));
    }

    #[test]
    fn supports_turn_pagination_on_v0_124_is_false() {
        let v = Version::parse("0.124.3").unwrap();
        assert!(!supports_turn_pagination(Some(&v)));
    }

    #[test]
    fn supports_turn_pagination_on_unknown_version_defaults_true() {
        assert!(supports_turn_pagination(None));
    }

    #[test]
    fn supports_turn_pagination_on_future_version() {
        let v = Version::parse("1.0.0").unwrap();
        assert!(supports_turn_pagination(Some(&v)));
    }

    #[test]
    fn supports_turn_pagination_on_alpha_of_v0_125() {
        let v = Version::parse("0.125.0-alpha.1").unwrap();
        // Semver pre-release lexically < 0.125.0 — clients running against an
        // alpha should not be treated as supporting the stable capability.
        assert!(!supports_turn_pagination(Some(&v)));
    }
}
