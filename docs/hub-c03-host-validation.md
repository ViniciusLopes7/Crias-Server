# C03 — Validação física e SSH (gate externo)

Estado: roteiro preparado, não executado em host físico. Candidato funcional validado: `70fa13e8e4414e99d15a7e86fb3c7447ff65cd67`, CI 45932442002. Não substituir o Hub Bash instalado. Sem root, sem instalar pacotes, iniciar/parar serviços, alterar configuração ou jogos. Usar conta e host de teste autorizados; se qualquer pré-requisito faltar, registrar bloqueador e interromper. Não usar o host de produção como ambiente de carga artificial.

## 1. Identidade e pré-requisitos

Em checkout confiável do candidato, confirme SHA, árvore limpa, ferramenta Go fixada 1.27.4, Python 3, Gum instalado e saudável, Linux/Arch e TTY. Registre localmente versão da release efetivamente instalada (a partir do mecanismo oficial de instalação/manifesto), caminho real e hash do Hub Bash, kernel, arquitetura, CPU/RAM, condições térmicas, carga e versão de Gum. Não publique hostname, IP, credenciais, ambiente completo, logs privados ou dados dos jogadores. Se versão instalada não puder ser confirmada, gate continua aberto. O hash sozinho não demonstra release instalada.

```bash
# No checkout confiável, sem root; parar se houver divergência.
git rev-parse HEAD
git status --porcelain
go version
python3 --version
gum --version
uname -srmo
command -v crias-tui
sha256sum /usr/local/bin/crias-tui
```

## 2. Binário separado e evidências locais

Ajuste o caminho do Hub instalado somente após confirmar sua identidade. O build depende da toolchain e módulos já disponíveis ou de download autorizado; se indisponíveis, não instalar no servidor. Comandos abaixo são Bash, executados na raiz do checkout confirmado. O diretório temporário privado deve ser preservado até revisar os resultados. Não usar sudo. Não publicar um relatório vazio ou parcial como válido.

```bash
set -euo pipefail
[ "$(id -u)" -ne 0 ]
[ "$(git rev-parse HEAD)" = "70fa13e8e4414e99d15a7e86fb3c7447ff65cd67" ]
[ -z "$(git status --porcelain)" ]
[ "$(go env GOVERSION)" = "go1.27.4" ]
umask 077
out="$(mktemp -d "${TMPDIR:-/tmp}/crias-m2.XXXXXX")"
(
  cd crias-hub
  GOTOOLCHAIN=local CGO_ENABLED=0 go build -mod=readonly -trimpath \
    -o "$out/crias-tui-next" ./cmd/crias-tui-next
)
sha256sum "$out/crias-tui-next"
python3 tests/hub-gum-negative-test.py
python3 tools/hub-gum-baseline.py --hub /usr/local/bin/crias-tui \
  --mode host --samples 30 --idle-seconds 600 > "$out/bash-gum.json"
python3 tests/hub-c01-pty-test.py "$out/crias-tui-next" \
  --compare-telemetry --samples 30 --idle-seconds 600 --warmup-seconds 15 \
  > "$out/go-telemetry.log"
printf 'Evidências locais: %s\n' "$out"
```

Um conjunto Go leva pelo menos 40 min de idle, além de aquecimento, startups e navegação; Bash soma pelo menos 10 min. São observações de 600 s por modo, não repetições independentes de idle. Repetir conjuntos em sessões controladas e alternar ordem Bash/Go entre conjuntos; o harness Go rotaciona a ordem de startups, mas a ordem de idle depende da última repetição. Para inferência robusta, coletar múltiplas janelas por modo sob carga equivalente. Registrar controle sem Hub, temperatura e carga com instrumentos autorizados. Não transformar a soma RSS Bash em PSS, nem comparar apresentação estática a telemetria ativa como trabalho equivalente. CPU Go inclui processo principal e filhos aguardados; não mede árvore completa. JSON só é publicado pelo harness após sucesso. Inspecionar código de saída e conteúdo; manter arquivos incompletos identificados como falha. Não executar automaticamente novamente após falha.

## 3. Teste interativo local e SSH

Usar o binário separado em terminal local e sessão SSH existente/autorizada, nunca alterar sshd, firewall ou rota. Conferir Bash/Gum e Go estático/telemetria; tamanhos 60x20, 80x24, 120x40; abas, busca, ajuda, perfil, janela histórica e resize. Testar saída normal, Ctrl+C e desconexão de sessão descartável, verificar restauração do terminal e ausência de processo experimental remanescente. Não interromper sessão administrativa principal. Não usar console de jogo nem ações mutantes. Registrar somente PASS/FAIL, versão, tamanho do terminal e observações sanitizadas; PTY não representa bytes de rede SSH.

## 4. Aceitação e devolução das evidências

Referências preservadas: RSS principal <=25 MiB (desejável <=15), startup <=300 ms (desejável <=150), navegação p95 <=50 ms (desejável <=20), binário <=15 MiB (desejável <=10), CPU média idle <=0,5% de um núcleo (desejável <=0,2%). Medir todos os perfis, inclusive detalhado, sem reduzir cadência para passar. Se CPU exceder, preservar dados e investigar em ambiente descartável; não homologar por média de runners diferentes. Confirmar identidade instalada e equivalência de trabalho antes de afirmar paridade. Revisão física dos sensores, custo agregado, carga de jogos/Chunky, estabilidade prolongada, rollback e controles físicos permanecem nos gates aprovados C10/C11. Gate M2 somente com evidências revisadas e decisão explícita; não iniciar C04 sem autorização/gates aplicáveis. Entregar relatórios sanitizados e checklist, não credenciais. Nenhuma etapa deste roteiro foi executada em host físico nesta sessão.

## 5. Executor automatizado para a VM

Após instalar o servidor e manter o Hub legado, no checkout confiável do PR #48 execute como usuário normal (Python 3.11+):

```bash
python3 tools/hub-vm-validation.py --binary "$HOME/.local/bin/crias-tui-next" --mode quick
python3 tools/hub-vm-validation.py --binary "$HOME/.local/bin/crias-tui-next" --mode full
```

O binário pode ser o experimental já instalado em caminho separado. Caso não tenha sido compilado, use `--build` no lugar de `--binary`: exige Go 1.27.4 e módulos em cache, compila no diretório privado de evidências e não instala nada. `--legacy /caminho` permite indicar a instalação Bash confiável; `--go-only` pula a comparação legada de forma explícita. `--source-audit` executa tidy -diff, verify, imports, vet, race e links sem baixar dependências; `--check-updates` autoriza somente consulta de versões Go pela rede, sem atualização. `--expected-binary-sha256` confere digest fornecido por fonte confiável. `--installed-release` é declaração do operador, não validação da release. O modo quick usa 3 sessões/modo, idle 5s, aquecimento 2s; é smoke, não prova CPU estável nem cobre a cadência de serviços de 45s. Full usa 30, 600s e 15s, mais 600s do Gum. Sem root, pacman, instalação ou ações administrativas. Relatório JSON e logs em diretório privado no HOME (ou --output-parent). Compartilhar primeiro report.json após revisar; logs podem conter paths/diagnósticos locais e devem ser sanitizados antes de enviar. O retorno 0 indica apenas que os testes automatizados executados passaram; referências de desempenho são observacionais e gates manuais continuam pendentes. Não alegar homologação física por teste em VM. O CI faz smoke Go-only e teste de contratos no job Hub existente; candidato ainda não validado.
