#!/bin/bash

CONFIG_FILE="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.bak"
LOG_FILE="/var/log/gestor_swap.log"

# Função para logar mensagens
log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# Função para restaurar backup em caso de erro
restore_backup() {
    cp "$BACKUP_FILE" "$CONFIG_FILE"
    if [ $? -eq 0 ]; then
        log_message "Backup restaurado com sucesso."
    else
        log_message "Erro ao restaurar o backup."
        exit 1
    fi
}

# Função para modificar o arquivo de configuração do SSH
modify_sshd_config() {
    local search="$1"
    local replace="$2"
    if grep -q "$search" "$CONFIG_FILE"; then
        sed -i "s/$search/$replace/g" "$CONFIG_FILE"
        if [ $? -eq 0 ]; then
            log_message "Modificado: $search -> $replace"
        else
            log_message "Erro ao modificar: $search -> $replace"
            restore_backup
            exit 1
        fi
    fi
}

# Backup do arquivo de configuração do SSH
cp "$CONFIG_FILE" "$BACKUP_FILE"
if [ $? -eq 0 ]; then
    log_message "Backup do arquivo SSH realizado com sucesso."
else
    log_message "Erro ao fazer o backup do arquivo SSH."
    exit 1
fi

# Modificar o arquivo de configuração do SSH
modify_sshd_config "prohibit-password" "yes"
modify_sshd_config "without-password" "yes"
modify_sshd_config "^#PermitRootLogin.*" "PermitRootLogin yes"

# Remover entradas de configuração específicas
for setting in "PasswordAuthentication" "X11Forwarding" "ClientAliveInterval" "ClientAliveCountMax" "MaxStartups"; do
    sed -i "/^#\?\s*${setting}[[:space:]]/d" "$CONFIG_FILE"
    if [ $? -eq 0 ]; then
        log_message "Removido: $setting"
    else
        log_message "Erro ao remover: $setting"
        restore_backup
        exit 1
    fi
done

# Adicionar configurações desejadas
{
    echo 'PasswordAuthentication yes'
    echo 'X11Forwarding no'
    echo 'ClientAliveInterval 60'
    echo 'ClientAliveCountMax 3'
    echo 'MaxStartups 100:10:1000'
} >> "$CONFIG_FILE"
log_message "Configurações SSH adicionais inseridas com sucesso."

# Verificar se a configuração SSH está válida antes de reiniciar
sshd -t
if [ $? -ne 0 ]; then
    log_message "Erro na configuração SSH. Restaurando backup."
    restore_backup
    exit 1
fi

# Função para verificar e instalar o bc se necessário
verificar_bc() {
    if ! command -v bc &> /dev/null; then
        apt-get update &> /dev/null
        apt-get install -y bc &> /dev/null
        if [ $? -ne 0 ]; then
            log_message "Erro ao instalar 'bc'. Verifique sua conexão com a internet ou instale manualmente."
            exit 1
        fi
        log_message "'bc' instalado com sucesso."
    fi
}

# Variáveis de cores para o terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Verificar a presença do bc
verificar_bc

# Função para executar comandos com barra de progresso
executar_comando() {
    local comando="$1"
    local mensagem="$2"
    local delay=0.1
    local percent=0
    local bar=""

    echo -e "${BLUE}${mensagem:0:50}...${NC}"
    echo -n ' '
    
    eval "$comando" & local cmd_pid=$!
    
    while kill -0 $cmd_pid 2>/dev/null; do
        percent=$((percent + 1))
        if [ $percent -ge 100 ]; then
            percent=100
        fi
        echo -ne "\r[${bar:0:$((percent / 5))}] $percent%"
        sleep $delay
        bar=$(printf "%-20s" | tr ' ' '=')
    done

    wait $cmd_pid
    if [ $? -eq 0 ]; then
        percent=100
        echo -ne "\r[${bar:0:20}] $percent%${NC}\n"
        log_message "Comando executado com sucesso: $comando"
    else
        echo -e "\r${RED}Erro ao executar o comando.${NC}"
        log_message "Erro ao executar o comando: $comando"
        restore_backup
        exit 1
    fi
    
    echo
    sleep 1
}

# Limpeza inicial
clear
echo -e "${YELLOW}======================================${NC}"
echo -e "${YELLOW}              GESTOR-SWAP${NC}"
echo -e "${YELLOW}======================================${NC}"
echo

executar_comando "apt-get clean && apt-get autoclean && apt-get autoremove -y" "Limpando cache de pacotes"
executar_comando "find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -exec rm -f {} + && find /var/log -type f -exec truncate -s 0 {} +" "Limpando logs antigos"
executar_comando "rm -rf /tmp/*" "Limpando arquivos temporários"
executar_comando "sync; echo 3 > /proc/sys/vm/drop_caches" "Limpando cache do sistema"

echo -e "${GREEN}Limpeza inicial concluída.${NC}"
echo

executar_comando "echo 1 > /proc/sys/vm/drop_caches" "Limpando a memória RAM"
echo -e "${GREEN}Memória RAM limpa.${NC}"
echo

# Desativar qualquer swap existente
executar_comando "swapoff -a && rm -f /swapfile /bin/ram.img" "Desativando qualquer swap existente"

# Calcular tamanho da swap
echo -e "${BLUE}Calculando tamanho da swap...${NC}"
disk=$(lsblk -o KNAME,TYPE | grep 'disk' | awk '{print $1}')
if [ -z "$disk" ]; then
    log_message "Não foi possível encontrar o disco principal."
    echo "Não foi possível encontrar o disco principal."
    exit 1
fi

total_size=$(lsblk -b -d -o SIZE "/dev/$disk" | tail -n1)
total_size_mb=$((total_size / (1024 * 1024)))

echo -e "${YELLOW}Escolha o tamanho da swap:${NC}"
echo -e "${YELLOW}1) 10% do tamanho total do disco (recomendado)${NC}"
echo -e "${YELLOW}2) 20% do tamanho total do disco${NC}"
echo -e "${YELLOW}3) 30% do tamanho total do disco${NC}"
echo -e "${YELLOW}4) Definir tamanho manualmente${NC}"
read -p "Selecione uma opção [1-4]: " swap_option

case "$swap_option" in
    1)
        swap_size=$(echo "$total_size_mb * 0.10 / 1" | bc)
        ;;
    2)
        swap_size=$(echo "$total_size_mb * 0.20 / 1" | bc)
        ;;
    3)
        swap_size=$(echo "$total_size_mb * 0.30 / 1" | bc)
        ;;
    4)
        read -p "Digite o tamanho da swap em MB: " swap_size
        ;;
    *)
        echo -e "${RED}Opção inválida!${NC}"
        exit 1
        ;;
esac

swap_size_rounded=$(( ((swap_size + 1023) / 1024) * 1024 ))

echo
echo -e "${YELLOW}Tamanho da swap: ${swap_size_rounded} MB (${swap_size_rounded} MB / $(echo "$swap_size_rounded / 1024" | bc) GB)${NC}"
log_message "Tamanho da swap calculado: ${swap_size_rounded} MB"
echo

# Criar e ativar swap em /swapfile
executar_comando "dd if=/dev/zero of=/swapfile bs=1M count=$swap_size_rounded && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile" "Criando e ativando swap"

# Garantir que a swap será ativada na reinicialização
executar_comando "echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab" "Configurando swap no fstab"

echo -e "${GREEN}Swap criada e ativada com sucesso.${NC}"

# Criação do serviço systemd para limpeza periódica
echo "[Unit]
Description=Limpeza de cache e swap
After=network.target

[Service]
ExecStart=/root/gestor-swap.sh
Restart=always

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/limpeza.service

executar_comando "systemctl daemon-reload && systemctl enable limpeza.service" "Configurando o serviço de limpeza no systemd"

echo -e "${GREEN}Serviço de limpeza configurado e habilitado.${NC}"
