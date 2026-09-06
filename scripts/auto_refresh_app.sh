#!/bin/bash
# ChatStorage iOS 自动重签重装脚本
# 每6天自动执行，确保免费开发者账号的描述文件永不过期
# 日志: ~/Library/Logs/chatstorage-refresh.log

PROJECT_DIR="/Users/debugcode/Documents/mac/chat-storage-ios"
DEVICE_ID="A5953958-90B5-5D58-A5CE-493DE191AB63"
LOG_FILE="$HOME/Library/Logs/chatstorage-refresh.log"
APP_PATH="$PROJECT_DIR/build/DerivedData/Build/Products/Debug-iphoneos/ChatStorage.app"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "===== 开始自动刷新 ====="

# 1. 拉取最新代码
cd "$PROJECT_DIR" || { log "ERROR: 无法进入项目目录"; exit 1; }
git pull origin master >> "$LOG_FILE" 2>&1
log "代码拉取完成"

# 2. 构建（自动签名，生成新的描述文件）
xcodebuild -project ChatStorage.xcodeproj -scheme ChatStorage \
    -sdk iphoneos -configuration Debug \
    -allowProvisioningUpdates \
    -derivedDataPath build/DerivedData \
    build >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    log "ERROR: 构建失败"
    exit 1
fi
log "构建成功"

# 3. 检查描述文件过期时间
EXPIRY=$(security cms -D -i "$APP_PATH/embedded.mobileprovision" 2>/dev/null \
    | plutil -p - 2>/dev/null | grep "ExpirationDate" | sed 's/.*=> //')
log "新描述文件过期时间: $EXPIRY"

# 4. 通过WiFi安装到设备（重试3次）
for i in 1 2 3; do
    log "尝试WiFi安装 (第$i次)..."
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        log "WiFi安装成功"
        break
    fi
    log "安装失败，等待10秒后重试..."
    sleep 10
done

log "===== 自动刷新完成 ====="
