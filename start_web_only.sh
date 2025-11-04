#!/bin/bash

# 웹 테스트만 시작 (기존 서버 사용)

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

# 정리 함수
cleanup() {
    log_info "웹 서버를 종료하는 중..."
    pkill -f "web_test_server.js" 2>/dev/null || true
    log_info "정리 완료"
}

trap cleanup EXIT INT TERM

echo "======================================================"
echo "🌐 재연결 로직 웹 테스트 (기존 서버 사용)"
echo "======================================================"

# 기존 WebSocket 서버 확인
log_info "기존 WebSocket 서버 상태 확인 중..."
if curl -s http://localhost:3002/status > /dev/null 2>&1; then
    log_success "✅ WebSocket 서버가 3002 포트에서 실행 중입니다"

    # 서버 상태 출력
    STATUS=$(curl -s http://localhost:3002/status | jq -r '.state')
    SESSIONS=$(curl -s http://localhost:3002/status | jq -r '.active_sessions')
    echo "   📊 현재 상태: $STATUS, 활성 세션: $SESSIONS"
else
    log_error "❌ WebSocket 서버가 실행되지 않고 있습니다"
    echo ""
    echo "💡 해결 방법:"
    echo "   다른 터미널에서 다음 명령어를 실행하세요:"
    echo "   cargo run"
    echo ""
    exit 1
fi

# 필요한 파일 확인
if [ ! -f "test_web.html" ]; then
    log_error "test_web.html 파일을 찾을 수 없습니다"
    exit 1
fi

if [ ! -f "web_test_server.js" ]; then
    log_error "web_test_server.js 파일을 찾을 수 없습니다"
    exit 1
fi

# 기존 웹 서버 정리
pkill -f "web_test_server.js" 2>/dev/null || true
sleep 1

# 로그 디렉토리 생성
mkdir -p logs

# 웹 서버 시작
log_info "웹 서버 시작 중..."
node web_test_server.js > logs/web_only_http.log 2>&1 &
WEB_SERVER_PID=$!
sleep 2

# 웹 서버 상태 확인
if ! curl -s http://localhost:8080 > /dev/null 2>&1; then
    log_error "웹 서버 시작 실패"
    cat logs/web_only_http.log
    exit 1
fi

log_success "웹 서버 시작 완료 (PID: $WEB_SERVER_PID)"

echo "======================================================"
log_success "🎉 웹 테스트 환경이 준비되었습니다!"
echo "======================================================"
echo ""
echo "📍 접속 주소:"
echo "   🌐 웹 테스트 페이지: http://localhost:8080"
echo "   🔧 기존 WebSocket 서버: ws://localhost:3002/rtc"
echo "   📊 서버 상태 API: http://localhost:3002/status"
echo ""
echo "🔧 웹 브라우저에서 테스트 방법:"
echo "   1. http://localhost:8080 접속"
echo "   2. '연결' 버튼 클릭으로 WebSocket 연결"
echo "   3. '네트워크 실패 시뮬레이션' 버튼으로 재연결 테스트"
echo "   4. '테스트 메시지 전송' 버튼으로 통신 테스트"
echo "   5. '서버 상태 확인' 버튼으로 서버 상태 모니터링"
echo ""
echo "🧪 테스트 시나리오:"
echo "   ✅ 네트워크 실패 버튼으로 즉시 재연결 테스트"
echo "   ✅ 다른 터미널에서 cargo run 재시작으로 서버 재시작 테스트"
echo "   ✅ 설정에서 재연결 파라미터 변경 후 테스트"
echo "   ✅ 여러 브라우저 탭에서 동시 연결 테스트"
echo ""
echo "💡 재연결 로직 작동 확인 포인트:"
echo "   🔄 지수 백오프: 1초 → 2초 → 4초 → 8초 → 16초"
echo "   📊 실시간 상태 변화: 연결됨 → 끊어짐 → 재연결중 → 연결됨"
echo "   📈 통계 업데이트: 재연결 시도 횟수, 연결 유지 시간"
echo ""
log_success "웹 테스트 준비 완료! 브라우저에서 http://localhost:8080 를 열어보세요!"
echo ""

# 백그라운드에서 서버 상태 모니터링
while true; do
    sleep 10

    # WebSocket 서버 상태 확인
    if ! curl -s http://localhost:3002/status > /dev/null 2>&1; then
        log_error "WebSocket 서버가 응답하지 않습니다"
        echo "💡 다른 터미널에서 'cargo run'으로 서버를 재시작하세요"
    fi

    # 웹 서버 상태 확인
    if ! curl -s http://localhost:8080 > /dev/null 2>&1; then
        log_error "웹 서버가 응답하지 않습니다"
        break
    fi

    # 간단한 상태 출력
    current_time=$(date +"%H:%M:%S")
    echo -ne "\r⏰ 웹 서버 실행 중... ($current_time) - 웹페이지: http://localhost:8080"
done