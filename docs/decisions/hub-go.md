# ADR — Nova geração do Crias Hub em Go

- Estado: decisão aprovada em 25/11/2026; implementação não iniciada.
- Épico e requisitos detalhados: [#22](https://github.com/ViniciusLopes7/Crias-Server/issues/22).
- Sequência: [roadmap](../../ROADMAP.md). Evidências pré-migração: [C00](../hub-c00-baseline.md).

## Contexto e decisão

O Hub é o centro administrativo de um host Arch minimalista, operado localmente ou por SSH/Tailscale. O objetivo é ampliar a capacidade administrativa sem prejudicar jogos, acesso remoto ou recuperação. Go foi escolhido em vez de Rust por já integrar o ecossistema do projeto (agente); ambos eram tecnicamente candidatos. Bubble Tea e Lip Gloss são candidatos prioritários, sujeitos ao protótipo C01. Não há obrigação de protótipo Rust. Bash continua como backend/instalador e fallback; não reescrever managers nem depender do agente para executar a TUI.

## Requisitos aprovados (dez etapas)

1. **Arquitetura:** UI Go compilada, eventos, estado compartilhado, operações validadas, adaptadores por jogo; binário pré-compilado e sem daemon exclusivo. Preservar CLI, systemd, tuning, atualização e instalação existentes.
2. **Visual:** layout híbrido, abas superiores, lateral contextual ocultável, header adaptativo, rodapé de atalhos, tela cheia quando compatível, modo compacto e fallback. Crias Forest: fundo #111713, superfície #202E24, destaque #94D5A5, secundária #91A89A (ajustáveis após testes); contraste, estados textuais, ASCII e cores limitadas.
3. **Navegação:** Visão geral, Servidores, Hardware, Backups, Sistema, Configurações. Dashboard inicial, ações rápidas, busca que navega sem executar ações destrutivas, foco/posição preservados, operações comuns em até três seleções (sem contar preenchimento/confirmações), teclado integral, mouse opcional; suspender atalhos globais durante entrada/console.
4. **Monitoramento:** CPU, memória, temperatura/fans, energia, bateria, armazenamento e rede; /proc e /sys prioritários, métricas com origem, unidade, escopo, timestamp e disponibilidade; cadências independentes e perfis Econômico/Balanceado/Detalhado; histórico circular de até 60 minutos em memória, sem banco/daemon, diagnósticos externos sob demanda. Não confundir potência parcial/estimada com consumo total; alertas térmicos por hardware e histerese.
5. **Hardware:** Automático (preserva estado), Econômico, Balanceado, Desempenho e Personalizado; clocks/governor/boost/EPP, perfis nativos, limites de carga/conservação e potência avançada somente quando suportados. Fans automáticos; controle manual/curva somente homologados com proteção autônoma. Separar tier, tuning de jogos/host e perfis. Validar, confirmar, registrar, reler, reverter quando possível, persistência explícita, conflitos externos detectados. Sem overclock/undervolt/registradores não documentados; automação energética futura opt-in.
6. **Jogos:** Minecraft prioritário, Terraria preservado; estados de prontidão, painel, console integrado logs/RCON local (Terraria inicialmente logs), histórico/filtros, sem repetir comando incerto. TPS/MSPT e heap real somente de fontes compatíveis; preservar orçamento JVM, modos fixo/dinâmico/auto e exigência de jogo parado. Jogadores, whitelist, operadores, banimentos, Chunky visual, mods/MRPack genérico, atualização preparada com backup/rollback, arquivos via Midnight Commander inicialmente, formulários e Voice Chat. Sem assumir compatibilidade universal.
7. **Sistema:** systemd como autoridade; leitura de serviços, escrita restrita; SSH/Tailscale, acesso privado sem exposição automática, recuperação independente para mudanças de rede; atualização de ferramentas separada de Arch (pacman -Syu completo, manutenção confirmada) e jogos; armazenamento com prévia de limpeza, journal filtrável, Doctor 2.0 independente, leitura padrão, energia/tampa opcionais e seguros.
8. **Segurança:** sem root permanente por padrão, elevação pontual, fronteiras de usuários, cinco níveis de risco (N0–N4). Backups tar/zstd/systemd, tipos mundo/servidor/completo/administrativo/pré-alteração, retenção e proteção, consistência por jogo, recuperação save-off, validação arquivo/conteúdo/extração/funcional. Restore isolado, snapshot, locks, journal, validação de caminhos; destinos externos/remotos opcionais, criptografia madura quando necessária. Tarefas independentes do SSH quando apropriado, histórico sanitizado, Bash/Doctor e falhas injetadas.
9. **Qualidade:** preservar baseline histórica e política de engenharia; nova referência pré-Go, metas RSS 15/25 MiB, CPU ociosa 0,2/0,5% de um núcleo, startup 150/300 ms, p95 20/50 ms, binário 10/15 MiB (desejável/referência inicial; não medidos); medir subprocessos, jogo, memória/PSI, MSPT e Chunky. Testes unitários, fuzz, race, PTY, QEMU, migração real, físico; benchmarking reproduzível, CI existente, retenção controlada, commits atômicos e DoD. Segurança, integridade e regressões graves são bloqueantes.
10. **Roadmap:** C00–C11, cinco fases e seis marcos; main estável, branches temporárias, PRs coerentes, #22 como épico, troca padrão só após paridade, homologação, migração e rollback. Merge e release conforme autorização.

O épico mantém as especificações detalhadas e os critérios de aceitação. Este ADR registra a decisão arquitetural, não atesta funcionalidades implementadas.

## Consequências e fronteiras

- A UI não duplica regras de heap, caminhos, portas, backups ou atualização; invoca contratos administrativos com argumentos validados e permissões pontuais.
- Operação crítica permanece indisponível até possuir sua proteção efetiva; C09 não é justificativa para adiar segurança de C05–C08.
- O instalador pode continuar usando Gum; abertura da nova UI e consultas não instalam dependências ou alteram serviços automaticamente.
- A troca do ponto de entrada é reversível, e diagnóstico/fallback Bash não dependem do binário Go. Nomes de comandos experimentais ainda não são contrato definitivo.
- Editor nativo, novas stacks, múltiplas instâncias, GPU avançada, temas e automação são extensões; não bloqueiam a entrega estável quando explicitamente adiados. Não habilitar controles físicos não homologados.
- A decisão de interface web anterior é histórica e fica fora do escopo deste roadmap.

## Critérios de revisão

Usar a política de engenharia vigente e evidência por SHA. Não declarar CI verde sem verificar os jobs; QEMU até EULA não comprova mundo jogável. Não alterar dados do host durante C00/C01. Revisar este ADR se houver decisão explícita que altere o escopo; registrar consequências e atualizar #22.
