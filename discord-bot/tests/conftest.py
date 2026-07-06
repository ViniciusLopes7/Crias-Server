"""Pytest config — adiciona src/ ao sys.path para importar crias_bot.

2E-008: este `sys.path.insert` é um fallback de conveniência para devs que
rodam `pytest` sem instalar o pacote. O caminho preferido é um destes:

1. **`pip install -e .`** (recomendado) — instala o pacote em modo editável;
   `pytest` resolve `from crias_bot.config import ...` normalmente e valida
   que o empacotamento (`packages = [{include = "crias_bot", from = "src"}]`
   em `pyproject.toml`) está correto.

2. **`pythonpath = ["src"]`** no `[tool.pytest.ini_options]` do
   `pyproject.toml` — alternativa nativa do pytest 8+ que não depende de
   `sys.path` manipulation (já configurado).

O hack abaixo é mantido por compatibilidade com devs que ainda não
instalaram o pacote editável. Pode ser removido quando toda a equipe
migrar para `pip install -e .` ou `pythonpath` no pyproject.toml.
"""

import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
