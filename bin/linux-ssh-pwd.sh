#!/bin/bash

# 禁用 SSH 密码登录

echo "禁用 SSH 密码登录..."

# 检查是否已经配置为 no
if grep -q "^PasswordAuthentication no$" /etc/ssh/sshd_config; then
  echo "SSH 密码登录已禁用。"
  exit 0
fi

# 如果存在 PasswordAuthentication yes 则修改，否则添加
if grep -q "^#*PasswordAuthentication yes$" /etc/ssh/sshd_config; then
  sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
else
  echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

# 检查 sed 命令是否执行成功
if [ $? -ne 0 ]; then
  echo "错误：修改 SSH 配置文件失败！"
  exit 1
fi

# 重启 SSH 服务
echo "重启 SSH 服务..."
systemctl restart sshd

# 检查 systemctl 命令是否执行成功
if [ $? -ne 0 ]; then
  echo "错误：重启 SSH 服务失败！"
  exit 1
fi

echo "SSH 配置已更新，密码登录已禁用。"