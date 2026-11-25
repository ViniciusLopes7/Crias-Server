# C00 — Protocolo Gum real e validação física

Estado: candidato experimental em branch temporária. Não substituir a referência
numérica já medida; não marcar teste executado sem logs de execução. A branch
principal do PR #45 deve permanecer intacta até terminar o QEMU de 9c07cc4.

## Gum em Arch descartável

O script tools/hub-gum-baseline.py requer Linux, Python 3 e Gum já instalado
e saudável. Executar como usuário não-root, a partir de checkout confiável.
O script usa PTY controlador (pty.fork), tamanho 120x40, Gum real, e não
executa pacman, sudo ou ações administrativas. A sequência é menu principal,
Enter no primeiro item Servidor, Esc, Esc. Se a renderização esperada não
aparecer ou ocorrer fallback, falha em vez de inventar números.
Não modifica os scripts produtivos. Validação inicial deve ser em VM.

Exemplos:

    python3 tools/hub-gum-baseline.py --mode fixture --stack minecraft --samples 30
    python3 tools/hub-gum-baseline.py --mode fixture --stack terraria --samples 30
    python3 tools/hub-gum-baseline.py --hub /usr/local/bin/crias-tui --mode host --samples 30 --idle-seconds 600

Modo host usa descoberta real; fixture simula somente descoberta e status.
Os tempos são até identificação de labels no fluxo PTY, não renderização
física do cliente. Bytes PTY não equivalem a tráfego SSH. RSS somada inclui
páginas compartilhadas; não confundir com PSS. CPU em repouso usa diferença de
ticks da sessão apenas se a identidade dos processos observados nos extremos
for estável; não captura filhos efêmeros. Sem limite temporal rígido no CI.
Idle de 600 s somente na primeira amostra; não introduzir espera longa em CI.

## Gate para integração

1. Validar o programa em Arch com Gum real; registrar versão, kernel, hash e
   resultados. Testar ambos stacks fixture, falta de Gum, terminal encerrado,
   timeout, saída inesperada e navegação sem escrita.
2. Integrar coleta curta à VM existente (pacman somente dentro da VM
   descartável); sem workflow paralelo ou daemon. Não aprovar desempenho com
   base em runner compartilhado.
3. Executar o roteiro físico em host de teste autorizado: revisão do hash e
   da versão instalada, Gum e fallback, PTY local e SSH real, terminais
   60x20/80x24/120x40, idle 10 min, 5 min de navegação, 2 h estabilidade;
   analisar PSS e CPU agregada, incluindo subprocessos efêmeros.
4. Impacto em jogo: repetir carga idêntica com/sem Hub e mundo descartável,
   guardar MSPT, throughput Chunky, PSI, RAM, condições térmicas e versões.
   Não aceitar EULA, iniciar tarefas ou alterar mundo de produção sem
   autorização apropriada. Não inferir resultados a partir de teste pré-EULA.
5. Registrar dados brutos sanitizados e as limitações por SHA. Caso o acesso
   físico não esteja disponível, registrar bloqueador explicitamente e
   manter o gate C00 aberto até decisão fundamentada do mantenedor.

