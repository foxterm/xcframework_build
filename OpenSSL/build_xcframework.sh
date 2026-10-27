#!/bin/bash

set -e

export GIT_ADVICE_DETACHED_HEAD=false

# ================= 配置区 =================
OPENSSL_VERSION="openssl-4.1.0"
MACOS_TARGET="14.0"
IOS_TARGET="17.0"

WORK_DIR="$(pwd)/openssl_xcframework_build"
SOURCE_DIR="${WORK_DIR}/sources"
BUILD_DIR="${WORK_DIR}/build"
OUTPUT_DIR="$(pwd)/xcframework"

mkdir -p "${SOURCE_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

# 依赖检查
FOR_CMDS="git curl tar xcodebuild make perl libtool"
for cmd in $FOR_CMDS; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd 未安装，请先安装"
        exit 1
    fi
done

# ================= 1. 源码下载 =================
echo "==> [1/4] 克隆与下载 OpenSSL 源码..."

if [ ! -d "${SOURCE_DIR}/openssl" ]; then
    echo "正在克隆 OpenSSL (${OPENSSL_VERSION})..."
    git clone --depth 1 --branch "${OPENSSL_VERSION}" https://github.com/openssl/openssl.git "${SOURCE_DIR}/openssl"
fi

# ================= 2. 编译各架构 OpenSSL (极致体积优化) =================

# 裁剪标志：基于 libssh + libvncserver 实际使用的 API 精确裁剪
# 保留: AES, DES, Blowfish, ChaCha20, Poly1305, RSA, ECDSA, Ed25519, ECDH, X25519, SHA-1/2, MD5, HMAC, TLS/SSL, X509
OPENSSL_NO_FLAGS=(
    no-shared
    no-async
    no-tests
    no-dso

    # 旧协议
    no-ssl3
    no-tls1
    no-tls1_1
    no-dtls
    no-dtls1
    no-dtls1_2

    # 不需要的加密算法（libssh/libvnc 不使用）
    no-aria
    no-camellia
    no-cast
    no-idea
    no-rc2
    no-rc5
    no-seed
    no-sm2
    no-sm3
    no-sm4
    no-whirlpool
    no-blake2
    no-rmd160
    no-md4

    # 不需要的功能
    no-comp
    no-ocb
    no-ct
    no-psk
    no-srp
    no-srtp
    no-scrypt
    no-ts
    no-cms
    no-gost
    no-ktls
    no-fips
    no-ec_nistp_64_gcc_128

    # 引擎 / 动态模块（静态库不需要）
    no-engine
    no-static-engine
    no-module

    # 杂项
    no-filenames
    no-pinshared
    no-autoload-config
    no-makedepend
    no-uplink
    no-dgram
)

compile_openssl_single_arch() {
    local target_id=$1
    local arch=$2
    local sysroot_name=$3
    local os_compiler=$4
    local min_flag=$5

    local install_prefix="${BUILD_DIR}/install_${target_id}"
    local bdir="${BUILD_DIR}/openssl_${target_id}"

    rm -rf "${bdir}" "${install_prefix}"
    mkdir -p "${bdir}" "${install_prefix}"

    echo "---> 编译 OpenSSL [MinSize] [${target_id}]..."

    local sdk_path=$(xcrun --sdk "${sysroot_name}" --show-sdk-path)
    local cc_path=$(xcrun -sdk "${sysroot_name}" -find cc)

    # Out-of-tree 编译：避免拷贝整份源码
    pushd "${bdir}" > /dev/null

    export CC="${cc_path}"
    # -Oz: Apple Clang 最激进的体积优化（比 -Os 更小）
    # -fvisibility=hidden: 隐藏内部符号，减小符号表
    # LTO 不在静态库编译期做，由最终 App 链接时统一执行
    export CFLAGS="${min_flag} -isysroot ${sdk_path} -arch ${arch} -Oz -fvisibility=hidden -DNDEBUG -fomit-frame-pointer"

    perl "${SOURCE_DIR}/openssl/Configure" "${os_compiler}" \
        "${OPENSSL_NO_FLAGS[@]}" \
        --prefix="${install_prefix}" \
        --openssldir="${install_prefix}"

    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_dev

    popd > /dev/null
}

echo "==> [2/4] 构建各架构 OpenSSL 极致体积静态库..."
compile_openssl_single_arch "macos-arm64"       "arm64"  "macosx"          "darwin64-arm64-cc"         "-mmacosx-version-min=${MACOS_TARGET}"
compile_openssl_single_arch "macos-x86_64"      "x86_64" "macosx"          "darwin64-x86_64-cc"        "-mmacosx-version-min=${MACOS_TARGET}"
compile_openssl_single_arch "ios-arm64"         "arm64"  "iphoneos"        "ios64-cross"               "-miphoneos-version-min=${IOS_TARGET}"
compile_openssl_single_arch "ios-sim-arm64"     "arm64"  "iphonesimulator" "iossimulator-arm64-xcrun"  "-mios-simulator-version-min=${IOS_TARGET}"

# ================= 3. 合并双库 (.a -> 单个 libopenssl.a) 与符号剥离 =================
echo "==> [3/4] 合并 libssl.a + libcrypto.a 为单库，并剥离符号..."

mkdir -p "${BUILD_DIR}/packaged_macos" \
         "${BUILD_DIR}/packaged_ios" \
         "${BUILD_DIR}/packaged_ios-simulator"

merge_libs() {
    local target_id=$1
    local out_dir=$2
    local lib_dir="${BUILD_DIR}/install_${target_id}/lib"

    libtool -static -o "${out_dir}/libopenssl.a" \
        "${lib_dir}/libssl.a" \
        "${lib_dir}/libcrypto.a"
}

merge_libs "ios-arm64"     "${BUILD_DIR}/packaged_ios"
merge_libs "ios-sim-arm64" "${BUILD_DIR}/packaged_ios-simulator"

mkdir -p "${BUILD_DIR}/tmp_macos_arm64" "${BUILD_DIR}/tmp_macos_x86_64"
merge_libs "macos-arm64"  "${BUILD_DIR}/tmp_macos_arm64"
merge_libs "macos-x86_64" "${BUILD_DIR}/tmp_macos_x86_64"

lipo -create \
    "${BUILD_DIR}/tmp_macos_arm64/libopenssl.a" \
    "${BUILD_DIR}/tmp_macos_x86_64/libopenssl.a" \
    -output "${BUILD_DIR}/packaged_macos/libopenssl.a"

# strip -x: 剥离所有本地符号（比 -S 更彻底）
strip -x "${BUILD_DIR}/packaged_macos/libopenssl.a"
strip -x "${BUILD_DIR}/packaged_ios/libopenssl.a"
strip -x "${BUILD_DIR}/packaged_ios-simulator/libopenssl.a"

# ================= 4. 自动扫描生成 OpenSSL.h 与 modulemap =================
echo "==> [4/4] 打包生成 Release 版 OpenSSL.xcframework..."

prepare_headers() {
    local platform_name=$1
    local sample_target_id=$2
    local target_headers_dir="${BUILD_DIR}/Headers_${platform_name}"

    rm -rf "${target_headers_dir}"
    mkdir -p "${target_headers_dir}"

    cp -R "${BUILD_DIR}/install_${sample_target_id}/include/openssl" "${target_headers_dir}/"

    local umbrella_file="${target_headers_dir}/openssl/OpenSSL.h"
    echo "/* Automatically generated OpenSSL Umbrella Header */" > "${umbrella_file}"
    echo "#ifndef OPENSSL_H" >> "${umbrella_file}"
    echo "#define OPENSSL_H" >> "${umbrella_file}"
    echo "" >> "${umbrella_file}"

    find "${target_headers_dir}/openssl" -maxdepth 1 -name "*.h" | while read -r header_path; do
        local header_name=$(basename "$header_path")
        if [ "$header_name" != "OpenSSL.h" ]; then
            echo "#include <openssl/${header_name}>" >> "${umbrella_file}"
        fi
    done

    echo "" >> "${umbrella_file}"
    echo "#endif /* OPENSSL_H */" >> "${umbrella_file}"

    cat << 'EOF' > "${target_headers_dir}/openssl/module.modulemap"
module OpenSSL {
    umbrella header "OpenSSL.h"
    export *
}
EOF
}

prepare_headers "macos" "macos-arm64"
prepare_headers "ios" "ios-arm64"
prepare_headers "ios-simulator" "ios-sim-arm64"

rm -rf "${OUTPUT_DIR}/OpenSSL.xcframework"

xcodebuild -create-xcframework \
    -library "${BUILD_DIR}/packaged_macos/libopenssl.a" -headers "${BUILD_DIR}/Headers_macos" \
    -library "${BUILD_DIR}/packaged_ios/libopenssl.a" -headers "${BUILD_DIR}/Headers_ios" \
    -library "${BUILD_DIR}/packaged_ios-simulator/libopenssl.a" -headers "${BUILD_DIR}/Headers_ios-simulator" \
    -output "${OUTPUT_DIR}/OpenSSL.xcframework"

# ================= 体积报告 =================
echo ""
echo "=========================================="
echo "构建完成！体积报告："
echo "=========================================="
printf "%-20s %10s\n" "平台" "大小"
echo "------------------------------------------"
for platform in macos ios ios-simulator; do
    lib_path="${BUILD_DIR}/packaged_${platform}/libopenssl.a"
    if [ -f "${lib_path}" ]; then
        size_bytes=$(stat -f%z "${lib_path}" 2>/dev/null || stat -c%s "${lib_path}")
        if [ "${size_bytes}" -ge 1048576 ]; then
            size_display="$(echo "scale=2; ${size_bytes} / 1048576" | bc) MB"
        else
            size_display="$(echo "scale=2; ${size_bytes} / 1024" | bc) KB"
        fi
        printf "%-20s %10s\n" "${platform}" "${size_display}"
    fi
done
echo "------------------------------------------"
xcfw_size=$(du -sh "${OUTPUT_DIR}/OpenSSL.xcframework" 2>/dev/null | cut -f1)
echo "xcframework 总大小:  ${xcfw_size}"
echo "输出: ${OUTPUT_DIR}/OpenSSL.xcframework"
echo "=========================================="
