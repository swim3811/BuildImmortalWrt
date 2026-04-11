#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

# 1. 先获取所有物理接口列表
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
echo "Detected physical interfaces: $ifnames" >>$LOGFILE
echo "Interface count: $count" >>$LOGFILE

# 2. 根据板子型号映射WAN和LAN接口
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Board detected: $board_name" >>$LOGFILE

wan_ifname=""
lan_ifnames=""
# 此处特殊处理个别开发板网口顺序问题
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        echo "Using $board_name mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
    *)
        # 默认第一个接口为WAN，其余为LAN
        wan_ifname=$(echo "$ifnames" | awk '{print $1}')
        lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
        echo "Using default mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
esac

# 3. 配置网络
if [ "$count" -eq 1 ]; then
    # 单网口设备，DHCP模式
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr
    uci delete network.lan.netmask
    uci delete network.lan.gateway
    uci delete network.lan.dns
    uci commit network
elif [ "$count" -gt 1 ]; then
    # 多网口设备配置
    # 配置WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'

    # 配置WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # 查找 br-lan 设备 section
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "error：cannot find device 'br-lan'." >>$LOGFILE
    else
        # 删除原有ports
        uci -q delete "network.$section.ports"
        # 添加LAN接口端口
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "Updated br-lan ports: $lan_ifnames" >>$LOGFILE
    fi

    # LAN口设置静态IP
    uci set network.lan.proto='static'
    # 多网口设备 支持修改为别的管理后台地址 在Github Action 的UI上自行输入即可 
    uci set network.lan.netmask='255.255.255.0'
    # 设置路由器管理后台地址
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        # 用户在UI上设置的路由器后台管理地址
        uci set network.lan.ipaddr=$CUSTOM_IP
        echo "custom router ip is $CUSTOM_IP" >> $LOGFILE
    else
        uci set network.lan.ipaddr='192.168.100.1'
        echo "default router ip is 192.168.100.1" >> $LOGFILE
    fi

    # PPPoE设置
    echo "enable_pppoe value: $enable_pppoe" >>$LOGFILE
    if [ "$enable_pppoe" = "yes" ]; then
        echo "PPPoE enabled, configuring..." >>$LOGFILE
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        echo "PPPoE config done." >>$LOGFILE
    else
        echo "PPPoE not enabled." >>$LOGFILE
    fi

    uci commit network
fi

# 若安装了dockerd 则设置docker的防火墙规则
# 扩大docker涵盖的子网范围 '172.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # 提交删除
    uci commit firewall
    # 追加新的 zone + forwarding 配置
    cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    echo "未检测到 Docker，跳过防火墙配置。"
fi

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by Hank"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if opkg list-installed | grep -q '^luci-app-advancedplus '; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
fi

# ==========================================
# 1. 基礎服務設定 (KMS & Lucky)
# ==========================================

# VLMCSD (KMS 激活服務)
uci set vlmcsd.config.enabled='1'
uci set vlmcsd.config.auto_activate='1'
uci del vlmcsd.config.internet_access

# Lucky (網盤服務)
uci del openlist.config.site_tls_insecure
uci del openlist.config.log_enable
uci set openlist.config.enabled='1'

# ==========================================
# 2. 基礎網路與 DNS 設定 (包含 IPv6 清理)
# ==========================================

# 清理舊有的 DNS 與 RA 宣告設定
uci del dhcp.lan.ra_slaac
uci del dhcp.lan.dhcpv6
uci set dhcp.lan.ra_preference='medium'
uci del dhcp.odhcpd.maindhcp
uci del dhcp.cfg01411c.nonwildcard
uci del dhcp.cfg01411c.boguspriv
uci del dhcp.cfg01411c.filterwin2k
uci del dhcp.cfg01411c.filter_aaaa
uci del dhcp.cfg01411c.filter_a
uci del dhcp.cfg01411c.rebind_localhost
uci add_list dhcp.lan.ra_flags='none'
uci set dhcp.cfg01411c.rebind_protection='0'
uci set dhcp.cfg01411c.localservice='0'
uci set dhcp.lan.dns_service='0'

# 防火牆基礎清理與 FullCone 設定
uci del firewall.cfg01e63d.syn_flood
uci del firewall.cfg02dc81.network
uci del firewall.cfg03dc81.network
uci set firewall.cfg01e63d.synflood_protect='1'
uci set firewall.cfg01e63d.fullcone6='1'
uci add_list firewall.cfg02dc81.network='lan'
uci add_list firewall.cfg03dc81.network='wan'
uci add_list firewall.cfg03dc81.network='wan6'

# 網路介面優化 (WAN/LAN)
uci del network.wan6
uci del network.wan.auto
uci set network.globals.packet_steering='1'
uci set network.lan.multipath='off'
uci set network.wan.ipv6='0'
uci set network.wan.sourcefilter='0'
uci set network.wan.delegate='0'
# uci set network.wan.mtu='1452'
uci set network.wan.multipath='off'

# 設定 WAN6 (IPv6)
uci set network.wan6=interface
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.device='@wan'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
uci set network.wan6.norelease='1'
uci set network.wan6.multipath='off'

# 設定 LAN IPv6 分配
uci set network.lan.delegate='0'
uci set network.lan.ip6assign='64'
uci set network.lan.ip6ifaceid='eui64'

# 手動指定 DNS (Cloudflare)
uci del network.wan.dns
uci set network.wan.peerdns='0'
uci add_list network.wan.dns='1.1.1.1'
uci add_list network.wan.dns='1.0.0.1'

uci del network.wan6.dns
uci set network.wan6.peerdns='0'
uci add_list network.wan6.dns='2606:4700:4700::1111'
uci add_list network.wan6.dns='2606:4700:4700::1001'

# 設定無線網路
# uci set wireless.radio0.htmode='HE80'
# uci set wireless.radio0.channel='157'
# uci set wireless.radio0.country='TW'
# uci set wireless.radio0.cell_density='0'
# uci set wireless.default_radio0.ssid="$wlan_name"
# uci set wireless.default_radio0.encryption='sae'
# uci set wireless.default_radio0.key="$wlan_password"
# uci set wireless.default_radio0.ocv='0'

# uci set wireless.radio1.htmode='HE40'
# uci set wireless.radio1.channel='11'
# uci set wireless.radio1.country='TW'
# uci set wireless.radio1.cell_density='0'
# uci set wireless.default_radio1.ssid="$wlan_name"
# uci set wireless.default_radio1.encryption='sae'
# uci set wireless.default_radio1.key="$wlan_password"
# uci set wireless.default_radio1.ocv='0'
# uci commit wireless

# ==========================================
# 3. WireGuard VPN 配置
# ==========================================

# 建立 wg0 介面
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key='uFaJylwL7gJ34K1QaUMDhQmXBDBnk7mSinxSLdWUTGg='
uci set network.wg0.listen_port='51820'
uci set network.wg0.mtu='1412'
uci set network.wg0.multipath='off'
uci del network.wg0.addresses
uci add_list network.wg0.addresses='10.8.0.1/24'

# 建立 Peer (Yi-Home)
uci -q delete network.wireguard_wg0
uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].description='Yi-Home'
uci set network.@wireguard_wg0[-1].public_key='+s/Dm1ZgEYBg54wMijVlj01sPGAXNqEoRyAFFDreons='
uci set network.@wireguard_wg0[-1].private_key='qNQwcM0U4jl+fj9JmknaSlCx+YheczkBxx2id9TFE18='
uci set network.@wireguard_wg0[-1].preshared_key='6EYeH3DwN5ucrg9jeXz1LyWdLrB8UWU+XT6c9mwYwvE='
uci add_list network.@wireguard_wg0[-1].allowed_ips='10.8.0.2/24'
uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'

# 防火牆：將 wg0 加入 LAN 區域並開啟 51820 埠位
uci del firewall.cfg02dc81.network
uci add_list firewall.cfg02dc81.network='lan'
uci add_list firewall.cfg02dc81.network='wg0'

# 防火牆：開啟 51820 埠位 (Wan 存取)
uci -q delete firewall.WireGuard
uci set firewall.WireGuard="rule"
uci set firewall.WireGuard.name='Allow-WireGuard'
uci set firewall.WireGuard.proto='udp'
uci set firewall.WireGuard.src='wan'
uci set firewall.WireGuard.dest_port='51820'
uci set firewall.WireGuard.target='ACCEPT'

# 防火牆：開啟 5244 埠位 (Wan 存取)
uci -q delete firewall.OpenList
uci set firewall.OpenList="rule"
uci set firewall.OpenList.name='Allow-OpenList'
uci set firewall.OpenList.src='wan'
uci set firewall.OpenList.dest_port='5244'
uci set firewall.OpenList.target='ACCEPT'

# ==========================================
# 4. 遠端管理設定 (安全性強化：僅限 wg0 存取)
# ==========================================

# 限制主 Dropbear (SSH)
uci del dropbear.main.enable
uci del dropbear.main.RootPasswordAuth

# 新增 VPN 專用 SSH
uci add dropbear dropbear
uci set dropbear.@dropbear[-1].PasswordAuth='on'
uci set dropbear.@dropbear[-1].Port='22'
uci set dropbear.@dropbear[-1].Interface='wg0'

# 新增 ttyd 終端機綁定 wg0
uci add ttyd ttyd
uci set ttyd.@ttyd[-1].interface='@wg0'
uci set ttyd.@ttyd[-1].command='/bin/login'
uci set ttyd.cfg01a8ea.debug='7'
uci set ttyd.cfg02a8ea.debug='7'

# ==========================================
# 5. DDNS 設定 (Cloudflare)
# ==========================================

# 刪除舊設定
uci del ddns.myddns_ipv4
uci del ddns.myddns_ipv6

# 全域設定
uci set ddns.global=ddns
uci set ddns.global.ddns_rundir='/var/run/ddns'
uci set ddns.global.ddns_logdir='/var/log/ddns'

# Cloudflare IPv4 設定
uci set ddns.Cloudflare_IPv4='service'
uci set ddns.Cloudflare_IPv4.enabled='1'
uci set ddns.Cloudflare_IPv4.service_name='cloudflare.com-v4'
uci set ddns.Cloudflare_IPv4.use_ipv6='0'
uci set ddns.Cloudflare_IPv4.username='swim3811@gmail.com'
uci set ddns.Cloudflare_IPv4.password='84ec25ca271a1cbc4044ebdfd1a8106e81b71'
uci set ddns.Cloudflare_IPv4.domain='h@yiqq.eu.org'
uci set ddns.Cloudflare_IPv4.lookup_host='h.yiqq.eu.org'
uci set ddns.Cloudflare_IPv4.ip_source='network'
uci set ddns.Cloudflare_IPv4.ip_network='wan'
uci set ddns.Cloudflare_IPv4.interface='wan'
uci set ddns.Cloudflare_IPv4.use_syslog='2'
uci set ddns.Cloudflare_IPv4.check_unit='minutes'
uci set ddns.Cloudflare_IPv4.force_unit='minutes'
uci set ddns.Cloudflare_IPv4.retry_unit='seconds'

# Cloudflare IPv6 設定
uci set ddns.Cloudflare_IPv6='service'
uci set ddns.Cloudflare_IPv6.enabled='1'
uci set ddns.Cloudflare_IPv6.service_name='cloudflare.com-v4'
uci set ddns.Cloudflare_IPv6.use_ipv6='1'
uci set ddns.Cloudflare_IPv6.username='swim3811@gmail.com'
uci set ddns.Cloudflare_IPv6.password='84ec25ca271a1cbc4044ebdfd1a8106e81b71'
uci set ddns.Cloudflare_IPv6.domain='h@yiqq.eu.org'
uci set ddns.Cloudflare_IPv6.lookup_host='h.yiqq.eu.org'
uci set ddns.Cloudflare_IPv6.ip_source='network'
uci set ddns.Cloudflare_IPv6.ip_network='wan6'
uci set ddns.Cloudflare_IPv6.interface='wan6'
uci set ddns.Cloudflare_IPv6.use_syslog='2'
uci set ddns.Cloudflare_IPv6.check_unit='minutes'
uci set ddns.Cloudflare_IPv6.force_unit='minutes'
uci set ddns.Cloudflare_IPv6.retry_unit='seconds'

# 其他
uci commit network
uci commit dhcp
uci commit firewall
uci commit dropbear
uci commit ttyd
uci commit vlmcsd
uci commit openlist

uci commit ddns
/etc/init.d/ddns restart

exit 0
