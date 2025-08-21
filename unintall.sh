#!/usr/bin/env bash

# 停止并禁用服务
echo "停止并禁用mihomo服务..."
systemctl stop mihomo.service 2>/dev/null
systemctl disable mihomo.service 2>/dev/null

# 删除服务文件
echo "删除systemd服务文件..."
rm -f /etc/systemd/system/mihomo.service
systemctl daemon-reload

# 删除二进制文件
echo "删除mihomo二进制文件..."
rm -f /usr/local/bin/mihomo

# 删除配置文件和证书
echo "删除配置目录..."
rm -rf /root/.config/mihomo

# 检查是否完全卸载
echo -e "\n卸载完成，检查残留文件："
if [[ -f /usr/local/bin/mihomo || -d /root/.config/mihomo ]]; then
    echo "警告：以下文件未被删除："
    [[ -f /usr/local/bin/mihomo ]] && echo "  /usr/local/bin/mihomo"
    [[ -d /root/.config/mihomo ]] && echo "  /root/.config/mihomo/"
else
    echo "所有相关文件已成功移除"
fi

# 提示用户手动操作
echo -e "\n可能需要手动执行以下操作："
echo "1. 如果修改过防火墙规则，请手动清理相关规则"
echo "2. 如果创建过专用用户，请手动删除用户"
echo "3. 运行 'systemctl reset-failed' 清理失败的服务记录"
