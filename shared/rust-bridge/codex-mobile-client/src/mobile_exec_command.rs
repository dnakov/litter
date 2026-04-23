use codex_shell_command::parse_command::extract_shell_command;
use codex_shell_command::parse_command::shlex_join;

/// Build the single command string that gets handed to the iOS `ios_system`
/// entry point (or the Android equivalent). The shared Rust preflight has
/// already rewritten login-shell wrappers like `bash -lc …` into
/// `["sh", "-c", <script>]`, so for any shell-wrapper argv we keep the
/// wrapper and let ios_system dispatch `sh_main`, which is a real-enough
/// parser (`;`, `&&`, heredocs, `printf` builtin, etc.). ios_system's
/// top-level tokenizer only handles pipes and simple redirects, so handing
/// it the bare script breaks those features.
///
/// Plain argv (no shell wrapper) stays as a space-joined command string.
pub(crate) fn mobile_system_command(argv: &[String]) -> String {
    if let Some((_, script)) = extract_shell_command(argv) {
        return format!("sh -c {}", single_quote(script));
    }
    shlex_join(argv)
}

/// POSIX single-quote: wrap in `'…'` and escape embedded `'` as `'\''`.
fn single_quote(script: &str) -> String {
    let escaped = script.replace('\'', "'\\''");
    format!("'{escaped}'")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_shell_wrapper_with_sh_c() {
        let argv = vec!["/bin/zsh".into(), "-lc".into(), "echo hello".into()];
        assert_eq!(mobile_system_command(&argv), "sh -c 'echo hello'");
    }

    #[test]
    fn wraps_script_with_semicolons() {
        let argv = vec!["sh".into(), "-c".into(), "echo one; echo two".into()];
        assert_eq!(
            mobile_system_command(&argv),
            "sh -c 'echo one; echo two'"
        );
    }

    #[test]
    fn wraps_script_with_heredoc() {
        let script = "cat <<'EOF' > out.txt\nA\nB\nEOF";
        let argv = vec!["sh".into(), "-c".into(), script.into()];
        assert_eq!(
            mobile_system_command(&argv),
            "sh -c 'cat <<'\\''EOF'\\'' > out.txt\nA\nB\nEOF'"
        );
    }

    #[test]
    fn escapes_single_quote_inside_script() {
        let argv = vec!["sh".into(), "-c".into(), "echo it's fine".into()];
        assert_eq!(
            mobile_system_command(&argv),
            "sh -c 'echo it'\\''s fine'"
        );
    }

    #[test]
    fn shell_joins_plain_argv() {
        let argv = vec!["cat".into(), "file with spaces.js".into()];
        assert_eq!(mobile_system_command(&argv), "cat 'file with spaces.js'");
    }
}
