#!/bin/bash
# XMRig Universal Installer - MoneroOcean Optimized
# Ubuntu Server 24.04.4 LTS
# Version: 3.2 - Conservative CPU / production-safe systemd
# Based on the user's original v3.1 project.
#
# Principais alterações:
# - Não usa FIFO/priority 99
# - Não grava MSR arbitrariamente
# - Usa max-threads-hint conservador (padrão 65%)
# - Huge Pages dimensionadas de forma moderada
# - Valida CPU/RAM e ambiente antes de configurar
# - Mantém MoneroOcean + fallback SupportXMR
# - Mantém worker identificado pelo hostname
# - Serviço systemd com Nice + CPUWeight para não disputar CPU agressivamente

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

WALLET="8784JLgEGHGFsPTwPebxkC99Z9xb2n6KEbjssyAdwnMKQYT6tueXD7bKmB5WVTd579WvK7rjnQV62B4a7wrA8KUeKaijbve"
POOL_PRIMARY="gulf.moneroocean.stream:10128"
POOL_BACKUP="pool.supportxmr.com:3333"
MINER_USER="xmrig"
INSTALL_DIR="/opt/xmrig"

# Percentual inicial da CPU destinado ao XMRig.
# Ajuste depois de medir o hashrate/impacto.
THREAD_HINT=65

echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     XMRig Universal Installer - MoneroOcean Optimized             ║"
echo "║          Ubuntu Server 24.04.4 - Production Safe                 ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Execute este instalador como root.${NC}"
    echo "Exemplo: sudo bash $0"
    exit 1
fi

# ============================================
# IDENTIFICAÇÃO DA MÁQUINA
# ============================================

MACHINE_NAME="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown-miner")"
MACHINE_NAME="$(echo "$MACHINE_NAME" | sed 's/[^a-zA-Z0-9_-]//g' | cut -c1-32)"

if [[ -z "$MACHINE_NAME" || ${#MACHINE_NAME} -lt 2 ]]; then
    MACHINE_NAME="miner-$(cat /proc/sys/kernel/random/uuid | cut -c1-8)"
fi

echo -e "${CYAN}Identificação da Máquina: ${MACHINE_NAME}${NC}"
echo ""

# ============================================
# DETECÇÃO DE AMBIENTE
# ============================================

echo -e "${BLUE}[1/15] Detectando ambiente de execução...${NC}"

IS_VM=false
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"

if echo "$VIRT_TYPE" | grep -qiE "vmware|kvm|virtualbox|xen|qemu|microsoft|oracle"; then
    IS_VM=true
    echo -e "${YELLOW}  ⚠ Ambiente virtualizado detectado: ${VIRT_TYPE}${NC}"
    echo -e "${YELLOW}  → MSR não será alterado${NC}"
else
    echo -e "${GREEN}  ✅ Ambiente físico ou virtualização não identificada${NC}"
fi

CPU_THREADS="$(nproc)"
CPU_VENDOR="$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2; exit}' 2>/dev/null || echo "Unknown")"
CPU_MODEL="$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' 2>/dev/null || echo "Unknown")"
TOTAL_RAM_GB="$(free -g | awk '/^Mem:/{print $2}')"

[[ -z "$CPU_THREADS" ]] && CPU_THREADS=1
[[ -z "$TOTAL_RAM_GB" ]] && TOTAL_RAM_GB=1

# Limite mínimo de threads para não deixar o minerador sem CPU.
if (( CPU_THREADS <= 2 )); then
    THREAD_HINT=50
elif (( CPU_THREADS <= 4 )); then
    THREAD_HINT=60
fi

echo "  CPU Model: $CPU_MODEL"
echo "  CPU Threads: $CPU_THREADS"
echo "  CPU Vendor: $CPU_VENDOR"
echo "  CPU Hint XMRig: ${THREAD_HINT}%"
echo "  RAM Total: ${TOTAL_RAM_GB} GB"
echo ""

# ============================================
# HUGE PAGES
# ============================================

# Configuração moderada para RandomX.
# 1280 páginas x 2 MiB ~= 2,5 GiB de memória reservada.
if (( TOTAL_RAM_GB >= 16 )); then
    HUGE_PAGES=1280
elif (( TOTAL_RAM_GB >= 8 )); then
    HUGE_PAGES=768
else
    HUGE_PAGES=384
fi

echo -e "${BLUE}  Huge Pages: ${HUGE_PAGES} páginas (~$((HUGE_PAGES * 2)) MiB)${NC}"
echo ""

# ============================================
# ATUALIZAÇÃO E DEPENDÊNCIAS
# ============================================

echo -e "${GREEN}[2/15] Atualizando sistema...${NC}"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo -e "${GREEN}[3/15] Instalando dependências...${NC}"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    cmake \
    automake \
    libtool \
    git \
    libhwloc-dev \
    libssl-dev \
    libuv1-dev \
    msr-tools \
    lm-sensors \
    htop \
    curl \
    wget \
    numactl \
    ca-certificates

# ============================================
# USUÁRIO DEDICADO
# ============================================

echo -e "${GREEN}[4/15] Criando usuário dedicado...${NC}"

if id "$MINER_USER" &>/dev/null; then
    echo -e "${YELLOW}  Usuário $MINER_USER já existe${NC}"
else
    useradd -r -s /usr/sbin/nologin -m -d "$INSTALL_DIR" "$MINER_USER"
    echo -e "${GREEN}  Usuário $MINER_USER criado${NC}"
fi

# ============================================
# MSR
# ============================================

echo -e "${GREEN}[5/15] Preparando suporte MSR sem alterar registradores...${NC}"

# Apenas carrega o módulo quando possível.
# Não executamos wrmsr automaticamente: isso evita alterar MSRs
# específicos de CPUs sem validar o modelo.
modprobe msr 2>/dev/null || true

if ! grep -qxF "msr" /etc/modules 2>/dev/null; then
    echo "msr" >> /etc/modules
fi

echo -e "${YELLOW}  MSR carregado quando disponível; nenhuma gravação arbitrária foi feita.${NC}"

# ============================================
# HUGE PAGES
# ============================================

echo -e "${GREEN}[6/15] Configurando Huge Pages...${NC}"

sysctl -w "vm.nr_hugepages=${HUGE_PAGES}" >/dev/null 2>&1 || true

# Remove uma configuração anterior do mesmo parâmetro para evitar duplicação.
if [[ -f /etc/sysctl.conf ]]; then
    sed -i '/^[[:space:]]*vm\.nr_hugepages[[:space:]]*=/d' /etc/sysctl.conf
fi
echo "vm.nr_hugepages=${HUGE_PAGES}" >> /etc/sysctl.conf

# Mantém THP em madvise: reduz impacto no restante do sistema e permite
# que aplicações solicitem THP quando apropriado.
if [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo madvise > /sys/kernel/mm/transparent_hugepage/enabled || true
fi

# Limites necessários ao serviço.
cat > /etc/security/limits.d/xmrig.conf <<EOF
# XMRig memory limits
${MINER_USER} soft memlock unlimited
${MINER_USER} hard memlock unlimited
${MINER_USER} soft stack unlimited
${MINER_USER} hard stack unlimited
${MINER_USER} soft nproc 1000000
${MINER_USER} hard nproc 1000000
EOF

# ============================================
# COMPILAÇÃO XMRig
# ============================================

echo -e "${GREEN}[7/15] Baixando código fonte do XMRig...${NC}"

mkdir -p /opt
cd /opt

if [[ -d "xmrig" ]]; then
    echo -e "${YELLOW}  Removendo instalação anterior em /opt/xmrig${NC}"
    rm -rf /opt/xmrig
fi

git clone --depth 1 https://github.com/xmrig/xmrig.git /opt/xmrig-src
cd /opt/xmrig-src

echo -e "${GREEN}[8/15] Compilando XMRig...${NC}"

rm -rf build
mkdir -p build
cd build

if [[ "$IS_VM" == false ]]; then
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_MSR=ON \
        -DWITH_HWLOC=ON
else
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_HWLOC=ON
fi

make -j"$CPU_THREADS"

if [[ ! -x "/opt/xmrig-src/build/xmrig" ]]; then
    echo -e "${RED}❌ Falha na compilação do XMRig.${NC}"
    exit 1
fi

echo -e "${GREEN}  ✅ Compilação concluída${NC}"

# ============================================
# ESTRUTURA DE INSTALAÇÃO
# ============================================

echo -e "${GREEN}[9/15] Instalando XMRig em ${INSTALL_DIR}...${NC}"

mkdir -p "$INSTALL_DIR/build"
cp /opt/xmrig-src/build/xmrig "$INSTALL_DIR/build/xmrig"
chmod 0755 "$INSTALL_DIR/build/xmrig"

# Mantém a fonte separada para facilitar manutenção.
ln -sfn /opt/xmrig-src "$INSTALL_DIR/source"

# ============================================
# CONFIGURAÇÃO XMRIG
# ============================================

echo -e "${GREEN}[10/15] Criando configuração MoneroOcean...${NC}"

cat > "$INSTALL_DIR/build/config.json" <<EOF
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "hw-aes": true,
        "priority": 0,
        "max-threads-hint": ${THREAD_HINT},
        "asm": true,
        "numa": true
    },
    "opencl": false,
    "cuda": false,
    "donate-level": 1,
    "pools": [
        {
            "url": "${POOL_PRIMARY}",
            "user": "${WALLET}",
            "pass": "${MACHINE_NAME}",
            "rig-id": "${MACHINE_NAME}",
            "keepalive": true,
            "tls": false,
            "nicehash": false
        },
        {
            "url": "${POOL_BACKUP}",
            "user": "${WALLET}",
            "pass": "${MACHINE_NAME}",
            "rig-id": "${MACHINE_NAME}",
            "keepalive": true,
            "tls": false,
            "nicehash": false
        }
    ],
    "print-time": 30,
    "retries": 10,
    "retry-pause": 5,
    "watch": true
}
EOF

# ============================================
# PERMISSÕES
# ============================================

echo -e "${GREEN}[11/15] Configurando permissões...${NC}"

chown -R "$MINER_USER:$MINER_USER" "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR/build/xmrig"
chmod 0644 "$INSTALL_DIR/build/config.json"

# ============================================
# SYSTEMD
# ============================================

echo -e "${GREEN}[12/15] Criando serviço systemd otimizado...${NC}"

cat > /etc/systemd/system/xmrig.service <<EOF
[Unit]
Description=XMRig MoneroOcean Miner - ${MACHINE_NAME}
Documentation=https://github.com/xmrig/xmrig
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${MINER_USER}
Group=${MINER_USER}

ExecStart=${INSTALL_DIR}/build/xmrig -c ${INSTALL_DIR}/build/config.json
WorkingDirectory=${INSTALL_DIR}/build

Restart=always
RestartSec=30

StandardOutput=journal
StandardError=journal

LimitMEMLOCK=infinity
LimitNOFILE=1000000

# Baixa prioridade para preservar serviços do servidor.
Nice=10

# Permite ao minerador usar CPU, mas com menor peso relativo.
CPUWeight=50
IOWeight=50

# Evita o FIFO/priority 99 do projeto original.
CPUSchedulingPolicy=other

# Ajuda a impedir que um processo em loop consuma memória
# de forma descontrolada em caso de falha.
OOMScoreAdjust=100

[Install]
WantedBy=multi-user.target
EOF

# ============================================
# SCRIPTS DE MONITORAMENTO
# ============================================

echo -e "${GREEN}[13/15] Criando scripts de monitoramento...${NC}"

cat > /usr/local/bin/xmrig-monitor <<'EOF'
#!/bin/bash
while true; do
    clear
    echo "=== XMRig Monitor ==="
    echo "Time: $(date)"
    echo
    echo "Service: $(systemctl is-active xmrig)"
    echo
    echo "Last accepted shares:"
    journalctl -u xmrig.service --since "15 minutes ago" --no-pager 2>/dev/null \
        | grep -i "accepted" | tail -15 || true
    echo
    echo "Latest speed:"
    journalctl -u xmrig.service --since "2 minutes ago" --no-pager 2>/dev/null \
        | grep -i "speed" | tail -1 || true
    echo
    echo "CPU:"
    top -bn1 | grep "Cpu(s)" | head -1 || true
    echo
    echo "Memory:"
    free -h | grep "^Mem:" || true
    echo
    echo "Huge Pages:"
    grep -i "Huge" /proc/meminfo
    echo
    echo "Press Ctrl+C to exit"
    sleep 10
done
EOF

cat > /usr/local/bin/xmrig-logs <<'EOF'
#!/bin/bash
journalctl -u xmrig.service -f -n 50
EOF

cat > /usr/local/bin/xmrig-restart <<'EOF'
#!/bin/bash
systemctl restart xmrig
sleep 3
systemctl status xmrig --no-pager -l
EOF

cat > /usr/local/bin/xmrig-status <<'EOF'
#!/bin/bash
echo "=== XMRig Status ==="
echo
echo "Service:"
systemctl status xmrig --no-pager -l || true
echo
echo "Last accepted shares:"
journalctl -u xmrig.service --since "30 minutes ago" --no-pager 2>/dev/null \
    | grep -i accepted | tail -10 || true
echo
echo "Last hashrates:"
journalctl -u xmrig.service --since "30 minutes ago" --no-pager 2>/dev/null \
    | grep -i speed | tail -3 || true
echo
echo "Huge Pages:"
grep -i "Huge" /proc/meminfo
echo
echo "CPU:"
nproc
lscpu | grep -E "Model name|CPU\(s\)|Thread|Core|Socket|NUMA" || true
echo
echo "Memory:"
free -h
EOF

chmod +x \
    /usr/local/bin/xmrig-monitor \
    /usr/local/bin/xmrig-logs \
    /usr/local/bin/xmrig-restart \
    /usr/local/bin/xmrig-status

# ============================================
# VALIDAÇÃO DA CONFIGURAÇÃO
# ============================================

echo -e "${GREEN}[14/15] Validando configuração...${NC}"

"$INSTALL_DIR/build/xmrig" --help >/dev/null 2>&1 || {
    echo -e "${RED}❌ O binário XMRig não executou corretamente.${NC}"
    exit 1
}

# ============================================
# INICIALIZAÇÃO
# ============================================

echo -e "${GREEN}[15/15] Habilitando e iniciando serviço...${NC}"

systemctl daemon-reload
systemctl enable xmrig.service
systemctl restart xmrig.service

sleep 5

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                 INSTALAÇÃO CONCLUÍDA                              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}Configuração:${NC}"
echo "  Worker:             ${MACHINE_NAME}"
echo "  Pool principal:     ${POOL_PRIMARY}"
echo "  Pool fallback:      ${POOL_BACKUP}"
echo "  CPU threads:        ${CPU_THREADS}"
echo "  CPU hint:           ${THREAD_HINT}%"
echo "  Huge Pages:         ${HUGE_PAGES}"
echo "  Ambiente:           $( [[ "$IS_VM" == true ]] && echo "Virtualizado" || echo "Físico/Não identificado" )"
echo ""

echo -e "${YELLOW}Status:${NC}"
systemctl --no-pager --full status xmrig || true

echo ""
echo -e "${YELLOW}Huge Pages:${NC}"
grep -i "Huge" /proc/meminfo || true

echo ""
echo -e "${YELLOW}Comandos úteis:${NC}"
echo "  xmrig-status     -> status completo"
echo "  xmrig-monitor    -> monitor em tempo real"
echo "  xmrig-logs       -> logs em tempo real"
echo "  xmrig-restart    -> reiniciar minerador"
echo "  systemctl stop xmrig"
echo "  systemctl start xmrig"
echo ""

echo -e "${GREEN}Worker MoneroOcean: ${MACHINE_NAME}${NC}"
echo -e "${GREEN}Instalação finalizada.${NC}"
