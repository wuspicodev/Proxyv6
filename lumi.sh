#!/bin/bash
set -e

# Hàm in màu
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# Detect OS
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    red "Không xác định được hệ điều hành."
    exit 1
  fi
}

# Cài đặt gói cần thiết
install_dependencies() {
  green "Cài đặt gói cần thiết..."
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt update
    apt install -y git build-essential curl net-tools openssl iproute2 firewalld ufw iptables
  elif [[ "$OS" == "almalinux" || "$OS" == "centos" || "$OS" == "rhel" ]]; then
    dnf install -y git gcc make curl net-tools openssl iproute firewalld iptables
    # Không cài ufw trên AlmaLinux/CentOS/RHEL
  else
    red "Hệ điều hành $OS không được hỗ trợ."
    exit 1
  fi
}

# Lấy prefix IPv6 từ interface
get_ipv6_prefix() {
  IPV6_FULL=$(ip -6 addr show dev "$INTERFACE" scope global | grep -oP 'inet6 \K[0-9a-f:]+')
  if [[ -z "$IPV6_FULL" ]]; then
    red "Không tìm thấy địa chỉ IPv6 global trên interface $INTERFACE"
    exit 1
  fi
  IPV6_PREFIX=$(echo "$IPV6_FULL" | cut -d':' -f1-4 | tr -d '\n')
  echo "$IPV6_PREFIX"
}

# Nhập thông tin tương tác
interactive_input() {
  echo "Bắt đầu cấu hình proxy IPv6 3proxy"
  read -p "Nhập số lượng proxy (ví dụ 100): " PROXY_COUNT
  PROXY_COUNT=${PROXY_COUNT:-100}

  read -p "Nhập port bắt đầu (ví dụ 30000): " PROXY_PORT_START
  PROXY_PORT_START=${PROXY_PORT_START:-30000}

  read -p "Nhập interface mạng (ví dụ eth0): " INTERFACE
  INTERFACE=${INTERFACE:-eth0}

  green "Đang lấy prefix IPv6 trên interface $INTERFACE..."
  IPV6_PREFIX=$(get_ipv6_prefix)
  green "Đã tự động lấy prefix IPv6: $IPV6_PREFIX"

  read -p "Có yêu cầu user:pass cho proxy không? (yes/no): " ENABLE_AUTH
  while [[ ! "$ENABLE_AUTH" =~ ^(yes|no)$ ]]; do
    echo "Chỉ chấp nhận yes hoặc no."
    read -p "Có yêu cầu user:pass cho proxy không? (yes/no): " ENABLE_AUTH
  done

  if [ "$ENABLE_AUTH" == "yes" ]; then
    read -p "Nhập username proxy: " PROXY_USER
    read -p "Nhập password proxy: " PROXY_PASS
  fi
}

# Tải và build 3proxy
install_3proxy() {
  green "Tải mã nguồn 3proxy mới nhất..."
  rm -rf /opt/3proxy
  git clone https://github.com/3proxy/3proxy.git /opt/3proxy

  cd /opt/3proxy || exit 1

  if [ -f Makefile.Linux ]; then
    green "Bắt đầu build 3proxy với Makefile.Linux"
    make -f Makefile.Linux
  else
    red "Không tìm thấy Makefile.Linux. Build bằng make mặc định"
    make
  fi

  if [ ! -f bin/3proxy ]; then
    red "Build thất bại: không tìm thấy bin/3proxy"
    exit 1
  fi

  mkdir -p /usr/local/3proxy/bin
  cp bin/3proxy /usr/local/3proxy/bin/
  mkdir -p /var/log/3proxy
}

# Tạo danh sách IPv6 mới random dựa trên prefix
generate_ipv6_list() {
  IPV6_LIST=()
  for _ in $(seq 1 $PROXY_COUNT); do
    ip="$IPV6_PREFIX:$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2)"
    IPV6_LIST+=("$ip")
  done
}

# Gán các địa chỉ IPv6 cho interface (bỏ qua lỗi nếu đã tồn tại)
assign_ipv6() {
  green "Gán địa chỉ IPv6 cho interface $INTERFACE..."
  for ip in "${IPV6_LIST[@]}"; do
    ip -6 addr add "$ip/64" dev "$INTERFACE" || true
  done
}

# Tạo file config 3proxy
generate_config() {
  green "Tạo file cấu hình 3proxy..."
  cat <<EOF > /usr/local/3proxy/3proxy.cfg
daemon
maxconn 2000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy/3proxy.log D
EOF

  if [ "$ENABLE_AUTH" == "yes" ]; then
    echo "auth strong" >> /usr/local/3proxy/3proxy.cfg
    echo "users $PROXY_USER:CL:$PROXY_PASS" >> /usr/local/3proxy/3proxy.cfg
  else
    echo "auth none" >> /usr/local/3proxy/3proxy.cfg
  fi

  PORT=$PROXY_PORT_START
  LOCAL_IP=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")

  for ip in "${IPV6_LIST[@]}"; do
    echo "proxy -6 -n -a -p$PORT -i$LOCAL_IP -e$ip" >> /usr/local/3proxy/3proxy.cfg
    PORT=$((PORT+1))
  done
}

# Bật chuyển tiếp IPv6
enable_forwarding() {
  green "Bật IPv6 forwarding..."
  if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
  fi
  sysctl -p
}

# Tạo systemd service cho 3proxy
create_systemd_service() {
  green "Tạo systemd service cho 3proxy..."
  cat <<EOF >/etc/systemd/system/3proxy.service
[Unit]
Description=3proxy IPv6 Proxy Server
After=network.target

[Service]
ExecStart=/usr/local/3proxy/bin/3proxy /usr/local/3proxy/3proxy.cfg
Restart=always
User=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable 3proxy
  systemctl restart 3proxy
}

# Mở port firewall với firewalld
open_ports_firewalld() {
  if systemctl is-active --quiet firewalld; then
    green "Phát hiện firewalld đang chạy, mở các port proxy..."
    PORT=$PROXY_PORT_START
    for _ in $(seq 1 $PROXY_COUNT); do
      firewall-cmd --permanent --add-port=${PORT}/tcp
      PORT=$((PORT+1))
    done
    firewall-cmd --reload
  fi
}

# Mở port firewall với ufw
open_ports_ufw() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    green "Phát hiện ufw đang bật, mở các port proxy..."
    PORT=$PROXY_PORT_START
    for _ in $(seq 1 $PROXY_COUNT); do
      ufw allow ${PORT}/tcp
      PORT=$((PORT+1))
    done
  fi
}

# Mở port firewall với iptables
open_ports_iptables() {
  if command -v iptables >/dev/null 2>&1; then
    green "Dùng iptables để mở các port proxy..."
    PORT=$PROXY_PORT_START
    for _ in $(seq 1 $PROXY_COUNT); do
      iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
      PORT=$((PORT+1))
    done
  fi
}

open_ports() {
  open_ports_firewalld
  open_ports_ufw
  open_ports_iptables
}

# Khởi động 3proxy ngay
start_3proxy() {
  pkill 3proxy || true
  /usr/local/3proxy/bin/3proxy /usr/local/3proxy/3proxy.cfg &
}

# Xuất danh sách proxy ra file
export_proxy_list() {
  echo "Xuất danh sách proxy ra proxy.txt..."
  PORT=$PROXY_PORT_START
  LOCAL_IP=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")

  echo "Danh sách proxy IPv6:" > proxy.txt
  for ip in "${IPV6_LIST[@]}"; do
    if [ "$ENABLE_AUTH" == "yes" ]; then
      echo "$LOCAL_IP:$PORT:$PROXY_USER:$PROXY_PASS" >> proxy.txt
    else
      echo "$LOCAL_IP:$PORT" >> proxy.txt
    fi
    PORT=$((PORT+1))
  done
  green "Danh sách proxy đã lưu vào proxy.txt"
}

# Main
main() {
  detect_os
  install_dependencies
  interactive_input
  install_3proxy
  enable_forwarding
  generate_ipv6_list
  assign_ipv6
  open_ports          # <=== Mở port firewall ở đây
  generate_config
  start_3proxy
  create_systemd_service
  export_proxy_list
  green "🎉 Cài đặt và cấu hình proxy IPv6 3proxy hoàn tất!"
}

main
