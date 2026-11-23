# Política de qualidade e melhoria contínua

**Estado:** política instituída com a integração do PR #28 à `main` (2026-11-23). Aplica-se a Shell, Java runtime, systemd, Go, Python, CI e documentação.

## Objetivo e não objetivos

O Crias-Server deve ser confiável em hosts Arch limitados, ser simples de operar por SSH e preservar mundos, backups, segredos e serviços existentes. Qualidade é **comportamento verificável + simplicidade necessária + recuperabilidade + documentação fiel**.

Não são objetivos: diminuir linhas a qualquer custo, adotar arquitetura de grandes empresas literalmente, exigir 100% de cobertura ou usar testes sintéticos para proclamar validação em produção.

## Regras de projeto

1. **Primeiro subtrair.** Antes de acrescentar código, verificar alternativa por remoção, correção local ou reutilização. Documentar por que a opção mais simples não basta.
2. **Uma fonte por regra.** Priorizar implementação canônica para cálculo de orçamento, parsing, deduplicação e transações; evitar cópias com comportamento divergente.
3. **Separar responsabilidades.** CLI/TUI orquestra; bibliotecas decidem regras; persistência possui contrato; ferramenta de diagnóstico não muda estado.
4. **Fail-closed onde há risco.** Falha de validação, cota, senha, atualização ou consistência bloqueia escrita irreversível; erro e recuperação são visíveis.
5. **Privilégio mínimo.** Código root fora da árvore gravável pelo usuário do jogo; nenhum script do jogo executado como root; cliente RCON via loopback e porta administrativa protegida no firewall (não presumir bind restrito do Minecraft).
6. **Alterações duráveis são transacionais.** Escrever em temporário no mesmo filesystem, validar, sincronizar/renomear; se múltiplos arquivos representam uma operação, definir journal, estado parcial e recuperação. Não afirmar atomicidade multi-arquivo sem prova.
7. **Compatibilidade explícita.** Preservar formatos, env, serviços e mundos; registrar consumidores de aliases legados antes da exclusão.
8. **Sem efeitos surpresa.** Abrir um menu, consultar status ou verificar atualização deve ser observacional. Ações perigosas exigem confirmação; não reiniciar jogo por efeito colateral.
9. **Testes proporcionais à falha.** Testar sucesso, ausência da dependência, erro, interrupção, idempotência, rollback e caminho real quando pertinente. Mocks são úteis, porém rotulados como mocks.
10. **Documentação em sincronia.** Cada PR atualiza os guias atingidos, CHANGELOG ou justifica por que não. Comentários descrevem o **porquê**, não transcrevem históricos de PR.

## Política de refatoração

Refatoração deve manter comportamento observável salvo incompatibilidade deliberada. Criar primeiro testes de caracterização, incluindo cenários negativos, e comparar antes/depois. Alterações mecânicas e mudanças de comportamento devem, em regra, ser PRs distintos. Remover aliases apenas após encontrar todos os consumidores no código, instalador, CI, scripts externos documentados e releases suportadas.

### Gatilhos de investigação (não são gates de merge)

- função Shell de aproximadamente 80+ linhas ou muito estado mutável;
- caminho executado como root dependente de arquivo controlado pelo jogo;
- dois ou mais lugares aplicando a mesma regra;
- duplicação de testes em runners diferentes ou teste não registrado;
- exceção permanente de lint sem justificativa;
- configuração/branch legado sem consumidor comprovado;
- documento que descreve comportamento divergente do código.

A solução pode ser manter o código existente com justificativa. Métricas são sinais: o relatório não reprova PR por contagem de linhas ou número de funções.

## Linha de base e definição de melhora

Gerar relatório com `python3 tools/quality-report.py --format markdown`; comparar com a referência histórica via `--compare-ref 9496a5f` quando o histórico Git estiver disponível, ou via `--compare` com JSON salvo. Arquivar o resumo, não substituir o original. Reportar por módulo: arquivos/linhas, funções Shell candidatas a revisão, testes disponíveis e diferenças documentais.

Usar indicadores de resultado quando houver dados verificáveis: regressões após release, necessidade de hotfix/rollback, recuperação de atualização, incidentes OOM, disponibilidade de SSH e validação física. **Sem série temporal real, anotar “não medido”; não inventar índice de qualidade.** DORA sugere métricas de falha e retrabalho, que não devem ser usadas para premiar mais releases.

## Critérios de conclusão (Definition of Done)

- problema e alternativa mais simples registrados;
- impacto e risco classificados;
- testes de caracterização/regressão adequados aprovados, limitações explicitadas;
- não introduzir duplicação injustificada nem perda de proteções;
- documentação, comandos e CHANGELOG coerentes no mesmo PR;
- plano de rollback ou explicação de por que não se aplica;
- CI final aprovado e revisão humana, sem confundir teste em VM até EULA com mundo pronto.

## Inspirações e adaptação

| Projeto ou guia | Prática adaptada | O que não copiar |
|---|---|---|
| [Google Engineering Practices](https://google.github.io/eng-practices/review/) | revisões com foco em design, simplicidade, testes, pequenos conjuntos de mudanças | processo burocrático de uma organização muito maior |
| [Kubernetes — Pull Request Process](https://www.kubernetes.dev/docs/guide/pull-requests/) | evidência de testes e PR revisável por escopo | múltiplos mantenedores obrigatórios num projeto pequeno |
| [DORA — Maintainability](https://dora.dev/capabilities/code-maintainability/) e [métricas](https://dora.dev/guides/dora-metrics/) | medir confiabilidade e retrabalho junto de fluxo de entrega | usar métricas sem amostra ou perseguir frequência de releases |
| [Diátaxis](https://diataxis.fr/) | separar tutoriais, how-to, referência e explicação, aproveitando arquivos existentes | gerar diretórios vazios só para cumprir uma estrutura |
| [Keep a Changelog](https://keepachangelog.com/) | registrar mudanças para operadores, com Unreleased | despejar todos os commits no histórico |
| [GitHub — branch protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches) | exigir CI e revisão antes de merge quando disponível | presumir que proteção está configurada sem verificar |

## Sequência de adoção

1. Congelar novas funcionalidades não críticas; estabelecer linha de base e documentos.
2. Corrigir divergências de documentação e alinhamento dos runners antes de refatorar código.
3. Refatorar duplicações verificadas em PRs isolados, com contrato e rollback.
4. Aprovar cada ciclo após CI e, nos caminhos críticos, homologação em hardware real.

**Esta política não modifica automaticamente proteções de branch, permissões ou sistemas em produção.**
