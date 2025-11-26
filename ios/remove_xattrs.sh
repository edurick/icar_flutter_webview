#!/bin/bash
# Script para remover atributos estendidos que causam problemas no codesign

# Remover atributos estendidos do Flutter.framework se existir
FLUTTER_FRAMEWORK_PATH="${BUILD_DIR}/Release-iphoneos/Flutter.framework/Flutter"
if [ -f "$FLUTTER_FRAMEWORK_PATH" ]; then
    echo "Removendo atributos estendidos de Flutter.framework..."
    xattr -cr "${BUILD_DIR}/Release-iphoneos/Flutter.framework" 2>/dev/null || true
    xattr -cr "${BUILD_DIR}/Release-iphonesimulator/Flutter.framework" 2>/dev/null || true
fi

# Remover atributos estendidos de todos os frameworks no build
if [ -d "${BUILD_DIR}/Release-iphoneos" ]; then
    echo "Removendo atributos estendidos de todos os frameworks..."
    find "${BUILD_DIR}/Release-iphoneos" -name "*.framework" -exec xattr -cr {} \; 2>/dev/null || true
fi

if [ -d "${BUILD_DIR}/Release-iphonesimulator" ]; then
    find "${BUILD_DIR}/Release-iphonesimulator" -name "*.framework" -exec xattr -cr {} \; 2>/dev/null || true
fi

