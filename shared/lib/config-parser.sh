#!/bin/bash

# Shared config parsing helpers used by the root installer and tests.

OVERRIDABLE_VARS=(
    SERVER_TYPE
    FORCE_HARDWARE_TIER
    INSTALL_TAILSCALE
    APPLY_SYSTEM_TUNING
    SYSTEM_TUNING_SCOPE
    CLEANUP_OTHER_STACK
    DRY_RUN
    NON_INTERACTIVE
    MINECRAFT_USER
    MINECRAFT_SERVER_DIR
    MINECRAFT_PORT
    MINECRAFT_ONLINE_MODE
    MINECRAFT_MOTD
    MINECRAFT_VERSION
    MINECRAFT_LOADER
    MINECRAFT_INSTALL_MODPACK
    MINECRAFT_ADRENALINE_VERSION
    MINECRAFT_INSTALL_QOL_MODS
    ACCEPT_EULA
    MRPACK_SHA256
    TERRARIA_USER
    TERRARIA_SERVER_DIR
    TERRARIA_PORT
    TERRARIA_WORLD_NAME
    TERRARIA_MOTD
    TERRARIA_DOWNLOAD_URL
    TERRARIA_SHA256
)

capture_env_overrides() {
    local var_name
    local has_name
    local value_name

    for var_name in "${OVERRIDABLE_VARS[@]}"; do
        has_name="ENV_HAS_${var_name}"
        value_name="ENV_VALUE_${var_name}"

        if [[ -v $var_name ]]; then
            printf -v "$has_name" '%s' "true"
            printf -v "$value_name" '%s' "${!var_name}"
        else
            printf -v "$has_name" '%s' "false"
        fi
    done
}

# Safely set and export a dynamic variable name.
set_config_var() {
    local __key="$1"
    local __val="$2"

    printf -v "$__key" '%s' "$__val"
}

restore_env_overrides() {
    local var_name
    local has_name
    local value_name

    for var_name in "${OVERRIDABLE_VARS[@]}"; do
        has_name="ENV_HAS_${var_name}"
        value_name="ENV_VALUE_${var_name}"

        if [ "${!has_name}" = "true" ]; then
            printf -v "$var_name" '%s' "${!value_name}"
        fi
    done
}

apply_config_with_env_precedence() {
    local config_file="${1:-}"

    # Capture current environment state (idempotent for each call).
    # This ensures proper precedence in all contexts, including:
    # - Direct calls in tests with subshells (each subshell reacaptures)
    # - Calls in install.sh after defaults are initialized
    capture_env_overrides
    load_config_file "$config_file"
    restore_env_overrides
}

load_config_file() {
    local config_file="${1:-}"

    if [ -z "$config_file" ]; then
        return 0
    fi

    if [ -f "$config_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            local __trim
            __trim="${line%%[![:space:]]*}"
            line="${line#"$__trim"}"
            __trim="${line##*[![:space:]]}"
            line="${line%"$__trim"}"

            [ -z "$line" ] && continue
            [[ "$line" == \#* ]] && continue

            if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"

                if [ -z "$value" ]; then
                    continue
                fi

                if [[ "$value" == '"'*'"' ]] || [[ "$value" == "'"*"'" ]]; then
                    value="${value:1:${#value}-2}"
                fi

                value="${value//\$\(/\\$\(}"
                value="${value//\`/\\\`}"
                value="${value//\$\{/\\$\{}"

                set_config_var "$key" "$value"
            else
                printf '%s\n' "Linha ignorada em ${config_file} (formato invalido): ${line}" >&2
            fi
        done < "$config_file"
    fi
}
