#!/bin/sh
# 该脚本为immortalwrt首次启动时 运行的脚本 即 /etc/uci-defaults/99-custom.sh 也就是说该文件在路由器内 重启后消失 只运行一次
# 设置默认防火墙规则，方便虚拟机首次访问 WebUI
LOGFILE="/etc/config/uci-defaults-log.txt"

# 检查配置文件是否存在
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >> $LOGFILE
else
   # 读取pppoe信息(由build.sh写入)
   . "$SETTINGS_FILE"
fi
# 设置子网掩码 
uci set network.lan.netmask='255.255.255.0'
# 设置路由器管理后台地址
IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
if [ -f "$IP_VALUE_FILE" ]; then
    CUSTOM_IP=$(cat "$IP_VALUE_FILE")
    # 设置路由器的管理后台地址
    uci set network.lan.ipaddr=$CUSTOM_IP
    echo "custom router ip is $CUSTOM_IP" >> $LOGFILE
fi


# 判断是否启用 PPPoE
echo "print enable_pppoe value=== $enable_pppoe" >> $LOGFILE
if [ "$enable_pppoe" = "yes" ]; then
    echo "PPPoE is enabled at $(date)" >> $LOGFILE
    # 设置拨号信息
    uci set network.wan.proto='pppoe'                
    uci set network.wan.username=$pppoe_account     
    uci set network.wan.password=$pppoe_password     
    uci set network.wan.peerdns='1'                  
    uci set network.wan.auto='1' 
    echo "PPPoE configuration completed successfully." >> $LOGFILE
else
    echo "PPPoE is not enabled. Skipping configuration." >> $LOGFILE
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

uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by Hank"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# --- 設定管理員登入密碼 ---
root_password="gg123456"
(echo "$root_password"; sleep 1; echo "$root_password") | passwd > /dev/null

wlan_name="ImmortalWrt"
wlan_password="12345678"


# ==========================================
# 1. 基礎服務設定 (KMS & Lucky)
# ==========================================

# VLMCSD (KMS 激活服務)
uci set vlmcsd.config.enabled='1'
uci set vlmcsd.config.auto_activate='1'
uci del vlmcsd.config.internet_access

# Openlist (網盤服務)
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

# 網路介面優化 (WAN/LAN/Docker)
uci del network.wan6
uci del network.wan.auto
uci set network.globals.packet_steering='1'
uci set network.lan.multipath='off'
uci set network.wan.ipv6='0'
uci set network.wan.sourcefilter='0'
uci set network.wan.delegate='0'
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
uci set wireless.radio0.htmode='HE40'
uci set wireless.radio0.channel='11'
uci set wireless.radio0.country='TW'
uci set wireless.radio0.cell_density='0'
uci set wireless.default_radio0.ssid='$wlan_name'
uci set wireless.default_radio0.encryption='sae'
uci set wireless.default_radio1.key='$wlan_password'
uci set wireless.default_radio0.ocv='0'

uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.channel='157'
uci set wireless.radio1.country='TW'
uci set wireless.radio1.cell_density='0'
uci set wireless.default_radio0.ssid='$wlan_name'
uci set wireless.default_radio1.encryption='sae'
uci set wireless.default_radio1.key='$wlan_password'
uci set wireless.default_radio1.ocv='0'

uci commit wireless

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

# 建立 Peer (Hank-Home)
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
uci commit luci
uci commit system
uci commit network
uci commit dhcp
uci commit firewall
uci commit dropbear
uci commit ttyd
uci commit vlmcsd
uci commit openlist
uci commit ddns
/etc/init.d/ddns restart

echo "All done!"

exit 0
