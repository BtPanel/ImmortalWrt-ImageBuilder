#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE

uci set firewall.@zone[1].input='REJECT'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

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

# 2. 配置网络
if [ "$count" -eq 1 ]; then
    # 单网口设备，DHCP模式
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr
    uci delete network.lan.netmask
    uci delete network.lan.gateway
    uci delete network.lan.dns
    uci commit network
elif [ "$count" -gt 1 ]; then
    echo "Configuring multi-port device ($count ports)..." >>$LOGFILE
    
    # 物理网口分配，第一个口做 LAN (eth0)
    LAN_MAIN=$(echo "$ifnames" | awk '{print $1}')
    # 第二个口做 WAN (eth1)
    WAN_IF=$(echo "$ifnames" | awk '{print $2}')
    # 剩下的所有口 (从第3个到第N个) 全部归为 LAN 扩展口
    LAN_OTHERS=$(echo "$ifnames" | cut -d' ' -f3-)
    
    # 配置WAN
    uci delete network.wan
    uci set network.wan=interface
    uci set network.wan.proto='dhcp'
    uci set network.wan.device="$WAN_IF"
    # 配置WAN6
    uci delete network.wan6
    uci set network.wan6=interface
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device="$WAN_IF"
    
    # 配置 LAN 网桥
    uci delete network.br_lan
    uci set network.br_lan=device
    uci set network.br_lan.name='br-lan'
    uci set network.br_lan.type='bridge'
    
    # 把 LAN 主口和所有扩展口加入网桥列表
    for p_if in $LAN_MAIN $LAN_OTHERS; do
        uci add_list network.br_lan.ports="$p_if"
        echo "Adding $p_if to LAN bridge" >>$LOGFILE
    done

    # LAN口设置静态IP,多网口设备 支持修改为别的管理后台地址 在Github Action 的UI上自行输入即可 
    uci set network.lan.proto='static'
    uci set network.lan.device='br-lan'  # 绑定到上面定义的网桥
    uci delete network.lan.gateway
    uci set network.lan.netmask='255.255.255.0'

    # 设置路由器管理后台地址
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        # 用户在UI上设置的路由器后台管理地址
        uci set network.lan.ipaddr=$CUSTOM_IP
        echo "custom router ip is $CUSTOM_IP" >> $LOGFILE
    else
        uci set network.lan.ipaddr='10.0.0.1'
        echo "default router ip is 10.0.0.1" >> $LOGFILE
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

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by ImmortalWrt"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if opkg list-installed | grep -q '^luci-app-advancedplus '; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
fi

# 插件菜单设置
sed -i 's#admin/status#admin/vpn#g' /usr/share/luci/menu.d/luci-proto-wireguard.json
sed -i 's#admin/network/bandix_plus#admin/control/bandixplus#g' /usr/share/luci/menu.d/luci-app-bandix-plus.json
#sed -i 's#admin/control/taskplan#admin/system/taskplan#g' /usr/share/luci/menu.d/luci-app-taskplan.json
sed -i 's#admin/services/frpc#admin/vpn/frpc#g' /usr/share/luci/menu.d/luci-app-frpc.json

# 应用过滤移动到管控菜单下,暂时有bug
#sed -i 's/{"admin", "services", "appfilter"}/{"admin", "control", "appfilter"}/g' /usr/lib/lua/luci/controller/appfilter.lua
#sed -i 's/"admin", "services", "appfilter"/"admin", "control", "appfilter"/g' /usr/lib/lua/luci/controller/appfilter.lua

# 插件兼容性修复
# 修复 pcdata，striptags（移除 HTML 标签函数）
find /usr/lib/lua/luci -type f -name "*.lua" | xargs sed -i 's/luci.util.pcdata/luci.xml.pcdata/g'
find /usr/lib/lua/luci -type f -name "*.lua" | xargs sed -i 's/luci.util.striptags/luci.xml.striptags/g'
# 清除 LuCI 缓存
rm -rf /tmp/luci-modulecache/ /tmp/luci-indexcache 
echo "All compatibility fixes applied." >>$LOGFILE
/etc/init.d/rpcd restart

exit 0
