#!/bin/bash
set -euo pipefail

# SLSsteam instalação para BazziteOS
# Otimizado para Bazzite (Fedora Atomic)

# Colors
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

# Função para verificar se estamos no Bazzite
check_bazzite() {
    if [ ! -f /etc/os-release ]; then
        return 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "bazzite" ]]; then
        echo -e "${RED}Este script é específico para BazziteOS${NC}"
        exit 1
    fi
    return 0
}

# Função para encontrar o Steam (Bazzite usa Flatpak por padrão)
find_steam_executable() {
    # 1. Flatpak Steam (padrão do Bazzite)
    if flatpak info com.valvesoftware.Steam &>/dev/null 2>&1; then
        echo "flatpak run com.valvesoftware.Steam"
        return 0
    fi
    
    # 2. Verificar se o Steam está instalado via rpm-ostree
    if rpm-ostree db list --installed | grep -q steam; then
        echo "/usr/bin/steam"
        return 0
    fi
    
    # 3. Verificar PATH
    if command -v steam &>/dev/null; then
        echo "$(command -v steam)"
        return 0
    fi
    
    return 1
}

# Função para encontrar diretório do Steam
find_steam_directory() {
    # Caminhos comuns no Bazzite
    local steam_paths=(
        "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"  # Flatpak Steam
        "$HOME/.steam/steam"                                   # Steam nativo
        "$HOME/.local/share/Steam"                             # Localização tradicional
    )
    
    for path in "${steam_paths[@]}"; do
        if [ -d "$path" ] && [ -f "$path/steam.sh" ]; then
            echo "$path"
            return 0
        fi
    done
    
    for path in "${steam_paths[@]}"; do
        if [ -d "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Função para obter diretórios de instalação
get_sls_install_dir() {
    if STEAM_DIR=$(find_steam_directory); then
        if [[ "$STEAM_DIR" == *".var/app/com.valvesoftware.Steam"* ]]; then
            echo "$HOME/.var/app/com.valvesoftware.Steam/.local/share/SLSsteam"
        else
            echo "$HOME/.local/share/SLSsteam"
        fi
    else
        echo "$HOME/.local/share/SLSsteam"
    fi
}

get_sls_config_dir() {
    if STEAM_DIR=$(find_steam_directory); then
        if [[ "$STEAM_DIR" == *".var/app/com.valvesoftware.Steam"* ]]; then
            echo "$HOME/.var/app/com.valvesoftware.Steam/.config/SLSsteam"
        else
            echo "$HOME/.config/SLSsteam"
        fi
    else
        echo "$HOME/.config/SLSsteam"
    fi
}

# Função para criar wrapper no /usr/local/bin/steam (Game Mode)
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
        echo -e "${YELLOW}Aviso: Nenhum arquivo .so encontrado em $sls_dir${NC}"
        return 1
    fi
    
    # Criar wrapper script
    echo "Criando wrapper Steam em $wrapper_path..."
    sudo tee "$wrapper_path" > /dev/null << EOF
#!/usr/bin/env bash
# BazziteOS Game Mode wrapper for SLSsteam
export LD_AUDIT="$ld_audit"
exec /usr/bin/steam "\$@"
EOF
    
    sudo chmod +x "$wrapper_path"
    echo -e "${GREEN}✓ Wrapper Steam criado com sucesso${NC}"
}

# Função para configurar injeção do SLSsteam
configure_slssteam_injection() {
    local sls_dir
    sls_dir=$(get_sls_install_dir)
    
    # Verificar se SLSsteam está instalado
    if [[ ! -d "$sls_dir" ]]; then
        echo -e "${YELLOW}Aviso: Diretório SLSsteam não encontrado${NC}"
        return 1
    fi
    
    # Habilitar PlayNotOwnedGames na configuração
    local config_file
    config_file=$(get_sls_config_dir)/config.yaml
    if [[ -f "$config_file" ]]; then
        if grep -q "^PlayNotOwnedGames:" "$config_file"; then
            sed -i 's/^PlayNotOwnedGames:.*/PlayNotOwnedGames: yes/' "$config_file"
            echo -e "${GREEN}✓ PlayNotOwnedGames habilitado${NC}"
        else
            echo "PlayNotOwnedGames: yes" >> "$config_file"
            echo -e "${GREEN}✓ PlayNotOwnedGames adicionado à configuração${NC}"
        fi
    else
        mkdir -p "$(dirname "$config_file")"
        echo "PlayNotOwnedGames: yes" > "$config_file"
        echo -e "${GREEN}✓ Arquivo de configuração criado com PlayNotOwnedGames${NC}"
    fi
    
    # Para Bazzite, não habilitamos SafeMode (não é Steam Deck)
    echo "Sistema Bazzite detectado - SafeMode não habilitado"
}

# Função para finalizar configuração do Steam
finalize_steam() {
    local steam_dir
    steam_dir=$(find_steam_directory)
    
    if [ -z "$steam_dir" ]; then
        echo -e "${YELLOW}Aviso: Diretório Steam não encontrado${NC}"
        return 1
    fi
    
    local steam_cfg="$steam_dir/steam.cfg"
    
    echo "Finalizando configuração do Steam..."
    
    # Fechar Steam se estiver rodando
    local steam_pids
    steam_pids=$(pgrep -x "steam" 2>/dev/null || true)
    if [ -z "$steam_pids" ] && flatpak info com.valvesoftware.Steam &>/dev/null; then
        steam_pids=$(pgrep -f "com.valvesoftware.Steam" 2>/dev/null || true)
    fi
    
    if [ -n "$steam_pids" ]; then
        echo "  Fechando Steam..."
        echo "$steam_pids" | xargs kill 2>/dev/null || true
        sleep 2
    fi
    
    # Remover steam.cfg para permitir atualizações
    if [ -f "$steam_cfg" ]; then
        rm -f "$steam_cfg"
        echo "  steam.cfg removido"
    fi
    
    # Iniciar Steam brevemente para atualizar
    echo "  Iniciando Steam para atualização..."
    if steam_exe=$(find_steam_executable); then
        $steam_exe &
        RUN_STEAM_PID=$!
        sleep 10
        
        # Dar tempo para atualizar
        sleep 20
        
        # Fechar Steam
        kill $RUN_STEAM_PID 2>/dev/null || true
        sleep 2
        
        # Garantir que Steam está fechado
        steam_pids=$(pgrep -x "steam" 2>/dev/null || true)
        if [ -z "$steam_pids" ] && flatpak info com.valvesoftware.Steam &>/dev/null; then
            steam_pids=$(pgrep -f "com.valvesoftware.Steam" 2>/dev/null || true)
        fi
        
        if [ -n "$steam_pids" ]; then
            echo "  Forçando fechamento do Steam..."
            echo "$steam_pids" | xargs kill -9 2>/dev/null || true
            sleep 2
        fi
    fi
    
    # Criar steam.cfg para bloquear atualizações futuras
    cat > "$steam_cfg" << 'EOF'
BootStrapperInhibitAll=enable
BootStrapperForceSelfUpdate=disable
EOF
    echo "  steam.cfg criado"
    
    echo -e "${GREEN}✓ Configuração do Steam finalizada${NC}"
}

# Instalação principal do SLSsteam para Bazzite
install_slssteam_bazzite() {
    echo -e "${GREEN}Instalando SLSsteam no Bazzite...${NC}"
    
    # Verificar Bazzite
    check_bazzite
    
    # Verificar se o Steam está instalado
    if ! steam_exe=$(find_steam_executable); then
        echo -e "${YELLOW}Steam não encontrado. Por favor, instale o Steam primeiro:${NC}"
        echo "1. Flatpak (recomendado): flatpak install flathub com.valvesoftware.Steam"
        echo "2. Via terminal: toolbox enter && sudo dnf install steam"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Steam encontrado: $steam_exe${NC}"
    
    # Fechar Steam antes da instalação
    echo "Verificando se Steam está rodando..."
    local steam_pids
    steam_pids=$(pgrep -x "steam" 2>/dev/null || true)
    if [ -z "$steam_pids" ] && flatpak info com.valvesoftware.Steam &>/dev/null; then
        steam_pids=$(pgrep -f "com.valvesoftware.Steam" 2>/dev/null || true)
    fi
    
    if [ -n "$steam_pids" ]; then
        echo -e "${YELLOW}Steam está rodando. Fechando...${NC}"
        echo "$steam_pids" | xargs kill 2>/dev/null || true
        sleep 3
    fi
    
    # Instalar dependências (a maioria já está no Bazzite)
    echo "Verificando dependências..."
    
    # Verificar e instalar 7zip se necessário
    if ! command -v 7z &>/dev/null && ! command -v 7za &>/dev/null; then
        echo "Instalando 7zip..."
        if command -v rpm-ostree &>/dev/null; then
            rpm-ostree install --apply-live p7zip p7zip-plugins
        else
            sudo dnf install -y p7zip p7zip-plugins
        fi
    fi
    
    # Verificar curl/wget
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        echo "Instalando curl..."
        if command -v rpm-ostree &>/dev/null; then
            rpm-ostree install --apply-live curl
        else
            sudo dnf install -y curl
        fi
    fi
    
    # Definir diretórios
    SLSSTEAM_INSTALL_DIR=$(get_sls_install_dir)
    SLSSTEAM_CONFIG_DIR=$(get_sls_config_dir)
    TEMP_SLS="/tmp/slssteam.7z"
    
    # Criar diretórios
    mkdir -p "$SLSSTEAM_INSTALL_DIR"
    mkdir -p "$SLSSTEAM_CONFIG_DIR"
    
    # Baixar SLSsteam
    echo "Baixando SLSsteam..."
    
    # Tentar curl primeiro, depois wget
    if command -v curl &>/dev/null; then
        RELEASE_JSON=$(curl -s "https://api.github.com/repos/AceSLS/SLSsteam/releases/latest")
    elif command -v wget &>/dev/null; then
        RELEASE_JSON=$(wget -q -O- "https://api.github.com/repos/AceSLS/SLSsteam/releases/latest")
    else
        echo -e "${RED}Erro: curl ou wget não disponíveis${NC}"
        exit 1
    fi
    
    if [ -z "$RELEASE_JSON" ] || echo "$RELEASE_JSON" | grep -q '"message":'; then
        echo -e "${RED}Erro ao buscar informações do release${NC}"
        exit 1
    fi
    
    # Extrair URL de download
    LATEST_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": *"[^\"]*SLSsteam-Any\.7z"' | \
                 sed 's/"browser_download_url": *"\([^\"]*\)"/\1/' | head -1)
    
    if [ -z "$LATEST_URL" ]; then
        echo -e "${RED}Erro: Não foi possível encontrar SLSsteam-Any.7z${NC}"
        exit 1
    fi
    
    echo "URL: $LATEST_URL"
    
    # Baixar arquivo
    if command -v curl &>/dev/null; then
        curl -L -o "$TEMP_SLS" "$LATEST_URL"
    elif command -v wget &>/dev/null; then
        wget -O "$TEMP_SLS" "$LATEST_URL"
    fi
    
    if [ ! -f "$TEMP_SLS" ]; then
        echo -e "${RED}Erro ao baixar SLSsteam${NC}"
        exit 1
    fi
    
    # Extrair
    echo "Extraindo SLSsteam..."
    rm -rf /tmp/slssteam_extract
    mkdir -p /tmp/slssteam_extract
    
    if command -v 7z &>/dev/null; then
        7z x "$TEMP_SLS" -o/tmp/slssteam_extract -y > /dev/null 2>&1
    elif command -v 7za &>/dev/null; then
        7za x "$TEMP_SLS" -o/tmp/slssteam_extract -y > /dev/null 2>&1
    else
        echo -e "${RED}Erro: 7zip não disponível para extrair${NC}"
        exit 1
    fi
    
    # Encontrar SLSsteam.so
    SLSSTEAM_SO=$(find /tmp/slssteam_extract -name "SLSsteam.so" -type f 2>/dev/null | head -1)
    
    if [ -z "$SLSSTEAM_SO" ]; then
        echo -e "${RED}Erro: SLSsteam.so não encontrado${NC}"
        rm -rf /tmp/slssteam_extract "$TEMP_SLS"
        exit 1
    fi
    
    echo -e "${GREEN}✓ SLSsteam.so encontrado${NC}"
    
    # Copiar arquivo .so
    cp "$SLSSTEAM_SO" "$SLSSTEAM_INSTALL_DIR/"
    
    # Executar setup.sh se existir
    if [ -f "/tmp/slssteam_extract/setup.sh" ]; then
        echo "Executando setup.sh..."
        chmod +x /tmp/slssteam_extract/setup.sh
        cd /tmp/slssteam_extract
        ./setup.sh install
    fi
    
    # Limpar
    rm -rf /tmp/slssteam_extract "$TEMP_SLS"
    
    # Configurar injeção
    echo ""
    configure_slssteam_injection
    
    # Finalizar Steam
    echo ""
    finalize_steam
    
    # Criar wrapper para Game Mode
    echo ""
    create_steam_wrapper
    
    # Mensagem final
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}SLSsteam instalado com sucesso no Bazzite!${NC}"
    echo ""
    echo "Para usar:"
    echo "1. Modo Desktop: Abra Steam normalmente"
    echo "2. Game Mode: Use o atalho Steam no Game Mode"
    echo ""
    echo "Configurações importantes:"
    echo "- PlayNotOwnedGames está habilitado"
    echo "- SafeMode NÃO está habilitado (não é Steam Deck)"
    echo "- Wrapper criado em /usr/local/bin/steam"
    echo -e "${GREEN}========================================${NC}"
}

# Função de desinstalação
uninstall_slssteam() {
    echo -e "${YELLOW}Desinstalando SLSsteam...${NC}"
    
    # Remover arquivos .so
    local sls_dir
    sls_dir=$(get_sls_install_dir)
    
    if [ -d "$sls_dir" ]; then
        echo "Removendo arquivos de $sls_dir..."
        rm -rf "$sls_dir"
        echo -e "${GREEN}✓ Arquivos SLSsteam removidos${NC}"
    fi
    
    # Remover configurações
    local config_dir
    config_dir=$(get_sls_config_dir)
    
    if [ -d "$config_dir" ]; then
        echo "Removendo configurações de $config_dir..."
        rm -rf "$config_dir"
        echo -e "${GREEN}✓ Configurações removidas${NC}"
    fi
    
    # Remover wrapper
    if [ -f "/usr/local/bin/steam" ]; then
        echo "Removendo wrapper Steam..."
        sudo rm -f "/usr/local/bin/steam"
        echo -e "${GREEN}✓ Wrapper removido${NC}"
    fi
    
    # Restaurar steam.sh se modificado
    local steam_dir
    steam_dir=$(find_steam_directory)
    
    if [ -n "$steam_dir" ] && [ -f "$steam_dir/steam.sh.bak" ]; then
        echo "Restaurando steam.sh original..."
        cp "$steam_dir/steam.sh.bak" "$steam_dir/steam.sh"
        rm -f "$steam_dir/steam.sh.bak"
        echo -e "${GREEN}✓ steam.sh restaurado${NC}"
    fi
    
    # Remover steam.cfg
    if [ -n "$steam_dir" ] && [ -f "$steam_dir/steam.cfg" ]; then
        echo "Removendo steam.cfg..."
        rm -f "$steam_dir/steam.cfg"
        echo -e "${GREEN}✓ steam.cfg removido${NC}"
    fi
    
    echo -e "${GREEN}Desinstalação completa!${NC}"
}

# Menu principal
show_menu() {
    echo -e "${GREEN}SLSsteam Installer para Bazzite${NC}"
    echo ""
    echo "1. Instalar SLSsteam"
    echo "2. Desinstalar SLSsteam"
    echo "3. Verificar instalação"
    echo "4. Sair"
    echo ""
    read -p "Escolha uma opção [1-4]: " choice
    
    case $choice in
        1)
            install_slssteam_bazzite
            ;;
        2)
            uninstall_slssteam
            ;;
        3)
            check_installation
            ;;
        4)
            exit 0
            ;;
        *)
            echo "Opção inválida"
            ;;
    esac
}

# Função para verificar instalação
check_installation() {
    echo -e "${GREEN}Verificando instalação do SLSsteam...${NC}"
    
    # Verificar diretório SLSsteam
    local sls_dir
    sls_dir=$(get_sls_install_dir)
    
    if [ -d "$sls_dir" ]; then
        echo -e "${GREEN}✓ Diretório SLSsteam: $sls_dir${NC}"
        
        # Verificar arquivos .so
        local so_files
        so_files=$(find "$sls_dir" -name "*.so" 2>/dev/null | wc -l)
        if [ "$so_files" -gt 0 ]; then
            echo -e "${GREEN}✓ $so_files arquivo(s) .so encontrado(s)${NC}"
        else
            echo -e "${YELLOW}⚠ Nenhum arquivo .so encontrado${NC}"
        fi
    else
        echo -e "${RED}✗ Diretório SLSsteam não encontrado${NC}"
    fi
    
    # Verificar wrapper
    if [ -f "/usr/local/bin/steam" ]; then
        echo -e "${GREEN}✓ Wrapper Steam encontrado em /usr/local/bin/steam${NC}"
    else
        echo -e "${YELLOW}⚠ Wrapper Steam não encontrado${NC}"
    fi
    
    # Verificar configuração
    local config_file
    config_file=$(get_sls_config_dir)/config.yaml
    if [ -f "$config_file" ]; then
        echo -e "${GREEN}✓ Arquivo de configuração encontrado${NC}"
        if grep -q "PlayNotOwnedGames: yes" "$config_file"; then
            echo -e "${GREEN}✓ PlayNotOwnedGames habilitado${NC}"
        else
            echo -e "${YELLOW}⚠ PlayNotOwnedGames não habilitado${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Arquivo de configuração não encontrado${NC}"
    fi
}

# Executar
if [[ $# -eq 0 ]]; then
    show_menu
else
    case $1 in
        install)
            install_slssteam_bazzite
            ;;
        uninstall)
            uninstall_slssteam
            ;;
        check)
            check_installation
            ;;
        *)
            echo "Uso: $0 [install|uninstall|check]"
            exit 1
            ;;
    esac
fi