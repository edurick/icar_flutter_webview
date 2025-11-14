#!/usr/bin/env python3
"""
Script para gerar ícones do Android a partir do iCarAndroid.png
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
SIZES = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}

def generate_icons(source_image, output_dir):
    """Gera os ícones em diferentes tamanhos"""
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
    
    # Gerar ícones para cada resolução
    for folder, size in SIZES.items():
        folder_path = output_path / folder
        folder_path.mkdir(parents=True, exist_ok=True)
        
        output_file = folder_path / 'ic_launcher.png'
        
        # Redimensionar imagem mantendo proporção e qualidade
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        
        # Salvar
        resized.save(output_file, 'PNG', optimize=True)
        print(f"✅ Gerado: {output_file} ({size}x{size})")
    
    return True

if __name__ == '__main__':
    script_dir = Path(__file__).parent
    source_image = script_dir / 'iCarAndroid.png'
    output_dir = script_dir / 'android' / 'app' / 'src' / 'main' / 'res'
    
    if generate_icons(source_image, output_dir):
        print("\n✅ Todos os ícones foram gerados com sucesso!")
    else:
        print("\n❌ Erro ao gerar ícones")
        sys.exit(1)

