# FoxTerm XCFramework Build System

<div align="center">

**Automated compilation of OpenSSL / libssh / libvncserver into Apple platform XCFrameworks**

**[English](README.md)** | [中文文档](README_CN.md)

[![Build XCFrameworks](https://github.com/foxterm/xcframework_build/actions/workflows/build-xcframeworks.yml/badge.svg)](https://github.com/foxterm/xcframework_build/actions/workflows/build-xcframeworks.yml)
[![Check Dependency Updates](https://github.com/foxterm/xcframework_build/actions/workflows/check-versions.yml/badge.svg)](https://github.com/foxterm/xcframework_build/actions/workflows/check-versions.yml)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20macOS%2014%2B-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

</div>

---

## Architecture Overview

```
+---------------------------------------------------------------------+
|                      GitHub Actions CI/CD                            |
+---------------------------------------------------------------------+
|                                                                      |
|  +--------------+    +--------------+    +--------------+           |
|  | Check Daily  |--->| Build on     |--->| Push to      |           |
|  | Version      |    | macOS 15     |    | Repos        |           |
|  | Update       |    | Runner       |    |              |           |
|  +------+-------+    +------+-------+    +------+-------+           |
|         |                   |                   |                    |
|         v                   v                   v                    |
|  +--------------+    +--------------+    +--------------+           |
|  | OpenSSL API  |    |  OpenSSL     |    | foxterm/     |           |
|  | GitLab API   |    |  CSSH        |    | OpenSSL      |           |
|  | GitHub API   |    |  VNC         |    | foxterm/SSH  |           |
|  +--------------+    +--------------+    | foxterm/VNC  |           |
|                                           +--------------+           |
|                                                                      |
+---------------------------------------------------------------------+
```

## Build Artifacts

| XCFramework | Source Library | Architecture Support | Output Location |
|-------------|----------------|---------------------|-----------------|
| `OpenSSL.xcframework` | [openssl/openssl](https://github.com/openssl/openssl) | macOS arm64/x86_64, iOS arm64, Simulator arm64 | [foxterm/OpenSSL](https://github.com/foxterm/OpenSSL) |
| `libssh.xcframework` | [libssh/libssh](https://gitlab.com/libssh/libssh-mirror) | macOS arm64/x86_64, iOS arm64, Simulator arm64 | [foxterm/SSH](https://github.com/foxterm/SSH) |
| `libvncclient.xcframework` | [LibVNC/libvncserver](https://github.com/LibVNC/libvncserver) | macOS arm64/x86_64, iOS arm64, Simulator arm64 | [foxterm/VNC](https://github.com/foxterm/VNC) |

## Core Features

### Extreme Size Optimization

OpenSSL compilation uses aggressive trimming strategy, keeping only APIs actually used by FoxTerm:

```bash
# Kept: AES, DES, ChaCha20, RSA, ECDSA, Ed25519, ECDH, X25519, SHA-1/2, TLS/SSL, X509
# Trimmed: 30+ unnecessary algorithms and modules

# Compilation optimization: -Oz (minimum size) + strip -x (strip local symbols)
# Merge: libssl.a + libcrypto.a → libopenssl.a (single library)
```

### Automated Version Detection

Automatically checks for dependency updates daily at UTC 00:00:

| Dependency | Detection Method | Data Source |
|------------|------------------|-------------|
| OpenSSL | GitHub Tags API | `api.github.com/repos/openssl/openssl/tags` |
| libssh | GitLab Tags API | `gitlab.com/api/v4/projects/libssh%2Flibssh-mirror/repository/tags` |
| libvncserver | Commit SHA Comparison | `api.github.com/repos/LibVNC/libvncserver/commits/master` |

When new versions are detected, automatically:
1. Updates version numbers in build scripts
2. Commits changes to repository
3. Triggers build workflow

### Smart Caching

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions Cache                       │
├─────────────────────────────────────────────────────────────┤
│  OpenSSL Build Cache                                        │
│  Key: openssl-{version}-macos15                             │
│  → Skips compilation when version unchanged, uses cache     │
│                                                              │
│  Source Code Cache                                          │
│  Key: {lib}-sources-{hash}                                  │
│  → Avoids repeated cloning/downloading of source code       │
└─────────────────────────────────────────────────────────────┘
```

## Build Pipeline

```
Build XCFrameworks Workflow
│
├─▶ Install Dependencies (cmake, ninja, nasm, ...)
│
├─▶ Build OpenSSL
│   ├─ Restore cache (version-based)
│   ├─ Clone source (if not cached)
│   ├─ Configure (4 architectures)
│   ├─ Compile with -Oz optimization
│   ├─ Merge libssl + libcrypto
│   └─ Save cache
│
├─▶ Build CSSH (libssh)
│   ├─ Link against OpenSSL artifacts
│   ├─ Compile (4 architectures)
│   └─ Package xcframework
│
├─▶ Build VNC (libvncserver)
│   ├─ Build dependencies (libjpeg-turbo, libpng, lzo)
│   ├─ Link against OpenSSL artifacts
│   ├─ Compile (4 architectures)
│   └─ Package xcframework
│
└─▶ Push to Target Repos
    ├─ foxterm/OpenSSL ← OpenSSL.xcframework
    ├─ foxterm/SSH ← libssh.xcframework
    └─ foxterm/VNC ← libvncclient.xcframework
```

## Manual Build Trigger

### Build All

```bash
gh workflow run build-xcframeworks.yml -R foxterm/xcframework_build -f build_libs=all
```

### Build Specific Libraries Only

```bash
# OpenSSL only
gh workflow run build-xcframeworks.yml -R foxterm/xcframework_build -f build_libs=openssl

# OpenSSL + CSSH
gh workflow run build-xcframeworks.yml -R foxterm/xcframework_build -f build_libs=openssl+cssh

# VNC only (requires OpenSSL cache)
gh workflow run build-xcframeworks.yml -R foxterm/xcframework_build -f build_libs=vnc
```

## Local Build

### Prerequisites

```bash
# macOS
brew install cmake ninja libtool autoconf automake nasm

# Xcode Command Line Tools
xcode-select --install
```

### Build OpenSSL

```bash
cd OpenSSL
bash build_xcframework.sh
```

### Build CSSH (libssh)

```bash
cd CSSH
# Ensure OpenSSL is built to ../openssl_xcframework_build/
bash build_xcframework.sh
```

### Build VNC (libvncserver)

```bash
cd VNC
# Ensure OpenSSL is built to ../openssl_xcframework_build/
bash build_xcframework.sh
```

## Repository Structure

```
xcframework_build/
├── .github/
│   └── workflows/
│       ├── build-xcframeworks.yml    # Build workflow
│       └── check-versions.yml        # Version check workflow
├── OpenSSL/
│   ├── build_xcframework.sh          # OpenSSL build script
│   └── openssl_xcframework_build/    # Build artifacts (gitignored)
├── CSSH/
│   ├── build_xcframework.sh          # libssh build script
│   └── xcframework_build/            # Build artifacts (gitignored)
├── VNC/
│   ├── build_xcframework.sh          # libvncserver build script
│   └── xcframework_build/            # Build artifacts (gitignored)
├── vnc_master_hash.txt               # libvncserver master branch tracking
├── README.md                         # English documentation
└── README_CN.md                      # Chinese documentation
```

## Environment Variables

Build scripts support overriding default configuration via environment variables:

| Variable | Description | Default Value |
|----------|-------------|---------------|
| `OPENSSL_VERSION` | OpenSSL version tag | `openssl-4.1.0` |
| `LIBSSH_VERSION` | libssh version number | `0.12.2` |
| `OPENSSL_BUILD_DIR` | OpenSSL artifacts path (for CI) | Script relative path |

Example:
```bash
OPENSSL_VERSION="openssl-4.0.0" bash OpenSSL/build_xcframework.sh
```

## Secrets Configuration

| Secret | Description |
|--------|-------------|
| `GH_PAT` | GitHub Personal Access Token for cross-repository xcframework push |

PAT requires `repo` permission, used to push build artifacts to:
- `foxterm/OpenSSL`
- `foxterm/SSH`
- `foxterm/VNC`

## Technical Details

### Build Targets

| Platform | Architecture | Minimum Version |
|----------|--------------|-----------------|
| macOS | arm64, x86_64 | macOS 14.0 |
| iOS | arm64 | iOS 17.0 |
| iOS Simulator | arm64 | iOS 17.0 |

### OpenSSL Trim List

<details>
<summary>Click to expand full trim list</summary>

**Disabled Protocols:**
- SSL 3.0, TLS 1.0, TLS 1.1, DTLS

**Disabled Encryption Algorithms:**
- ARIA, Camellia, CAST, IDEA, RC2, RC5, SEED, SM2, SM3, SM4, Whirlpool, BLAKE2, RMD160, MD4

**Disabled Features:**
- Compression, OCB, CT, PSK, SRP, SRTP, Scrypt, TS, CMS, GOST, KTLS, FIPS

**Disabled Modules:**
- Engine, Dynamic modules, Filenames tracking, Async operations

</details>

### libvncserver Dependencies

VNC build includes the following statically linked dependencies:
- libjpeg-turbo (no SIMD)
- libpng
- LZO 2.10

## License

Build scripts are licensed under the MIT License. Each dependency library follows its respective license:
- OpenSSL: [Apache License 2.0](https://github.com/openssl/openssl/blob/master/LICENSE.txt)
- libssh: [LGPL 2.1](https://gitlab.com/libssh/libssh-mirror/-/blob/master/COPYING)
- libvncserver: [GPL 2.0](https://github.com/LibVNC/libvncserver/blob/master/COPYING)

---

<div align="center">

**Built for [FoxTerm](https://foxterm.app)**

*Secure · Efficient · Automated*

</div>
