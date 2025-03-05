#!/bin/bash
# 
#  https://github.com/lav8bit/openvpn-install
#
# BASED on fork: https://github.com/Nyr/openvpn-install
#
# Copyright (c) 2025 lav8bit. Released under the MIT License.

# Function to print usage information
print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options for non-interactive mode:"
    echo "  --auto                  Enable non-interactive mode"
    echo "  --protocol PROTO        Protocol (udp/tcp)"
    echo "  --port PORT             Port number"
    echo "  --dns DNS               DNS option (1-6)"
    echo "  --public-ip IP          Public IP address (optional)"
    echo
    echo "For existing installation:"
    echo "  --add-client NAME       Add a new client"
    echo "  --revoke-client NAME    Revoke an existing client"
    echo "  --remove                Remove OpenVPN"
    echo
    echo "Example:"
    echo "  $0 --auto --add-client myclient --protocol udp --port 1194 --dns 1"
}

# Function to check system requirements
check_system_requirements() {
    # Detect Debian users running the script with "sh" instead of bash
    if readlink /proc/$$/exe | grep -q "dash"; then
        echo 'This installer needs to be run with "bash", not "sh".'
        exit 1
    fi

    # Discard stdin. Needed when running from an one-liner which includes a newline
    read -N 999999 -t 0.001

    # Detect OS
    # $os_version variables aren't always in use, but are kept here for convenience
    if grep -qs "ubuntu" /etc/os-release; then
        os="ubuntu"
        os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
        group_name="nogroup"
    elif [[ -e /etc/debian_version ]]; then
        os="debian"
        os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
        group_name="nogroup"
    elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release ]]; then
        os="centos"
        os_version=$(grep -shoE '[0-9]+' /etc/almalinux-release /etc/rocky-release /etc/centos-release | head -1)
        group_name="nobody"
    elif [[ -e /etc/fedora-release ]]; then
        os="fedora"
        os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
        group_name="nobody"
    else
        echo "This installer seems to be running on an unsupported distribution.
Supported distros are Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS and Fedora."
        exit 1
    fi

    # OS version checks
    if [[ "$os" == "ubuntu" && "$os_version" -lt 2204 ]]; then
        echo "Ubuntu 22.04 or higher is required to use this installer.
This version of Ubuntu is too old and unsupported."
        exit 1
    fi

    if [[ "$os" == "debian" ]]; then
        if grep -q '/sid' /etc/debian_version; then
            echo "Debian Testing and Debian Unstable are unsupported by this installer."
            exit 1
        fi
        if [[ "$os_version" -lt 11 ]]; then
            echo "Debian 11 or higher is required to use this installer.
This version of Debian is too old and unsupported."
            exit 1
        fi
    fi

    if [[ "$os" == "centos" && "$os_version" -lt 9 ]]; then
        os_name=$(sed 's/ release.*//' /etc/almalinux-release /etc/rocky-release /etc/centos-release 2>/dev/null | head -1)
        echo "$os_name 9 or higher is required to use this installer.
This version of $os_name is too old and unsupported."
        exit 1
    fi

    # Detect environments where $PATH does not include the sbin directories
    if ! grep -q sbin <<< "$PATH"; then
        echo '$PATH does not include sbin. Try using "su -" instead of "su".'
        exit 1
    fi

    if [[ "$EUID" -ne 0 ]]; then
        echo "This installer needs to be run with superuser privileges."
        exit 1
    fi

    if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
        echo "The system does not have the TUN device available.
TUN needs to be enabled before running this installer."
        exit 1
    fi
}

# Function to generate a new client configuration
new_client() {
    # Generates the custom client.ovpn
    {
    cat /etc/openvpn/server/client-common.txt
    echo "<ca>"
    cat /etc/openvpn/server/easy-rsa/pki/ca.crt
    echo "</ca>"
    echo "<cert>"
    sed -ne '/BEGIN CERTIFICATE/,$ p' /etc/openvpn/server/easy-rsa/pki/issued/"$client".crt
    echo "</cert>"
    echo "<key>"
    cat /etc/openvpn/server/easy-rsa/pki/private/"$client".key
    echo "</key>"
    echo "<tls-crypt>"
    sed -ne '/BEGIN OpenVPN Static key/,$ p' /etc/openvpn/server/tc.key
    echo "</tls-crypt>"
    } > ~/"$client".ovpn
}

pre_install() {
	if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
		echo "Wget is required to use this installer."
		echo "Installing Wget automatically..."
		DEBIAN_FRONTEND=noninteractive apt-get update -qq
		DEBIAN_FRONTEND=noninteractive apt-get install -y wget > /dev/null
		echo "Wget installed successfully."
	fi
}

detect_ip() {
	# Check if IP was provided as an argument
	if [[ -n "$provided_ip" ]]; then
		ip="$provided_ip"
		echo "Using provided IP address: $ip"
	# If system has a single IPv4, it is selected automatically
	elif [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
		echo "Detected single IPv4 address: $ip"
	# If system has multiple IPv4, use the first one
	else
		number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
		echo "Multiple IPv4 addresses detected. Using the first one."
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "1p")
		echo "Selected IPv4 address: $ip"
	fi
	
	# If $ip is a private IP address, the server must be behind NAT
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo "Server is behind NAT. Attempting to detect public IP address."
		# Check if public IP was provided
		if [[ -n "$provided_public_ip" ]]; then
			public_ip="$provided_public_ip"
			echo "Using provided public IP: $public_ip"
		else
			# Get public IP and sanitize with grep
			get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
			if [[ -n "$get_public_ip" ]]; then
				public_ip="$get_public_ip"
				echo "Detected public IP: $public_ip"
			else
				echo "Warning: Could not detect public IP address. OpenVPN may not be accessible from outside."
				public_ip="$ip"
			fi
		fi
	fi
	
	# Check if IPv6 was provided as an argument
	if [[ -n "$provided_ip6" ]]; then
		ip6="$provided_ip6"
		echo "Using provided IPv6 address: $ip6"
	# If system has a single IPv6, it is selected automatically
	elif [[ $(ip -6 addr | grep -c 'inet6 [23]') -eq 1 ]]; then
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}')
		echo "Detected single IPv6 address: $ip6"
	# If system has multiple IPv6, use the first one
	elif [[ $(ip -6 addr | grep -c 'inet6 [23]') -gt 1 ]]; then
		echo "Multiple IPv6 addresses detected. Using the first one."
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | sed -n "1p")
		echo "Selected IPv6 address: $ip6"
	fi
}


interactive_install() {

	if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
		echo "Wget is required to use this installer."
		read -n1 -r -p "Press any key to install Wget and continue..."
		apt-get update
		apt-get install -y wget
	fi
	clear
	echo 'Welcome to this OpenVPN road warrior installer!'
	# If system has a single IPv4, it is selected automatically. Else, ask the user
	if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	else
		number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
		echo
		echo "Which IPv4 address should be used?"
		ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
		read -p "IPv4 address [1]: " ip_number
		until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
			echo "$ip_number: invalid selection."
			read -p "IPv4 address [1]: " ip_number
		done
		[[ -z "$ip_number" ]] && ip_number="1"
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "$ip_number"p)
	fi
	# If $ip is a private IP address, the server must be behind NAT
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		# Get public IP and sanitize with grep
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		# If the checkip service is unavailable and user didn't provide input, ask again
		until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
			echo "Invalid input."
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
	fi
	# If system has a single IPv6, it is selected automatically
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -eq 1 ]]; then
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}')
	fi
	# If system has multiple IPv6, ask the user to select one
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -gt 1 ]]; then
		number_of_ip6=$(ip -6 addr | grep -c 'inet6 [23]')
		echo
		echo "Which IPv6 address should be used?"
		ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | nl -s ') '
		read -p "IPv6 address [1]: " ip6_number
		until [[ -z "$ip6_number" || "$ip6_number" =~ ^[0-9]+$ && "$ip6_number" -le "$number_of_ip6" ]]; do
			echo "$ip6_number: invalid selection."
			read -p "IPv6 address [1]: " ip6_number
		done
		[[ -z "$ip6_number" ]] && ip6_number="1"
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | sed -n "$ip6_number"p)
	fi
	echo
	echo "Which protocol should OpenVPN use?"
	echo "   1) UDP (recommended)"
	echo "   2) TCP"
	read -p "Protocol [1]: " protocol
	until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
		echo "$protocol: invalid selection."
		read -p "Protocol [1]: " protocol
	done
	case "$protocol" in
		1|"") 
		protocol=udp
		;;
		2) 
		protocol=tcp
		;;
	esac
	echo
	echo "What port should OpenVPN listen to?"
	read -p "Port [1194]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid port."
		read -p "Port [1194]: " port
	done
	[[ -z "$port" ]] && port="1194"
	echo
	echo "Select a DNS server for the clients:"
	echo "   1) Current system resolvers"
	echo "   2) Google"
	echo "   3) 1.1.1.1"
	echo "   4) OpenDNS"
	echo "   5) Quad9"
	echo "   6) AdGuard"
	read -p "DNS server [1]: " dns
	until [[ -z "$dns" || "$dns" =~ ^[1-6]$ ]]; do
		echo "$dns: invalid selection."
		read -p "DNS server [1]: " dns
	done
	echo
	echo "Enter a name for the first client:"
	read -p "Name [client]: " unsanitized_client
	# Allow a limited set of characters to avoid conflicts
	client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
	[[ -z "$client" ]] && client="client"
	echo
	echo "OpenVPN installation is ready to begin."
	# Install a firewall if firewalld or iptables are not already available
	if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
		if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
			firewall="firewalld"
			# We don't want to silently enable firewalld, so we give a subtle warning
			# If the user continues, firewalld will be installed and enabled during setup
			echo "firewalld, which is required to manage routing tables, will also be installed."
		elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
			# iptables is way less invasive than firewalld so no warning is given
			firewall="iptables"
		fi
	fi
	read -n1 -r -p "Press any key to continue..."
	install_openvpn
}

install_openvpn() {
	# Install a firewall if firewalld or iptables are not already available
	if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
		if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
			firewall="firewalld"
			# We don't want to silently enable firewalld, so we give a subtle warning
			# If the user continues, firewalld will be installed and enabled during setup
			echo "firewalld, which is required to manage routing tables, will also be installed."
		elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
			# iptables is way less invasive than firewalld so no warning is given
			firewall="iptables"
		fi
	fi
	# If running inside a container, disable LimitNPROC to prevent conflicts
	if systemd-detect-virt -cq; then
		mkdir /etc/systemd/system/openvpn-server@server.service.d/ 2>/dev/null
		echo "[Service]
LimitNPROC=infinity" > /etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf
	fi
	if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
		DEBIAN_FRONTEND=noninteractive apt-get update
		DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openvpn openssl ca-certificates $firewall
	elif [[ "$os" = "centos" ]]; then
		dnf install -y epel-release
		dnf install -y openvpn openssl ca-certificates tar $firewall
	else
		# Else, OS must be Fedora
		dnf install -y openvpn openssl ca-certificates tar $firewall
	fi
	# If firewalld was just installed, enable it
	if [[ "$firewall" == "firewalld" ]]; then
		systemctl enable --now firewalld.service
	fi
	# Get easy-rsa
	easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.2.2/EasyRSA-3.2.2.tgz'
	mkdir -p /etc/openvpn/server/easy-rsa/
	{ wget -qO- "$easy_rsa_url" 2>/dev/null || curl -sL "$easy_rsa_url" ; } | tar xz -C /etc/openvpn/server/easy-rsa/ --strip-components 1
	chown -R root:root /etc/openvpn/server/easy-rsa/
	cd /etc/openvpn/server/easy-rsa/
	# Create the PKI, set up the CA and the server and client certificates
	./easyrsa --batch init-pki
	./easyrsa --batch build-ca nopass
	./easyrsa --batch --days=3650 build-server-full server nopass
	./easyrsa --batch --days=3650 build-client-full "$client" nopass
	./easyrsa --batch --days=3650 gen-crl
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
	# CRL is read with each client connection, while OpenVPN is dropped to nobody
	chown nobody:"$group_name" /etc/openvpn/server/crl.pem
	# Without +x in the directory, OpenVPN can't run a stat() on the CRL file
	chmod o+x /etc/openvpn/server/
	# Generate key for tls-crypt
	openvpn --genkey secret /etc/openvpn/server/tc.key
	# Create the DH parameters file using the predefined ffdhe2048 group
	echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > /etc/openvpn/server/dh.pem
	# Generate server.conf
	echo "local $ip
port $port
proto $protocol
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-crypt tc.key
topology subnet
server 10.8.0.0 255.255.255.0" > /etc/openvpn/server/server.conf
	# IPv6
	if [[ -z "$ip6" ]]; then
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	else
		echo 'server-ipv6 fddd:1194:1194:1194::/64' >> /etc/openvpn/server/server.conf
		echo 'push "redirect-gateway def1 ipv6 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	fi
	echo 'ifconfig-pool-persist ipp.txt' >> /etc/openvpn/server/server.conf
	# DNS
	case "$dns" in
		1|"")
			# Locate the proper resolv.conf
			# Needed for systems running systemd-resolved
			if grep '^nameserver' "/etc/resolv.conf" | grep -qv '127.0.0.53' ; then
				resolv_conf="/etc/resolv.conf"
			else
				resolv_conf="/run/systemd/resolve/resolv.conf"
			fi
			# Obtain the resolvers from resolv.conf and use them for OpenVPN
			grep -v '^#\|^;' "$resolv_conf" | grep '^nameserver' | grep -v '127.0.0.53' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | while read line; do
				echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server/server.conf
			done
		;;
		2)
			echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server/server.conf
		;;
		3)
			echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server/server.conf
		;;
		4)
			echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server/server.conf
		;;
		5)
			echo 'push "dhcp-option DNS 9.9.9.9"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 149.112.112.112"' >> /etc/openvpn/server/server.conf
		;;
		6)
			echo 'push "dhcp-option DNS 94.140.14.14"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 94.140.15.15"' >> /etc/openvpn/server/server.conf
		;;
	esac
	echo 'push "block-outside-dns"' >> /etc/openvpn/server/server.conf
	echo "keepalive 10 120
user nobody
group $group_name
persist-key
persist-tun
verb 3
crl-verify crl.pem" >> /etc/openvpn/server/server.conf
	if [[ "$protocol" = "udp" ]]; then
		echo "explicit-exit-notify" >> /etc/openvpn/server/server.conf
	fi
	# Enable net.ipv4.ip_forward for the system
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
	# Enable without waiting for a reboot or service restart
	echo 1 > /proc/sys/net/ipv4/ip_forward
	if [[ -n "$ip6" ]]; then
		# Enable net.ipv6.conf.all.forwarding for the system
		echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-openvpn-forward.conf
		# Enable without waiting for a reboot or service restart
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi
	if systemctl is-active --quiet firewalld.service; then
		# Using both permanent and not permanent rules to avoid a firewalld
		# reload.
		# We don't use --add-service=openvpn because that would only work with
		# the default port and protocol.
		firewall-cmd --add-port="$port"/"$protocol"
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --add-port="$port"/"$protocol"
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
		# Set NAT for the VPN subnet
		firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		if [[ -n "$ip6" ]]; then
			firewall-cmd --zone=trusted --add-source=fddd:1194:1194:1194::/64
			firewall-cmd --permanent --zone=trusted --add-source=fddd:1194:1194:1194::/64
			firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
			firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
		fi
	else
		# Create a service to set up persistent iptables rules
		iptables_path=$(command -v iptables)
		ip6tables_path=$(command -v ip6tables)
		# nf_tables is not available as standard in OVZ kernels. So use iptables-legacy
		# if we are in OVZ, with a nf_tables backend and iptables-legacy is available.
		if [[ $(systemd-detect-virt) == "openvz" ]] && readlink -f "$(command -v iptables)" | grep -q "nft" && hash iptables-legacy 2>/dev/null; then
			iptables_path=$(command -v iptables-legacy)
			ip6tables_path=$(command -v ip6tables-legacy)
		fi
		echo "[Unit]
Before=network.target
[Service]
Type=oneshot
ExecStart=$iptables_path -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ip
ExecStart=$iptables_path -I INPUT -p $protocol --dport $port -j ACCEPT
ExecStart=$iptables_path -I FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStart=$iptables_path -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$iptables_path -t nat -D POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ip
ExecStop=$iptables_path -D INPUT -p $protocol --dport $port -j ACCEPT
ExecStop=$iptables_path -D FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStop=$iptables_path -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" > /etc/systemd/system/openvpn-iptables.service
		if [[ -n "$ip6" ]]; then
			echo "ExecStart=$ip6tables_path -t nat -A POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ip6
ExecStart=$ip6tables_path -I FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
ExecStart=$ip6tables_path -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$ip6tables_path -t nat -D POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ip6
ExecStop=$ip6tables_path -D FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
ExecStop=$ip6tables_path -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
		fi
		echo "RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >> /etc/systemd/system/openvpn-iptables.service
		systemctl enable --now openvpn-iptables.service
	fi
	# If SELinux is enabled and a custom port was selected, we need this
	if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
		# Install semanage if not already present
		if ! hash semanage 2>/dev/null; then
				dnf install -y policycoreutils-python-utils
		fi
		semanage port -a -t openvpn_port_t -p "$protocol" "$port"
	fi
	# If the server is behind NAT, use the correct IP address
	[[ -n "$public_ip" ]] && ip="$public_ip"
	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
proto $protocol
remote $ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "route-ipv6"
remote-cert-tls server
auth SHA512
ignore-unknown-option block-outside-dns
verb 3" > /etc/openvpn/server/client-common.txt
	# Enable and start the OpenVPN service
	systemctl enable --now openvpn-server@server.service
	# Generates the custom client.ovpn
	new_client
}

check_client() {
	while [[ -z "$client" || -e /etc/openvpn/server/easy-rsa/pki/issued/"$client".crt ]]; do
		echo "$client: invalid name."
		read -p "Name: " unsanitized_client
		client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
	done
}			
# Function to add a new client
add_client() {
    # Check if client name is provided, if not, ask for it
    if [[ -z "$client" ]]; then
        echo "Error: Client name must be provided as an argument."
        echo "Usage: $0 --add-client client_name"
        exit 1
    fi
    
    # Allow a limited set of characters to avoid conflicts
    client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$client")
    
    # Validate input
    if [[ -z "$client" ]]; then
        echo "Error: Client name contains invalid characters."
        exit 1
    fi

    # Check if client already exists
    if [[ -e /etc/openvpn/server/easy-rsa/pki/issued/"$client".crt ]]; then
        # Check if the client has been revoked
        if grep -q "^R.*CN=$client" /etc/openvpn/server/easy-rsa/pki/index.txt; then
            echo "Client $client was revoked. Please choose a different name."
            exit 1
        else
            echo "Client $client already exists and has not been revoked."
            exit 1
        fi
    fi

    cd /etc/openvpn/server/easy-rsa/ || return
    EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full "$client" nopass
    new_client
    echo
    echo "Client $client added. Configuration available in ~/$client.ovpn"
}

# Function to revoke a client
revoke_client() {
    # Check if client name is provided, if not, ask for it
	number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep -c "^V")
	if [[ "$number_of_clients" = 0 ]]; then
		echo
		echo "There are no existing clients!"
		exit
	fi
    if [[ -z "$client" ]]; then
        
        # List existing clients
        echo "Existing clients:"
        ls -1 /etc/openvpn/server/easy-rsa/pki/issued/ | grep -v "server.crt" | sed 's/\.crt//'
        echo
        
        # Validate input

        if [[ -z "$client" || ! -f "/etc/openvpn/server/easy-rsa/pki/issued/$client.crt" ]]; then
            echo "You must specify existing client name."
        else
            echo "Client '$client' does not exist."
			exit 1
        fi
    fi

    # Confirm revocation
    cd /etc/openvpn/server/easy-rsa/ || return
    ./easyrsa --batch revoke "$client"
    EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
    rm -f /etc/openvpn/server/crl.pem
    cp /etc/openvpn/server/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
    chown nobody:"$group_name" /etc/openvpn/server/crl.pem
	chmod 644 /etc/openvpn/server/crl.pem
    rm -f ~/"$client".ovpn
}

interactive_revoke() {
	number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep -c "^V")
	if [[ "$number_of_clients" = 0 ]]; then
		echo
		echo "There are no existing clients!"
		exit
	fi
	echo
	echo "Select the client to revoke:"
	tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
	read -p "Client: " client_number
	until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
		echo "$client_number: invalid selection."
		read -p "Client: " client_number
	done
	client=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$client_number"p)
	echo
	read -p "Confirm $client revocation? [y/N]: " revoke
	until [[ "$revoke" =~ ^[yYnN]*$ ]]; do
		echo "$revoke: invalid selection."
		read -p "Confirm $client revocation? [y/N]: " revoke
	done
	if [[ "$revoke" =~ ^[yY]$ ]]; then
		cd /etc/openvpn/server/easy-rsa/
		./easyrsa --batch revoke "$client"
		./easyrsa --batch --days=3650 gen-crl
		rm -f /etc/openvpn/server/crl.pem
		cp /etc/openvpn/server/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
		# CRL is read with each client connection, when OpenVPN is dropped to nobody
		chown nobody:"$group_name" /etc/openvpn/server/crl.pem
		echo
		echo "$client revoked!"
	else
		echo
		echo "$client revocation aborted!"
	fi
	exit	
}

# Function to remove OpenVPN
remove_openvpn() {
	read -p "Confirm OpenVPN removal? [y/N]: " remove
	until [[ "$remove" =~ ^[yYnN]*$ ]]; do
		echo "$remove: invalid selection."
		read -p "Confirm OpenVPN removal? [y/N]: " remove
	done
	if [[ "$remove" =~ ^[yY]$ ]]; then
		port=$(grep '^port ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
		protocol=$(grep '^proto ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
		if systemctl is-active --quiet firewalld.service; then
			ip=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep '\-s 10.8.0.0/24 '"'"'!'"'"' -d 10.8.0.0/24' | grep -oE '[^ ]+$')
			# Using both permanent and not permanent rules to avoid a firewalld reload.
			firewall-cmd --remove-port="$port"/"$protocol"
			firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
			firewall-cmd --permanent --remove-port="$port"/"$protocol"
			firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
			firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
			firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
			if grep -qs "server-ipv6" /etc/openvpn/server/server.conf; then
				ip6=$(firewall-cmd --direct --get-rules ipv6 nat POSTROUTING | grep '\-s fddd:1194:1194:1194::/64 '"'"'!'"'"' -d fddd:1194:1194:1194::/64' | grep -oE '[^ ]+$')
				firewall-cmd --zone=trusted --remove-source=fddd:1194:1194:1194::/64
				firewall-cmd --permanent --zone=trusted --remove-source=fddd:1194:1194:1194::/64
				firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
				firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
			fi
		else
			systemctl disable --now openvpn-iptables.service
			rm -f /etc/systemd/system/openvpn-iptables.service
		fi
		if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
			semanage port -d -t openvpn_port_t -p "$protocol" "$port"
		fi
		systemctl disable --now openvpn-server@server.service
		rm -f /etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf
		rm -f /etc/sysctl.d/99-openvpn-forward.conf
		if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
			rm -rf /etc/openvpn/server
			apt-get remove --purge -y openvpn
		else
			# Else, OS must be CentOS or Fedora
			dnf remove -y openvpn
			rm -rf /etc/openvpn/server
		fi
		echo
		echo "OpenVPN removed!"
	else
		echo
		echo "OpenVPN removal aborted!"
	fi
	exit
}

# Function to handle new OpenVPN installation in auto mode
auto_install() {
    # Validate required parameters for non-interactive mode
    if [[ -z "$protocol" || -z "$port" || -z "$dns" ]]; then
        echo "Error: In non-interactive mode, --protocol, --port, and --dns are required"
        print_usage
        exit 1
    fi
    
    # Validate protocol
    if [[ "$protocol" != "udp" && "$protocol" != "tcp" ]]; then
        echo "Error: protocol must be 'udp' or 'tcp'"
        exit 1
    fi
    
    # Validate port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        echo "Error: port must be between 1 and 65535"
        exit 1
    fi
    
    # Validate DNS
    if ! [[ "$dns" =~ ^[1-6]$ ]]; then
        echo "Error: DNS must be between 1 and 6"
        exit 1
    fi
    

    
    # Install OpenVPN
	check_system_requirements
	pre_install
	detect_ip
	install_openvpn

}

# Function to display interactive menu for existing installation
show_menu() {
    clear
    echo "OpenVPN is already installed."
    echo
    echo "Select an option:"
    echo "   1) Add a new client"
    echo "   2) Revoke an existing client"
    echo "   3) Remove OpenVPN"
    echo "   4) Exit"
    read -p "Option: " option
    until [[ "$option" =~ ^[1-4]$ ]]; do
        echo "$option: invalid selection."
        read -p "Option: " option
    done
    case "$option" in
        1)
			check_client
            add_client
            ;;
        2)
            interactive_revoke
            ;;
        3)
            remove_openvpn
            ;;
        4)
            exit 0
            ;;
    esac
}


# Main function to control script flow
main() {
    # Check system requirements
    check_system_requirements
    
    # Main script logic
    if [[ ! -e /etc/openvpn/server/server.conf ]]; then
        # New installation
        if [[ "$auto_mode" = 1 ]]; then
            auto_install
        else
            interactive_install
        fi
    elif [[ -n "$mode" ]]; then
        # OpenVPN is already installed and mode is specified
	    if [[ "$auto_mode" = 1 ]]; then
			case "$mode" in
				"add-client")
					add_client
					;;
				"revoke-client")
					revoke_client
					;;
				"remove")
					remove_openvpn
					;;
			esac
        else
            show_menu
        fi	

    else
        # Interactive menu for existing installation
        show_menu
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)
                auto_mode=1
                shift
                ;;
            --protocol)
                protocol="$2"
                shift 2
                ;;
            --port)
                port="$2"
                shift 2
                ;;
            --dns)
                dns="$2"
                shift 2
                ;;
            --public-ip)
                public_ip="$2"
                shift 2
                ;;
            --add-client)
                mode="add-client"
                client="$2"
                shift 2
                ;;
            --revoke-client)
                mode="revoke-client"
                client="$2"
                shift 2
                ;;
            --remove)
                mode="remove"
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

# Initialize script
parse_args "$@"
main
