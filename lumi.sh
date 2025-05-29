#!/bin/bash

set -e

# Hàm in màu
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# ------------ HỖ TRỢ NHẬN BIẾT HỆ ĐIỀU HÀNH ------------
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    red "Không xác định được hệ điều hành."
    exit 1
  fi
}

# ------------ CÀI ĐẶT THƯ VIỆN CẦN THIẾT ------------
install_dependencies() {
  green "Cài đặt gói cần thiết..."
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt update
    apt install -y git build-essential curl net-tools openssl
  elif [[ "$OS" == "almalinux" || "$OS" == "centos" || "$OS" == "rhel" ]]; then
    dnf install -y git gcc make curl net-tools openssl
  else
    red "Hệ điều hành $OS không được hỗ trợ."
    exit 1
  fi
}

# ------------ TƯƠNG TÁC NGƯỜI DÙNG ------------
interactive_input() {
  echo "Bắt đầu cấu hình proxy IPv6 3proxy"
  read -p "Nhập số lượng proxy (ví dụ 100): " PROXY_COUNT
  PROXY_COUNT=${PROXY_COUNT:-100}

  read -p "Nhập port bắt đầu (ví dụ 30000): " PROXY_PORT_START
  PROXY_PORT_START=${PROXY_PORT_START:-30000}

  read -p "Nhập prefix IPv6 (ví dụ 2001:db8:abcd:0012): " IPV6_PREFIX
  while [[ ! $IPV6_PREFIX =~ ^([0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{0,4}$ ]]; do
    echo "Prefix IPv6 không hợp lệ. Nhập lại."
    read -p "Prefix IPv6: " IPV6_PREFIX
  done

  read -p "Nhập interface mạng (ví dụ eth0): " INTERFACE
  INTERFACE=${INTERFACE:-eth0}

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

# ------------ TẢI VÀ BUILD 3PROXY ------------
install_3proxy() {
  green "Tải mã nguồn 3proxy mới nhất..."
  rm -rf /opt/3proxy
  git clone https://github.com/3proxy/3proxy.git /opt/3proxy

  cd /opt/3proxy || exit 1

  # Kiểm tra và sử dụng đúng Makefile
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

# ------------ TẠO DANH SÁCH IPV6 ------------
generate_ipv6_list() {
  for _ in $(seq 1 $PROXY_COUNT); do
    # Tạo IPv6 random dựa trên prefix
    echo "$IPV6_PREFIX:$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2)"
  done
}

# ------------ GÁN IPv6 CHO INTERFACE ------------
assign_ipv6() {
  for ip in "${IPV6_LIST[@]}"; do
    ip -6 addr add "$ip/64" dev "$INTERFACE" || true
  done
}

# ------------ TẠO FILE CẤU HÌNH 3PROXY ------------
generate_config() {
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
  LOCAL_IP=$(curl -s ipv4.icanhazip.com)

  for ip in "${IPV6_LIST[@]}"; do
    echo "proxy -6 -n -a -p$PORT -i$LOCAL_IP -e$ip" >> /usr/local/3proxy/3proxy.cfg
    PORT=$((PORT+1))
  done
}

# ------------ KÍCH HOẠT FORWARD IPV6 ------------
enable_forwarding() {
  if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
  fi
  sysctl -p
}

# ------------ KHỞI ĐỘNG 3PROXY ------------
start_3proxy() {
  pkill 3proxy || true
  /usr/local/3proxy/bin/3proxy /usr/local/3proxy/3proxy.cfg &
}

# ------------ TẠO SYSTEMD SERVICE ------------
create_systemd_service() {
  cat <<EOF >/etc/systemd/system/3proxy.service
[Unit]
Description=3proxy IPv6 Proxy Server
After=network.target

[Service]
ExecStart=/usr/local/3proxy/bin/3proxy /usr/local/3proxy/3proxy.cfg
Restart=always
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable 3proxy
  systemctl restart 3proxy
  green "Đã tạo và khởi động systemd service 3proxy"
}

# ------------ XUẤT DANH SÁCH PROXY ------------
export_proxy_list() {
  echo "Danh sách proxy IPv6:" > proxy.txt
  PORT=$PROXY_PORT_START
  LOCAL_IP=$(curl -s ipv4.icanhazip.com)

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

# ------------ CHẠY CHƯƠNG TRÌNH ------------
main() {
  detect_os
  install_dependencies
  interactive_input
  install_3proxy
  enable_forwarding
  readarray -t IPV6_LIST < <(generate_ipv6_list)
  assign_ipv6
  generate_config
  start_3proxy
  create_systemd_service
  export_proxy_list

  green "🎉 Cài đặt và cấu hình proxy IPv6 3proxy hoàn tất!"
}

main
