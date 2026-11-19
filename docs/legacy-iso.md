# Legacy: live ISO customizada (DESCONTINUADA)

> **A ISO customizada foi descontinuada.** Este documento preserva o
> procedimento HISTÓRICO para mídias antigas que ainda o embutem. O fluxo
> suportado atualmente é o bootstrap em host já instalado:
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/crias-bootstrap.sh | sudo bash
> ```

### Live ISO

O `install.sh` instala `openssh` se necessário. O `sshd` **não** sobe
sozinho no boot do live USB. O `root` está **travado** no `/etc/shadow`
(hash `!` ou `*` — verificado por `tests/iso-live-credentials-validate.sh`),
mas um drop-in systemd (`/etc/systemd/system/getty@tty1.service.d/autologin.conf`)
de senha apenas naquele terminal físico.

Para iniciar `sshd` manualmente no live (ex.: para instalar remotamente via
SSH), você precisa primeiro definir uma senha de root (porque root está
travado por padrão):

```bash
# No console do live ISO (como root, já autologado no tty1):
passwd                  # define uma senha de root (NÃO deixe vazia)
systemctl start sshd
# Agora: ssh root@<ip-do-live>
```

> **Atenção**: o autologin do root no tty1 é uma conveniência de mídia de
> Se você iniciar o `sshd` no live **sem** definir uma senha de root forte,
> qualquer um que alcançar a porta 22 NÃO terá shell (root está travado).
> Mas se você definiu `passwd` com senha fraca, o risco é real. **Sempre**
> defina uma senha forte OU restrinja via firewall antes de iniciar o `sshd`.
>
> Em outros ttys (tty2-tty6), root não consegue logar (senha travada). Para
> acesso non-root no live, crie um usuário: `useradd -m -G wheel -s /bin/bash
> <nome>` + `passwd <nome>`.

