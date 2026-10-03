#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/BtPanel/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/

  # ============= 🔴 针对 25.12 apk 包管理器修复包索引 =============
  # 注意：25.12 用的是 apk-tools 3.x，生成 apkv3 索引(packages.adb)的命令是 mkndx，
  #       不是 2.x 的 `apk index`；且 apk 不在 PATH 里，必须用工具链里的全路径。
  echo "🔄 正在为 25.12 apk 本地仓库构建索引数据库..."
  IB_HOME="/home/build/immortalwrt"
  cd "$IB_HOME/packages/"

  if ! ls *.apk >/dev/null 2>&1; then
      echo "⚠️ packages/ 下没有 apk，跳过索引生成"
  else
      # 1. 定位工具链里的 apk / openssl（它们不在系统 PATH 中）
      APK_BIN="$IB_HOME/staging_dir/host/bin/apk"
      [ -x "$APK_BIN" ] || APK_BIN="$(command -v apk 2>/dev/null)"
      OPENSSL_BIN="$IB_HOME/staging_dir/host/bin/openssl"
      [ -x "$OPENSSL_BIN" ] || OPENSSL_BIN="$(command -v openssl 2>/dev/null)"
      if [ -z "$APK_BIN" ]; then
          echo "❌ 找不到 apk 工具，无法生成 packages.adb"
          exit 1
      fi
      echo "🔧 使用 apk: $APK_BIN"

      # 2. 准备本地签名密钥
      #    imm25.config 里 CONFIG_SIGNATURE_CHECK=y，apk 只信任 $(TOPDIR)/keys 下的公钥，
      #    未签名的 packages.adb 会被直接丢弃，表现就是第三方包全部 no such package。
      #    这里照抄 IB 的 _check_keys 生成，保证后面 make image 复用同一份密钥。
      KEY_DIR="$IB_HOME/keys"
      KEY_SEC="$KEY_DIR/local-private-key.pem"
      KEY_PUB="$KEY_DIR/local-public-key.pem"
      mkdir -p "$KEY_DIR"
      if [ -n "$OPENSSL_BIN" ] && { [ ! -s "$KEY_SEC" ] || [ ! -s "$KEY_PUB" ]; }; then
          echo "🔑 生成本地签名密钥..."
          "$OPENSSL_BIN" ecparam -name prime256v1 -genkey -noout -out "$KEY_SEC"
          sed -i '1s/^/untrusted comment: Local build key\n/' "$KEY_SEC"
          "$OPENSSL_BIN" ec -in "$KEY_SEC" -pubout > "$KEY_PUB"
          sed -i '1s/^/untrusted comment: Local build key\n/' "$KEY_PUB"
      fi

      # 3. 生成索引（apk-tools 3 里没有 apk-sign，签名要用 mkndx --sign）
      if [ -s "$KEY_SEC" ]; then
          echo "✍️ 使用 $KEY_SEC 为 packages.adb 签名..."
          MKNDX_CMD=("$APK_BIN" mkndx --root "$IB_HOME" --keys-dir "$KEY_DIR" \
                     --sign "$KEY_SEC" --allow-untrusted --output packages.adb)
      else
          echo "⚠️ 无可用私钥，以未签名方式生成索引（SIGNATURE_CHECK=y 时可能被拒绝）"
          MKNDX_CMD=("$APK_BIN" mkndx --root "$IB_HOME" --keys-dir "$KEY_DIR" \
                     --allow-untrusted --output packages.adb)
      fi

      BROKEN_DIR="$IB_HOME/packages-broken"
      if ! "${MKNDX_CMD[@]}" *.apk; then
          # mkndx 遇到格式错误的 apk 会整体中断（这也是 IB 自己建索引一直失败的原因），
          # 所以逐个校验、把坏包隔离出去，再用剩下的包重试
          echo "⚠️ 索引生成失败，逐个校验并隔离坏包..."
          mkdir -p "$BROKEN_DIR"
          for f in *.apk; do
              if ! "$APK_BIN" mkndx --allow-untrusted --output /tmp/idx-probe.adb "$f" \
                      >/dev/null 2>&1; then
                  echo "   💥 坏包已隔离: $f"
                  mv -f "$f" "$BROKEN_DIR/"
              fi
          done
          rm -f /tmp/idx-probe.adb

          echo "🔁 隔离后重试，剩余 $(ls *.apk 2>/dev/null | wc -l) 个包..."
          if ! "${MKNDX_CMD[@]}" *.apk; then
              echo "⚠️ 带签名失败，退回无签名最小参数..."
              "$APK_BIN" mkndx --allow-untrusted --output packages.adb *.apk || {
                  echo "❌ packages.adb 仍然无法生成"
                  exit 1
              }
          fi
      fi

      # 4. 必须确认索引真的生成了（IB 自带的 package_index 会用 || true 静默吞掉失败）
      ls -lah packages.adb
      if [ ! -s packages.adb ]; then
          echo "❌ packages.adb 未生成或为空，make image 必然报 no such package"
          exit 1
      fi
      echo "✅ 本地仓库索引已生成，共 $(ls *.apk | wc -l) 个包"

      # 5. 被隔离的坏包如果还在 PACKAGES 里，后面仍会 no such package，提前点名
      if ls "$BROKEN_DIR"/*.apk >/dev/null 2>&1; then
          echo "⚠️ 以下 apk 格式错误已被隔离到 packages-broken/："
          for f in "$BROKEN_DIR"/*.apk; do
              echo "   - $(basename "$f")"
          done
          echo "   若它们出现在 PACKAGES 中，请修复 apk 源或将其从 shell/apk-custom-packages.sh 移除"
      fi
  fi

  # 返回源码根目录，确保不影响后续的 make 流程
  cd "$IB_HOME/"
  # ===============================================================
  
fi

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#25.12
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件 暂时注释
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE USER_PACKAGES_DIR="/home/build/immortalwrt/packages"


if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
