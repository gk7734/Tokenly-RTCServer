#!/usr/bin/env node

const WebSocket = require('ws');

class ReconnectTestClient {
    constructor(url, options = {}) {
        this.url = url;
        this.options = {
            reconnectInterval: 1000,
            maxReconnectAttempts: 5,
            enableHeartbeat: true,
            heartbeatInterval: 30000,
            ...options
        };

        this.ws = null;
        this.reconnectAttempts = 0;
        this.isIntentionalClose = false;
        this.heartbeatTimer = null;
    }

    connect() {
        console.log(`[${new Date().toISOString()}] WebSocket 연결 시도: ${this.url}`);

        this.ws = new WebSocket(this.url);

        this.ws.on('open', () => {
            console.log(`[${new Date().toISOString()}] ✅ WebSocket 연결 성공`);
            this.reconnectAttempts = 0;

            // 테스트 메시지 전송
            this.sendTestMessage();

            // 하트비트 시작
            if (this.options.enableHeartbeat) {
                this.startHeartbeat();
            }
        });

        this.ws.on('message', (data) => {
            const message = data.toString();
            console.log(`[${new Date().toISOString()}] 📨 수신: ${message}`);

            try {
                const parsed = JSON.parse(message);
                this.handleMessage(parsed);
            } catch (e) {
                console.log(`[${new Date().toISOString()}] 📨 원시 메시지: ${message}`);
            }
        });

        this.ws.on('close', (code, reason) => {
            console.log(`[${new Date().toISOString()}] ❌ WebSocket 연결 종료 (코드: ${code}, 이유: ${reason})`);

            this.clearHeartbeat();

            if (!this.isIntentionalClose) {
                this.attemptReconnect();
            }
        });

        this.ws.on('error', (error) => {
            console.error(`[${new Date().toISOString()}] 🚫 WebSocket 오류:`, error.message);
        });

        this.ws.on('ping', () => {
            console.log(`[${new Date().toISOString()}] 🏓 Ping 수신`);
        });

        this.ws.on('pong', () => {
            console.log(`[${new Date().toISOString()}] 🏓 Pong 수신`);
        });
    }

    sendTestMessage() {
        const testMessage = {
            type: "create-peer",
            session_id: `test-session-${Date.now()}`,
            room_id: "test-room-001"
        };

        this.send(JSON.stringify(testMessage));
    }

    handleMessage(message) {
        switch (message.type) {
            case 'peer-created':
                console.log(`[${new Date().toISOString()}] 🎯 피어 생성 응답: ${message.success ? '성공' : '실패'}`);
                break;
            case 'peer-destroyed':
                console.log(`[${new Date().toISOString()}] 🎯 피어 제거 완료`);
                break;
            default:
                console.log(`[${new Date().toISOString()}] 🔄 알 수 없는 메시지 타입: ${message.type}`);
        }
    }

    startHeartbeat() {
        this.heartbeatTimer = setInterval(() => {
            if (this.ws && this.ws.readyState === WebSocket.OPEN) {
                console.log(`[${new Date().toISOString()}] 💓 하트비트 전송`);
                this.ws.ping();
            }
        }, this.options.heartbeatInterval);
    }

    clearHeartbeat() {
        if (this.heartbeatTimer) {
            clearInterval(this.heartbeatTimer);
            this.heartbeatTimer = null;
        }
    }

    attemptReconnect() {
        if (this.reconnectAttempts >= this.options.maxReconnectAttempts) {
            console.error(`[${new Date().toISOString()}] ❌ 최대 재연결 시도 횟수(${this.options.maxReconnectAttempts}) 초과`);
            return;
        }

        this.reconnectAttempts++;
        const delay = this.options.reconnectInterval * Math.pow(2, this.reconnectAttempts - 1);

        console.log(`[${new Date().toISOString()}] 🔄 재연결 시도 ${this.reconnectAttempts}/${this.options.maxReconnectAttempts} - ${delay}ms 후 시도`);

        setTimeout(() => {
            this.connect();
        }, delay);
    }

    send(message) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            console.log(`[${new Date().toISOString()}] 📤 전송: ${message}`);
            this.ws.send(message);
        } else {
            console.warn(`[${new Date().toISOString()}] ⚠️  WebSocket이 열려있지 않음 (상태: ${this.ws ? this.ws.readyState : 'null'})`);
        }
    }

    disconnect() {
        console.log(`[${new Date().toISOString()}] 🔌 의도적 연결 종료`);
        this.isIntentionalClose = true;
        this.clearHeartbeat();
        if (this.ws) {
            this.ws.close();
        }
    }

    // 네트워크 중단 시뮬레이션 (강제 종료)
    simulateNetworkFailure() {
        console.log(`[${new Date().toISOString()}] 💥 네트워크 실패 시뮬레이션 - 연결 강제 종료`);
        if (this.ws) {
            this.ws.terminate(); // 즉시 연결 종료 (close 이벤트 없이)
        }
    }
}

// CLI 사용법
if (require.main === module) {
    const url = process.argv[2] || 'ws://localhost:3003/rtc';

    console.log('🚀 WebSocket 재연결 테스트 클라이언트 시작');
    console.log('사용법:');
    console.log('  q: 종료');
    console.log('  r: 재연결');
    console.log('  f: 네트워크 실패 시뮬레이션');
    console.log('  s: 상태 확인');
    console.log('  m: 테스트 메시지 전송');
    console.log('');

    const client = new ReconnectTestClient(url, {
        reconnectInterval: 1000,
        maxReconnectAttempts: 5,
        enableHeartbeat: true,
        heartbeatInterval: 10000  // 10초마다 하트비트
    });

    client.connect();

    // 키보드 입력 처리 (TTY 환경에서만)
    if (process.stdin.isTTY) {
        process.stdin.setRawMode(true);
        process.stdin.resume();
        process.stdin.setEncoding('utf8');

        process.stdin.on('data', (key) => {
        switch (key.toString().trim().toLowerCase()) {
            case 'q':
                console.log('\n👋 클라이언트 종료');
                client.disconnect();
                process.exit(0);
                break;
            case 'r':
                console.log('\n🔄 수동 재연결');
                client.disconnect();
                setTimeout(() => {
                    client.isIntentionalClose = false;
                    client.connect();
                }, 1000);
                break;
            case 'f':
                console.log('\n💥 네트워크 실패 시뮬레이션');
                client.simulateNetworkFailure();
                break;
            case 's':
                console.log('\n📊 상태 확인 중...');
                require('http').get('http://localhost:3003/status', (res) => {
                    let data = '';
                    res.on('data', chunk => data += chunk);
                    res.on('end', () => {
                        console.log('서버 상태:', JSON.parse(data));
                    });
                }).on('error', err => {
                    console.error('상태 확인 실패:', err.message);
                });
                break;
            case 'm':
                console.log('\n📤 테스트 메시지 전송');
                client.sendTestMessage();
                break;
            }
        });
    } else {
        // TTY가 아닌 환경에서는 10초 후 자동 종료 (테스트 환경)
        setTimeout(() => {
            console.log('\n🤖 자동 테스트 모드 - 10초 후 종료');
            client.disconnect();
            process.exit(0);
        }, 10000);
    }
}

module.exports = ReconnectTestClient;