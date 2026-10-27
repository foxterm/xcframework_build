# FoxTerm XCFramework Build System

<div align="center">

**自动化编译 OpenSSL / libssh / libvncserver 为 Apple 平台 XCFramework**

[![Build XCFrameworks](https://github.com/foxterm/xcframework_build/actions/workflows/build-xcframeworks.yml/badge.svg)](https://github.com/foxterm/xcframework_build/actions/workflows/build-xcframeworks.yml)
[![Check Dependency Updates](https://github.com/foxterm/xcframework_build/actions/workflows/check-versions.yml/badge.svg)](https://github.com/foxterm/xcframework_build/actions/workflows/check-versions.yml)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20macOS%2014%2B-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

</div>

---

## 架构概览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GitHub Actions CI/CD                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐         │
│  │   Check Daily   │───▶│  Build on macOS │───▶│  Push to Repos  │         │
│  │  Version Update │    │    15 Runner    │    │                 │         │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘         │
│         │                       │                        │                  │
│         ▼                       ▼                        ▼                  │
│  ┌─────────────┐        ┌─────────────┐         ┌─────────────┐           │
│  │ OpenSSL API │        │  OpenSSL    │         │foxterm/     │           │
│  │ GitLab API  │        │  CSSH       │         │OpenSSL      │           │
│  │ GitHub API  │        │  VNC        │         │foxterm/SSH  │           │
│  └─────────────┘        └─────────────┘         │foxterm/VNC  │           │
│                                                  └─────────────┘           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 编译产物

| XCFramework | 源库 | 架构支持 | 输出位置 |
|-------------|------|----------|----------|
| `OpenSSL.xcframework` | [openssl/openssl](https://github.com/openssl/openssl) | macOS arm64/x86_64, iOS arm64, Simulator arm64 | [foxterm/OpenSSL](https://github.com/foxterm/OpenSSL) |
| `libssh.xcframework` | [libssh/libssh](https://gitlab.com/libssh/libssh-mirror) | macOS arm64/x86_64, iOS arm64, Simulator arm64 | [foxterm/SSH](https://github.com/foxterm/SSH) |
| `libvncclient.xcframework` | [LibVNC/libvncserver](https://github.com/LibVNC/libvncserver) | macOS arm64/x86_64, iOS arm64, Simulator arm64 | [foxterm/VNC](https://github.com/foxterm/VNC) |

## 核心特性

### 极致体积优化

OpenSSL 编译采用激进的裁剪策略，仅保留 FoxTerm 实际使用的 API：

```bash
# 保留: AES, DES, ChaCha20, RSA, ECDSA, Ed25519, ECDH, X25519, SHA-1/2, TLS/SSL, X509
# 裁剪: 30+ 不需要的算法和模块

# 编译优化: -Oz (最小体积) + strip -x (剥离本地符号)
# 合并: libssl.a + libcrypto.a → libopenssl.a (单库)
```

### 自动化版本检测

每天 UTC 00:00 自动检查依赖更新：

| 依赖 | 检测方式 | 数据源 |
|------|----------|--------|
| OpenSSL | GitHub Tags API | `api.github.com/repos/openssl/openssl/tags` |
| libssh | GitLab Tags API | `gitlab.com/api/v4/projects/libssh%2Flibssh-mirror/repository/tags` |
| libvncserver | Commit SHA 对比 | `api.github.com/repos/LibVNC/libvncserver/commits/master` |

发现新版本时自动：
1. 更新构建脚本中的版本号
2. 提交变更到仓库
3. 触发构建工作流

### 智能缓存

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions Cache                       │
├─────────────────────────────────────────────────────────────┤
│  OpenSSL Build Cache                                        │
│  Key: openssl-{version}-macos15                             │
│  → 版本不变时跳过编译，直接使用缓存                            │
│                                                              │
│  Source Code Cache                                          │
│  Key: {lib}-sources-{hash}                                  │
│  → 避免重复克隆/下载源码                                     │
└─────────────────────────────────────────────────────────────┘
```

## 构建流程

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

## 手动触发构建

### 构建全部

```bash
gh workflow run build-xcframeworks.yml -R foxterm/xcframework_build -f build_libs=all
```

### 仅构建特定库

```bash
# 仅 OpenSSL
gh workflow run build-xcframeworks.yml -R foxterm/xcframework_build -f build_libs=openssl

# OpenSSL + CSSH
gh workflow run build-xcframeworks.yml -R foxterm/xcframework_build -f build_libs=openssl+cssh

# 仅 VNC (需要 OpenSSL 缓存)
gh workflow run build-xcframeworks.yml -R foxterm/xcframework_build -f build_libs=vnc
```

## 本地构建

### 前置要求

```bash
# macOS
brew install cmake ninja libtool autoconf automake nasm

# Xcode Command Line Tools
xcode-select --install
```

### 编译 OpenSSL

```bash
cd OpenSSL
bash build_xcframework.sh
```

### 编译 CSSH (libssh)

```bash
cd CSSH
# 确保 OpenSSL 已编译到 ../openssl_xcframework_build/
bash build_xcframework.sh
```

### 编译 VNC (libvncserver)

```bash
cd VNC
# 确保 OpenSSL 已编译到 ../openssl_xcframework_build/
bash build_xcframework.sh
```

## 仓库结构

```
xcframework_build/
├── .github/
│   └── workflows/
│       ├── build-xcframeworks.yml    # 构建工作流
│       └── check-versions.yml        # 版本检测工作流
├── OpenSSL/
│   ├── build_xcframework.sh          # OpenSSL 构建脚本
│   └── openssl_xcframework_build/    # 构建产物 (gitignored)
├── CSSH/
│   ├── build_xcframework.sh          # libssh 构建脚本
│   └── xcframework_build/            # 构建产物 (gitignored)
├── VNC/
│   ├── build_xcframework.sh          # libvncserver 构建脚本
│   └── xcframework_build/            # 构建产物 (gitignored)
├── vnc_master_hash.txt               # libvncserver master 分支追踪
└── README.md
```

## 环境变量

构建脚本支持通过环境变量覆盖默认配置：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `OPENSSL_VERSION` | OpenSSL 版本标签 | `openssl-4.1.0` |
| `LIBSSH_VERSION` | libssh 版本号 | `0.12.2` |
| `OPENSSL_BUILD_DIR` | OpenSSL 产物路径 (CI 用) | 脚本相对路径 |

示例：
```bash
OPENSSL_VERSION="openssl-4.0.0" bash OpenSSL/build_xcframework.sh
```

## Secrets 配置

| Secret | 说明 |
|--------|------|
| `GH_PAT` | GitHub Personal Access Token，用于跨仓库推送 xcframework |

PAT 需要 `repo` 权限，用于推送构建产物到：
- `foxterm/OpenSSL`
- `foxterm/SSH`
- `foxterm/VNC`

## 技术细节

### 编译目标

| 平台 | 架构 | 最低版本 |
|------|------|----------|
| macOS | arm64, x86_64 | macOS 14.0 |
| iOS | arm64 | iOS 17.0 |
| iOS Simulator | arm64 | iOS 17.0 |

### OpenSSL 裁剪清单

<details>
<summary>点击展开完整裁剪列表</summary>

**禁用的协议:**
- SSL 3.0, TLS 1.0, TLS 1.1, DTLS

**禁用的加密算法:**
- ARIA, Camellia, CAST, IDEA, RC2, RC5, SEED, SM2, SM3, SM4, Whirlpool, BLAKE2, RMD160, MD4

**禁用的功能:**
- Compression, OCB, CT, PSK, SRP, SRTP, Scrypt, TS, CMS, GOST, KTLS, FIPS

**禁用的模块:**
- Engine, Dynamic modules, Filenames tracking, Async operations

</details>

### libvncserver 依赖

VNC 构建包含以下静态链接的依赖：
- libjpeg-turbo (无 SIMD)
- libpng
- LZO 2.10

## 许可证

构建脚本遵循 MIT 许可证。各依赖库遵循其各自的许可证：
- OpenSSL: [Apache License 2.0](https://github.com/openssl/openssl/blob/master/LICENSE.txt)
- libssh: [LGPL 2.1](https://gitlab.com/libssh/libssh-mirror/-/blob/master/COPYING)
- libvncserver: [GPL 2.0](https://github.com/LibVNC/libvncserver/blob/master/COPYING)

---

<div align="center">

**为 [FoxTerm](https://foxterm.app) 打造**

*安全 · 高效 · 自动化*

</div>
