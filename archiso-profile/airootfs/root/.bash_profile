#!/bin/bash

if [ -z "${CRIAS_SKIP_AUTOSTART:-}" ] && [ -t 0 ] && [ -z "${SSH_CONNECTION:-}" ]; then
    case "$(tty 2>/dev/null || true)" in
        /dev/tty1)
            echo ""
            echo "Iniciando o bootstrap do Crias-Server."
            echo "Defina CRIAS_SKIP_AUTOSTART=1 para entrar somente no shell do live ISO."
            echo ""
            /root/.automated_script.sh
            ;;
    esac
fi