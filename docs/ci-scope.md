# CI seletivo — bot e agente

O workflow permanece disparado em PR para main, push main, tags e execução
manual. Um job curto classifica o diff Git completo: PR usa merge-base entre
base e head do evento; push usa before/after, inclusive múltiplos commits.
Não usar lista de arquivos truncada do payload. Renomes contam ambos os
caminhos. Se o histórico não puder ser determinado, executar ambos.

| Alteração | Agente | Bot |
|---|---|---|
| Hub, Minecraft, Terraria ou docs gerais | não | não |
| discord-agent/ fora de proto/ | sim | não |
| discord-bot/ ou .dockerignore | não | sim |
| discord-agent/proto/ | sim | sim |
| workflows, actions locais ou classificador/teste | sim | sim |
| tag, [release] na main, execução manual | sim | sim |

O bot depende do proto do agente no Dockerfile e nos testes. Hooks Shell de
instalação/integração continuam na suíte geral, independentemente do filtro.
Lint, testes e build de cada componente compartilham a mesma decisão.
O Hub Go agora tem job próprio, sem protoc nem dependência do agente.
O release consolidado exige o Hub e todos os gates anteriores; tags,
dispatch e pushes [release] forçam ambos os componentes, sem reutilizar
artefatos de outra execução. Não alteramos permissões nem publicação.
Os jobs omitidos não criam artefatos; retenções de builds executados
permanecem iguais. Nenhum teste essencial do núcleo é desativado.

Testar localmente: python3 tests/ci-scope-test.py.
O PR que altera o próprio workflow executa ambos por segurança. O job de classificação e o novo job independente Hub foram aprovados no run 45669875941; o log confirmou agent=True, bot=True. A integração completa deve ser verificada separadamente. A economia
real será verificada em um PR subsequente sem mudanças de bot/agente/CI.
Se checks obrigatórios de branch protection dependerem de nomes específicos,
manter os nomes existentes e avaliar o novo check Test Hub Go antes da
integração. Não alterar branch protection automaticamente.

Refs #22. C01 permanece experimental; release/merge não autorizado.

O run 45672307862 confirmou integração completa (15 jobs, incluindo QEMU); a mudança de workflow ainda exige bot/agente neste PR. Rebuild frio do Hub e comparação Gum, já comprovados no C01, ficam reservados a dispatch/releases; os testes PTY Go e a varredura detalhada de vulnerabilidades permanecem em toda execução do Hub. Validação desse ajuste pendente. A economia de seis jobs Discord só será demonstrável em um diff sem alteração de CI após sua integração; não criar PR extra nem publicar release para simular o cenário.
