#!/bin/bash

# 재연결 테스트만 실행하는 스크립트

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SERVER_URL="http://localhost:3003"
WS_URL="ws://localhost:3003/rtc"
SERVER_PID=""
CLIENT_PID=""
LOG_DIR="logs"

# 로그 함수
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 정리 함수
cleanup() {
    log_info "테스트 환경 정리 중..."

    if [ ! -z "$CLIENT_PID" ]; then
        kill $CLIENT_PID 2>/dev/null || true
    fi

    if [ ! -z "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
    fi

    pkill -f "target/debug/Tokenly" 2>/dev/null || true
    pkill -f "target/release/Tokenly" 2>/dev/null || true
    lsof -ti:3003 | xargs kill -9 2>/dev/null || true

    log_info "정리 완료"
}

trap cleanup EXIT INT TERM

# 서버 상태 확인 함수
check_server_status() {
    local expected_state=$1
    local max_attempts=${2:-10}
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -s $SERVER_URL/status > /dev/null 2>&1; then
            local state=$(curl -s $SERVER_URL/status | jq -r '.state' 2>/dev/null || echo "unknown")
            if [ "$state" = "$expected_state" ]; then
                return 0
            fi
            log_info "현재 상태: $state, 예상 상태: $expected_state (시도 $((attempt+1))/$max_attempts)"
        else
            log_info "서버 상태 API 응답 없음 (시도 $((attempt+1))/$max_attempts)"
        fi

        sleep 1
        ((attempt++))
    done

    return 1
}

# 환경 초기화
mkdir -p $LOG_DIR
rm -f $LOG_DIR/reconnect_test_*

# 서버 시작
log_info "테스트용 서버 시작"
cargo build --release > $LOG_DIR/reconnect_test_build.log 2>&1
./target/release/Tokenly > $LOG_DIR/reconnect_test_server.log 2>&1 &
SERVER_PID=$!
sleep 3

# 서버 시작 확인
if ! curl -s $SERVER_URL/status > /dev/null 2>&1; then
    log_error "서버 시작 실패"
    exit 1
fi

log_success "서버 시작 완료 (PID: $SERVER_PID)"

# 재연결 전용 클라이언트 연결
log_info "재연결 테스트 클라이언트 연결 중"
node -e "
const WebSocket = require('ws');
const WS_URL = 'ws://localhost:3003/rtc';

class PersistentReconnectClient {
    constructor() {
        this.isIntentionalClose = false;
        this.reconnectAttempts = 0;
        this.maxReconnectAttempts = 5;
        this.reconnectInterval = 1000;
        this.connect();

        // 60초 후 자동 종료 (재연결 테스트 완료 대기)
        setTimeout(() => {
            console.log('테스트 완료 - 클라이언트 종료');
            this.disconnect();
            process.exit(0);
        }, 60000);
    }

    connect() {
        console.log(\`[재연결클라이언트] WebSocket 연결 시도: \${WS_URL}\`);

        this.ws = new WebSocket(WS_URL);

        this.ws.on('open', () => {
            console.log('[재연결클라이언트] ✅ WebSocket 연결 성공');
            this.reconnectAttempts = 0;

            // 테스트 메시지 전송
            const testMessage = {
                type: 'create-peer',
                session_id: \`persistent-session-\${Date.now()}\`,
                room_id: 'persistent-test-room'
            };
            this.ws.send(JSON.stringify(testMessage));
            console.log(\`[재연결클라이언트] 📤 전송: \${JSON.stringify(testMessage)}\`);
        });

        this.ws.on('message', (data) => {
            const message = data.toString();
            console.log(\`[재연결클라이언트] 📨 수신: \${message}\`);

            try {
                const parsed = JSON.parse(message);
                if (parsed.type === 'peer-created') {
                    console.log(\`[재연결클라이언트] 🎯 피어 생성 응답: \${parsed.success ? '성공' : '실패'}\`);
                }
            } catch (e) {
                console.log(\`[재연결클라이언트] 📨 원시 메시지: \${message}\`);
            }
        });

        this.ws.on('close', (code, reason) => {
            console.log(\`[재연결클라이언트] ❌ WebSocket 연결 종료 (코드: \${code}, 이유: \${reason})\`);

            if (!this.isIntentionalClose) {
                this.attemptReconnect();
            }
        });

        this.ws.on('error', (error) => {
            console.error(\`[재연결클라이언트] 🚫 WebSocket 오류: \${error.message}\`);
        });

        this.ws.on('ping', () => {
            console.log('[재연결클라이언트] 🏓 Ping 수신');
        });

        this.ws.on('pong', () => {
            console.log('[재연결클라이언트] 🏓 Pong 수신');
        });
    }

    attemptReconnect() {
        if (this.reconnectAttempts >= this.maxReconnectAttempts) {
            console.error('[재연결클라이언트] ❌ 최대 재연결 시도 횟수 초과');
            return;
        }

        this.reconnectAttempts++;
        const delay = this.reconnectInterval * Math.pow(2, this.reconnectAttempts - 1);

        console.log(\`[재연결클라이언트] 🔄 재연결 시도 \${this.reconnectAttempts}/\${this.maxReconnectAttempts} - \${delay}ms 후 시도\`);

        setTimeout(() => {
            this.connect();
        }, delay);
    }

    disconnect() {
        console.log('[재연결클라이언트] 🔌 의도적 연결 종료');
        this.isIntentionalClose = true;
        if (this.ws) {
            this.ws.close();
        }
    }
}

new PersistentReconnectClient();
" > $LOG_DIR/reconnect_test_client.log 2>&1 &
CLIENT_PID=$!
sleep 5

# 연결 상태 확인
if ! check_server_status "connected" 10; then
    log_error "클라이언트 연결 실패"
    cat $LOG_DIR/reconnect_test_client.log
    exit 1
fi

log_success "클라이언트 연결 완료"

# 서버 재시작 테스트
log_info "서버 재시작 테스트 시작"

# 기존 서버 종료
kill $SERVER_PID 2>/dev/null || true
sleep 2

# 포트 해제 대기
log_info "포트 해제 대기 중..."
port_check_count=0
while lsof -ti:3003 > /dev/null 2>&1 && [ $port_check_count -lt 20 ]; do
    log_info "포트 해제 대기... (시도 $((port_check_count + 1))/20)"
    pkill -f "target/release/Tokenly" 2>/dev/null || true
    sleep 1
    ((port_check_count++))
done

# 강제 포트 해제
if lsof -ti:3003 > /dev/null 2>&1; then
    log_info "포트 강제 해제"
    lsof -ti:3003 | xargs kill -9 2>/dev/null || true
    sleep 3
fi

# 새 서버 시작
log_info "새 서버 시작"
./target/release/Tokenly > $LOG_DIR/reconnect_test_server_new.log 2>&1 &
SERVER_PID=$!

# 서버 시작 대기
sleep 5
restart_check_count=0
while ! curl -s $SERVER_URL/status > /dev/null 2>&1 && [ $restart_check_count -lt 15 ]; do
    log_info "새 서버 시작 대기... (시도 $((restart_check_count + 1))/15)"
    sleep 1
    ((restart_check_count++))
done

if ! curl -s $SERVER_URL/status > /dev/null 2>&1; then
    log_error "새 서버 시작 실패"
    cat $LOG_DIR/reconnect_test_server_new.log
    exit 1
fi

log_success "새 서버 시작 완료"

# 재연결 확인 (더 긴 대기 시간)
log_info "자동 재연결 확인 중..."
if check_server_status "connected" 30; then
    log_success "🎉 자동 재연결 테스트 성공!"

    # 상태 정보 출력
    local status=$(curl -s $SERVER_URL/status | jq)
    echo "최종 서버 상태:"
    echo "$status"
else
    log_error "자동 재연결 실패"

    echo "=== 클라이언트 로그 ==="
    tail -10 $LOG_DIR/reconnect_test_client.log

    echo "=== 서버 로그 ==="
    tail -10 $LOG_DIR/reconnect_test_server_new.log

    echo "=== 서버 상태 ==="
    curl -s $SERVER_URL/status | jq || echo "상태 API 응답 없음"

    exit 1
fi

log_success "재연결 테스트 완료"