#!/bin/bash
set -e
set -u

CONFIG_FILE="/etc/ssh/sshd_config"
TEMP_FILE="/tmp/sshd"

# Função para modificar o arquivo de configuração do SSH
modify_sshd_config() {
    local search="$1"
    local replace="$2"
    if grep -q "$search" "$CONFIG_FILE"; then
        sed -i "s/$search/$replace/g" "$CONFIG_FILE"
    fi
}

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
    else
        echo -e "\r${RED}Erro ao executar o comando.${NC}"
    fi
    
    echo
    sleep 1
}

# Função para verificar e instalar o bc se necessário
verificar_bc() {
    if ! command -v bc &> /dev/null; then
        apt-get update &> /dev/null
        apt-get install -y bc &> /dev/null
        if [ $? -ne 0 ]; then
            echo "Erro ao instalar 'bc'. Verifique sua conexão com a internet ou instale manualmente."
            exit 1
        fi
    fi
}

# Função para calcular e criar swap
criar_swap() {
    local swap_size_rounded="$1"
    echo -e "${BLUE}Criando e ativando swap...${NC}"
    executar_comando "dd if=/dev/zero of=/bin/ram.img bs=1M count=$swap_size_rounded && chmod 600 /bin/ram.img && mkswap /bin/ram.img && swapon /bin/ram.img" "Criando e ativando swap"
    executar_comando "sed -i '/\/bin\/ram.img/d' /etc/fstab && echo '/bin/ram.img none swap sw 0 0' >> /etc/fstab" "Configurando swap"
    echo -e "${GREEN}Swap criada e ativada com sucesso!${NC}"
}

# Limpeza inicial
clear
echo -e "${YELLOW}======================================${NC}"
echo -e "${YELLOW}              OTMIZAÇÃO-PLUS${NC}"
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

# Escolha do tamanho da swap
echo -e "${YELLOW}Escolha o tamanho da swap:${NC}"
echo -e "${YELLOW}1) 10% do tamanho total do disco (recomendado)${NC}"
echo -e "${YELLOW}2) 20% do tamanho total do disco${NC}"
echo -e "${YELLOW}3) 30% do tamanho total do disco${NC}"
echo -e "${YELLOW}4) Definir tamanho manualmente${NC}"
read -p "Selecione uma opção [1-4]: " swap_option

case "$swap_option" in
    1) swap_percentage=0.10 ;;
    2) swap_percentage=0.20 ;;
    3) swap_percentage=0.30 ;;
    4)
        read -p "Digite o tamanho da swap em MB: " swap_size_rounded
        if ! [[ "$swap_size_rounded" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Tamanho da swap inválido. Deve ser um número inteiro.${NC}"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}Opção inválida. Saindo...${NC}"
        exit 1
        ;;
esac

if [ -z "${swap_size_rounded-}" ]; then
    echo -e "${BLUE}Calculando tamanho da swap...${NC}"
    disk=$(lsblk -o KNAME,TYPE | grep 'disk' | awk '{print $1}')
    if [ -z "$disk" ]; then
        echo "Não foi possível encontrar o disco principal."
        exit 1
    fi

    total_size=$(lsblk -b -d -o SIZE "/dev/$disk" | tail -n1)
    total_size_mb=$((total_size / (1024 * 1024)))

    swap_size=$(echo "$total_size_mb * $swap_percentage / 1" | bc)
    swap_size_rounded=$(( ((swap_size + 1023) / 1024) * 1024 ))
fi

echo
echo -e "${YELLOW}Tamanho da swap: ${swap_size_rounded} MB (${swap_size_rounded} MB / $(echo "$swap_size_rounded / 1024" | bc) GB)${NC}"
echo

criar_swap "$swap_size_rounded"

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
        if [ "$days_diff" -gt "$max_days" ]; then
            rm "$logfile"
        fi
    done
}

cleanup_old_logs

LOG_FILE="$LOG_DIR/$(date +%Y%m%d).txt"
current_time=$(date '+%d/%m/%Y %H:%M:%S')
apt-get clean &> /dev/null
apt-get autoclean &> /dev/null
apt-get autoremove -y &> /dev/null
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -exec rm -f {} + &> /dev/null && find /var/log -type f -exec truncate -s 0 {} + &> /dev/null
rm -rf /tmp/* &> /dev/null
sync; echo 3 > /proc/sys/vm/drop_caches &> /dev/null
pm2 flush &> /dev/null
echo "$current_time - Script de limpeza executado" >> "$LOG_FILE"

exit 0
EOF

chmod +x /opt/limpeza.sh

# Serviço systemd para o script de limpeza
cat << 'EOF' > /etc/systemd/system/limpeza.service
[Unit]
Description=Script de limpeza do sistema
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/limpeza.sh

[Install]
WantedBy=multi-user.target
EOF

executar_comando "systemctl daemon-reload && systemctl enable limpeza.service && systemctl start limpeza.service" "Configurando script de limpeza"

# Reiniciar o serviço SSH
/etc/init.d/ssh restart
echo -e "${GREEN}Configuração concluída.${NC}"

exit 0
