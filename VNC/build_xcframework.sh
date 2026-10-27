#!/bin/bash

set -e

export GIT_ADVICE_DETACHED_HEAD=false

# ================= 配置区 =================
MACOS_TARGET="14.0"
IOS_TARGET="17.0"
LZO_VERSION="2.10"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/xcframework_build"
SOURCE_DIR="${WORK_DIR}/sources"
DEPS_DIR="${WORK_DIR}/deps"
BUILD_DIR="${WORK_DIR}/build"
OUTPUT_DIR="${SCRIPT_DIR}/xcframework"

# OpenSSL 预编译产物路径 (CI 通过环境变量覆盖，本地运行使用默认相对路径)
OPENSSL_BUILD_DIR="${OPENSSL_BUILD_DIR:-${SCRIPT_DIR}/../openssl_xcframework_build}"
OPENSSL_BUILD_DIR="$(cd "${OPENSSL_BUILD_DIR}" && pwd)"

mkdir -p "${SOURCE_DIR}" "${DEPS_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

# 依赖检查
FOR_CMDS="cmake ninja git curl tar xcodebuild libtool nasm lipo autoconf automake"
for cmd in $FOR_CMDS; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd 未安装，请先安装 (例: brew install cmake ninja nasm autoconf automake libtool)"
        exit 1
    fi
done

# 检查 glibtoolize 或 libtoolize
if ! command -v glibtoolize &> /dev/null && ! command -v libtoolize &> /dev/null; then
    echo "Error: 未找到 libtoolize / glibtoolize，请先执行: brew install libtool"
    exit 1
fi

# 检查 OpenSSL 预编译目录是否存在
if [ ! -d "${OPENSSL_BUILD_DIR}" ]; then
    echo "Error: 未找到 OpenSSL 预编译路径: ${OPENSSL_BUILD_DIR}，请先编译 OpenSSL！"
    exit 1
fi

# ================= 1. 源码下载 (全部采用 Git Clone) =================
echo "==> [1/4] 克隆依赖库与主项目源码..."

#rm -rf "${SOURCE_DIR}/libvncserver"
if [ ! -d "${SOURCE_DIR}/libvncserver" ]; then
   git clone --depth 1 -b master https://github.com/LibVNC/libvncserver.git "${SOURCE_DIR}/libvncserver"
fi

# if [ ! -d "${SOURCE_DIR}/zlib" ]; then
#     git clone https://github.com/madler/zlib.git "${SOURCE_DIR}/zlib"
# fi

if [ ! -d "${SOURCE_DIR}/jpeg" ]; then
    git clone https://github.com/libjpeg-turbo/libjpeg-turbo.git "${SOURCE_DIR}/jpeg"
fi

if [ ! -d "${SOURCE_DIR}/png" ]; then
    git clone https://github.com/pnggroup/libpng.git "${SOURCE_DIR}/png"
fi

if [ ! -d "${SOURCE_DIR}/lzo" ]; then
    echo "正在下载 LZO (${LZO_VERSION})..."
    mkdir -p "${SOURCE_DIR}/lzo"
    curl -L "https://www.oberhumer.com/opensource/lzo/download/lzo-${LZO_VERSION}.tar.gz" | tar -xz -C "${SOURCE_DIR}/lzo" --strip-components=1
fi



# ================= 2. 编译依赖库 (单架构基础函数) =================
compile_deps_single_arch() {
    local target_id=$1
    local arch=$2
    local sysroot=$3
    local min_flag=$4

    local install_prefix="${DEPS_DIR}/${target_id}"
    mkdir -p "${install_prefix}"

    echo "---> 编译依赖库 [${target_id}]..."

    # 1. Zlib
    # if [ ! -f "${install_prefix}/lib/libz.a" ]; then
    #     local bdir="${BUILD_DIR}/deps_build/${target_id}/zlib"
    #     cmake -B "${bdir}" -S "${SOURCE_DIR}/zlib" -G Ninja \
    #         -DCMAKE_BUILD_TYPE=Release \
    #         -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
    #         -DCMAKE_OSX_SYSROOT="${sysroot}" \
    #         -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    #         -DCMAKE_C_FLAGS="${min_flag}" \
    #         -DBUILD_SHARED_LIBS=OFF
    #     cmake --build "${bdir}" --target install
    # fi

    # 2. Libjpeg-turbo
    if [ ! -f "${install_prefix}/lib/libjpeg.a" ]; then
        local bdir="${BUILD_DIR}/deps_build/${target_id}/jpeg"
        cmake -B "${bdir}" -S "${SOURCE_DIR}/jpeg" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
            -DCMAKE_OSX_ARCHITECTURES="${arch}" \
            -DCMAKE_C_FLAGS="${min_flag}" \
            -DENABLE_SHARED=OFF \
            -DWITH_SIMD=OFF
        cmake --build "${bdir}" --target install
    fi

    # 3. Libpng
    if [ ! -f "${install_prefix}/lib/libpng.a" ]; then
        local bdir="${BUILD_DIR}/deps_build/${target_id}/png"
        cmake -B "${bdir}" -S "${SOURCE_DIR}/png" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
            -DCMAKE_OSX_SYSROOT="${sysroot}" \
            -DCMAKE_OSX_ARCHITECTURES="${arch}" \
            -DCMAKE_C_FLAGS="${min_flag} -I${install_prefix}/include" \
            -DPNG_SHARED=OFF \
            -DPNG_TESTS=OFF \
            -DPNG_ARM_NEON=off
            # -DZLIB_INCLUDE_DIR="${install_prefix}/include" \
            # -DZLIB_LIBRARY="${install_prefix}/lib/libz.a"
        cmake --build "${bdir}" --target install
    fi

    # 4. LZO
    if [ ! -f "${install_prefix}/lib/liblzo2.a" ]; then
        local bdir="${BUILD_DIR}/deps_build/${target_id}/lzo"
        cmake -B "${bdir}" -S "${SOURCE_DIR}/lzo" -G Ninja \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
            -DCMAKE_OSX_SYSROOT="${sysroot}" \
            -DCMAKE_OSX_ARCHITECTURES="${arch}" \
            -DCMAKE_C_FLAGS="${min_flag}" \
            -DENABLE_SHARED=OFF \
            -DENABLE_STATIC=ON
        cmake --build "${bdir}" --target install
    fi


}

echo "==> [2/4] 构建各架构依赖库..."
compile_deps_single_arch "macos-arm64" "arm64" "macosx" "-mmacosx-version-min=${MACOS_TARGET}"
compile_deps_single_arch "macos-x86_64" "x86_64" "macosx" "-mmacosx-version-min=${MACOS_TARGET}"

compile_deps_single_arch "ios-arm64" "arm64" "iphoneos" "-miphoneos-version-min=${IOS_TARGET}"
compile_deps_single_arch "ios-sim-arm64" "arm64" "iphonesimulator" "-mios-simulator-version-min=${IOS_TARGET}"

# ================= 3. 编译 LibVNCClient 并合并静态库 =================
compile_libvnc_single_arch() {
    local target_id=$1
    local arch=$2
    local sysroot=$3
    local min_flag=$4

    local deps="${DEPS_DIR}/${target_id}"
    local bdir="${BUILD_DIR}/vnc_${target_id}"
    local target_out="${BUILD_DIR}/packaged_${target_id}"

    # 映射外部 OpenSSL 对应的架构产物目录
    local openssl_arch_dir="${OPENSSL_BUILD_DIR}/build/install_${target_id}"
    if [ ! -d "${openssl_arch_dir}" ]; then
        echo "Error: 找不到 OpenSSL 针对架构 [${target_id}] 的产物目录: ${openssl_arch_dir}"
        exit 1
    fi

    mkdir -p "${target_out}"


    echo "---> 编译 LibVNCClient [${target_id}]..."

    # 2. 重新编译前强制清理 CMake 构建缓存，防止头文件定义污染
    rm -rf "${bdir}"

    cmake -B "${bdir}" -S "${SOURCE_DIR}/libvncserver" -G Ninja \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_SYSROOT="${sysroot}" \
        -DCMAKE_OSX_ARCHITECTURES="${arch}" \
        -DCMAKE_C_FLAGS="${min_flag} -I${deps}/include" \
        -DCMAKE_EXE_LINKER_FLAGS="-L${deps}/lib" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_LIBVNCSERVER=OFF \
        -DWITH_LIBVNCCLIENT=ON \
        -DWITH_ZLIB=ON \
        -DWITH_LZO=ON \
        -DLZO_INCLUDE_DIR="${deps}/include" \
        -DLZO_LIBRARY="${deps}/lib/liblzo2.a" \
        -DWITH_JPEG=ON \
        -DJPEG_INCLUDE_DIR="${deps}/include" \
        -DJPEG_LIBRARY="${deps}/lib/libjpeg.a" \
        -DWITH_PNG=ON \
        -DPNG_PNG_INCLUDE_DIR="${deps}/include" \
        -DPNG_INCLUDE_DIR="${deps}/include" \
        -DPNG_LIBRARY="${deps}/lib/libpng.a" \
        -DWITH_OPENSSL=ON \
        -DOPENSSL_ROOT_DIR="${openssl_arch_dir}" \
        -DOPENSSL_INCLUDE_DIR="${openssl_arch_dir}/include" \
        -DOPENSSL_LIBRARIES="${openssl_arch_dir}/lib/libssl.a;${openssl_arch_dir}/lib/libcrypto.a" \
        -DWITH_SASL=OFF \
        -DWITH_TIGHTVNC_FILETRANSFER=ON \
        -DWITH_WEBSOCKETS=ON \
        -DWITH_24BPP=ON \
        -DWITH_IPv6=ON \
        -DWITH_THREADS=ON \
        -DWITH_GCRYPT=OFF \
        -DWITH_GNUTLS=OFF \
        -DWITH_EXAMPLES=OFF \
        -DWITH_TESTS=OFF \
        -DWITH_SDL=OFF \
        -DWITH_GTK=OFF \
        -DWITH_QT=OFF


    cmake --build "${bdir}" --target vncclient

    libtool -static -o "${target_out}/libvncclient.a" \
        "${bdir}/libvncclient.a" \
        "${deps}/lib/libjpeg.a" \
        "${deps}/lib/libpng.a" \
        "${deps}/lib/liblzo2.a"
}


echo "==> [3/4] 编译各架构 LibVNCClient 并合并依赖..."
compile_libvnc_single_arch "macos-arm64" "arm64" "macosx" "-mmacosx-version-min=${MACOS_TARGET}"
compile_libvnc_single_arch "macos-x86_64" "x86_64" "macosx" "-mmacosx-version-min=${MACOS_TARGET}"

compile_libvnc_single_arch "ios-arm64" "arm64" "iphoneos" "-miphoneos-version-min=${IOS_TARGET}"
compile_libvnc_single_arch "ios-sim-arm64" "arm64" "iphonesimulator" "-mios-simulator-version-min=${IOS_TARGET}"

echo "---> 打包各 Platform 静态库..."
mkdir -p "${BUILD_DIR}/packaged_macos" "${BUILD_DIR}/packaged_ios-simulator" "${BUILD_DIR}/packaged_ios"

lipo -create \
    "${BUILD_DIR}/packaged_macos-arm64/libvncclient.a" \
    "${BUILD_DIR}/packaged_macos-x86_64/libvncclient.a" \
    -output "${BUILD_DIR}/packaged_macos/libvncclient.a"

cp "${BUILD_DIR}/packaged_ios-sim-arm64/libvncclient.a" "${BUILD_DIR}/packaged_ios-simulator/libvncclient.a"
cp "${BUILD_DIR}/packaged_ios-arm64/libvncclient.a" "${BUILD_DIR}/packaged_ios/libvncclient.a"

# ================= 4. 构建 Headers 及最终 XCFramework =================
echo "==> [4/4] 打包生成 XCFramework..."

# 修正后的 Headers 准备函数
prepare_headers() {
    local platform_name=$1
    local sample_bdir=$2
    local target_headers_dir="${BUILD_DIR}/Headers_${platform_name}"

    # 清理并创建干净的目录结构
    rm -rf "${target_headers_dir}"

    # 1. 必须建立 rfb 子目录，因为头文件内部互相引用的是 <rfb/xxx.h>
    local rfb_dir="${target_headers_dir}/rfb"
    mkdir -p "${rfb_dir}"
    mkdir -p "${target_headers_dir}/libvncclient"

    # 2. 复制源码头文件到 rfb 目录下
    cp "${SOURCE_DIR}/libvncserver/include/rfb/keysym.h" "${rfb_dir}/"
    cp "${SOURCE_DIR}/libvncserver/include/rfb/threading.h" "${rfb_dir}/"
    cp "${SOURCE_DIR}/libvncserver/include/rfb/rfbproto.h" "${rfb_dir}/"
    cp "${SOURCE_DIR}/libvncserver/include/rfb/rfbregion.h" "${rfb_dir}/"
    cp "${SOURCE_DIR}/libvncserver/include/rfb/rfbclient.h" "${rfb_dir}/"

    # 3. 复制平台专有的 rfbconfig.h
    cp "${BUILD_DIR}/${sample_bdir}/include/rfb/rfbconfig.h" "${rfb_dir}/"

    # 4. 创建标准的 Umbrella Header（放在 Headers 根目录）
    cat << 'EOF' > "${target_headers_dir}/libvncclient/rfb.h"
#include <rfb/rfbconfig.h>
#include <rfb/keysym.h>
#include <rfb/threading.h>
#include <rfb/rfbproto.h>
#include <rfb/rfbregion.h>
#include <rfb/rfbclient.h>
EOF

    # 5. 创建标准命名的 modulemap（直接命名为 module.modulemap，且内部路径加上 rfb/ 前缀）
    cat << 'EOF' > "${target_headers_dir}/libvncclient/module.modulemap"
module libvncclient {
    umbrella header "rfb.h"
    export *
}
EOF
}


# 分别准备 3 个平台各自专属的 Headers 目录
prepare_headers "macos" "vnc_macos-arm64"
prepare_headers "ios" "vnc_ios-arm64"
prepare_headers "ios-simulator" "vnc_ios-sim-arm64"

rm -rf "${OUTPUT_DIR}/libvncclient.xcframework"

# 打包时各 Platform 关联自己专属的 -headers 目录
xcodebuild -create-xcframework \
    -library "${BUILD_DIR}/packaged_macos/libvncclient.a" -headers "${BUILD_DIR}/Headers_macos" \
    -library "${BUILD_DIR}/packaged_ios/libvncclient.a" -headers "${BUILD_DIR}/Headers_ios" \
    -library "${BUILD_DIR}/packaged_ios-simulator/libvncclient.a" -headers "${BUILD_DIR}/Headers_ios-simulator" \
    -output "${OUTPUT_DIR}/libvncclient.xcframework"

echo "=========================================="
echo "完成！已成功构建 XCFramework（iOS 已隔离并禁用 SASL）"
echo "输出文件: ${OUTPUT_DIR}/libvncclient.xcframework"
echo "=========================================="
