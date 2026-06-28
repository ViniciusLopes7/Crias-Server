"""Pytest config — adiciona src/ ao sys.path para importar crias_bot."""
import sys
from pathlib import Path

# Adiciona src/ ao path para que `from crias_bot.config import ...` funcione
# sem precisar instalar o pacote (Poetry/pip install -e .).
SRC = Path(__file__).resolve().parent.parent / "src"
sys.path.insert(0, str(SRC))
