#!/usr/bin/env node

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 8080;

// MIME 타입 매핑
const mimeTypes = {
    '.html': 'text/html',
    '.js': 'text/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.gif': 'image/gif',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon'
};

const server = http.createServer((req, res) => {
    console.log(`${new Date().toISOString()} - ${req.method} ${req.url}`);

    // CORS 헤더 추가
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }

    let filePath = req.url === '/' ? '/test_web.html' : req.url;
    filePath = path.join(__dirname, filePath);

    // 파일 확장자 확인
    const ext = path.extname(filePath).toLowerCase();
    const mimeType = mimeTypes[ext] || 'application/octet-stream';

    fs.readFile(filePath, (err, content) => {
        if (err) {
            if (err.code === 'ENOENT') {
                // 404 - 파일을 찾을 수 없음
                res.writeHead(404, { 'Content-Type': 'text/html' });
                res.end(`
                    <html>
                        <body>
                            <h1>404 - 파일을 찾을 수 없습니다</h1>
                            <p>요청한 파일: ${req.url}</p>
                            <a href="/">테스트 페이지로 돌아가기</a>
                        </body>
                    </html>
                `);
            } else {
                // 500 - 서버 오류
                res.writeHead(500, { 'Content-Type': 'text/html' });
                res.end(`
                    <html>
                        <body>
                            <h1>500 - 서버 오류</h1>
                            <p>오류: ${err.message}</p>
                        </body>
                    </html>
                `);
            }
        } else {
            // 파일 정상 제공
            res.writeHead(200, { 'Content-Type': mimeType });
            res.end(content);
        }
    });
});

server.listen(PORT, () => {
    console.log('='.repeat(50));
    console.log('🌐 웹 테스트 서버가 시작되었습니다!');
    console.log(`📍 주소: http://localhost:${PORT}`);
    console.log(`📋 테스트 페이지: http://localhost:${PORT}/test_web.html`);
    console.log('='.repeat(50));
    console.log('');
    console.log('✅ 사용 방법:');
    console.log('1. 브라우저에서 위 주소로 접속');
    console.log('2. "연결" 버튼으로 WebSocket 연결');
    console.log('3. "네트워크 실패 시뮬레이션" 버튼으로 재연결 테스트');
    console.log('4. 서버를 Ctrl+C로 종료 후 재시작해서 재연결 확인');
    console.log('');
    console.log('🔧 재연결 테스트 시나리오:');
    console.log('- 시나리오 1: 네트워크 실패 버튼으로 즉시 재연결 테스트');
    console.log('- 시나리오 2: 서버 재시작으로 실제 재연결 테스트');
    console.log('- 시나리오 3: 설정 변경으로 다양한 재연결 파라미터 테스트');
    console.log('');
});

server.on('error', (err) => {
    if (err.code === 'EADDRINUSE') {
        console.error(`❌ 포트 ${PORT}이 이미 사용중입니다.`);
        console.error('다른 포트를 사용하거나 실행중인 프로세스를 종료하세요.');
    } else {
        console.error('❌ 서버 오류:', err.message);
    }
});

// 종료 시그널 처리
process.on('SIGINT', () => {
    console.log('\n👋 웹 테스트 서버를 종료합니다...');
    server.close(() => {
        console.log('✅ 서버가 정상적으로 종료되었습니다.');
        process.exit(0);
    });
});