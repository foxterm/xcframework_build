#!/bin/bash

set -e

export GIT_ADVICE_DETACHED_HEAD=false

# ================= 配置区 =================
LLAMA_VERSION="v0.8.0"
MACOS_TARGET="14.0"
IOS_TARGET="17.0"

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/llama_xcframework_build"
SOURCE_DIR="${WORK_DIR}/sources"
BUILD_DIR="${WORK_DIR}/build"
OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/xcframework"

mkdir -p "${SOURCE_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

# 依赖检查
FOR_CMDS="git curl cmake xcodebuild xcrun libtool"
for cmd in $FOR_CMDS; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd 未安装，请先安装 (例: brew install cmake; xcode-select --install)"
        exit 1
    fi
done

# ================= 1. 源码下载 =================
echo "==> [1/4] 克隆 llama.cpp 源码..."

if [ ! -d "${SOURCE_DIR}/llama.cpp" ]; then
    echo "正在克隆 llama.cpp (${LLAMA_VERSION})..."
    git clone --depth 1 --branch "${LLAMA_VERSION}" https://github.com/ggml-org/llama.cpp.git "${SOURCE_DIR}/llama.cpp"
fi

# ================= 2. 编译各平台 (CMake + Xcode Generator) =================
# 选项与 llama.cpp 官方 build-xcframework.sh 保持一致：
#   - GGML_METAL_EMBED_LIBRARY=ON: 将 .metallib 嵌入静态库，无需外部资源
#   - GGML_NATIVE=OFF: 交叉编译/通用架构，禁止按构建机指令集优化
#   - GGML_OPENMP=OFF: 避免依赖 libomp
#   - LLAMA_BUILD_MTMD=ON: 多模态支持 (CLIP/vision)
#   - LLAMA_OPENSSL=OFF: 纯本地推理，不需要 OpenSSL/HTTPS

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_APP=OFF
    -DLLAMA_BUILD_COMMON=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_MTMD=ON
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DLLAMA_OPENSSL=OFF
    -DMTMD_VIDEO=OFF
)

compile_llama_single_platform() {
    local target_id=$1
    local sysroot=$2            # macosx / iphoneos / iphonesimulator
    local architectures=$3
    local min_target=$4
    local metal_target_os=$5    # macos / ios

    local bdir="${BUILD_DIR}/llama_${target_id}"
    rm -rf "${bdir}"
    mkdir -p "${bdir}"

    echo "---> 编译 llama.cpp [Release] [${target_id}] (${architectures})..."

    # iOS 需要显式指定 CMAKE_SYSTEM_NAME / SYSROOT；macOS 为原生编译
    local ios_args=()
    if [ "${sysroot}" != "macosx" ]; then
        ios_args+=(
            -DCMAKE_SYSTEM_NAME=iOS
            -DCMAKE_OSX_SYSROOT="${sysroot}"
            -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="${sysroot}"
        )
    fi

    cmake -B "${bdir}" -S "${SOURCE_DIR}/llama.cpp" -G Xcode \
        "${COMMON_CMAKE_ARGS[@]}" \
        "${ios_args[@]}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${min_target}" \
        -DCMAKE_OSX_ARCHITECTURES="${architectures}" \
        -DGGML_METAL_TARGET_OS="${metal_target_os}"

    cmake --build "${bdir}" --config Release -j"$(sysctl -n hw.ncpu)"
}

echo "==> [2/4] 构建各平台 llama.cpp 静态库..."
compile_llama_single_platform "macos"    "macosx"          "arm64;x86_64" "${MACOS_TARGET}" "macos"
compile_llama_single_platform "ios"      "iphoneos"        "arm64"        "${IOS_TARGET}"   "ios"
compile_llama_single_platform "ios-sim"  "iphonesimulator" "arm64"        "${IOS_TARGET}"   "ios"

# ================= 3. 合并静态库 (单库 libllama.a) 与符号剥离 =================
echo "==> [3/4] 合并 llama + ggml 系列静态库为单库，并剥离符号..."

# 与官方 build-xcframework.sh 合并清单一致。
# Xcode Generator 产物路径: <target_dir>/<CONFIG><EFFECTIVE_PLATFORM_NAME>/
#   macOS: Release, iOS: Release-iphoneos, Simulator: Release-iphonesimulator
LLAMA_LIB_SUBDIRS=(
    "src"
    "ggml/src"
    "ggml/src"
    "ggml/src"
    "ggml/src/ggml-metal"
    "ggml/src/ggml-blas"
    "tools/mtmd"
    "vendor/hash"
)
LLAMA_LIB_NAMES=(
    "libllama.a"
    "libggml.a"
    "libggml-base.a"
    "libggml-cpu.a"
    "libggml-metal.a"
    "libggml-blas.a"
    "libmtmd.a"
    "libvendor-hash.a"
)

merge_libs() {
    local target_id=$1
    local out_dir=$2
    local config_dir=$3    # Release / Release-iphoneos / Release-iphonesimulator
    local bdir="${BUILD_DIR}/llama_${target_id}"

    mkdir -p "${out_dir}"

    local lib_args=()
    for i in "${!LLAMA_LIB_SUBDIRS[@]}"; do
        local lib="${bdir}/${LLAMA_LIB_SUBDIRS[$i]}/${config_dir}/${LLAMA_LIB_NAMES[$i]}"
        if [ ! -f "${lib}" ]; then
            echo "Error: 缺少静态库 ${lib}，编译可能失败"
            exit 1
        fi
        lib_args+=("${lib}")
    done

    echo "---> 合并 [${target_id}] 静态库..."
    libtool -static -o "${out_dir}/libllama.a" "${lib_args[@]}"

    # strip -S: 剥离调试符号，保留全部全局符号 (C++ 链接所需)
    strip -S "${out_dir}/libllama.a"
}

merge_libs "macos"   "${BUILD_DIR}/packaged_macos"           "Release"
merge_libs "ios"     "${BUILD_DIR}/packaged_ios"             "Release-iphoneos"
merge_libs "ios-sim" "${BUILD_DIR}/packaged_ios-simulator"   "Release-iphonesimulator"

# ================= 4. 自动生成 Llama.h 与 modulemap 并打包 XCFramework =================
echo "==> [4/4] 打包生成 Release 版 llama.xcframework..."

prepare_headers() {
    local platform_name=$1
    local target_headers_dir="${BUILD_DIR}/Headers_${platform_name}"
    local src_dir="${SOURCE_DIR}/llama.cpp"

    rm -rf "${target_headers_dir}"
    mkdir -p "${target_headers_dir}/llama"

    # 拷贝全部公共头文件到 llama/ 子目录 (与 OpenSSL 的 openssl/ 子目录模式一致)
    cp "${src_dir}/include/llama.h"            "${target_headers_dir}/llama/"
    cp "${src_dir}/include/llama-cpp.h"        "${target_headers_dir}/llama/"
    cp "${src_dir}/ggml/include/ggml.h"        "${target_headers_dir}/llama/"
    cp "${src_dir}/ggml/include/ggml-opt.h"    "${target_headers_dir}/llama/"
    cp "${src_dir}/ggml/include/ggml-alloc.h"  "${target_headers_dir}/llama/"
    cp "${src_dir}/ggml/include/ggml-backend.h" "${target_headers_dir}/llama/"
    cp "${src_dir}/ggml/include/ggml-metal.h"  "${target_headers_dir}/llama/"
    cp "${src_dir}/ggml/include/ggml-cpu.h"    "${target_headers_dir}/llama/"
    cp "${src_dir}/ggml/include/ggml-blas.h"   "${target_headers_dir}/llama/"
    cp "${src_dir}/ggml/include/gguf.h"        "${target_headers_dir}/llama/"
    cp "${src_dir}/tools/mtmd/mtmd.h"          "${target_headers_dir}/llama/"
    cp "${src_dir}/tools/mtmd/mtmd-helper.h"   "${target_headers_dir}/llama/"

    # Umbrella Header
    # 注意: 不能命名为 Llama.h — macOS 文件系统大小写不敏感，会覆盖真实的 llama.h
    cat << 'EOF' > "${target_headers_dir}/llama/LlamaUmbrella.h"
/* Automatically generated Llama Umbrella Header */
#ifndef LLAMA_UMBRELLA_H
#define LLAMA_UMBRELLA_H

#include "llama.h"
#include "llama-cpp.h"
#include "ggml.h"
#include "ggml-opt.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-metal.h"
#include "ggml-cpu.h"
#include "ggml-blas.h"
#include "gguf.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#endif /* LLAMA_UMBRELLA_H */
EOF

    # modulemap: 声明自动链接 c++ 运行时与系统框架
    cat << 'EOF' > "${target_headers_dir}/llama/module.modulemap"
module Llama {
    umbrella header "LlamaUmbrella.h"
    export *

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
}
EOF
}

prepare_headers "macos"
prepare_headers "ios"
prepare_headers "ios-simulator"

rm -rf "${OUTPUT_DIR}/llama.xcframework"

xcodebuild -create-xcframework \
    -library "${BUILD_DIR}/packaged_macos/libllama.a" -headers "${BUILD_DIR}/Headers_macos" \
    -library "${BUILD_DIR}/packaged_ios/libllama.a" -headers "${BUILD_DIR}/Headers_ios" \
    -library "${BUILD_DIR}/packaged_ios-simulator/libllama.a" -headers "${BUILD_DIR}/Headers_ios-simulator" \
    -output "${OUTPUT_DIR}/llama.xcframework"

# ================= 体积报告 =================
echo ""
echo "=========================================="
echo "构建完成！体积报告："
echo "=========================================="
printf "%-20s %10s\n" "平台" "大小"
echo "------------------------------------------"
for platform in macos ios ios-simulator; do
    lib_path="${BUILD_DIR}/packaged_${platform}/libllama.a"
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
xcfw_size=$(du -sh "${OUTPUT_DIR}/llama.xcframework" 2>/dev/null | cut -f1)
echo "xcframework 总大小:  ${xcfw_size}"
echo "输出: ${OUTPUT_DIR}/llama.xcframework"
echo "=========================================="
