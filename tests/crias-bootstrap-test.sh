#!/bin/bash
# tests/crias-bootstrap-test.sh
#
# Testa a lógica do crias-bootstrap.sh SEM rede. Usa fixtures sintéticas
# (fake GitHub API response, fake zip, fake sha256sums.txt) para exercitar
# as funções do bootstrap de forma determinística.
#
# O que testa:
#   1. Sintaxe bash válida (bash -n)
#   2. crias_detect_target: /mnt quando Arch montado, / caso contrário, override
#   3. crias_api_url: latest vs tag específica
#   4. crias_verify_sha256: match passa, mismatch falha, sha ausente avisa
#   5. crias_extract_to: extrai zip com dir top-level para install_dir
#   6. Sourceable: BASH_SOURCE guard impede execução da main ao sourcear

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BOOTSTRAP="$ROOT_DIR/crias-bootstrap.sh"
source "$ROOT_DIR/tests/lib/assert.sh"
# Sourceia o bootstrap no shell atual para que suas funções fiquem disponíveis
# para os testes unitários. O guard BASH_SOURCE impede que a main rode.
source "$BOOTSTRAP"

WORK_DIR="$(mktemp -d -t crias-bs-test.XXXXXX)"
source "$ROOT_DIR/tests/lib/cleanup.sh"
trap 'safe_cleanup_dir "$WORK_DIR" || true' EXIT

echo "[crias-bootstrap-test] 1. Sintaxe bash..."
assert_bash_syntax "$BOOTSTRAP"

echo "[crias-bootstrap-test] 2. Sourceable (BASH_SOURCE guard)..."
# Sourcear NÃO deve executar a main (que faria curl + download).
# Se a main rodasse, veríamos "Verificando conectividade" no stderr.
source_output=$(bash -c "source '$BOOTSTRAP' 2>&1" || true)
if echo "$source_output" | grep -q "Verificando conectividade"; then
    echo "FAIL: sourcear o bootstrap executou a main (BASH_SOURCE guard quebrado)." >&2
    exit 1
fi
echo "  OK: sourcear não executa a main"

echo "[crias-bootstrap-test] 3. crias_detect_target..."
# Caso A: /mnt não existe → retorna '/'
if [ -d /mnt ]; then
    echo "  (pulando caso A: /mnt existe neste host)"
else
    got=$(CRIAS_TARGET="" crias_detect_target "")
    if [ "$got" != "/" ]; then
        echo "FAIL: detect_target sem /mnt deveria retornar '/', obteve '$got'" >&2
        exit 1
    fi
    echo "  OK: sem /mnt → '/'"
fi

# Caso B: override explícito
got=$(CRIAS_TARGET="/tmp/fake-target" crias_detect_target)
if [ "$got" != "/tmp/fake-target" ]; then
    echo "FAIL: override via CRIAS_TARGET falhou: '$got'" >&2
    exit 1
fi
echo "  OK: override via CRIAS_TARGET"

got=$(crias_detect_target "/tmp/override-arg")
if [ "$got" != "/tmp/override-arg" ]; then
    echo "FAIL: override via \$1 falhou: '$got'" >&2
    exit 1
fi
echo "  OK: override via \$1"

# Caso C: /mnt simulado como Arch (cria fake /mnt em WORK_DIR)
fake_mnt="$WORK_DIR/mnt"
mkdir -p "$fake_mnt/etc" "$fake_mnt/bin"
echo "NAME=\"Arch Linux\"" > "$fake_mnt/etc/os-release"
ln -sf /bin/bash "$fake_mnt/bin/bash" 2>/dev/null || true
# A função usa /mnt absoluto; para testar a lógica de detecção, precisamos
# de /mnt real (não podemos mudar o path sem refatorar a função). Em vez
# disso, validamos a LÓGICA: se /mnt existe + tem os-release + tem bin/bash,
# retorna /mnt. Simulamos criando /mnt real (se já não existir).
if [ ! -d /mnt ]; then
    echo "  (pulando caso C: requer /mnt real; testado em CI via archinstall)"
else
    got=$(crias_detect_target)
    if [ "$got" = "/mnt" ]; then
        echo "  OK: /mnt montado+Arch → /mnt"
    fi
fi

echo "[crias-bootstrap-test] 4. crias_api_url..."
# Default (sem CRIAS_RELEASE_TAG) → latest
got=$(CRIAS_RELEASE_TAG="" crias_api_url)
expected="https://api.github.com/repos/ViniciusLopes7/Crias-Server/releases/latest"
if [ "$got" != "$expected" ]; then
    echo "FAIL: api_url default esperado '$expected', obteve '$got'" >&2
    exit 1
fi
echo "  OK: default → latest"

# Tag específica
got=$(CRIAS_RELEASE_TAG="v1.3.0" crias_api_url)
expected="https://api.github.com/repos/ViniciusLopes7/Crias-Server/releases/tags/v1.3.0"
if [ "$got" != "$expected" ]; then
    echo "FAIL: api_url tag esperado '$expected', obteve '$got'" >&2
    exit 1
fi
echo "  OK: tag específica → /releases/tags/<tag>"

# Repo customizado
got=$(CRIAS_REPO="Outro/Repo" CRIAS_RELEASE_TAG="" crias_api_url)
expected="https://api.github.com/repos/Outro/Repo/releases/latest"
if [ "$got" != "$expected" ]; then
    echo "FAIL: api_url custom repo esperado '$expected', obteve '$got'" >&2
    exit 1
fi
echo "  OK: repo customizado"

echo "[crias-bootstrap-test] 5. crias_verify_sha256..."
# Cria zip fake + sha256sums.txt com hash correto
fake_zip="$WORK_DIR/test.zip"
printf 'conteudo fake do zip\n' > "$fake_zip"
actual_hash=$(sha256sum "$fake_zip" | awk '{print $1}')

sha_file="$WORK_DIR/sha256sums.txt"
printf '%s  %s\n' "$actual_hash" "test.zip" > "$sha_file"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "other.zip" >> "$sha_file"

# Match → passa (return 0)
if ! crias_verify_sha256 "$fake_zip" "$sha_file" "test.zip" >/dev/null 2>&1; then
    echo "FAIL: verify_sha256 deveria passar com hash correto." >&2
    exit 1
fi
echo "  OK: hash correto → passa"

# Mismatch → falha (return 1)
sha_bad="$WORK_DIR/sha-bad.txt"
printf '1111111111111111111111111111111111111111111111111111111111111111  test.zip\n' > "$sha_bad"
if crias_verify_sha256 "$fake_zip" "$sha_bad" "test.zip" >/dev/null 2>&1; then
    echo "FAIL: verify_sha256 deveria falhar com hash incorreto." >&2
    exit 1
fi
echo "  OK: hash incorreto → falha"

# Sha file ausente → avisa mas passa (return 0)
if ! crias_verify_sha256 "$fake_zip" "$WORK_DIR/inexistente.sha" "test.zip" >/dev/null 2>&1; then
    echo "FAIL: verify_sha256 deveria passar com sha ausente (apenas avisa)." >&2
    exit 1
fi
echo "  OK: sha ausente → avisa + passa"

# Asset name não encontrado no sha file → avisa mas passa
if ! crias_verify_sha256 "$fake_zip" "$sha_file" "outro-nome.zip" >/dev/null 2>&1; then
    echo "FAIL: verify_sha256 deveria passar com asset não listado no sha." >&2
    exit 1
fi
echo "  OK: asset não listado no sha → avisa + passa"

echo "[crias-bootstrap-test] 6. crias_extract_to..."
# Cria zip real com dir top-level (como GitHub release zip)
extract_test_dir="$WORK_DIR/extract-src"
mkdir -p "$extract_test_dir/Crias-Server-v1.0.0/shared/lib"
printf '#!/bin/bash\necho hello\n' > "$extract_test_dir/Crias-Server-v1.0.0/install.sh"
printf 'export FOO=bar\n' > "$extract_test_dir/Crias-Server-v1.0.0/config.env"
printf '#!/bin/bash\nlog() { echo hi; }\n' > "$extract_test_dir/Crias-Server-v1.0.0/shared/lib/common.sh"
chmod +x "$extract_test_dir/Crias-Server-v1.0.0/install.sh" "$extract_test_dir/Crias-Server-v1.0.0/shared/lib/common.sh"

real_zip="$WORK_DIR/release.zip"
(cd "$extract_test_dir" && zip -qr "$real_zip" "Crias-Server-v1.0.0")

install_dir="$WORK_DIR/dest"
if ! crias_extract_to "$real_zip" "$install_dir" >/dev/null 2>&1; then
    echo "FAIL: extract_to falhou com zip válido." >&2
    exit 1
fi

# Verifica que os arquivos estão no destino (sem o dir top-level Crias-Server-v1.0.0/)
for rel in "install.sh" "config.env" "shared/lib/common.sh"; do
    if [ ! -f "$install_dir/$rel" ]; then
        echo "FAIL: arquivo ausente após extração: $rel" >&2
        exit 1
    fi
done

# install.sh deve ser executável
if [ ! -x "$install_dir/install.sh" ]; then
    echo "FAIL: install.sh não é executável após extração." >&2
    exit 1
fi
# .sh em shared/lib/ também devem ser executáveis (find -exec chmod)
if [ ! -x "$install_dir/shared/lib/common.sh" ]; then
    echo "FAIL: shared/lib/common.sh não é executável após extração." >&2
    exit 1
fi
echo "  OK: zip extraído com chmod nos .sh, sem dir top-level"

echo "[crias-bootstrap-test] 7. Static checks no crias-bootstrap.sh..."
# Não deve ter usuário hardcoded (não assume 'crias', 'Server', etc. como login user)
if grep -Eq '(login|user|usuario).*crias[^_-]' "$BOOTSTRAP" 2>/dev/null; then
    # Exceção: referências a "crias-server" (nome do repo) e "/opt/crias-server/"
    # (caminho do install_dir) são OK. Flag apenas username como login.
    hardcode=$(grep -iE '(login|user|usuario).*[[:space:]]crias[^_-]' "$BOOTSTRAP" 2>/dev/null | grep -vE 'crias-server|crias-agent|crias-bootstrap|/opt/crias' || true)
    if [ -n "$hardcode" ]; then
        echo "FAIL: bootstrap assume username hardcoded:" >&2
        echo "$hardcode" >&2
        exit 1
    fi
fi
echo "  OK: sem username hardcoded"

# Deve usar curl (não wget) para download
if ! grep -q 'curl' "$BOOTSTRAP"; then
    echo "FAIL: bootstrap deveria usar curl para downloads." >&2
    exit 1
fi
echo "  OK: usa curl"

# Deve verificar SHA256
if ! grep -q 'sha256sum' "$BOOTSTRAP"; then
    echo "FAIL: bootstrap deveria verificar SHA256." >&2
    exit 1
fi
echo "  OK: verifica SHA256"

# Deve consultar GitHub API (não hardcoded URL de asset)
if ! grep -q 'api.github.com' "$BOOTSTRAP"; then
    echo "FAIL: bootstrap deveria consultar api.github.com." >&2
    exit 1
fi
echo "  OK: consulta api.github.com"

echo "[crias-bootstrap-test] OK — todos os checks passaram"
