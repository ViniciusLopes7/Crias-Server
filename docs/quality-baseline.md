# Linha de base de qualidade — 2026-11-23

**Referência imutável:** `main@9496a5f04e3c2f093926f21f69b38251c11af8fe`, anterior ao PR de política. Objetivo: permitir comparar mudanças futuras sem confundir aumento de testes/documentação com inchaço de produção.

## Inventário inicial (GitHub tree)

| Medida | Valor | Método/limite |
|---|---:|---|
| Arquivos versionados | 165 | blobs da árvore Git da referência |
| Arquivos `.sh` | 84 | extensão, inclui testes |
| Arquivos sob `tests/` | 62 | inclui fixtures; não equivale a 62 testes executáveis |
| Arquivos sob `docs/` | 16 | diretório, não inclui README da raiz |
| `install.sh` | 2.274 linhas | contagem textual da versão de referência |
| `minecraft/install.sh` | 944 linhas | idem |
| `crias-tui.sh` | 603 linhas | idem |
| `minecraft/mc-manager.sh` | 615 linhas | idem |
| `crias-update.sh` | 481 linhas | idem |
| `shared/lib/minecraft-tuning.sh` | 541 linhas | idem |

Funções que merecem revisão de coesão: `install_crias_agent_if_enabled()` (~461 linhas até a função seguinte), `crias-tui.sh:main()` (~387), `compute_minecraft_tuning()` (~186). **Tamanho não é erro por si só**; a análise é manual.

## Lacunas da referência

- CI possui cenários recentes ausentes na lista direta de `tests/run-all.sh`. Há execução indireta via `quick-script-tests.sh`, portanto contar nomes não equivale a medir cobertura.
- `CHANGELOG.md` registra até a fase de 21/11 no início, faltando as releases de 22/11 no topo.
- `docs/tui.md` descreve TTY interativo como manual apesar dos testes recentes de PTY.
- PRs #24–#27 têm CI, mas não há evidência de homologação de mundo modded com jogadores para essa referência.
- Não foi coletado inventário confiável de incidência de bugs pós-release, sucesso de backups em hardware ou tempo de recuperação. **Valores: não medidos.**

## Método de medição para próximas alterações

Execute no checkout de cada SHA:

```bash
python3 tools/quality-report.py --format markdown
python3 tools/quality-report.py --format json > quality-report.json
# Comparação direta com a versão anterior aos fundamentos (clone com histórico completo):
python3 tools/quality-report.py --compare-ref 9496a5f04e3c2f093926f21f69b38251c11af8fe --format markdown
# Alternativa para runners rasos: salve o JSON da baseline num checkout com histórico e compare:
python3 tools/quality-report.py --compare quality-baseline.json --format markdown
```

O modo `--compare-ref` lê os arquivos **diretamente do objeto Git histórico**, mesmo que o commit antigo não contenha essa ferramenta. Em clones superficiais (`fetch-depth: 1`), obtenha o histórico necessário antes da comparação; o relatório em CI permanece apenas observacional. Não atribuir alterações locais não commitadas ao SHA do HEAD.

Comparar por módulo e explicar a diferença. O relatório automático é observacional; não há gate automático para reduzir linhas. Analisar separadamente linhas de produção, testes e documentação.

Indicadores qualitativos por PR: duplicação eliminada, superfície de erro reduzida, consumidores legados verificados, contratos preservados, casos negativos cobertos e documentação corrigida.

Indicadores operacionais somente se houver fonte: deploy com recuperação/hotfix, OOM real, restauração de backup real, desempenho sob Chunky e retorno do SSH. Jamais marcar como zero um incidente que simplesmente não foi medido.

## Hipóteses para PRs posteriores (não são correções deste PR)

1. Unificar a identificação de mods extras/QoL sem mudar políticas de instalação.
2. Isolar controladores do Hub mantendo comandos e UX estáveis.
3. Transacionar conjuntamente recalibração do heap e alterações do systemd.
4. Cobrir atualização de release anterior → atual, além da migração histórica já testada.
5. Comprovar recovery de save-on com RCON real em mundo descartável.

Arquivar uma nova seção de resultados depois de cada ciclo, preservando este estado inicial e seu SHA.

## Ciclo 1 — Deduplicação de mods (issue #29 / PR #30)

- **Referência anterior ao ciclo:** `main@645871d` (já com a política de engenharia).
- **Commit de caracterização:** `eee271c` — somente `tests/server-extras-test.sh`, passando de 23 para 147 linhas e registrando **três falhas de identificação** no comportamento original.
- **Commit funcional:** `4b45195` — `minecraft/install.sh` passa de 944 para 950 linhas; substitui **duas varreduras divergentes** por uma rotina de identificação compartilhada. O número de linhas é **+6**, e não uma meta de redução.
- **Efeito verificável:** Spark/Chunky/Skin Restorer identificados tanto por nome versionado quanto por ID de manifesto Fabric, Forge e NeoForge, incluindo arquivos renomeados. Reduz risco de downloads duplicados.
- **Contratos preservados:** filtros por loader, versão efetiva, destinos distintos de QoL e extras, SHA-256 fixado para QoL, sinalização de pendências e modo strict/best-effort. O test runner no CI já executava `tests/server-extras-test.sh`; não foi criado um segundo executor redundante.
- **Limites:** testes usam JARs de fixture e substituem a função de download; não demonstram compatibilidade real do modpack, instalação em host físico nem performance de mundos. Scanner procura manifestos em arquivos JAR locais; não valida assinatura, dependências ou versões de mods instalados.

A primeira mudança **não reduziu necessariamente as linhas totais**, mas eliminou uma divergência comprovada. O próximo ciclo deverá registrar os próprios valores e contraprovas, sem sobrescrever a referência histórica.
