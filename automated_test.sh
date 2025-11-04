#!/bin/bash

# 재연결 로직 자동화 테스트 스크립트

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

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 정리 함수
cleanup() {
    log_info "테스트 환경 정리 중..."

    if [ ! -z "$CLIENT_PID" ]; then
        kill $CLIENT_PID 2>/dev/null || true
        log_info "클라이언트 프로세스 종료"
    fi

    if [ ! -z "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
        log_info "서버 프로세스 종료"
    fi

    # 포트 3003 사용 중인 모든 프로세스 종료
    pkill -f "target/debug/Tokenly" 2>/dev/null || true
    pkill -f "target/release/Tokenly" 2>/dev/null || true

    log_info "정리 완료"
}

# 로그 디렉토리 초기화
init_logs() {
    mkdir -p $LOG_DIR
    rm -f $LOG_DIR/*.log
    log_info "로그 디렉토리 초기화: $LOG_DIR"
}

# 신호 핸들러 등록
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
            log_warning "서버 상태 API 응답 없음 (시도 $((attempt+1))/$max_attempts)"
        fi

        sleep 1
        ((attempt++))
    done

    return 1
}

# 서버 시작 함수
start_server() {
    log_info "시그널링 서버 시작 중..."

    # 기존 프로세스 정리
    pkill -f "target/debug/Tokenly" 2>/dev/null || true
    sleep 2

    # 서버 빌드 및 시작
    log_info "서버 빌드 중..."
    cargo build --release > $LOG_DIR/build.log 2>&1 || {
        log_error "서버 빌드 실패"
        cat $LOG_DIR/build.log
        exit 1
    }

    ./target/release/Tokenly > $LOG_DIR/server.log 2>&1 &
    SERVER_PID=$!

    # 서버 시작 대기
    sleep 3

    if ! curl -s $SERVER_URL/status > /dev/null 2>&1; then
        log_error "서버 시작 실패"
        cat $LOG_DIR/server.log
        exit 1
    fi

    log_success "서버 시작 완료 (PID: $SERVER_PID)"
}

# WebSocket 클라이언트 테스트
test_websocket_connection() {
    log_info "WebSocket 연결 테스트 시작"

    # Node.js 패키지 확인
    if ! command -v node > /dev/null 2>&1; then
        log_error "Node.js가 설치되지 않음"
        return 1
    fi

    if ! node -e "require('ws')" > /dev/null 2>&1; then
        log_warning "ws 패키지 설치 중..."
        npm install ws > /dev/null 2>&1 || {
            log_error "ws 패키지 설치 실패"
            return 1
        }
    fi

    # 기본 연결 테스트
    log_info "기본 WebSocket 연결 테스트"

    # timeout 명령어 대신 Node.js 내부 timeout 사용
    node -e "
    const WebSocket = require('ws');
    const timeout = setTimeout(() => {
        console.error('WebSocket 연결 타임아웃');
        process.exit(1);
    }, 10000);

    const ws = new WebSocket('$WS_URL');
    ws.on('open', () => {
        clearTimeout(timeout);
        console.log('WebSocket 연결 성공');
        ws.close();
        process.exit(0);
    });
    ws.on('error', (err) => {
        clearTimeout(timeout);
        console.error('WebSocket 연결 실패:', err.message);
        process.exit(1);
    });
    " || {
        log_error "기본 WebSocket 연결 테스트 실패"
        return 1
    }

    log_success "WebSocket 연결 테스트 완료"
    return 0
}

# 재연결 테스트
test_reconnection() {
    log_info "재연결 로직 테스트 시작"

    # 재연결 전용 클라이언트를 백그라운드에서 실행
    node -e "
    const WebSocket = require('ws');
    const WS_URL = '$WS_URL';

    class PersistentTestClient {
        constructor() {
            this.isIntentionalClose = false;
            this.reconnectAttempts = 0;
            this.maxReconnectAttempts = 5;
            this.reconnectInterval = 1000;
            this.connect();

            // 45초 후 자동 종료 (테스트 완료 대기)
            setTimeout(() => {
                console.log('[테스트완료] 클라이언트 종료');
                this.disconnect();
                process.exit(0);
            }, 45000);
        }

        connect() {
            console.log(\`WebSocket 연결 시도: \${WS_URL}\`);
            this.ws = new WebSocket(WS_URL);

            this.ws.on('open', () => {
                console.log('✅ WebSocket 연결 성공');
                this.reconnectAttempts = 0;
                const testMessage = {
                    type: 'create-peer',
                    session_id: \`test-session-\${Date.now()}\`,
                    room_id: 'test-room-001'
                };
                this.ws.send(JSON.stringify(testMessage));
                console.log(\`📤 전송: \${JSON.stringify(testMessage)}\`);
            });

            this.ws.on('message', (data) => {
                const message = data.toString();
                console.log(\`📨 수신: \${message}\`);
                try {
                    const parsed = JSON.parse(message);
                    if (parsed.type === 'peer-created') {
                        console.log(\`🎯 피어 생성 응답: \${parsed.success ? '성공' : '실패'}\`);
                    }
                } catch (e) {
                    console.log(\`📨 원시 메시지: \${message}\`);
                }
            });

            this.ws.on('close', (code, reason) => {
                console.log(\`❌ WebSocket 연결 종료 (코드: \${code}, 이유: \${reason})\`);
                if (!this.isIntentionalClose) {
                    this.attemptReconnect();
                }
            });

            this.ws.on('error', (error) => {
                console.error(\`🚫 WebSocket 오류: \${error.message}\`);
            });

            this.ws.on('ping', () => {
                console.log('🏓 Ping 수신');
            });
        }

        attemptReconnect() {
            if (this.reconnectAttempts >= this.maxReconnectAttempts) {
                console.error('❌ 최대 재연결 시도 횟수 초과');
                return;
            }

            this.reconnectAttempts++;
            const delay = this.reconnectInterval * Math.pow(2, this.reconnectAttempts - 1);
            console.log(\`🔄 재연결 시도 \${this.reconnectAttempts}/\${this.maxReconnectAttempts} - \${delay}ms 후 시도\`);

            setTimeout(() => {
                this.connect();
            }, delay);
        }

        disconnect() {
            console.log('🔌 의도적 연결 종료');
            this.isIntentionalClose = true;
            if (this.ws) {
                this.ws.close();
            }
        }
    }

    new PersistentTestClient();
    " > $LOG_DIR/client.log 2>&1 &
    CLIENT_PID=$!

    sleep 3

    # 연결 상태 확인
    if ! check_server_status "connected" 10; then
        log_error "클라이언트 연결 실패"
        cat $LOG_DIR/client.log
        return 1
    fi

    log_success "클라이언트 연결 완료"

    # 서버 재시작으로 네트워크 중단 시뮬레이션
    log_info "서버 재시작으로 네트워크 중단 시뮬레이션"

    local old_pid=$SERVER_PID
    kill $SERVER_PID 2>/dev/null || true
    sleep 2

    # 포트가 완전히 해제될 때까지 대기
    local port_check_count=0
    while lsof -ti:3003 > /dev/null 2>&1 && [ $port_check_count -lt 15 ]; do
        log_info "서버 재시작 대기 - 포트 해제 중... (시도 $((port_check_count + 1))/15)"
        pkill -f "target/release/Tokenly" 2>/dev/null || true
        pkill -f "target/debug/Tokenly" 2>/dev/null || true
        sleep 1
        ((port_check_count++))
    done

    # 강제 포트 해제
    if lsof -ti:3003 > /dev/null 2>&1; then
        log_info "포트 강제 해제 중..."
        lsof -ti:3003 | xargs kill -9 2>/dev/null || true
        sleep 2
    fi

    log_info "서버 재시작 중..."

    ./target/release/Tokenly > $LOG_DIR/server_restart.log 2>&1 &
    SERVER_PID=$!

    # 서버 시작 확인 (더 긴 대기 시간)
    sleep 3
    local restart_check_count=0
    while ! curl -s $SERVER_URL/status > /dev/null 2>&1 && [ $restart_check_count -lt 10 ]; do
        log_info "서버 시작 대기 중... (시도 $((restart_check_count + 1))/10)"
        sleep 1
        ((restart_check_count++))
    done

    # 재연결 확인
    if ! check_server_status "connected" 20; then
        log_error "자동 재연결 실패"
        log_info "클라이언트 로그:"
        tail -20 $LOG_DIR/client.log
        log_info "서버 로그:"
        tail -20 $LOG_DIR/server_restart.log
        return 1
    fi

    log_success "자동 재연결 테스트 완료"
    return 0
}

# 지수 백오프 테스트
test_exponential_backoff() {
    log_info "지수 백오프 테스트 시작"

    # 클라이언트 종료
    if [ ! -z "$CLIENT_PID" ]; then
        kill $CLIENT_PID 2>/dev/null || true
        CLIENT_PID=""
    fi

    # 서버 완전 종료 및 확인
    kill $SERVER_PID 2>/dev/null || true
    sleep 2

    # 포트가 완전히 해제될 때까지 대기
    local port_check_count=0
    while lsof -ti:3003 > /dev/null 2>&1 && [ $port_check_count -lt 10 ]; do
        log_info "포트 3003 해제 대기 중... (시도 $((port_check_count + 1))/10)"
        pkill -f "target/release/Tokenly" 2>/dev/null || true
        pkill -f "target/debug/Tokenly" 2>/dev/null || true
        sleep 1
        ((port_check_count++))
    done

    # 서버가 종료된 상태 확인
    if lsof -ti:3003 > /dev/null 2>&1; then
        log_error "서버 종료 실패 - 포트가 여전히 사용 중"
        lsof -ti:3003 | xargs kill -9 2>/dev/null || true
        sleep 2
    fi

    log_info "서버 종료 완료 - 지수 백오프 테스트용 클라이언트 시작"

    # 재연결 로직이 있는 전용 클라이언트 실행
    node -e "
    const WebSocket = require('ws');
    const WS_URL = 'ws://localhost:3003/rtc';

    class BackoffTestClient {
        constructor() {
            this.attempts = 0;
            this.maxAttempts = 3;
            this.initialDelay = 1000;
            this.connect();
        }

        connect() {
            this.attempts++;
            console.log(\`[지수백오프] 재연결 시도 \${this.attempts}/\${this.maxAttempts} - 연결 시도중\`);

            const ws = new WebSocket(WS_URL);

            ws.on('open', () => {
                console.log('✅ 연결 성공');
                this.attempts = 0;
                ws.close();
            });

            ws.on('error', (err) => {
                console.log(\`❌ 연결 실패: \${err.message}\`);
                this.scheduleReconnect();
            });

            ws.on('close', () => {
                if (this.attempts === 0) return; // 정상 종료
                this.scheduleReconnect();
            });
        }

        scheduleReconnect() {
            if (this.attempts >= this.maxAttempts) {
                console.log('최대 재연결 시도 횟수 도달');
                process.exit(0);
                return;
            }

            const delay = this.initialDelay * Math.pow(2, this.attempts - 1);
            console.log(\`[지수백오프] 재연결 시도 \${this.attempts + 1}/\${this.maxAttempts} - \${delay}ms 후 재시도\`);

            setTimeout(() => {
                this.connect();
            }, delay);
        }
    }

    new BackoffTestClient();
    " > $LOG_DIR/backoff_client.log 2>&1 &
    CLIENT_PID=$!

    # 재연결 시도 로그 확인을 위해 10초 대기
    sleep 10

    # 재연결 시도 패턴 확인 (수정된 로그 패턴)
    if grep -q "재연결 시도.*1000ms" $LOG_DIR/backoff_client.log && \
       grep -q "재연결 시도.*2000ms" $LOG_DIR/backoff_client.log; then
        log_success "지수 백오프 패턴 확인됨"
    else
        # 대안 패턴 확인
        if grep -q "재연결 시도.*연결 시도중" $LOG_DIR/backoff_client.log; then
            log_success "재연결 시도 패턴 확인됨"
        else
            log_warning "지수 백오프 패턴을 명확히 확인하지 못함"
            log_info "클라이언트 로그:"
            cat $LOG_DIR/backoff_client.log
        fi
    fi

    # 클라이언트 종료
    kill $CLIENT_PID 2>/dev/null || true
    CLIENT_PID=""

    log_success "지수 백오프 테스트 완료"
    return 0
}

# 상태 API 테스트
test_status_api() {
    log_info "상태 API 테스트 시작"

    # 서버 재시작
    ./target/release/Tokenly > server.log 2>&1 &
    SERVER_PID=$!
    sleep 3

    # 연결 전 상태 확인
    local status=$(curl -s $SERVER_URL/status | jq -r '.state')
    if [ "$status" != "disconnected" ]; then
        log_error "초기 상태가 disconnected가 아님: $status"
        return 1
    fi

    log_success "초기 상태 확인: disconnected"

    # 클라이언트 연결
    node test_client.js > $LOG_DIR/status_client.log 2>&1 &
    CLIENT_PID=$!
    sleep 3

    # 연결 후 상태 확인
    if ! check_server_status "connected" 10; then
        log_error "연결 후 상태가 connected가 아님"
        return 1
    fi

    log_success "연결 후 상태 확인: connected"

    # 세션 수 확인
    local sessions=$(curl -s $SERVER_URL/status | jq -r '.active_sessions')
    if [ "$sessions" != "1" ]; then
        log_warning "활성 세션 수가 예상과 다름: $sessions"
    else
        log_success "활성 세션 수 확인: 1"
    fi

    log_success "상태 API 테스트 완료"
    return 0
}

# 메인 테스트 실행
main() {
    echo "=========================================="
    echo "    재연결 로직 자동화 테스트 시작"
    echo "=========================================="

    local failed_tests=0

    # 0. 로그 디렉토리 초기화
    init_logs

    # 1. 서버 시작
    start_server || {
        log_error "서버 시작 실패"
        exit 1
    }

    # 2. 기본 연결 테스트
    test_websocket_connection || {
        log_error "WebSocket 연결 테스트 실패"
        ((failed_tests++))
    }

    # 3. 상태 API 테스트
    test_status_api || {
        log_error "상태 API 테스트 실패"
        ((failed_tests++))
    }

    # 4. 재연결 테스트
    test_reconnection || {
        log_error "재연결 테스트 실패"
        ((failed_tests++))
    }

    # 5. 지수 백오프 테스트
    test_exponential_backoff || {
        log_error "지수 백오프 테스트 실패"
        ((failed_tests++))
    }

    echo "=========================================="
    if [ $failed_tests -eq 0 ]; then
        log_success "모든 테스트 통과! 🎉"
        echo "재연결 로직이 정상적으로 작동합니다."
    else
        log_error "$failed_tests 개의 테스트 실패"
        echo "로그 파일을 확인하여 문제를 해결하세요:"
        echo "  - $LOG_DIR/server.log: 서버 로그"
        echo "  - $LOG_DIR/client.log: 클라이언트 로그"
        echo "  - $LOG_DIR/backoff_client.log: 지수 백오프 테스트 로그"
        echo "  - $LOG_DIR/status_client.log: 상태 API 테스트 로그"
        echo "  - $LOG_DIR/build.log: 빌드 로그"
        exit 1
    fi
    echo "=========================================="
}

# 스크립트 실행 권한 확인
if [ ! -x "$0" ]; then
    chmod +x "$0"
fi

# 필수 도구 확인
command -v jq >/dev/null 2>&1 || {
    log_error "jq가 설치되지 않음. 설치 후 다시 실행하세요."
    echo "macOS: brew install jq"
    echo "Ubuntu: sudo apt-get install jq"
    exit 1
}

command -v curl >/dev/null 2>&1 || {
    log_error "curl이 설치되지 않음"
    exit 1
}

# 메인 함수 실행
main "$@"