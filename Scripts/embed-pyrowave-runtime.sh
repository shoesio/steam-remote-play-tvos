#!/bin/sh
set -eu

PYROWAVE_DYLIB="${PYROWAVE_DYLIB:-${PROJECT_DIR}/Runtime/PyroWave/libpyrowave-shared.0.4.0.dylib}"
MOLTENVK_FRAMEWORK="${MOLTENVK_FRAMEWORK:-${PROJECT_DIR}/Runtime/PyroWave/MoltenVK.framework}"

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${FRAMEWORKS_FOLDER_PATH:-}" ]; then
    echo "warning: PyroWave runtime embed skipped; Xcode build paths are unavailable"
    exit 0
fi

DESTINATION="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${DESTINATION}"

sign_runtime_item() {
    item="$1"
    if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
        return
    fi
    if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        return
    fi

    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${item}"
}

if [ -f "${PYROWAVE_DYLIB}" ]; then
    cp -f "${PYROWAVE_DYLIB}" "${DESTINATION}/libpyrowave-shared.0.dylib"
    chmod 0755 "${DESTINATION}/libpyrowave-shared.0.dylib"
    sign_runtime_item "${DESTINATION}/libpyrowave-shared.0.dylib"
else
    echo "warning: PyroWave dylib not found at ${PYROWAVE_DYLIB}; runtime decoder will stay disabled"
fi

if [ -f "${MOLTENVK_FRAMEWORK}/MoltenVK" ] && [ -f "${MOLTENVK_FRAMEWORK}/Info.plist" ]; then
    rm -rf "${DESTINATION}/MoltenVK.framework"
    cp -R "${MOLTENVK_FRAMEWORK}" "${DESTINATION}/MoltenVK.framework"
    sign_runtime_item "${DESTINATION}/MoltenVK.framework"
else
    echo "warning: Complete MoltenVK tvOS framework not found at ${MOLTENVK_FRAMEWORK}; PyroWave Vulkan device creation may fail"
fi
