#!/bin/bash
set -euo pipefail

# Cores (desabilitadas se não for terminal interativo)
if [ -t 1 ] && [ -t 0 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    NC=''
fi

# Variáveis legadas para compatibilidade com versões anteriores
STEAM_DIR="$HOME/.steam/steam"
FLATPAK_STEAM_DIR="$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"
FLATPAK_SLS_INSTALL_DIR="$HOME/.var/app/com.valvesoftware.Steam/.local/share/SLSsteam"
FLATPAK_SLS_CONFIG_DIR="$HOME/.var/app/com.valvesoftware.Steam/.config/SLSsteam"

# Função para detectar se é um Steam Deck (SteamOS)
is_steam_deck() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
    fi

    if [[ "$ID" == "steamos" ]] || [[ "${VARIANT_ID:-}" == "steamdeck" ]]; then
        return 0
    fi

    return 1
}

# Função para obter a string LD_AUDIT dos arquivos do SLSsteam
get_ld_audit() {
    local sls_dir
    sls_dir=$(get_sls_install_dir)
    local ld_audit=""

    while IFS= read -r so_file; do
        if [ -n "$so_file" ]; then
            if [ -z "$ld_audit" ]; then
                ld_audit="$so_file"
            else
                ld_audit="$ld_audit:$so_file"
            fi
        fi
    done < <(find "$sls_dir" -maxdepth 1 -name "*.so" 2>/dev/null | sort)

    echo "$ld_audit"
}

# Função auxiliar para instalar pacotes um por um, pulando os indisponíveis
install_packages_one_by_one() {
    local packages="$1"
    local family="$2"
    local count=0
    local skipped=0

    for pkg in $packages; do
        count=$((count + 1))

        case "$family" in
            fedora)
                if sudo dnf install -y "$pkg" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $pkg"
                else
                    echo -e "  ${YELLOW}⊘${NC} $pkg (não encontrado)"
                    skipped=$((skipped + 1))
                fi
                ;;
            debian)
                if sudo apt-get install -y -m "$pkg" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $pkg"
                else
                    echo -e "  ${YELLOW}⊘${NC} $pkg (não encontrado)"
                    skipped=$((skipped + 1))
                fi
                ;;
            arch)
                if sudo pacman -Sy --noconfirm "$pkg" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} $pkg"
                else
                    echo -e "  ${YELLOW}⊘${NC} $pkg (não encontrado)"
                    skipped=$((skipped + 1))
                fi
                ;;
        esac
    done

    if [ $skipped -gt 0 ]; then
        echo -e "  ${YELLOW}Pulou $skipped pacotes indisponíveis${NC}"
    fi
}

# Função para detectar a família de distribuição
detect_distro_family() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
    fi

    ID_LIKE="${ID_LIKE:-}"

    # SteamOS (HoloISO) - baseado no Arch Linux
    if [[ "$ID" == "steamos" ]] || [[ "$ID_LIKE" =~ "steamos" ]]; then
        echo "arch"
        return 0
    fi

    # Bazzite - baseado no Fedora Atomic (usa rpm-ostree, pular instalação de dependências)
    if [[ "$ID" == "bazzite" ]]; then
        echo "bazzite"
        return 0
    fi

    # Fedora/RHEL/CentOS
    if [[ "$ID" == "fedora" || "$ID" == "rhel" || "$ID" == "centos" || \
          "$ID_LIKE" =~ "fedora" || "$ID_LIKE" =~ "rhel" ]]; then
        echo "fedora"
        return 0
    fi

    # Debian/Ubuntu
    if [[ "$ID" == "debian" || "$ID" == "ubuntu" || \
          "$ID_LIKE" =~ "debian" || "$ID_LIKE" =~ "ubuntu" ]]; then
        echo "debian"
        return 0
    fi

    # Arch Linux
    if [[ "$ID" == "arch" || "$ID_LIKE" =~ "arch" ]] || \
       [ -f "/etc/arch-release" ]; then
        echo "arch"
        return 0
    fi

    return 1
}

# Função para encontrar o executável do Steam (lida com nativo, Flatpak, caminhos personalizados)
find_steam_executable() {
    # 1. Usar caminho padrão do Steam
    if [ -f "/usr/bin/steam" ]; then
        echo "/usr/bin/steam"
        return 0
    fi

    # 2. Verificar se o Steam Flatpak está disponível
    if command -v flatpak &>/dev/null; then
        if flatpak info com.valvesoftware.Steam &>/dev/null 2>&1; then
            echo "flatpak run com.valvesoftware.Steam"
            return 0
        fi
    fi

    # 3. Verificar PATH pelo comando steam (fallback)
    if command -v steam &>/dev/null; then
        echo "$(command -v steam)"
        return 0
    fi

    # 4. Verificar caminhos alternativos
    for path in /usr/local/bin/steam "$HOME/.local/bin/steam"; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

# Função para encontrar o diretório do Steam (lida com nativo, Flatpak, caminhos personalizados)
find_steam_directory() {
    # Caminhos comuns de instalação do Steam (em ordem de preferência)
    local steam_paths=(
        "$HOME/.steam/steam"                    # Steam moderno
        "$HOME/.local/share/Steam"              # Localização tradicional
        "$FLATPAK_STEAM_DIR"                    # Steam Flatpak
        "/opt/steam/steam"                      # Personalizado /opt
        "/usr/local/steam"                      # Personalizado /usr/local
    )

    for path in "${steam_paths[@]}"; do
        if [ -d "$path" ] && [ -f "$path/steam.sh" ]; then
            echo "$path"
            return 0
        fi
    done

    # Fallback: verificar qualquer diretório com steam.sh
    for path in "${steam_paths[@]}"; do
        if [ -d "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

# Função para detectar o tipo de instalação do Steam (legado, use find_steam_* em vez disso)
get_steam_dir() {
    local dir
    if dir=$(find_steam_directory); then
        echo "$dir"
    else
        echo "$STEAM_DIR"
    fi
}

# Função para obter diretório de instalação do SLSsteam
get_sls_install_dir() {
    if find_steam_directory &>/dev/null; then
        if [ -d "$FLATPAK_STEAM_DIR" ]; then
            echo "$FLATPAK_SLS_INSTALL_DIR"
        else
            echo "$HOME/.local/share/SLSsteam"
        fi
    else
        echo "$HOME/.local/share/SLSsteam"
    fi
}

# Função para obter diretório de configuração do SLSsteam
get_sls_config_dir() {
    if find_steam_directory &>/dev/null; then
        if [ -d "$FLATPAK_STEAM_DIR" ]; then
            echo "$FLATPAK_SLS_CONFIG_DIR"
        else
            echo "$HOME/.config/SLSsteam"
        fi
    else
        echo "$HOME/.config/SLSsteam"
    fi
}

# Função para configurar a injeção do SLSsteam
configure_slssteam_injection() {
    local sls_dir
    sls_dir=$(get_sls_install_dir)
    local steam_script
    local ld_audit

    # Verificar se o SLSsteam está instalado
    if [[ ! -d "$sls_dir" ]]; then
        echo "Aviso: Diretório do SLSsteam não encontrado"
        return 1
    fi

    # Verificar se o executável do Steam está disponível (apenas aviso)
    if ! steam_script=$(find_steam_executable 2>/dev/null); then
        echo -e "${YELLOW}Aviso: Executável do Steam não encontrado${NC}"
        echo "A injeção do SLSsteam será pulada. Execute novamente após instalar o Steam."
        return 0
    fi

    # Construir string LD_AUDIT a partir dos arquivos .so
    local so_files
    so_files=$(find "$sls_dir" -maxdepth 1 -name "*.so" | sort)
    if [[ -z "$so_files" ]]; then
        echo "Aviso: Nenhum arquivo .so encontrado em $sls_dir"
        return 1
    fi

    ld_audit=""
    while IFS= read -r so_file; do
        if [[ -z "$ld_audit" ]]; then
            ld_audit="$so_file"
        else
            ld_audit="$ld_audit:$so_file"
        fi
        echo "  Encontrado: $so_file"
    done <<< "$so_files"

    echo "Configurando injeção do SLSsteam em $steam_script..."

    # Fazer backup do script steam original
    if [[ ! -f "${steam_script}.bak" ]]; then
        sudo cp "$steam_script" "${steam_script}.bak"
        echo "  Backup criado: ${steam_script}.bak"
    fi

    # Verificar se já foi modificado (injeção do SLSsteam presente)
    if grep -q "LD_AUDIT.*SLSsteam" "$steam_script" 2>/dev/null; then
        echo "  Injeção do SLSsteam já presente. Atualizando..."
        # Remover linhas LD_AUDIT existentes
        sudo sed -i '/^export LD_AUDIT.*SLSsteam/d' "$steam_script"
    fi

    # Encontrar a última linha exec e adicionar LD_AUDIT antes dela
    sudo sed -i '/^exec.*steam.*"\$\@"/i export LD_AUDIT="'"$ld_audit"'"' "$steam_script"

    # Nota: Atalhos de desktop já são corrigidos pelo setup.sh do SLSsteam

    # Habilitar PlayNotOwnedGames na configuração
    local config_file
    config_file=$(get_sls_config_dir)/config.yaml
    if [[ -f "$config_file" ]]; then
        if grep -q "^PlayNotOwnedGames:" "$config_file"; then
            sed -i 's/^PlayNotOwnedGames:.*/PlayNotOwnedGames: yes/' "$config_file"
            echo "  PlayNotOwnedGames habilitado"
        fi
    fi

    # Habilitar SafeMode APENAS no Steam Deck
    if is_steam_deck; then
        echo "  Steam Deck detectado - habilitando SafeMode"
        if grep -q "^SafeMode:" "$config_file" 2>/dev/null; then
            sed -i 's/^SafeMode:.*/SafeMode: yes/' "$config_file"
        else
            echo "SafeMode: yes" >> "$config_file"
        fi
        echo "  SafeMode habilitado"
    else
        echo "  Sistema não Steam Deck - SafeMode não habilitado"
    fi

    echo "Injeção do SLSsteam configurada com sucesso."
}

# Função para criar wrapper em /usr/local/bin/steam para o Modo de Jogo do Bazzite
create_steam_wrapper() {
    local sls_dir
    sls_dir=$(get_sls_install_dir)
    local wrapper_path="/usr/local/bin/steam"

    # Construir string LD_AUDIT
    local ld_audit=""
    while IFS= read -r so_file; do
        if [ -n "$so_file" ]; then
            if [ -z "$ld_audit" ]; then
                ld_audit="$so_file"
            else
                ld_audit="$ld_audit:$so_file"
            fi
        fi
    done < <(find "$sls_dir" -maxdepth 1 -name "*.so" 2>/dev/null | sort)

    if [ -z "$ld_audit" ]; then
        echo "  Aviso: Nenhum arquivo .so encontrado em $sls_dir"
        return 1
    fi

    # Verificar se /usr/local/bin existe
    if [ ! -d "/usr/local/bin" ]; then
        echo "  Criando diretório /usr/local/bin..."
        sudo mkdir -p /usr/local/bin
    fi

    # Criar script wrapper
    echo "  Criando wrapper do Steam em $wrapper_path..."
    sudo tee "$wrapper_path" > /dev/null << EOF
#!/usr/bin/env bash
# Wrapper do Modo de Jogo do BazziteOS para SLSsteam
export LD_AUDIT="$ld_audit"
exec /usr/bin/steam "\$@"
EOF

    sudo chmod +x "$wrapper_path"
    echo "  Wrapper do Steam criado com sucesso"
}

# Função para corrigir steam-jupiter para o Modo de Jogo do Steam Deck
patch_steam_jupiter() {
    local steam_jupiter="/usr/bin/steam-jupiter"
    local sls_dir
    sls_dir=$(get_sls_install_dir)

    if [ ! -f "$steam_jupiter" ]; then
        echo "  steam-jupiter não encontrado em $steam_jupiter (não é um Steam Deck)"
        return 1
    fi

    echo "  Corrigindo steam-jupiter em $steam_jupiter..."

    # Fazer backup do arquivo original
    if [ ! -f "${steam_jupiter}.bak" ]; then
        sudo cp "$steam_jupiter" "${steam_jupiter}.bak"
        echo "  Backup criado: ${steam_jupiter}.bak"
    fi

    # Construir string LD_AUDIT
    local ld_audit=""
    while IFS= read -r so_file; do
        if [ -n "$so_file" ]; then
            if [ -z "$ld_audit" ]; then
                ld_audit="$so_file"
            else
                ld_audit="$ld_audit:$so_file"
            fi
        fi
    done < <(find "$sls_dir" -maxdepth 1 -name "*.so" 2>/dev/null | sort)

    if [ -z "$ld_audit" ]; then
        echo "  Aviso: Nenhum arquivo .so encontrado em $sls_dir"
        return 1
    fi

    # Verificar se já foi corrigido
    if grep -q "LD_AUDIT.*SLSsteam" "$steam_jupiter" 2>/dev/null; then
        echo "  steam-jupiter já corrigido, atualizando..."
        sudo sed -i '/^export LD_AUDIT.*SLSsteam/d' "$steam_jupiter"
    fi

    # Encontrar a linha exec com steam -steamdeck e adicionar LD_AUDIT antes dela
    if grep -q 'exec /usr/lib/steam/steam -steamdeck' "$steam_jupiter" 2>/dev/null; then
        sudo sed -i '/^exec \/usr\/lib\/steam\/steam -steamdeck/i export LD_AUDIT="'"$ld_audit"'"' "$steam_jupiter"
        echo "  steam-jupiter corrigido com LD_AUDIT"
    else
        # Fallback: adicionar antes de qualquer linha exec steam
        sudo sed -i '/^exec.*steam.*"-steamdeck"/i export LD_AUDIT="'"$ld_audit"'"' "$steam_jupiter" 2>/dev/null || \
        sudo sed -i '/^exec.*steam/i export LD_AUDIT="'"$ld_audit"'"' "$steam_jupiter" 2>/dev/null || true
        echo "  Aplicada correção alternativa ao steam-jupiter"
    fi
}

# Função para corrigir steam.sh com LD_AUDIT
patch_steam_sh() {
    local steam_dir
    steam_dir=$(get_steam_dir)
    local sls_dir
    sls_dir=$(get_sls_install_dir)
    local steam_sh="$steam_dir/steam.sh"

    if [ ! -f "$steam_sh" ]; then
        echo "  steam.sh não encontrado em $steam_sh"
        return 1
    fi

    # Construir string LD_AUDIT
    local ld_audit=""
    while IFS= read -r so_file; do
        if [ -n "$so_file" ]; then
            if [ -z "$ld_audit" ]; then
                ld_audit="$so_file"
            else
                ld_audit="$ld_audit:$so_file"
            fi
        fi
    done < <(find "$sls_dir" -maxdepth 1 -name "*.so" 2>/dev/null | sort)

    # Verificar se já foi corrigido (usar padrão grep mais simples)
    if grep -q "LD_AUDIT.*SLSsteam" "$steam_sh" 2>/dev/null; then
        echo "  steam.sh já corrigido, atualizando..."
        sed -i '/^export LD_AUDIT.*SLSsteam/d' "$steam_sh"
    fi

    # Adicionar export LD_AUDIT na linha 10 (mesma abordagem do headcrab.sh)
    sed -i '10a export LD_AUDIT="'"$ld_audit"'"' "$steam_sh"
    echo "  steam.sh corrigido em $steam_sh"
}

# Função para executar o Steam com injeção do SLSsteam
run_steam_with_sls() {
    local sls_dir
    sls_dir=$(get_sls_install_dir)
    local steam_exe

    if ! steam_exe=$(find_steam_executable); then
        echo "  Aviso: Executável do Steam não encontrado, não é possível executar o Steam"
        return 1
    fi

    local ld_audit=""
    while IFS= read -r so_file; do
        if [ -n "$so_file" ]; then
            if [ -z "$ld_audit" ]; then
                ld_audit="$so_file"
            else
                ld_audit="$ld_audit:$so_file"
            fi
        fi
    done < <(find "$sls_dir" -maxdepth 1 -name "*.so" 2>/dev/null | sort)

    if [ -n "$ld_audit" ]; then
        LD_AUDIT="$ld_audit" $steam_exe "$@"
    else
        echo "  Aviso: Nenhum arquivo .so do SLSsteam encontrado, executando Steam sem injeção" >&2
        $steam_exe "$@"
    fi
}

# Função para finalizar o Steam após a instalação
finalize_steam() {
    local steam_dir
    steam_dir=$(get_steam_dir)
    local steam_cfg="$steam_dir/steam.cfg"
    local steam_jupiter="/usr/bin/steam-jupiter"

    echo "Finalizando configuração do Steam..."

    # Remover steam.cfg para permitir atualizações
    if [ -f "$steam_cfg" ]; then
        rm -f "$steam_cfg"
        echo "  steam.cfg removido"
    fi

    # Matar o Steam se estiver executando (verificar tanto nativo, flatpak quanto Steam Deck)
    local steam_pids
    steam_pids=$(pgrep -x "steam" 2>/dev/null || true)
    if [ -z "$steam_pids" ] && [ -d "$FLATPAK_STEAM_DIR" ]; then
        steam_pids=$(pgrep -f "com.valvesoftware.Steam" 2>/dev/null || true)
    fi

    if [ -n "$steam_pids" ]; then
        echo "  Fechando Steam..."
        echo "$steam_pids" | xargs kill 2>/dev/null || true
        sleep 2
    fi

    # Para Steam Deck: Não executar Steam aqui, apenas preparar para correção
    # O Modo de Jogo usa steam-jupiter que precisa ser corrigido após o Steam fechar
    if [ -f "$steam_jupiter" ]; then
        echo "  Steam Deck detectado - irá corrigir steam-jupiter para o Modo de Jogo"
        echo "  Iniciando Steam brevemente para verificar atualizações..."
        # Iniciar Steam brevemente e depois fechá-lo
        if command -v steam &>/dev/null; then
            steam &
            RUN_STEAM_PID=$!
            sleep 10
            kill $RUN_STEAM_PID 2>/dev/null || true
            sleep 2
        fi
    else
        # Para não Steam Deck: Executar Steam com SLSsteam (permite que o Steam atualize se necessário)
        echo "  Iniciando Steam (irá atualizar automaticamente se necessário)..."
        run_steam_with_sls &
        RUN_STEAM_PID=$!

        # Aguardar o Steam abrir
        sleep 5

        # Aguardar o Steam iniciar completamente (verificar tanto nativo quanto flatpak)
        local attempts=0
        while [ $attempts -lt 12 ]; do
            steam_pids=$(pgrep -x "steam" 2>/dev/null || true)
            if [ -z "$steam_pids" ] && [ -d "$FLATPAK_STEAM_DIR" ]; then
                steam_pids=$(pgrep -f "com.valvesoftware.Steam" 2>/dev/null || true)
            fi
            if [ -n "$steam_pids" ]; then
                break
            fi
            sleep 1
            attempts=$((attempts + 1))
        done

        # Dar tempo para o Steam atualizar
        sleep 30

        # Forçar fechamento do Steam
        steam_pids=$(pgrep -x "steam" 2>/dev/null || true)
        if [ -z "$steam_pids" ] && [ -d "$FLATPAK_STEAM_DIR" ]; then
            steam_pids=$(pgrep -f "com.valvesoftware.Steam" 2>/dev/null || true)
        fi

        if [ -n "$steam_pids" ]; then
            echo "  Fechando Steam..."
            echo "$steam_pids" | xargs kill 2>/dev/null || true
            sleep 2
        fi

        # Também matar a execução em segundo plano que iniciamos
        kill $RUN_STEAM_PID 2>/dev/null || true
    fi

    # Criar steam.cfg para bloquear atualizações futuras
    cat > "$steam_cfg" << 'EOF'
BootStrapperInhibitAll=enable
BootStrapperForceSelfUpdate=disable
EOF
    echo "  steam.cfg criado"
    echo "Status: Corrigido"
}

# Função principal de instalação
install_slssteam() {
    echo -e "${GREEN}Instalando SLSsteam...${NC}"

    # Variáveis - usar diretórios dinâmicos
    SLSSTEAM_INSTALL_DIR=$(get_sls_install_dir)
    SLSSTEAM_CONFIG_DIR=$(get_sls_config_dir)
    STEAM_DIR=$(get_steam_dir)
    STEAM_LIB_DIR="$STEAM_DIR/ubuntu12_32"
    TEMP_SLS="/tmp/slssteam.7z"

    # Obter família da distribuição para instalação de dependências
    FAMILY=$(detect_distro_family)
    if [ -z "$FAMILY" ]; then
        FAMILY="debian"
    fi

    # Instalar dependências do SLSsteam uma por uma, pulando as indisponíveis
    echo "Instalando dependências do SLSsteam..."
    case "$FAMILY" in
        bazzite)
            # Bazzite usa rpm-ostree - dependências já devem estar na imagem base
            echo "  Bazzite detectado - pulando instalação de dependências (pacotes estão na imagem base)"
            ;;
        fedora)
            SLS_PACKAGES="git libnotify curl libcurl-devel openssl-devel libcrypto-devel 7zip p7zip-plugins"
            install_packages_one_by_one "$SLS_PACKAGES" "$FAMILY"
            ;;
        debian)
            SLS_PACKAGES="git libnotify-bin curl 7zip-full libcurl4-openssl-dev libcurl4 libcurl4:i386 libcurl libcurl:i386 libssl3 libssl-dev libcrypto++6 libcrypto++-dev libxcb-cursor0"
            install_packages_one_by_one "$SLS_PACKAGES" "$FAMILY"
            ;;
        arch)
            SLS_PACKAGES="git libnotify curl 7zip"
            install_packages_one_by_one "$SLS_PACKAGES" "$FAMILY"
            ;;
    esac

    # Habilitar arquitetura i386 para Debian/Ubuntu se necessário
    if [ "$FAMILY" = "debian" ]; then
        if ! dpkg --print-foreign-architectures 2>/dev/null | grep -q i386; then
            echo "Habilitando arquitetura i386..."
            sudo dpkg --add-architecture i386
            sudo apt update || true
        fi
    fi

    # Remover link simbólico antigo do libcurl se existir
    if [ -d "$STEAM_LIB_DIR" ]; then
        rm -f "$STEAM_LIB_DIR/libcurl.so"*
        echo "Links simbólicos antigos do libcurl removidos."
    fi

    # Verificar se 7z está instalado, tentar unzip como fallback
    EXTRACT_CMD=""
    EXTRACT_TYPE=""
    if command -v 7z >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1; then
        EXTRACT_CMD="7z x"
        EXTRACT_TYPE="7z"
    elif command -v unzip >/dev/null 2>&1; then
        echo -e "${YELLOW}Aviso: 7z não encontrado, usando unzip como fallback${NC}"
        EXTRACT_CMD="unzip -AA"
        EXTRACT_TYPE="unzip"
    elif [ "$FAMILY" = "bazzite" ]; then
        # Bazzite: 7z deve estar na imagem base, avisar e falhar
        echo -e "${YELLOW}Aviso: 7z não disponível no Bazzite${NC}"
        echo "A instalação do SLSsteam será pulada."
        return 1
    else
        echo "Instalando p7zip..."
        if case "$FAMILY" in
            fedora) sudo dnf install -y p7zip p7zip-plugins ;;
            debian) sudo apt install -y p7zip-full ;;
            arch)   sudo pacman -Sy --noconfirm p7zip ;;
        esac; then
            EXTRACT_CMD="7z x"
            EXTRACT_TYPE="7z"
        else
            echo -e "${YELLOW}Aviso: Não foi possível instalar 7z, tentando unzip...${NC}"
            if command -v unzip >/dev/null 2>&1; then
                EXTRACT_CMD="unzip -AA"
                EXTRACT_TYPE="unzip"
            else
                echo -e "${YELLOW}Aviso: Nem 7z nem unzip disponíveis${NC}"
                echo "A instalação do SLSsteam será pulada."
                return 1
            fi
        fi
    fi

    # Verificar se wget está instalado, tentar curl como fallback
    DOWNLOAD_CMD=""
    if command -v wget >/dev/null 2>&1; then
        DOWNLOAD_CMD="wget -q -O"
    elif command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}Aviso: wget não encontrado, usando curl como fallback${NC}"
        DOWNLOAD_CMD="curl -sL -o"
    elif [ "$FAMILY" = "bazzite" ]; then
        # Bazzite: wget/curl devem estar na imagem base, avisar e falhar
        echo -e "${YELLOW}Aviso: Nem wget nem curl disponíveis no Bazzite${NC}"
        echo "A instalação do SLSsteam será pulada."
        return 1
    else
        echo "Instalando wget..."
        if case "$FAMILY" in
            fedora) sudo dnf install -y wget ;;
            debian) sudo apt install -y wget ;;
            arch)   sudo pacman -Sy --noconfirm wget ;;
        esac; then
            DOWNLOAD_CMD="wget -q -O"
        else
            echo -e "${YELLOW}Aviso: Não foi possível instalar wget, tentando curl...${NC}"
            if command -v curl >/dev/null 2>&1; then
                DOWNLOAD_CMD="curl -sL -o"
            else
                echo -e "${YELLOW}Aviso: Nem wget nem curl disponíveis${NC}"
                echo "A instalação do SLSsteam será pulada."
                return 1
            fi
        fi
    fi

    # Verificar se o Steam está instalado (apenas aviso, não falhar)
    if ! STEAM_DIR=$(find_steam_directory); then
        echo -e "${YELLOW}Aviso: Diretório do Steam não encontrado${NC}"
        echo "A instalação do SLSsteam será pulada."
        echo "Instale o Steam e execute novamente este script para habilitar o SLSsteam."
        return 0
    fi

    # Verificar se o Steam está executando e avisar o usuário
    STEAM_PID=$(pgrep -x "steam" 2>/dev/null || true)
    if [ -n "$STEAM_PID" ]; then
        echo -e "${YELLOW}Steam está executando. Feche o Steam manualmente.${NC}"
        if [ -t 0 ]; then
            echo "Pressione Enter após fechar o Steam..."
            read -r
            STEAM_PID=$(pgrep -x "steam" 2>/dev/null || true)
            while [ -n "$STEAM_PID" ]; do
                echo "Steam ainda está executando. Feche-o."
                sleep 2
                STEAM_PID=$(pgrep -x "steam" 2>/dev/null || true)
            done
        else
            echo "Reinicie o Steam após a instalação completar."
            sleep 3
        fi
    fi

    # Criar diretórios
    mkdir -p "$SLSSTEAM_INSTALL_DIR"
    mkdir -p "$SLSSTEAM_CONFIG_DIR"

    # Fazer backup da configuração existente
    if [ -f "$SLSSTEAM_CONFIG_DIR/config.yaml" ]; then
        cp "$SLSSTEAM_CONFIG_DIR/config.yaml" "$SLSSTEAM_CONFIG_DIR/config.yaml.bak"
        echo "Backup da configuração criado."
    fi

    echo "Baixando SLSsteam..."
    # Obter dados da versão da API do GitHub
    RELEASE_JSON=$(curl -s "https://api.github.com/repos/AceSLS/SLSsteam/releases/latest")

    if [ -z "$RELEASE_JSON" ] || echo "$RELEASE_JSON" | grep -q '"message":'; then
        echo -e "${RED}Erro ao buscar informações da versão do SLSsteam.${NC}"
        return 1
    fi

    # Extrair URL de download usando grep com padrão mais específico
    LATEST_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": *"[^\"]*SLSsteam-Any\.7z"' | \
                 sed 's/"browser_download_url": *"\([^\"]*\)"/\1/' | head -1)

    if [ -z "$LATEST_URL" ]; then
        echo -e "${RED}Erro: Não foi possível encontrar SLSsteam-Any.7z nos assets da versão.${NC}"
        return 1
    fi

    if ! $DOWNLOAD_CMD "$TEMP_SLS" "$LATEST_URL"; then
        echo -e "${RED}Erro ao baixar SLSsteam.${NC}"
        rm -f "$TEMP_SLS"
        return 1
    fi

    # Extrair e instalar
    echo "Extraindo SLSsteam..."
    rm -rf /tmp/slssteam_extract
    mkdir -p /tmp/slssteam_extract

    if ! $EXTRACT_CMD "$TEMP_SLS" -o/tmp/slssteam_extract -y 2>&1 | tail -5; then
        echo -e "${RED}Erro ao extrair arquivo.${NC}"
        rm -rf /tmp/slssteam_extract "$TEMP_SLS"
        return 1
    fi

    # Encontrar SLSsteam.so em qualquer subdiretório
    SLSSTEAM_SO=$(find /tmp/slssteam_extract -name "SLSsteam.so" -type f 2>/dev/null | head -1)

    if [ -z "$SLSSTEAM_SO" ]; then
        echo -e "${RED}Erro: SLSsteam.so não encontrado no arquivo.${NC}"
        echo "Conteúdo do arquivo:"
        find /tmp/slssteam_extract -type f 2>/dev/null | head -20
        rm -rf /tmp/slssteam_extract "$TEMP_SLS"
        return 1
    fi

    echo "SLSsteam.so encontrado em: $SLSSTEAM_SO"

    # Configurar SLSsteam: garantir que PlayNotOwnedGames está habilitado (antes da limpeza)
    mkdir -p "$SLSSTEAM_CONFIG_DIR"
    if [ ! -f "$SLSSTEAM_CONFIG_DIR/config.yaml" ]; then
        if [ -f "/tmp/slssteam_extract/res/config.yaml" ]; then
            cp /tmp/slssteam_extract/res/config.yaml "$SLSSTEAM_CONFIG_DIR/config.yaml"
        fi
    fi

    if grep -q "^PlayNotOwnedGames:" "$SLSSTEAM_CONFIG_DIR/config.yaml" 2>/dev/null; then
        sed -i 's/^PlayNotOwnedGames:.*/PlayNotOwnedGames: yes/' "$SLSSTEAM_CONFIG_DIR/config.yaml"
        echo "PlayNotOwnedGames habilitado na configuração."
    else
        echo "PlayNotOwnedGames: yes" >> "$SLSSTEAM_CONFIG_DIR/config.yaml"
        echo "PlayNotOwnedGames adicionado à configuração."
    fi

    # Executar setup.sh install do SLSsteam (lida com wrappers, arquivos de desktop, etc.)
    cd /tmp/slssteam_extract
    if [ -f "setup.sh" ]; then
        ./setup.sh install
    else
        echo "setup.sh não encontrado, usando instalação manual..."
        # Fallback: instalação manual
        cp "$SLSSTEAM_SO" "$SLSSTEAM_INSTALL_DIR/"
    fi

    rm -rf /tmp/slssteam_extract "$TEMP_SLS"

    echo ""
    echo -e "${GREEN}Finalizando configuração do Steam...${NC}"
    finalize_steam

    echo ""
    echo -e "${GREEN}Corrigindo scripts do Steam...${NC}"
    configure_slssteam_injection

    # Steam Deck: corrigir steam-jupiter para Modo de Jogo
    if [ -f "/usr/bin/steam-jupiter" ]; then
        echo ""
        echo -e "${GREEN}Corrigindo steam-jupiter para Modo de Jogo do Steam Deck...${NC}"
        patch_steam_jupiter
    fi

    # Sempre corrigir steam.sh (usado no Modo Desktop, mesmo no Steam Deck)
    if [ -f "$HOME/.steam/steam/steam.sh" ] || [ -f "$HOME/.local/share/Steam/steam.sh" ]; then
        patch_steam_sh
    fi

    # Criar wrapper em /usr/local/bin/steam para Modo de Jogo do Bazzite (injeção redundante)
    echo ""
    echo -e "${GREEN}Criando wrapper do Steam para injeção no Modo de Jogo...${NC}"
    create_steam_wrapper

    echo ""
    echo "SLSsteam instalado e configurado com sucesso!"
    echo "Basta abrir o Steam normalmente para jogar."
}

# Executar instalação se o script for executado diretamente (não source)
# Também executar se executado via curl | bash (BASH_SOURCE[0] == "-")
if [ -z "${BASH_SOURCE:-}" ] || [ ${#BASH_SOURCE[@]} -eq 0 ] || [[ "${BASH_SOURCE[0]:-}" == "-" ]] || [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    install_slssteam
fi
