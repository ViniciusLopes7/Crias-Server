# Gerador de ISO (Archiso) para o Minecraft

Com essas configurações, você pode construir sua própria ISO Bootável que já contém todas as dependências pré-instaladas. Isso economiza muito tempo em formatações porque toda a base do sistema (Kernel Padrão Linux), dependências do Minecraft (Java 21, Screen, Tailscale, NetworkManager) já estarão embutidas e prontas na hora do Boot. 

### Como Construir a Imagem .iso

1. **Rodando a partir de um Arch Linux Hospedeiro**, instale a ferramenta de construção:
```bash
sudo pacman -S archiso
```

2. **Copie o perfil original** `releng` para servir de esqueleto:
```bash
cp -r /usr/share/archiso/configs/releng ~/archiso-minecraft
```

3. **Substitua os arquivos** pelos da pasta `archiso-profile`:
   * Adicione o `packages.x86_64` modificado para conter os nossos pacotes listados.
   * Adicione o `profiledef.sh` para mudar o nome e título da ISO.
   * Cole o `setup-minecraft.sh` dentro do subdiretório `airootfs/root/` que será o script rápido na hora de dar o boot.

4. **Inicie o gerador (`mkarchiso`)**:
```bash
sudo mkarchiso -v -w /tmp/archiso-tmp -o ~/out ~/archiso-minecraft
```

Ao final desse processo (que pode demorar um pouco e exigir alguns GBs livres em disco e RAM), ele vai gerar o arquivo da ISO dentro da pasta `~/out`. Você pode flashear essa ISO em um Pendrive pelo BalenaEtcher ou Rufus.

Depois, na máquina alvo, basta plugar o pendrive e dar Boot. Quando cair no console do Live USB como Root, basta rodar `./setup-minecraft.sh` e ele irá configurar nativamente o Repo do GitHub e disparar a instalação interativa.