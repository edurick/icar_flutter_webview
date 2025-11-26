#!/bin/bash
# Script para remover atributos estendidos antes do build
# Execute este script antes de fazer flutter build ios

echo "Removendo atributos estendidos de todo o projeto..."

# Remover atributos estendidos do diretório ios
cd "$(dirname "$0")"
xattr -rc . 2>/dev/null || true

# Remover atributos estendidos do diretório build se existir
if [ -d "../build/ios" ]; then
    echo "Removendo atributos estendidos do diretório build..."
    xattr -rc ../build/ios 2>/dev/null || true
fi

echo "✅ Atributos estendidos removidos!"

