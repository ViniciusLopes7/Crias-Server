# ADR-0001 — Qualidade antes de novas funcionalidades

- **Data:** 2026-11-23
- **Status:** Proposto (pendente de revisão e merge)
- **Escopo:** Desenvolvimento do Crias-Server

## Contexto

PRs consecutivos corrigiram RAM/OOM, updater, Hub, RCON e Chunky, mas surgiram duplicações, longas funções, desvios entre suites de testes e documentação defasada. Refatorar sem registrar a referência tornaria impossível demonstrar resultado.

## Decisão proposta

Adotar política de engenharia sustentável: subtração/reutilização antes de adição; PRs pequenos com justificativa, risco e testes; baseline reprodutível; documentação sincronizada no mesmo PR; preservação de mundo e rollback acima de metas de linhas. Avaliar refatorações separadamente de novas funcionalidades.

## Alternativas consideradas

- **Seguir corrigindo pontualmente sem critérios:** menor custo inicial, mas conserva divergências.
- **Reescrever instalador e Hub imediatamente:** arrisca regressões e impede atribuir melhora às mudanças.
- **Fundação documental e mensurável primeiro (escolhida):** custo baixo, prepara verificações gradativas e revisão humana.

## Consequências

- Positivas: PRs mais comparáveis e revisáveis; clareza sobre o que é validado; menor acoplamento progressivo.
- Negativas: documentos e checklist devem permanecer atualizados, ou viram burocracia.
- Limites: não cria proteção de branch automaticamente nem certifica o modpack real; a adoção efetiva depende de revisão e merge.

## Referências

- [Google — code review e code health](https://google.github.io/eng-practices/review/reviewer/standard.html)
- [Google — pequenas mudanças e testes de caracterização](https://google.github.io/eng-practices/review/developer/small-cls.html)
- [Kubernetes — PRs e testes](https://www.kubernetes.dev/docs/guide/pull-requests/)
- [DORA — code maintainability](https://dora.dev/capabilities/code-maintainability/)
- [Diátaxis](https://diataxis.fr/)
- [MADR — registros de decisões](https://adr.github.io/adr-templates/)
