# Guia de Conexão - Linux e Windows
## Como conectar ao servidor Minecraft

---

## 📋 Métodos de Conexão

### Método 1: Tailscale (RECOMENDADO) ⭐

**Vantagens:**
- ✅ Não precisa abrir portas no roteador
- ✅ Conexão criptografada e segura
- ✅ IP fixo (não muda)
- ✅ Funciona de qualquer lugar
- ✅ Fácil de compartilhar com amigos

---

#### No Servidor (Notebook com Arch)

```bash
# 1. Verificar se Tailscale está instalado
which tailscale

# 2. Se não estiver, instalar
sudo pacman -S tailscale

# 3. Habilitar e iniciar serviço
sudo systemctl enable --now tailscaled

# 4. Conectar à sua conta Tailscale
sudo tailscale up

# 5. Siga as instruções na tela:
#    - Copie o link que aparecer
#    - Abra no navegador
#    - Faça login (Google/Microsoft/GitHub)
#    - Autorize o dispositivo

# 6. Verificar IP do Tailscale
sudo tailscale ip -4
# Exemplo de saída: 100.64.123.45
# ANOTE ESTE IP! É o endereço do seu servidor.
```

---

#### No Seu PC (Linux)

##### Ubuntu/Debian

```bash
# 1. Instalar Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# 2. Iniciar serviço
sudo systemctl enable --now tailscaled

# 3. Conectar com a MESMA conta usada no servidor
sudo tailscale up

# 4. Verificar conexão
sudo tailscale status
# Deve mostrar o servidor na lista!
```

##### Arch Linux

```bash
# 1. Instalar Tailscale
sudo pacman -S tailscale

# 2. Iniciar serviço
sudo systemctl enable --now tailscaled

# 3. Conectar
sudo tailscale up

# 4. Verificar
sudo tailscale status
```

##### Fedora

```bash
# 1. Instalar Tailscale
sudo dnf install tailscale

# 2. Iniciar serviço
sudo systemctl enable --now tailscaled

# 3. Conectar
sudo tailscale up

# 4. Verificar
sudo tailscale status
```

---

#### No Seu PC (Windows)

1. Acesse o site oficial do Tailscale: [tailscale.com/download/windows](https://tailscale.com/download/windows)
2. Clique em **"Download Tailscale for Windows"** e baixe o instalador.
3. Execute o instalador baixado.
4. Após a instalação, o Tailscale aparecerá na bandeja do sistema (perto do relógio, no canto inferior direito).
5. Clique no ícone do Tailscale e selecione **"Log in"**.
6. Uma página abrirá no navegador. Faça login com a **MESMA conta** que você usou no servidor Linux.
7. Após o login, clique no ícone do Tailscale novamente. Você verá seus dispositivos na lista, incluindo o servidor!

---

#### No Minecraft (Qualquer SO)

1. Abra o Minecraft Launcher
2. Inicie o jogo na versão **1.21.11** (com Fabric se tiver mods)
3. Clique em **"Multiplayer"**
4. Clique em **"Add Server"**
5. Preencha:
   - **Server Name:** Meu Servidor (ou qualquer nome)
   - **Server Address:** `100.64.123.45:25565` (use o IP do seu servidor)
6. Clique em **"Done"**
7. Clique no servidor na lista
8. Clique em **"Join Server"**

✅ **Pronto!** Você está conectado!

---

### Método 2: IP Local (Mesma Rede WiFi/Cabo)

**Quando usar:** PC e servidor na mesma rede local.

#### No Servidor

```bash
# Descobrir IP local
ip addr show | grep "inet " | grep -v "127.0.0.1" | head -1
# Exemplo de saída: inet 192.168.1.50/24
# IP é: 192.168.1.50
```

#### No Minecraft

- **Server Address:** `192.168.1.50:25565` (use o IP do seu servidor)

---

### Método 3: IP Público (Port Forwarding)

⚠️ **Aviso:** Menos seguro! Prefira Tailscale.

#### Descobrir IP Público

```bash
# No servidor
curl ifconfig.me
# Exemplo: 203.0.113.45
```

#### Configurar Roteador

1. Acesse `192.168.1.1` no navegador (geralmente)
2. Login: `admin` / senha do roteador
3. Procure **"Port Forwarding"** ou **"Virtual Servers"**
4. Adicione regra:
   - **Nome:** Minecraft
   - **Porta Externa:** 25565
   - **Porta Interna:** 25565
   - **IP Interno:** 192.168.1.50 (IP do servidor)
   - **Protocolo:** TCP
5. Salve

#### No Minecraft

- **Server Address:** `203.0.113.45:25565` (use seu IP público)

---

## 🔧 Troubleshooting

### Problema: "Can't resolve hostname"

**Causa:** IP incorreto ou Tailscale desconectado.

**Solução:**
```bash
# No servidor
sudo tailscale status
# Deve mostrar "Connected"

# Se não estiver conectado:
sudo tailscale up
```

---

### Problema: "Connection timed out"

**Causas possíveis:**
1. Servidor não está rodando
2. Firewall bloqueando
3. Porta incorreta

**Solução:**
```bash
# 1. Verificar se servidor está rodando
sudo systemctl status minecraft

# 2. Se não estiver, iniciar
sudo systemctl start minecraft

# 3. Verificar firewall
sudo iptables -L | grep 25565

# 4. Se não aparecer, liberar porta
sudo iptables -A INPUT -p tcp --dport 25565 -j ACCEPT
```

---

### Problema: "Outdated server"

**Causa:** Versão do Minecraft diferente do servidor.

**Solução:**
- Servidor é 1.21.11
- Use Minecraft 1.21.11 no launcher

---

### Problema: Tailscale não conecta

```bash
# 1. Verificar serviço
sudo systemctl status tailscaled

# 2. Se parado, iniciar
sudo systemctl start tailscaled

# 3. Tentar conectar novamente
sudo tailscale up

# 4. Se falhar, reautenticar
sudo tailscale up --force-reauth
```

---

## 📝 Comandos Úteis do Tailscale

```bash
# Ver status detalhado
sudo tailscale status

# Ver IP do dispositivo
sudo tailscale ip -4

# Listar dispositivos na rede
sudo tailscale status | grep -v "^#"

# Desconectar
sudo tailscale down

# Reconectar
sudo tailscale up

# Ver logs
sudo journalctl -u tailscaled -f

# Atualizar Tailscale
sudo pacman -Syu tailscale  # Arch
sudo apt update && sudo apt upgrade tailscale  # Ubuntu/Debian
```

---

## 🎯 Resumo Rápido

| Método | Quando Usar | Segurança | Dificuldade |
|--------|-------------|-----------|-------------|
| **Tailscale** | Sempre que possível | ⭐⭐⭐⭐⭐ | Fácil |
| **IP Local** | Mesma rede apenas | ⭐⭐⭐ | Muito Fácil |
| **IP Público** | Último recurso | ⭐⭐ | Difícil |

---

## 💡 Dicas

1. **Sempre use Tailscale** quando possível - é o método mais seguro
2. **Anote o IP do Tailscale** do servidor - ele não muda
3. **Compartilhe o IP** com amigos que estiverem na mesma rede Tailscale
4. **Teste a conexão** antes de chamar amigos para jogar

---

## 📞 Precisa de Ajuda?

**Verifique:**
1. Servidor está rodando: `sudo systemctl status minecraft`
2. Tailscale conectado: `sudo tailscale status`
3. IP correto: `sudo tailscale ip -4`
4. Porta 25565 liberada: `sudo ss -tulpn | grep 25565`
