#!/usr/bin/env python3
"""
Script para gerar ícones do Android e iOS a partir do iCar.png
"""

import sys
import os
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow não está instalado. Instalando...")
    os.system("pip3 install Pillow --user")
    from PIL import Image

# Tamanhos necessários para Android (em pixels)
ANDROID_SIZES = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

# Tamanhos necessários para iOS (em pixels)
IOS_SIZES = {
    'Icon-App-20x20@1x.png': 20,
    'Icon-App-20x20@2x.png': 40,
    'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29,
    'Icon-App-29x29@2x.png': 58,
    'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40,
    'Icon-App-40x40@2x.png': 80,
    'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120,
    'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76,
    'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
}

def generate_android_icons(source_image, output_dir):
    """Gera os ícones do Android em diferentes tamanhos"""
    source_path = Path(source_image)
    output_path = Path(output_dir)
    
    if not source_path.exists():
        print(f"❌ Arquivo não encontrado: {source_image}")
        return False
    
    # Abrir imagem original
    try:
        img = Image.open(source_path)
        print(f"✅ Imagem carregada: {img.size[0]}x{img.size[1]} pixels")
    except Exception as e:
        print(f"❌ Erro ao abrir imagem: {e}")
        return False
    
    # Gerar ícones para cada resolução Android
    print("\n📱 Gerando ícones para Android...")
    for folder, size in ANDROID_SIZES.items():
        folder_path = output_path / folder
        folder_path.mkdir(parents=True, exist_ok=True)
        
        output_file = folder_path / 'ic_launcher.png'
        
        # Redimensionar imagem mantendo proporção e qualidade
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        
        # Salvar
        resized.save(output_file, 'PNG', optimize=True)
        print(f"  ✅ Gerado: {output_file} ({size}x{size})")
    
    return True

def generate_ios_icons(source_image, output_dir):
    """Gera os ícones do iOS em diferentes tamanhos"""
    source_path = Path(source_image)
    output_path = Path(output_dir)
    
    if not source_path.exists():
        print(f"❌ Arquivo não encontrado: {source_image}")
        return False
    
    # Abrir imagem original
    try:
        img = Image.open(source_path)
    except Exception as e:
        print(f"❌ Erro ao abrir imagem: {e}")
        return False
    
    # Criar diretório se não existir
    output_path.mkdir(parents=True, exist_ok=True)
    
    # Gerar ícones para cada tamanho iOS
    print("\n🍎 Gerando ícones para iOS...")
    for filename, size in IOS_SIZES.items():
        output_file = output_path / filename
        
        # Redimensionar imagem mantendo proporção e qualidade
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        
        # Salvar
        resized.save(output_file, 'PNG', optimize=True)
        print(f"  ✅ Gerado: {output_file} ({size}x{size})")
    
    return True

if __name__ == '__main__':
    script_dir = Path(__file__).parent
    source_image = script_dir / 'iCar.png'
    
    # Diretórios de saída
    android_output_dir = script_dir / 'android' / 'app' / 'src' / 'main' / 'res'
    ios_output_dir = script_dir / 'ios' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
    
    print("🚀 Iniciando geração de ícones...")
    print(f"📂 Imagem fonte: {source_image}")
    
    success = True
    
    # Gerar ícones Android
    if not generate_android_icons(source_image, android_output_dir):
        success = False
    
    # Gerar ícones iOS
    if not generate_ios_icons(source_image, ios_output_dir):
        success = False
    
    if success:
        print("\n✅ Todos os ícones foram gerados com sucesso!")
        print("\n📝 Próximos passos:")
        print("   1. Execute 'flutter clean' para limpar o cache")
        print("   2. Execute 'flutter pub get' para atualizar dependências")
        print("   3. Reconstrua o app para Android e iOS")
    else:
        print("\n❌ Erro ao gerar ícones")
        sys.exit(1)
