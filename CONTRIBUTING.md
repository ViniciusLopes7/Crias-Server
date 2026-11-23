# Contribuindo para o Crias-Server

Antes de modificar código, leia a [política de qualidade](docs/engineering-quality.md), a [arquitetura atual](docs/architecture.md) e a [linha de base](docs/quality-baseline.md).

**Princípio:** uma mudança só é boa quando o ganho é verificável e seu custo de manutenção é justificável. Não adicionar abstrações, opções ou camadas sem um problema demonstrado. Não remover proteções para diminuir linhas.

## Fluxo obrigatório de cada alteração

1. **Problema e evidência.** Descreva o comportamento atual, como reproduzi-lo e a consequência concreta. Registre evidências mesmo quando não for possível reproduzir.
2. **Alternativas antes de implementar.** Pergunte: dá para eliminar código? corrigir a função existente? reutilizar uma biblioteca do repositório? simplificar a configuração? Só então considere adicionar um componente.
3. **Contrato e risco.** Liste arquivos afetados, interface existente, entradas/saídas, efeitos persistentes, compatibilidade e como desfazer a alteração. Separe mudanças funcionais de refatorações mecânicas, exceto quando tecnicamente inseparáveis.
4. **Teste antes/depois.** Registre o comportamento antigo com teste de caracterização quando necessário. Adicione testes para o bug, limites, falhas e regressões. Testes com mocks não são provas de integração real.
5. **Implementação incremental.** Preferir PRs pequenos, com escopo único, sem remodelar áreas não relacionadas. Priorizar fronteiras de responsabilidade claras, mensagens úteis e caminhos de erro explícitos.
6. **Documentação no mesmo PR.** Atualize instruções operacionais, exemplos, README/índices quando relevantes, limites de homologação, e `CHANGELOG.md` em `Unreleased` para mudanças relevantes ao usuário.
7. **Revisão e CI.** Comparar métricas com a linha de base e declarar aumentos de complexidade que sejam necessários. Conferir testes aplicáveis e os jobs QEMU/Arch quando a mudança alcançar instalador, sistema, game runtime ou update.
8. **Entrega controlada.** Não publicar release nem efetuar merge sem autorização do mantenedor. CI verde não significa homologação de mundo real. A validação física deve ser registrada separadamente.

## Matriz mínima de risco

| Risco | Exemplos | Evidência mínima |
|---|---|---|
| P0: integridade/disponibilidade | backups, mundo, heap, cgroups, updater, SSH/Tailscale, privilégios, firewall | Teste negativo e de interrupção, restauração, rollback, CI/QEMU apropriado e plano de homologação física |
| P1: operação | RCON, console, TUI, Chunky, mods extras, Voice Chat | Teste funcional, degradação controlada, PTY/RCON quando aplicável, instruções de diagnóstico |
| P2: apresentação | texto, documentação, estilo sem mudança de comportamento | Verificação de links, exemplos e coerência com o código; explicar a ausência de teste de execução |

A classificação depende do impacto, não do número de linhas. Alterações P0 exigem atenção ao estado de disco, serviço ativo, quedas de energia, permissões e falha na metade da operação. Se o teste real for inviável, documentar a lacuna em vez de afirmar que está validado.

## Checklist de revisão

- O problema continua existindo depois de retirar partes redundantes?
- Existe outra implementação ou opção equivalente no repositório?
- O código novo pode ser eliminado sem perder requisitos?
- O comportamento externo mudou? Quais comandos/configurações/arquivos persistidos?
- Interfaces e nomes antigos ainda possuem consumidores reais? Há procedimento de migração?
- Funções longas têm responsabilidade coesa? O estado é explícito?
- Erros, interrupções e rollback deixam o sistema recuperável?
- O usuário consegue reconhecer falha e ação corretiva?
- Documentação e testes demonstram **o que funciona**, **o que não é testado** e **o que mudou**?
- Dados do jogo, credenciais, mundo e serviços existentes permanecem protegidos?

## Testes e medições

- `bash tests/run-all.sh`: executor local Shell, com resumo PASS/FAIL/SKIP e exit code confiável. Desde o ciclo 2, inclui todas as chamadas Shell diretas do job `test-shell`, com proteção contra divergência em `tests/run-all-contract-test.sh`. **Não executa** por si só os jobs Go, Python, Java, migração, Arch/QEMU; o CI completo continua obrigatório.
- `python3 tools/quality-report.py --format markdown`: inventário reprodutível de tamanho e candidatos de complexidade, sem limites cegos.
- `python3 tools/quality-report.py --compare-ref 9496a5f --format markdown`: comparação com a linha de base em clone com histórico Git disponível (ou use `--compare baseline.json`).
- `python3 tests/docs-links-test.py`: links Markdown locais.
- GitHub Actions: executar a matriz completa, inclusive QEMU, quando requerida pelo impacto.

Registrar na descrição do PR o comando executado, ambiente, resultado e limitações. Não substituir evidência de execução por lista de arquivos de teste existentes.

## Governança documental

- `README.md`: proposta e primeiros passos, enxuto.
- `docs/tutorial.md` e guias específicos: procedimentos reproduzíveis.
- `docs/architecture.md` e `docs/engineering-quality.md`: explicação de arquitetura e critérios.
- `docs/quality-baseline.md`: estado medido, limitações e evolução.
- `CHANGELOG.md`: mudanças relevantes por release; `ROADMAP.md`: planejamento, não histórico.
- `docs/decisions/`: decisões arquiteturais duráveis, cada uma com contexto, alternativas e consequências.

Veja também [o modelo de PR](.github/pull_request_template.md).
