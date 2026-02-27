#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$ANDROID_ROOT/app/src/main/assets/bundled_env"
JNI_LIBS_DIR="$ANDROID_ROOT/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$ASSETS_DIR"
mkdir -p "$ASSETS_DIR/bin"
mkdir -p "$JNI_LIBS_DIR"

TERMUX_BOOTSTRAP_URL="https://github.com/termux/termux-packages/releases/latest/download/bootstrap-aarch64.zip"
CODEX_BASE_VERSION="${CODEX_VERSION:-latest}"

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool" >&2
        exit 1
    fi
}

require_tool curl
require_tool npm
require_tool tar

NODEJS_INDEX_URL="https://packages.termux.dev/apt/termux-main/pool/main/n/nodejs/"
NODEJS_DEB_NAME="$(
    curl -fsSL "$NODEJS_INDEX_URL" \
    | grep -Eo 'nodejs_[0-9][^"]*_aarch64\.deb' \
    | head -n1
)"
if [[ -z "$NODEJS_DEB_NAME" ]]; then
    echo "Unable to resolve Termux nodejs aarch64 package" >&2
    exit 1
fi
NODEJS_PACKAGE_URL="${NODEJS_INDEX_URL}${NODEJS_DEB_NAME}"

if [[ "$CODEX_BASE_VERSION" == "latest" ]]; then
    CODEX_BASE_VERSION="$(npm view @openai/codex version --silent)"
fi
if [[ -z "$CODEX_BASE_VERSION" ]]; then
    echo "Unable to resolve @openai/codex version" >&2
    exit 1
fi
CODEX_PACKAGE_VERSION="${CODEX_BASE_VERSION}-linux-arm64"

echo "Preparing bundled assets for Codex version $CODEX_PACKAGE_VERSION"

if [[ ! -f "$ASSETS_DIR/termux-bootstrap.zip" ]]; then
    echo "Downloading Termux bootstrap..."
    curl -fL --retry 3 --retry-delay 1 "$TERMUX_BOOTSTRAP_URL" -o "$ASSETS_DIR/termux-bootstrap.zip"
else
    echo "Termux bootstrap already exists."
fi

existing_version=""
if [[ -f "$ASSETS_DIR/version.txt" ]]; then
    existing_version="$(grep -E '^codex_package_version=' "$ASSETS_DIR/version.txt" | head -n1 | cut -d'=' -f2- || true)"
fi
existing_node_package=""
if [[ -f "$ASSETS_DIR/version.txt" ]]; then
    existing_node_package="$(grep -E '^nodejs_package_url=' "$ASSETS_DIR/version.txt" | head -n1 | cut -d'=' -f2- || true)"
fi

if [[ ! -f "$ASSETS_DIR/codex" || "$existing_version" != "$CODEX_PACKAGE_VERSION" ]]; then
    echo "Downloading OpenAI Codex binary package..."
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    pushd "$TMP_DIR" >/dev/null
    PACKAGE_TGZ="$(npm pack "@openai/codex@${CODEX_PACKAGE_VERSION}" --silent)"
    tar -xzf "$PACKAGE_TGZ"

    CODEX_SOURCE="package/vendor/aarch64-unknown-linux-musl/codex/codex"
    RG_SOURCE="package/vendor/aarch64-unknown-linux-musl/path/rg"
    if [[ ! -f "$CODEX_SOURCE" ]]; then
        echo "OpenAI Codex binary not found in package $CODEX_PACKAGE_VERSION" >&2
        exit 1
    fi

    cp "$CODEX_SOURCE" "$ASSETS_DIR/codex"
    cp "$CODEX_SOURCE" "$JNI_LIBS_DIR/libcodex.so"
    if [[ -f "$RG_SOURCE" ]]; then
        cp "$RG_SOURCE" "$ASSETS_DIR/bin/rg"
    fi
    popd >/dev/null

    rm -rf "$TMP_DIR"
    trap - EXIT
else
    echo "Codex binary already matches requested version."
    if [[ -f "$ASSETS_DIR/codex" ]]; then
        cp "$ASSETS_DIR/codex" "$JNI_LIBS_DIR/libcodex.so"
    fi
fi

if [[ ! -f "$ASSETS_DIR/bin/node" || "$existing_node_package" != "$NODEJS_PACKAGE_URL" ]]; then
    echo "Downloading Termux node package..."
    TMP_NODE_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_NODE_DIR"' EXIT
    pushd "$TMP_NODE_DIR" >/dev/null
    curl -fL --retry 3 --retry-delay 1 "$NODEJS_PACKAGE_URL" -o nodejs.deb
    # GNU ar works on Linux, while BSD ar on macOS can fail for some .deb member names.
    # Some BSD ar versions still return exit code 0 on failure, so verify outputs exist.
    if command -v ar >/dev/null 2>&1; then
        ar x nodejs.deb || true
    fi
    if [[ ! -f data.tar.xz && ! -f data.tar.gz && ! -f data.tar.zst && ! -f data.tar ]]; then
        tar -xf nodejs.deb
    fi

    DATA_ARCHIVE=""
    for candidate in data.tar.xz data.tar.gz data.tar.zst data.tar; do
        if [[ -f "$candidate" ]]; then
            DATA_ARCHIVE="$candidate"
            break
        fi
    done
    if [[ -z "$DATA_ARCHIVE" ]]; then
        echo "Unable to locate data archive inside nodejs.deb" >&2
        exit 1
    fi
    tar -xf "$DATA_ARCHIVE" "./data/data/com.termux/files/usr/bin/node"
    cp "./data/data/com.termux/files/usr/bin/node" "$ASSETS_DIR/bin/node"
    popd >/dev/null
    rm -rf "$TMP_NODE_DIR"
    trap - EXIT
else
    echo "Node binary already matches requested package."
fi

echo "Creating Node.js proxy script..."
cat << 'EOF' > "$ASSETS_DIR/proxy.js"
const net = require('net');
const dns = require('dns');

// Simple connect proxy to handle musl libc DNS issues
const server = net.createServer((clientToProxySocket) => {
    clientToProxySocket.once('data', (data) => {
        const requestString = data.toString();
        const isConnect = requestString.startsWith('CONNECT');
        
        let hostPort;
        if (isConnect) {
            hostPort = requestString.split(' ')[1];
        } else {
            // For simple HTTP, parse Host header
            const match = requestString.match(/Host: ([^\r\n]+)/);
            if (match) hostPort = match[1];
        }
        
        if (!hostPort) {
            clientToProxySocket.end();
            return;
        }
        
        const [host, port] = hostPort.split(':');
        const targetPort = port || (isConnect ? 443 : 80);
        
        dns.lookup(host, (err, address) => {
            if (err) {
                clientToProxySocket.end();
                return;
            }
            
            const proxyToServerSocket = net.createConnection({
                host: address,
                port: targetPort
            }, () => {
                if (isConnect) {
                    clientToProxySocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
                } else {
                    proxyToServerSocket.write(data);
                }
                
                clientToProxySocket.pipe(proxyToServerSocket);
                proxyToServerSocket.pipe(clientToProxySocket);
            });
            
            proxyToServerSocket.on('error', () => clientToProxySocket.end());
            clientToProxySocket.on('error', () => proxyToServerSocket.end());
        });
    });
});

server.listen(8080, '127.0.0.1', () => {
    console.log('Node proxy listening on 127.0.0.1:8080');
});
EOF

echo "Creating config.toml..."
cat << 'EOF' > "$ASSETS_DIR/config.toml"
approval_policy = "never"
sandbox = "danger-full-access"
EOF

cat << EOF > "$ASSETS_DIR/version.txt"
codex_package_version=$CODEX_PACKAGE_VERSION
termux_bootstrap_url=$TERMUX_BOOTSTRAP_URL
nodejs_package_url=$NODEJS_PACKAGE_URL
generated_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

chmod +x "$ASSETS_DIR/codex"
if [[ -f "$JNI_LIBS_DIR/libcodex.so" ]]; then
    chmod +x "$JNI_LIBS_DIR/libcodex.so"
fi
if [[ -f "$ASSETS_DIR/bin/rg" ]]; then
    chmod +x "$ASSETS_DIR/bin/rg"
fi
if [[ -f "$ASSETS_DIR/bin/node" ]]; then
    chmod +x "$ASSETS_DIR/bin/node"
fi
echo "Done! Assets are ready in $ASSETS_DIR"
