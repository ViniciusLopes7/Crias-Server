## Por que mudar?

Problema observado, evidência e impacto (link para issue/log/teste, sem segredos):

## O que foi considerado antes de adicionar código?

- O que pode ser removido, corrigido ou reutilizado?
- Por que a alternativa mais simples não resolve?
- Há duplicação, legado ou novas dependências?

## Escopo e compatibilidade

Arquivos e interfaces afetados, comportamento antes/depois, dados persistentes, serviços, usuários e versões suportadas:

## Classificação do risco

- [ ] P0 — integridade, mundo, backup, memória, systemd, SSH, updater ou privilégios
- [ ] P1 — operação, console, rede, TUI, mod e integração
- [ ] P2 — texto, documentação, estilo sem efeito em execução

## Evidências verificadas

- [ ] Teste antes/depois ou caracterização do comportamento
- [ ] Testes negativos, interrupção, idempotência ou rollback pertinentes
- [ ] CI aplicável (Shell/Go/Python, Arch/QEMU quando necessário)
- [ ] Cenário real validado **ou** limitação não homologada explicitada
- [ ] Relatório de qualidade comparado com a baseline, sem usar LoC como meta

Comandos, ambiente, links de execução e resultados:

## Documentação e entrega

- [ ] Documentação e exemplos relevantes sincronizados
- [ ] `CHANGELOG.md` atualizado em `Unreleased` ou justificativa
- [ ] Impactos e plano de rollback documentados ou não aplicáveis
- [ ] Nenhum mundo, segredo ou serviço de produção modificado sem autorização
- [ ] Merge/release **não** serão feitos sem autorização explícita

**Consulte:** [CONTRIBUTING.md](../CONTRIBUTING.md) e [política](../docs/engineering-quality.md).
