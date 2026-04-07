# Essential Commands

Adiciona comandos de qualidade de vida essenciais para a gameplay sem grandes complexidades.

## Comandos Disponíveis (Jogadores comuns)

| Comando | O que faz | Exemplo |
|---------|-----------|---------|
| `/home` | Teletransporta para sua home | `/home base_principal` |
| `/sethome` | Define uma home no seu local | `/sethome casa` |
| `/delhome` | Deleta uma home | `/delhome casa` |
| `/spawn` | Retorna para o spawn do mundo | `/spawn` |
| `/tpa` | Envia pedido de teleporte até alguém | `/tpa Marcos` |
| `/tpahere` | Pede para que o jogador venha até você | `/tpahere Marcos` |
| `/tpaccept` | Aceita pedido de teleporte recebido | `/tpaccept` |
| `/tpadeny` | Recusa pedido de teleporte recebido | `/tpadeny` |
| `/back` | Retorna ao local prévio (ex: pós-morte) | `/back` |
| `/rtp` | Teletransporte aleatório pelo mapa | `/rtp` |

## Comandos Administrativos (OP)

| Comando | O que faz | Exemplo |
|---------|-----------|---------|
| `/nickname` | Define um apelido | `/nickname [jogador] ProPlayer` |
| `/nickname clear` | Remove o apelido de um jogador | `/nickname clear [jogador]` |

## Configuração Padrão do Servidor
- Máximo de 3 homes por jogador.
- Teleporte gratuito (Custo de XP foi removido na config.toml).
- O teleporte e spawn respeitam dimensões, ou seja, é possível dar `/home` e ir para o Nether se uma home foi definida lá, ou ser levado até o Overworld.