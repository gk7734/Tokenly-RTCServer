#!/bin/bash

# 웹 테스트 환경 시작 스크립트

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 정리 함수
cleanup() {
    log_info "서비스들을 종료하는 중..."

    # WebSocket 서버 종료
    pkill -f "target/debug/Tokenly" 2>/dev/null || true
    pkill -f "target/release/Tokenly" 2>/dev/null || true

    # 웹 서버 종료
    pkill -f "web_test_server.js" 2>/dev/null || true

    log_info "정리 완료"
}

trap cleanup EXIT INT TERM

echo "======================================================"
echo "🌐 재연결 로직 웹 테스트 환경 시작"
echo "======================================================"

# 필요한 파일 확인
if [ ! -f "test_web.html" ]; then
    log_error "test_web.html 파일을 찾을 수 없습니다"
    exit 1
fi

if [ ! -f "web_test_server.js" ]; then
    log_error "web_test_server.js 파일을 찾을 수 없습니다"
    exit 1
fi

# 기존 프로세스 정리
log_info "기존 프로세스 정리 중..."
cleanup
sleep 2

# WebSocket 서버 빌드 및 시작
log_info "WebSocket 서버 빌드 중..."
if ! cargo build --release > /dev/null 2>&1; then
    log_error "서버 빌드 실패"
    exit 1
fi

log_info "WebSocket 서버 시작 중..."
./target/release/Tokenly > logs/web_test_websocket.log 2>&1 &
WS_SERVER_PID=$!
sleep 3

# WebSocket 서버 상태 확인
if ! curl -s http://localhost:3002/status > /dev/null 2>&1; then
    log_error "WebSocket 서버 시작 실패"
    cat logs/web_test_websocket.log
    exit 1
fi

log_success "WebSocket 서버 시작 완료 (PID: $WS_SERVER_PID)"

# 웹 서버 시작
log_info "웹 서버 시작 중..."
node web_test_server.js > logs/web_test_http.log 2>&1 &
WEB_SERVER_PID=$!
sleep 2

# 웹 서버 상태 확인
if ! curl -s http://localhost:8080 > /dev/null 2>&1; then
    log_error "웹 서버 시작 실패"
    cat logs/web_test_http.log
    exit 1
fi

log_success "웹 서버 시작 완료 (PID: $WEB_SERVER_PID)"

echo "======================================================"
log_success "🎉 웹 테스트 환경이 준비되었습니다!"
echo "======================================================"
echo ""
echo "📍 접속 주소:"
echo "   🌐 웹 테스트 페이지: http://localhost:8080"
echo "   🔧 WebSocket 서버: ws://localhost:3002/rtc"
echo "   📊 서버 상태 API: http://localhost:3002/status"
echo ""
echo "🔧 웹 브라우저에서 테스트 방법:"
echo "   1. http://localhost:8080 접속"
echo "   2. '연결' 버튼 클릭으로 WebSocket 연결"
echo "   3. '네트워크 실패 시뮬레이션' 버튼으로 재연결 테스트"
echo "   4. '테스트 메시지 전송' 버튼으로 통신 테스트"
echo "   5. '서버 상태 확인' 버튼으로 서버 상태 모니터링"
echo ""
echo "🧪 고급 테스트 시나리오:"
echo "   - 시나리오 1: 네트워크 실패 버튼으로 즉시 재연결 테스트"
echo "   - 시나리오 2: 이 터미널에서 Ctrl+C로 서버 종료 후 재시작"
echo "   - 시나리오 3: 설정에서 재연결 파라미터 변경 후 테스트"
echo "   - 시나리오 4: 여러 브라우저 탭에서 동시 연결 테스트"
echo ""
echo "📋 실시간 모니터링:"
echo "   - 연결 상태 표시기"
echo "   - 재연결 시도 횟수 카운터"
echo "   - 실시간 로그 출력"
echo "   - 연결 유지 시간 타이머"
echo ""
echo "💡 팁:"
echo "   - 개발자 도구(F12) Network 탭에서 WebSocket 트래픽 확인 가능"
echo "   - Console 탭에서 추가 디버깅 정보 확인 가능"
echo ""
log_warning "Ctrl+C를 눌러 모든 서비스를 종료할 수 있습니다"
echo ""

# 백그라운드에서 서버 상태 모니터링
while true; do
    sleep 10

    # WebSocket 서버 상태 확인
    if ! curl -s http://localhost:3002/status > /dev/null 2>&1; then
        log_error "WebSocket 서버가 응답하지 않습니다"
        break
    fi

    # 웹 서버 상태 확인
    if ! curl -s http://localhost:8080 > /dev/null 2>&1; then
        log_error "웹 서버가 응답하지 않습니다"
        break
    fi

    # 간단한 상태 출력
    current_time=$(date +"%H:%M:%S")
    echo -ne "\r⏰ 서비스 실행 중... ($current_time) - 웹페이지: http://localhost:8080"
done