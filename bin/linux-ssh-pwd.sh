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
SSH_SERVICE=""

# 先优先选择当前正在运行的服务名，再回退到已安装的服务名
if systemctl is-active --quiet sshd; then
  SSH_SERVICE="sshd"
elif systemctl is-active --quiet ssh; then
  SSH_SERVICE="ssh"
elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
  SSH_SERVICE="sshd"
elif systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
  SSH_SERVICE="ssh"
else
  echo "错误：未检测到 SSH 服务（sshd 或 ssh）。"
  exit 1
fi

echo "检测到 SSH 服务名：${SSH_SERVICE}"

if ! systemctl restart "${SSH_SERVICE}"; then
  echo "错误：重启 SSH 服务失败！"
  exit 1
fi

echo "已重启 SSH 服务：${SSH_SERVICE}"

echo "SSH 配置已更新，密码登录已禁用。"
