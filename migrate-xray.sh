#!/usr/bin/env bash
# ============================================================
# migrate-xray.sh — 一键迁移 Xray VLESS+REALITY 到新 VPS
#
# 用法:
#   ./migrate-xray.sh <新VPS_IP> [SSH端口]
#
# 功能:
#   1. SSH 到新 VPS，安装 Xray
#   2. 生成新的密钥对 + UUID + shortId
#   3. 部署服务端配置并启动
#   4. 自动更新本机 Xray 客户端配置
#   5. 重启本机 Xray 并验证连通性
#   6. 生成手机导入链接
#
# 前提:
#   - 新 VPS 可通过 root SSH 登录（密钥或密码）
#   - 本机已安装 jq（brew install jq）
# ============================================================

set -euo pipefail

NEW_IP="${1:?用法: $0 <新VPS_IP> [SSH端口]}"
SSH_PORT="${2:-22}"
LOCAL_CONFIG="/opt/homebrew/etc/xray/config.json"
OLD_IP="82.40.42.122"

echo "🚀 开始迁移 Xray 到 ${NEW_IP}:${SSH_PORT}"
echo ""

# ---- Step 1: 在新 VPS 安装 Xray ----
echo "📦 [1/6] 在新 VPS 安装 Xray ..."
ssh -o StrictHostKeyChecking=accept-new -p "$SSH_PORT" "root@${NEW_IP}" bash <<'REMOTE_INSTALL'
set -e
if command -v xray &>/dev/null; then
    echo "Xray 已安装: $(xray version | head -1)"
else
    echo "正在安装 Xray ..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    echo "安装完成: $(xray version | head -1)"
fi
mkdir -p /var/log/xray
REMOTE_INSTALL
echo "✅ Xray 安装完成"
echo ""

# ---- Step 2: 生成新密钥 ----
echo "🔑 [2/6] 生成新的密钥、UUID、ShortId ..."
KEYS_JSON=$(ssh -p "$SSH_PORT" "root@${NEW_IP}" bash <<'REMOTE_KEYGEN'
set -e
UUID=$(xray uuid)
KEYPAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "Public" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
cat <<EOF
{
  "uuid": "${UUID}",
  "privateKey": "${PRIVATE_KEY}",
  "publicKey": "${PUBLIC_KEY}",
  "shortId": "${SHORT_ID}"
}
EOF
REMOTE_KEYGEN
)

NEW_UUID=$(echo "$KEYS_JSON" | jq -r .uuid)
NEW_PRIVATE_KEY=$(echo "$KEYS_JSON" | jq -r .privateKey)
NEW_PUBLIC_KEY=$(echo "$KEYS_JSON" | jq -r .publicKey)
NEW_SHORT_ID=$(echo "$KEYS_JSON" | jq -r .shortId)

echo "  UUID:       ${NEW_UUID}"
echo "  PublicKey:  ${NEW_PUBLIC_KEY}"
echo "  ShortId:    ${NEW_SHORT_ID}"
echo "✅ 密钥生成完成"
echo ""

# ---- Step 3: 部署服务端配置 ----
echo "⚙️  [3/6] 部署服务端配置 ..."
ssh -p "$SSH_PORT" "root@${NEW_IP}" bash <<REMOTE_CONFIG
set -e
cat > /usr/local/etc/xray/config.json <<'XRAY_EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${NEW_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "www.microsoft.com:443",
          "serverNames": [
            "www.microsoft.com",
            "microsoft.com"
          ],
          "privateKey": "${NEW_PRIVATE_KEY}",
          "shortIds": [
            "${NEW_SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
XRAY_EOF

systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active xray && echo "Xray 服务运行正常" || echo "⚠️ Xray 启动失败"
REMOTE_CONFIG
echo "✅ 服务端配置部署完成"
echo ""

# ---- Step 4: 更新本机客户端配置 ----
echo "🔧 [4/6] 更新本机 Xray 客户端配置 ..."
cp "$LOCAL_CONFIG" "${LOCAL_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

# Use jq to update the config
jq --arg ip "$NEW_IP" \
   --arg uuid "$NEW_UUID" \
   --arg pubkey "$NEW_PUBLIC_KEY" \
   --arg sid "$NEW_SHORT_ID" \
   '
   (.outbounds[] | select(.tag == "vps-proxy") | .settings.vnext[0].address) = $ip |
   (.outbounds[] | select(.tag == "vps-proxy") | .settings.vnext[0].users[0].id) = $uuid |
   (.outbounds[] | select(.tag == "vps-proxy") | .streamSettings.realitySettings.publicKey) = $pubkey |
   (.outbounds[] | select(.tag == "vps-proxy") | .streamSettings.realitySettings.shortId) = $sid
   ' "$LOCAL_CONFIG" > "${LOCAL_CONFIG}.tmp" && mv "${LOCAL_CONFIG}.tmp" "$LOCAL_CONFIG"

echo "  旧 IP: ${OLD_IP} → 新 IP: ${NEW_IP}"
echo "✅ 本机配置已更新（旧配置已备份）"
echo ""

# ---- Step 5: 重启本机 Xray 并验证 ----
echo "🔄 [5/6] 重启本机 Xray ..."
brew services restart xray
sleep 3

echo "🧪 验证代理连通性 ..."
if curl -s --connect-timeout 10 --proxy "http://127.0.0.1:18924" "https://www.google.com" >/dev/null 2>&1; then
    echo "✅ 代理连通正常！"
else
    echo "⚠️  代理连通失败，请检查。旧配置备份在 ${LOCAL_CONFIG}.bak.*"
fi
echo ""

# ---- Step 6: 生成手机导入链接 ----
echo "📱 [6/6] 手机导入链接："
echo ""
SHARE_URL="vless://${NEW_UUID}@${NEW_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${NEW_PUBLIC_KEY}&sid=${NEW_SHORT_ID}&type=tcp#VPS-Proxy"
echo "$SHARE_URL"
echo ""
echo "复制上面的链接到 Shadowrocket / v2rayNG 导入即可。"
echo ""

# ---- 汇总 ----
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 迁移完成！"
echo ""
echo "  新 VPS:     ${NEW_IP}"
echo "  UUID:       ${NEW_UUID}"
echo "  PublicKey:  ${NEW_PUBLIC_KEY}"
echo "  ShortId:    ${NEW_SHORT_ID}"
echo ""
echo "  本机配置:   ${LOCAL_CONFIG}"
echo "  配置备份:   ${LOCAL_CONFIG}.bak.*"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
