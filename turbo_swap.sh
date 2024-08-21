#!/bin/bash

CONFIG_FILE="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.bak"
LOG_FILE="/var/log/gestor_swap.log"

# Função para logar mensagens
log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
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

# Remover o script gestor_swap.sh
rm -f gestor_swap.sh
if [ $? -eq 0 ]; then
    log_message "Script gestor_swap.sh removido com sucesso."
else
    log_message "Erro ao remover o script gestor_swap.sh."
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

# Desativar qualquer swap existente
executar_comando "swapoff -a && rm -f /swapfile /bin/ram.img" "Desativando qualquer swap existente"

# Definir o tamanho total do disco em MB
total_size_mb=$(df --output=size / | tail -1)

# Calcular tamanho da swap
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
        while true; do
            read -p "Digite o tamanho da swap em MB: " swap_size
            if is_number "$swap_size" && [ "$swap_size" -ge 40 ]; then
                break
            else
                echo -e "${RED}Entrada inválida. Por favor, insira um número positivo e maior ou igual a 40.${NC}"
            fi
        done
        ;;
    *)
        echo -e "${RED}Opção inválida!${NC}"
        exit 1
        ;;
esac

# Garantir que o tamanho da swap seja pelo menos 40 MB
if [ -z "$swap_size" ] || [ "$swap_size" -lt 40 ]; then
    swap_size=40
fi

# Arredondar o tamanho para o próximo MB
swap_size_rounded=$(( ((swap_size + 1023) / 1024) * 1024 ))

echo
echo -e "${YELLOW}Tamanho da swap: ${swap_size_rounded} MB (${swap_size_rounded} MB / $(echo "$swap_size_rounded / 1024" | bc) GB)${NC}"
log_message "Tamanho da swap calculado: ${swap_size_rounded} MB"
echo

# Criar e ativar swap em /swapfile
executar_comando "dd if=/dev/zero of=/swapfile bs=1M count=$swap_size_rounded status=progress && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile" "Criando e ativando swap"
executar_comando "sed -i '/\/swapfile/d' /etc/fstab && echo '/swapfile none swap sw 0 0' >> /etc/fstab" "Configurando swap"

echo -e "${GREEN}Swap criada e ativada com sucesso!${NC}"
log_message "Swap criada e ativada com sucesso."
echo

# Script de limpeza automático
cat << 'EOF' > /opt/limpeza.sh
#!/bin/bash

LOG_DIR="/root/limpeza"
mkdir -p "$LOG_DIR"
current_date=$(date +%Y%m%d)
max_days=7

cleanup_old_logs() {
    for logfile in "$LOG_DIR"/*.txt; do
        log_date=$(basename "$logfile" .txt | cut -c1-8)
        days_diff=$(( (current_date - log_date) / 10000 ))
        if [ "$days_diff" -ge "$max_days" ]; then
            rm -f "$logfile"
        fi
    done
}

cleanup_old_logs

apt-get clean
apt-get autoclean
apt-get autoremove -y
find /var/log -type f -name "*.gz" -exec rm -f {} \;
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/log -type f -name "*.log.*" -exec rm -f {} \;
find /var/log -type f -name "*.[0-9]" -exec rm -f {} \;
find /tmp -type f -exec rm -f {} \;
find /var/tmp -type f -exec rm -f {} \;

echo "Limpeza realizada em $(date)" >> "$LOG_DIR/limpeza_$current_date.txt"
EOF

chmod +x /opt/limpeza.sh
log_message "Script de limpeza criado em /opt/limpeza.sh."

# Agendar tarefa cron para limpeza automática
(crontab -l ; echo "0 3 * * * /opt/limpeza.sh") | crontab -
log_message "Tarefa cron para limpeza automática agendada para 03:00 diariamente."

echo -e "${GREEN}Configurações e scripts de limpeza configurados com sucesso!${NC}"
