#!/bin/bash

# ----------- CẤU HÌNH -------------
PROXY_COUNT=100                        # Số lượng proxy
PROXY_PORT_START=30000                 # Port bắt đầu
IPV6_PREFIX="2001:db8:abcd:0012"       # Prefix IPv6
INTERFACE="eth0"                       # Interface mạng (eth0, ens18...)

ENABLE_AUTH="yes"                      # "yes" để dùng user:pass, "no" thì proxy mở
PROXY_USER="proxyuser"                 # Dùng nếu ENABLE_AUTH="yes"
PROXY_PASS="proxypass"
# -----------------------------------

PROXY_DIR="/usr/local/3proxy"
CONFIG_FILE="$PROXY_DIR/3proxy.cfg"
BIN="$PROXY_DIR/bin/3proxy"

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo "❌ Không xác định được hệ điều hành."
        exit 1
    fi
}

install_dependencies() {
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt update && apt install -y git build-essential curl net-tools
    elif [[ "$OS" == "almalinux" || "$OS" == "centos" || "$OS" == "rhel" ]]; then
        dnf install -y git gcc make curl net-tools
    else
        echo "❌ Hệ điều hành không được hỗ trợ: $OS"
        exit 1
    fi
}

install_3proxy() {
    rm -rf /opt/3proxy
    git clone https://github.com/z3APA3A/3proxy.git /opt/3proxy
    cd /opt/3proxy || exit 1
    make

    if [ ! -f bin/3proxy ]; then
        echo "❌ Build thất bại: không tìm thấy bin/3proxy"
        exit 1
    fi

    mkdir -p $PROXY_DIR/bin
    cp bin/3proxy $BIN
    mkdir -p /var/log/3proxy
}

generate_ipv6_list() {
    for i in $(seq 1 $PROXY_COUNT); do
        echo "$IPV6_PREFIX:$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2)"
    done
}

assign_ipv6() {
    for ip in "${IPV6_LIST[@]}"; do
        ip -6 addr add "$ip/64" dev "$INTERFACE" || true
    done
}

generate_config() {
    cat <<EOF > $CONFIG_FILE
daemon
maxconn 2000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy/3proxy.log D
EOF

    if [[ "$ENABLE_AUTH" == "yes" ]]; then
        echo "auth strong" >> $CONFIG_FILE
        echo "users $PROXY_USER:CL:$PROXY_PASS" >> $CONFIG_FILE
    else
        echo "auth none" >> $CONFIG_FILE
    fi

    port=$PROXY_PORT_START
    for ip in "${IPV6_LIST[@]}"; do
        echo "proxy -6 -n -a -p$port -i$(curl -s ipv4.icanhazip.com) -e$ip" >> $CONFIG_FILE
        ((port++))
    done
}

start_3proxy() {
    pkill 3proxy &>/dev/null || true
    $BIN $CONFIG_FILE
}

create_systemd_service() {
    cat <<EOF > /etc/systemd/system/3proxy.service
[Unit]
Description=3proxy IPv6 Proxy Server
After=network.target

[Service]
ExecStart=$BIN $CONFIG_FILE
Restart=always
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable 3proxy
    systemctl restart 3proxy

    echo "✅ Đã tạo và khởi động systemd service: 3proxy"
}

export_proxy_list() {
    echo "Danh sách proxy IPv6:" > proxy.txt
    port=$PROXY_PORT_START
    for ip in "${IPV6_LIST[@]}"; do
        if [[ "$ENABLE_AUTH" == "yes" ]]; then
            echo "$(curl -s ipv4.icanhazip.com):$port:$PROXY_USER:$PROXY_PASS" >> proxy.txt
        else
            echo "$(curl -s ipv4.icanhazip.com):$port" >> proxy.txt
        fi
        ((port++))
    done
    echo "✅ Danh sách proxy đã lưu tại: proxy.txt"
}

enable_forwarding() {
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    sysctl -p
}

# ------------ THỰC THI ------------
detect_os
install_dependencies
install_3proxy
enable_forwarding
readarray -t IPV6_LIST < <(generate_ipv6_list)
assign_ipv6
generate_config
start_3proxy
create_systemd_service
export_proxy_list

echo "🎉 Proxy IPv6 đã cấu hình hoàn chỉnh và chạy như systemd service!"
echo "📂 File danh sách proxy: proxy.txt"
echo "Script Remake By Lumi - Vui Lòng Không Chỉnh Sửa Tác Giả"
