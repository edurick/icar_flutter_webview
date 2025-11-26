#!/bin/bash
# Script para remover atributos estendidos antes do codesign

FLUTTER_FRAMEWORK="${BUILD_DIR}/${CONFIGURATION}${EFFECTIVE_PLATFORM_NAME}/Flutter.framework"
if [ -d "$FLUTTER_FRAMEWORK" ]; then
    echo "Removendo atributos estendidos de Flutter.framework..."
    xattr -cr "$FLUTTER_FRAMEWORK" 2>/dev/null || true
    # Também remover do binário dentro do framework
    if [ -f "$FLUTTER_FRAMEWORK/Flutter" ]; then
        xattr -c "$FLUTTER_FRAMEWORK/Flutter" 2>/dev/null || true
    fi
fi

# Executar o comando original
exec "$@"

