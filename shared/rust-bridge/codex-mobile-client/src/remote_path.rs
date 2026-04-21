//! Cross-platform remote path handling.
//!
//! `std::path::Path` uses the *host* OS separator, which is always `/` on
//! iOS/Android. When manipulating paths on a remote Windows machine we need
//! string-based handling that knows the remote OS's conventions.

/// A remote filesystem path that knows whether it lives on a POSIX or
/// Windows host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemotePath {
    Posix(String),
    Windows(String),
}

impl RemotePath {
    /// Auto-detect the path kind from its format.
    ///
    /// A path is considered Windows if it starts with a drive letter followed
    /// by `:` (e.g. `C:\Users\...` or `D:`).  Everything else is POSIX.
    pub fn parse(path: &str) -> Self {
        let p = path.trim();
        let bytes = p.as_bytes();
        if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
            Self::Windows(p.to_string())
        } else {
            Self::Posix(p.to_string())
        }
    }

    /// The raw path string.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Posix(s) | Self::Windows(s) => s,
        }
    }

    pub fn is_windows(&self) -> bool {
        matches!(self, Self::Windows(_))
    }

    pub fn separator(&self) -> char {
        if self.is_windows() { '\\' } else { '/' }
    }

    pub fn is_root(&self) -> bool {
        match self {
            Self::Posix(s) => s == "/",
            Self::Windows(s) => {
                // "C:\" or "C:"
                let b = s.as_bytes();
                (b.len() == 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'\\')
                    || (b.len() == 2 && b[0].is_ascii_alphabetic() && b[1] == b':')
            }
        }
    }

    /// Append a child name using the correct separator.
    pub fn join(&self, name: &str) -> Self {
        let sep = self.separator();
        let s = self.as_str();
        let next = if s.ends_with('/') || s.ends_with('\\') {
            format!("{s}{name}")
        } else {
            format!("{s}{sep}{name}")
        };
        match self {
            Self::Posix(_) => Self::Posix(next),
            Self::Windows(_) => Self::Windows(next),
        }
    }

    /// Navigate up one directory level. Root paths return themselves.
    pub fn parent(&self) -> Self {
        match self {
            Self::Posix(s) => {
                if s == "/" {
                    return self.clone();
                }
                match s.rfind('/') {
                    Some(0) => Self::Posix("/".to_string()),
                    Some(i) => Self::Posix(s[..i].to_string()),
                    None => Self::Posix("/".to_string()),
                }
            }
            Self::Windows(s) => {
                let parts: Vec<&str> = s.split('\\').collect();
                if parts.len() <= 1 {
                    return self.clone();
                }
                let parent_parts = &parts[..parts.len() - 1];
                let joined = parent_parts.join("\\");
                // Preserve trailing backslash for drive root (e.g. "C:\")
                if joined.ends_with(':') {
                    Self::Windows(format!("{joined}\\"))
                } else if joined.is_empty() {
                    self.clone()
                } else {
                    Self::Windows(joined)
                }
            }
        }
    }

    /// Split the path into breadcrumb segments.
    ///
    /// Each segment is `(label, full_path)`.
    pub fn segments(&self) -> Vec<(String, String)> {
        match self {
            Self::Posix(s) => {
                let normalized = s.trim();
                if normalized.is_empty() || normalized == "/" {
                    return vec![("/".to_string(), "/".to_string())];
                }
                let mut output = vec![("/".to_string(), "/".to_string())];
                let mut running = String::new();
                for component in normalized.split('/').filter(|c| !c.is_empty()) {
                    running = if running.is_empty() {
                        format!("/{component}")
                    } else {
                        format!("{running}/{component}")
                    };
                    output.push((component.to_string(), running.clone()));
                }
                output
            }
            Self::Windows(s) => {
                let normalized = s.trim();
                let parts: Vec<&str> = normalized.split('\\').filter(|c| !c.is_empty()).collect();
                if parts.is_empty() {
                    return vec![(normalized.to_string(), normalized.to_string())];
                }
                let mut output = Vec::new();
                let mut running = String::new();
                for (i, component) in parts.iter().enumerate() {
                    if i == 0 {
                        // Drive root: "C:\"
                        running = format!("{component}\\");
                        output.push((running.clone(), running.clone()));
                    } else {
                        running = if running.ends_with('\\') {
                            format!("{running}{component}")
                        } else {
                            format!("{running}\\{component}")
                        };
                        output.push((component.to_string(), running.clone()));
                    }
                }
                output
            }
        }
    }
}

/// Parse the stdout of a directory listing command into sorted directory names.
pub fn parse_directory_listing(stdout: &str, is_windows: bool) -> Vec<String> {
    let mut dirs: Vec<String> = if is_windows {
        // `dir /b /ad` outputs one directory name per line
        stdout
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect()
    } else {
        // `/bin/ls -1ap` marks directories with trailing `/`
        stdout
            .lines()
            .map(|l| l.trim())
            .filter(|l| l.ends_with('/') && *l != "./" && *l != "../")
            .map(|l| l.trim_end_matches('/').to_string())
            .collect()
    };
    dirs.sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()));
    dirs
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- parse / detection --

    #[test]
    fn parse_posix() {
        assert!(!RemotePath::parse("/home/user").is_windows());
        assert!(!RemotePath::parse("/").is_windows());
        assert!(!RemotePath::parse("relative/path").is_windows());
    }

    #[test]
    fn parse_windows() {
        assert!(RemotePath::parse(r"C:\Users\npace").is_windows());
        assert!(RemotePath::parse("D:").is_windows());
        assert!(RemotePath::parse(r"C:\").is_windows());
    }

    #[test]
    fn parse_trims_whitespace() {
        assert!(RemotePath::parse("  C:\\Users  ").is_windows());
        assert!(!RemotePath::parse("  /home  ").is_windows());
    }

    // -- separator --

    #[test]
    fn separator() {
        assert_eq!(RemotePath::parse("/home").separator(), '/');
        assert_eq!(RemotePath::parse("C:\\").separator(), '\\');
    }

    // -- is_root --

    #[test]
    fn is_root_posix() {
        assert!(RemotePath::parse("/").is_root());
        assert!(!RemotePath::parse("/home").is_root());
    }

    #[test]
    fn is_root_windows() {
        assert!(RemotePath::parse(r"C:\").is_root());
        assert!(RemotePath::parse("C:").is_root());
        assert!(!RemotePath::parse(r"C:\Users").is_root());
    }

    // -- join --

    #[test]
    fn join_posix() {
        let p = RemotePath::parse("/home");
        assert_eq!(p.join("user").as_str(), "/home/user");
    }

    #[test]
    fn join_posix_trailing_slash() {
        let p = RemotePath::parse("/home/");
        assert_eq!(p.join("user").as_str(), "/home/user");
    }

    #[test]
    fn join_windows() {
        let p = RemotePath::parse(r"C:\Users");
        assert_eq!(p.join("npace").as_str(), r"C:\Users\npace");
    }

    #[test]
    fn join_windows_root() {
        let p = RemotePath::parse(r"C:\");
        assert_eq!(p.join("Users").as_str(), r"C:\Users");
    }

    // -- parent --

    #[test]
    fn parent_posix() {
        assert_eq!(RemotePath::parse("/home/user").parent().as_str(), "/home");
        assert_eq!(RemotePath::parse("/home").parent().as_str(), "/");
        assert_eq!(RemotePath::parse("/").parent().as_str(), "/");
    }

    #[test]
    fn parent_windows() {
        assert_eq!(
            RemotePath::parse(r"C:\Users\npace").parent().as_str(),
            r"C:\Users"
        );
        assert_eq!(RemotePath::parse(r"C:\Users").parent().as_str(), r"C:\");
        assert_eq!(RemotePath::parse(r"C:\").parent().as_str(), r"C:\");
    }

    // -- segments --

    #[test]
    fn segments_posix_root() {
        let segs = RemotePath::parse("/").segments();
        assert_eq!(segs, vec![("/".to_string(), "/".to_string())]);
    }

    #[test]
    fn segments_posix_deep() {
        let segs = RemotePath::parse("/home/user/docs").segments();
        assert_eq!(
            segs,
            vec![
                ("/".to_string(), "/".to_string()),
                ("home".to_string(), "/home".to_string()),
                ("user".to_string(), "/home/user".to_string()),
                ("docs".to_string(), "/home/user/docs".to_string()),
            ]
        );
    }

    #[test]
    fn segments_windows() {
        let segs = RemotePath::parse(r"C:\Users\npace").segments();
        assert_eq!(
            segs,
            vec![
                (r"C:\".to_string(), r"C:\".to_string()),
                ("Users".to_string(), r"C:\Users".to_string()),
                ("npace".to_string(), r"C:\Users\npace".to_string()),
            ]
        );
    }

    #[test]
    fn segments_windows_root() {
        let segs = RemotePath::parse(r"C:\").segments();
        assert_eq!(segs, vec![(r"C:\".to_string(), r"C:\".to_string())]);
    }

    // -- parse_directory_listing --

    #[test]
    fn parse_listing_posix() {
        let stdout = "./\n../\nDocuments/\nDownloads/\n.hidden/\nfile.txt\n";
        let dirs = parse_directory_listing(stdout, false);
        assert_eq!(dirs, vec![".hidden", "Documents", "Downloads"]);
    }

    #[test]
    fn parse_listing_windows() {
        let stdout = "Documents\r\nDownloads\r\nDesktop\r\n";
        let dirs = parse_directory_listing(stdout, true);
        assert_eq!(dirs, vec!["Desktop", "Documents", "Downloads"]);
    }

    #[test]
    fn parse_listing_windows_no_crlf() {
        let stdout = "Documents\nDownloads\n";
        let dirs = parse_directory_listing(stdout, true);
        assert_eq!(dirs, vec!["Documents", "Downloads"]);
    }

    #[test]
    fn parse_listing_empty() {
        assert!(parse_directory_listing("", false).is_empty());
        assert!(parse_directory_listing("", true).is_empty());
    }

    #[test]
    fn parse_listing_posix_sorts_case_insensitive() {
        let stdout = "zebra/\nalpha/\nBeta/\n";
        let dirs = parse_directory_listing(stdout, false);
        assert_eq!(dirs, vec!["alpha", "Beta", "zebra"]);
    }
}
