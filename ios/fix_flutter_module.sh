#!/bin/bash

# Script para corrigir o problema "No such module 'Flutter'" no Xcode

# Obter o diretório do script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "🔧 Corrigindo problema do módulo Flutter no Xcode..."
echo "📁 Diretório do projeto: $PROJECT_ROOT"

# 1. Limpar build do Flutter
echo "📦 Limpando build do Flutter..."
cd "$PROJECT_ROOT"
flutter clean
flutter pub get

# 2. Limpar pods
echo "📦 Limpando pods..."
cd "$SCRIPT_DIR"
rm -rf Pods Podfile.lock
rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*

# 3. Reinstalar pods
echo "📦 Reinstalando pods..."
pod install --repo-update

# 4. Limpar build do Xcode
echo "🧹 Limpando build do Xcode..."
xcodebuild clean -workspace Runner.xcworkspace -scheme Runner 2>/dev/null || true

echo "✅ Concluído!"
echo ""
echo "📝 Próximos passos:"
echo "1. Feche o Xcode completamente"
echo "2. Abra o projeto usando: open ios/Runner.xcworkspace"
echo "3. No Xcode: Product → Clean Build Folder (Shift+Cmd+K)"
echo "4. No Xcode: File → Close Project e abra novamente"
echo "5. Tente compilar novamente"

